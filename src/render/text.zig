//! Font atlas + text shaping (HarfBuzz) + glyph-index rasterization (stb_truetype).
//!
//! Glyphs are cached by *glyph index* (not codepoint) and rasterized on demand at
//! a fixed reference size into a shelf-packed single-channel atlas; the renderer
//! scales the quad to the requested font size. HarfBuzz drives shaping (ligatures,
//! kerning, RTL) and advances; stb_truetype rasterizes each glyph by index. When a
//! new glyph is added the atlas is marked `dirty` so the GPU backend re-uploads it.

const std = @import("std");
const lb = @import("linebreak.zig");
const Shaper = @import("shaper.zig").Shaper;
pub const ShapedGlyph = @import("shaper.zig").ShapedGlyph;

/// Default line-height multiplier, shared by measurement, render and the caret.
/// A text node may override it with the `line_height` style (see `lineHeightWith`).
/// Prefer `lineHeight(size)` over multiplying by this yourself.
pub const LINE_HEIGHT_FACTOR: f32 = 1.55;

/// `max_width` that means "no soft wrap" (unbounded): lines break only at `\n`.
pub const NO_WRAP: f32 = std.math.inf(f32);

/// Height of one line slot at `size` with the default multiplier. The one
/// conversion from font size to line box: measurement, wrapping, hit-testing, the
/// caret and the renderer all go through it (or `lineHeightWith`), so none of them
/// can drift from the others.
pub fn lineHeight(size: f32) f32 {
    return size * LINE_HEIGHT_FACTOR;
}

/// Height of one line slot at `size` with an explicit multiplier (CSS unitless
/// `line-height`). A non-positive or non-finite factor falls back to the default,
/// so a bad style value can never collapse text to zero height.
pub fn lineHeightWith(size: f32, factor: f32) f32 {
    return size * sanitizeLineHeight(factor);
}

/// `factor` if usable as a line-height multiplier, else `LINE_HEIGHT_FACTOR`.
pub fn sanitizeLineHeight(factor: f32) f32 {
    return if (std.math.isFinite(factor) and factor > 0) factor else LINE_HEIGHT_FACTOR;
}

/// Average advance as a fraction of the font size — the stand-in for real shaping
/// when no font is available. Calibrated on the bundled UI face (8px at 16px).
pub const FALLBACK_ADVANCE_RATIO: f32 = 0.5;

/// Advance per character at `size`, for the **no-font** path only: headless tests
/// and any build where text measurement wasn't injected. Everything with a font
/// measures for real (`TextMeasure.width`) — this exists so the estimate at least
/// scales with the font size instead of being frozen at one size's numbers.
pub fn fallbackCharWidth(size: f32) f32 {
    return size * FALLBACK_ADVANCE_RATIO;
}

const stb = @cImport({
    @cInclude("stb_truetype.h");
});

pub const ATLAS_WIDTH = 2048;
pub const ATLAS_HEIGHT = 2048;
/// Reference rasterization size (px). UI text (≤ this) scales down → crisp.
pub const REF_PX: f32 = 64.0;
const PAD: u32 = 2;

pub const TextLine = struct {
    start_index: usize,
    end_index: usize,
    width: f32,
    // Range into `TextLayoutInfo.shaped` for this line (filled by `ensureShaped`).
    glyph_start: usize = 0,
    glyph_count: usize = 0,
};

pub const TextLayoutInfo = struct {
    lines: std.array_list.Managed(TextLine),
    max_width: f32,
    total_height: f32,
    /// Font size this layout was measured at — also the size `shaped` is built at.
    font_size: f32 = 0,
    /// Cached HarfBuzz-shaped glyphs for every line, concatenated; each line indexes
    /// into it via `glyph_start`/`glyph_count`. Built lazily once per layout (see
    /// `ensureShaped`) so the render path never re-shapes a static string per frame.
    /// Invalidated naturally: the whole struct is rebuilt when the node is layout-dirty.
    shaped: std.array_list.Managed(ShapedGlyph),
    shaped_built: bool = false,
    /// Preferred font index this layout was measured with (0 = primary). Travels
    /// with the layout so `ensureShaped`/caret metrics shape with the same face the
    /// measurement used (bold/mono selection stays consistent across measure→draw).
    preferred_font: u32 = 0,
    /// Extra tracking (px) added to every glyph advance, measured with this layout
    /// so `ensureShaped` and caret math stay in step with the measured widths.
    letter_spacing: f32 = 0,
    /// Line-height multiplier this layout was measured with (the node's
    /// `line_height` style, else `LINE_HEIGHT_FACTOR`). Travels with the layout so
    /// the renderer, caret and hit-testing step lines by the same slot as
    /// `total_height`.
    line_height_factor: f32 = LINE_HEIGHT_FACTOR,

    pub fn deinit(self: *TextLayoutInfo) void {
        self.lines.deinit();
        self.shaped.deinit();
    }
};

/// A face's vertical proportions, as fractions of the em. Passing these in (rather
/// than reaching for a `FontAtlas`) is what lets `verticalLayoutFor` be the single
/// implementation for both the engine — which has the real font — and the component
/// layer's headless path, which has only these defaults.
pub const FontMetrics = struct {
    /// Top of the capitals. Optical centering is defined on this.
    cap_ratio: f32 = 0.72,
    ascent_ratio: f32 = 0.9,
    descent_ratio: f32 = 0.21,
    /// Offset from a slot's center down to the icon face's baseline.
    icon_vcenter_ratio: f32 = 0,
};

/// Text's vertical geometry inside a box, all in px from the box's top edge.
/// Produced only by `FontAtlas.verticalLayout` — see the note there on why this is
/// the single point of truth.
pub const VerticalLayout = struct {
    /// Height of one line slot (`size × LINE_HEIGHT_FACTOR`).
    line_height: f32,
    /// Top of the first line slot; add `line_height` per subsequent line.
    block_offset: f32,
    /// Baseline of the first line — where the pen sits.
    baseline: f32,
    /// Top of the capitals on the first line. `cap_top` and `box_height − baseline`
    /// are equal by construction: that equality *is* optical centering.
    cap_top: f32,
    /// Bottom of the deepest descender on the first line. Past the box's bottom edge
    /// on a tight box — descenders are meant to hang, so this is not a defect.
    ink_bottom: f32,
    /// Baseline for glyphs from the icon face, which centers on the em box instead.
    icon_baseline: f32,
    /// Top of the caret / selection band, and its height: the first line's slot,
    /// clipped to the box. Widgets that draw a caret or a highlight take these
    /// instead of picking their own numbers, so the bar can't drift from the glyphs
    /// when the font size or the box height changes.
    caret_top: f32,
    caret_height: f32,
};

/// The one implementation of text's vertical geometry — see `FontAtlas.verticalLayout`,
/// which is how the engine reaches it. Free-standing and pure so a caller without a
/// font (headless widgets, tests) computes the *same* geometry from `FontMetrics{}`
/// defaults rather than inventing its own.
pub fn verticalLayoutFor(m: FontMetrics, size: f32, box_height: f32, num_lines: usize) VerticalLayout {
    return verticalLayoutWith(m, size, box_height, num_lines, LINE_HEIGHT_FACTOR);
}

// Alias so `FontAtlas.verticalLayoutWith` can reach the free function below
// without the method name shadowing it.
const text_vertical_with = verticalLayoutWith;

/// `verticalLayoutFor` with an explicit line-height multiplier (a node's
/// `line_height` style). The cap band stays centered in each slot, so a taller
/// line adds leading evenly above and below the text.
pub fn verticalLayoutWith(m: FontMetrics, size: f32, box_height: f32, num_lines: usize, line_height_factor: f32) VerticalLayout {
    const line_height = lineHeightWith(size, line_height_factor);
    const lines: f32 = @floatFromInt(@max(@as(usize, 1), num_lines));
    const block_height = line_height * lines;
    // A single line centers even when its slot is taller than the box (a 20px text
    // node at font 16 has a 24.8px slot); clamping there would pin it to the top and
    // spill the leading out the bottom. Multi-line keeps the clamp: shifting a tall
    // block up cuts the first lines instead of the last.
    const block_offset = if (lines > 1)
        @max(@as(f32, 0), (box_height - block_height) / 2.0)
    else
        (box_height - block_height) / 2.0;
    const cap = m.cap_ratio * size;
    const baseline = block_offset + (line_height + cap) / 2.0;
    const caret_top = @max(@as(f32, 0), block_offset);
    const caret_bottom = @min(box_height, block_offset + line_height);
    return .{
        .line_height = line_height,
        .block_offset = block_offset,
        .baseline = baseline,
        .cap_top = baseline - cap,
        .ink_bottom = baseline + m.descent_ratio * size,
        // Icon faces fill the em box with no descent, so they center on the slot's
        // midline instead of sitting on the text baseline (see icon_vcenter_ratio).
        .icon_baseline = block_offset + line_height / 2.0 + m.icon_vcenter_ratio * size,
        .caret_top = caret_top,
        .caret_height = @max(@as(f32, 0), caret_bottom - caret_top),
    };
}

/// A rasterized glyph cached in the atlas. `ox/oy` are the bitmap's top-left
/// offset from the pen baseline at REF_PX (oy negative = above baseline). UVs are
/// normalized atlas coordinates.
pub const Glyph = struct {
    s0: f32,
    t0: f32,
    s1: f32,
    t1: f32,
    ox: f32,
    oy: f32,
    w: u32,
    h: u32,
};

/// One loaded font: its owned TTF bytes plus the stb (rasterize) and HarfBuzz
/// (shape) handles that reference them. Copyable by value — neither stb's
/// `fontinfo` nor HarfBuzz's handles store a pointer back into this struct (they
/// reference the heap-stable `ttf`), so the stack's ArrayList may freely realloc.
const Font = struct {
    ttf: []u8,
    info: stb.stbtt_fontinfo,
    shaper: Shaper,
    ref_scale: f32, // stb scale for REF_PX
    /// Cap height as a fraction of the em — the top of the capitals, measured off
    /// 'H'. Optical centering is defined on this band, not on ascent/descent (see
    /// `FontAtlas.baselineInSlot`), and it varies enough between faces (a bold or a
    /// mono is not the primary) that it has to be per-font.
    cap_ratio: f32,

    fn init(allocator: std.mem.Allocator, ttf_data: []const u8) !Font {
        const ttf = try allocator.dupe(u8, ttf_data);
        errdefer allocator.free(ttf);

        var info: stb.stbtt_fontinfo = undefined;
        // Bounded, not stbtt_InitFont: every font Celeris loads — app-supplied
        // bytes across the C-ABI, discovered system fonts, bundled assets —
        // goes through this one path, so this is the one call site to arm
        // against CVE-2026-18497 (stbtt__GetGlyphShapeTT reads past a
        // malformed font's buffer with no length to check against; see the
        // patch notes on stbtt_fontinfo.data_end in vendor/stb_truetype.h).
        if (stb.stbtt_InitFontBounded(&info, ttf.ptr, @intCast(ttf.len), stb.stbtt_GetFontOffsetForIndex(ttf.ptr, 0)) == 0) {
            return error.FontInitFailed;
        }

        var shaper = try Shaper.init(allocator, ttf);
        errdefer shaper.deinit();

        return .{
            .ttf = ttf,
            .info = info,
            .shaper = shaper,
            .ref_scale = stb.stbtt_ScaleForMappingEmToPixels(&info, REF_PX),
            .cap_ratio = capRatio(&info),
        };
    }

    /// Cap height / em, from 'H'’s bounding box. A face with no 'H' (icon fonts,
    /// CJK-only fallbacks) falls back to a fraction of the ascent — those runs are
    /// centered by their own rule anyway (see `icon_vcenter_ratio`).
    fn capRatio(info: *stb.stbtt_fontinfo) f32 {
        const inv_upem = stb.stbtt_ScaleForMappingEmToPixels(info, 1.0);
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        if (stb.stbtt_GetCodepointBox(info, 'H', &x0, &y0, &x1, &y1) != 0 and y1 > 0) {
            return @as(f32, @floatFromInt(y1)) * inv_upem;
        }
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(info, &asc, &desc, &gap);
        return @as(f32, @floatFromInt(asc)) * inv_upem * 0.72;
    }

    fn deinit(self: *Font, allocator: std.mem.Allocator) void {
        self.shaper.deinit();
        allocator.free(self.ttf);
    }

    /// True if this font has a (non-.notdef) glyph for the codepoint.
    fn covers(self: *Font, codepoint: u32) bool {
        return stb.stbtt_FindGlyphIndex(&self.info, @intCast(codepoint)) != 0;
    }
};

/// Decodes the next codepoint at `i.*`, advancing `i.*`. Tolerant of malformed
/// UTF-8: a bad byte is returned as-is and consumed as one byte.
fn decodeNext(text: []const u8, i: *usize) u32 {
    const first = text[i.*];
    const len = std.unicode.utf8ByteSequenceLength(first) catch {
        i.* += 1;
        return first;
    };
    if (i.* + len > text.len) {
        i.* += 1;
        return first;
    }
    const cp = std.unicode.utf8Decode(text[i.* .. i.* + len]) catch {
        i.* += 1;
        return first;
    };
    i.* += len;
    return cp;
}

/// Semantic font selection for a text node. Orthogonal weight×family collapsed
/// into four roles; each maps to a registered face (see `FontAtlas.addRoleFont`).
/// A role with no registered face degrades gracefully to the primary font.
pub const FontRole = enum(u8) {
    default = 0,
    bold = 1,
    mono = 2,
    mono_bold = 3,
};

/// Decodes a `font_role` style ordinal (stored as `.number`) into a `FontRole`,
/// clamping out-of-range values to `.default`.
pub fn roleFromOrdinal(n: f32) FontRole {
    if (n < 0 or n > 3) return .default;
    return @enumFromInt(@as(u8, @intFromFloat(n)));
}

pub const FontAtlas = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    /// Fallback stack: `[0]` is the primary; later entries cover glyphs the
    /// primary lacks (CJK, emoji, symbols). One shared atlas across all fonts.
    fonts: std.array_list.Managed(Font),
    /// Cached by `(font_index << 32) | glyph_id` so the same glyph index in two
    /// different fallback fonts never collides.
    glyphs: std.AutoHashMap(u64, Glyph),
    pen_x: u32,
    pen_y: u32,
    row_h: u32,
    dirty: bool,
    /// Index (in `fonts`) of the bundled icon font, if registered. Glyphs from
    /// this font are vertically centered on the font's em-box midline instead of
    /// sitting on the text baseline — icon fonts fill the em box with no descent,
    /// so the baseline heuristic (tuned for text) would push them visually up.
    icon_font_index: ?u32 = null,
    /// Indices (in `fonts`) of the faces registered for the non-default roles, if
    /// any. Unset roles resolve to the primary (font 0) — see `fontIndexForRole`.
    bold_font_index: ?u32 = null,
    mono_font_index: ?u32 = null,
    mono_bold_font_index: ?u32 = null,
    /// Signed offset (as a fraction of font size) from a line-slot's vertical
    /// center down to where the icon font's baseline must sit so the em-box
    /// midline lands on that center: `(ascent + descent) / (2 * unitsPerEm)`.
    /// Per-glyph bbox centering fails here — many icon glyphs (e.g. the minimize
    /// bar) have a loose bitmap box with empty space, so their ink isn't box-centered.
    icon_vcenter_ratio: f32 = 0,
    /// Primary font's vertical metrics as fractions of the em, cached at init:
    /// `ascent_ratio` above the baseline, `descent_ratio` below it (positive).
    /// One line has one baseline, so these come from font 0 even when a run falls
    /// back to another face — a per-glyph baseline would make a mixed-script line
    /// wobble. Defaults are a sane stand-in until `init` fills them in.
    ascent_ratio: f32 = 0.9,
    descent_ratio: f32 = 0.21,

    pub fn init(allocator: std.mem.Allocator, ttf_data: []const u8, font_height: f32) !FontAtlas {
        _ = font_height; // glyphs rasterize at REF_PX and scale per draw

        var fonts = std.array_list.Managed(Font).init(allocator);
        errdefer fonts.deinit();
        const primary = try Font.init(allocator, ttf_data);
        try fonts.append(primary);

        const pixels = try allocator.alloc(u8, ATLAS_WIDTH * ATLAS_HEIGHT);
        @memset(pixels, 0);

        // Vertical metrics of the primary face, normalized to the em — the basis
        // for `baselineInSlot`.
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(&fonts.items[0].info, &asc, &desc, &gap);
        const inv_upem = stb.stbtt_ScaleForMappingEmToPixels(&fonts.items[0].info, 1.0);

        return .{
            .allocator = allocator,
            .pixels = pixels,
            .fonts = fonts,
            .glyphs = std.AutoHashMap(u64, Glyph).init(allocator),
            .pen_x = PAD,
            .pen_y = PAD,
            .row_h = 0,
            .dirty = true,
            .ascent_ratio = @as(f32, @floatFromInt(asc)) * inv_upem,
            .descent_ratio = -@as(f32, @floatFromInt(desc)) * inv_upem, // hhea descent is negative
        };
    }

    /// Baseline offset from the top of a `line_height`-tall line slot, for text at
    /// `size` drawn with face `font_index`.
    ///
    /// Optical centering is defined on the **cap band** — cap height down to the
    /// alphabetic baseline — not on the font's ascent/descent. Ascent carries accent
    /// room and descent carries descenders, neither of which the eye reads as the
    /// text's extent, so centering that band leaves the letters looking low. This is
    /// what CSS `text-box: trim-both cap alphabetic` trims to, and what designers
    /// mean by centering on cap height: equal space above the capitals and below the
    /// baseline, with descenders allowed to hang past the bottom.
    ///
    /// Prefer `verticalLayout` — this is the per-slot piece of it, kept public for
    /// callers that already know their slot.
    pub fn baselineInSlot(self: *const FontAtlas, font_index: u32, size: f32, line_height: f32) f32 {
        const idx = if (font_index < self.fonts.items.len) font_index else 0;
        const cap = self.fonts.items[idx].cap_ratio * size;
        return (line_height + cap) / 2.0;
    }

    /// Where text sits vertically inside a box — **the** answer, for the renderer,
    /// for widgets, and for tests. Everything is measured in px from the box's top
    /// edge, for text at `size` drawn with face `font_index` over `num_lines` lines.
    ///
    /// This is deliberately the single point of truth: the same three rules
    /// (line slot = size × LINE_HEIGHT_FACTOR, block centered in the box, baseline
    /// centering the cap band in its slot) were previously spread across the render
    /// path and re-derived by callers, which is how the box, the caret and the glyphs
    /// ended up disagreeing. Anything that needs to know where a glyph, a baseline or
    /// a caret lands must come through here.
    pub fn verticalLayout(self: *const FontAtlas, font_index: u32, size: f32, box_height: f32, num_lines: usize) VerticalLayout {
        return verticalLayoutFor(self.metricsOf(font_index), size, box_height, num_lines);
    }

    /// `verticalLayout` with an explicit line-height multiplier (a node's
    /// `line_height` style — the renderer passes the measured layout's factor).
    pub fn verticalLayoutWith(self: *const FontAtlas, font_index: u32, size: f32, box_height: f32, num_lines: usize, line_height_factor: f32) VerticalLayout {
        return text_vertical_with(self.metricsOf(font_index), size, box_height, num_lines, line_height_factor);
    }

    /// Vertical proportions of face `font_index` (out of range → the primary).
    pub fn metricsOf(self: *const FontAtlas, font_index: u32) FontMetrics {
        const idx = if (font_index < self.fonts.items.len) font_index else 0;
        return .{
            .cap_ratio = self.fonts.items[idx].cap_ratio,
            .ascent_ratio = self.ascent_ratio,
            .descent_ratio = self.descent_ratio,
            .icon_vcenter_ratio = self.icon_vcenter_ratio,
        };
    }

    /// Appends a fallback font to the stack. Call before rendering; ignored-safe
    /// to skip (a font that fails to load just isn't added). Best-effort: a bad
    /// TTF returns an error the caller can swallow.
    pub fn addFallback(self: *FontAtlas, ttf_data: []const u8) !void {
        const f = try Font.init(self.allocator, ttf_data);
        try self.fonts.append(f);
    }

    /// Like `addFallback`, but tags the added font as the icon font so its glyphs
    /// are bbox-centered at draw time (see `icon_font_index`). Register it before
    /// the CJK/symbol fallbacks so its private-use codepoints resolve to it.
    pub fn addIconFont(self: *FontAtlas, ttf_data: []const u8) !void {
        try self.addFallback(ttf_data);
        const idx = self.fonts.items.len - 1;
        self.icon_font_index = @intCast(idx);
        // Precompute the em-center offset ratio from the font's vertical metrics.
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(&self.fonts.items[idx].info, &asc, &desc, &gap);
        // ScaleForMappingEmToPixels(1.0) == 1/unitsPerEm.
        const inv_upem = stb.stbtt_ScaleForMappingEmToPixels(&self.fonts.items[idx].info, 1.0);
        self.icon_vcenter_ratio = (@as(f32, @floatFromInt(asc)) + @as(f32, @floatFromInt(desc))) * 0.5 * inv_upem;
    }

    /// Registers `ttf` as the face for `role` (bold / mono / mono_bold), appending
    /// it to the fallback stack and recording its index. Best-effort: a bad TTF
    /// returns an error the caller can swallow (the role then stays unregistered).
    /// `.default` is the primary and cannot be reassigned here: it is `fonts[0]`,
    /// not an append to the fallback stack, and every cached glyph is keyed by font
    /// index — re-basing it under a live atlas would silently invalidate them. An
    /// app chooses its primary by handing the bytes to `FontAtlas.init` instead
    /// (`AppOptions.fonts.primary` → `c_api.setAppFonts`).
    pub fn addRoleFont(self: *FontAtlas, role: FontRole, ttf_data: []const u8) !void {
        if (role == .default) return;
        try self.addFallback(ttf_data);
        const idx: u32 = @intCast(self.fonts.items.len - 1);
        switch (role) {
            .default => unreachable,
            .bold => self.bold_font_index = idx,
            .mono => self.mono_font_index = idx,
            .mono_bold => self.mono_bold_font_index = idx,
        }
    }

    /// Whether `role` has a face of its own registered (as opposed to degrading to
    /// the primary). `.default` is always satisfied — `fonts[0]` exists by construction.
    pub fn hasRoleFont(self: *const FontAtlas, role: FontRole) bool {
        return switch (role) {
            .default => true,
            .bold => self.bold_font_index != null,
            .mono => self.mono_font_index != null,
            .mono_bold => self.mono_bold_font_index != null,
        };
    }

    /// Resolves a role to a concrete font index, degrading to a related face and
    /// finally the primary (0) when the exact face isn't registered.
    pub fn fontIndexForRole(self: *const FontAtlas, role: FontRole) u32 {
        return switch (role) {
            .default => 0,
            .bold => self.bold_font_index orelse 0,
            .mono => self.mono_font_index orelse 0,
            .mono_bold => self.mono_bold_font_index orelse self.mono_font_index orelse self.bold_font_index orelse 0,
        };
    }

    pub fn deinit(self: *FontAtlas) void {
        self.glyphs.deinit();
        for (self.fonts.items) |*f| f.deinit(self.allocator);
        self.fonts.deinit();
        self.allocator.free(self.pixels);
    }

    /// Index of the font covering `codepoint`. A non-zero `preferred` face wins
    /// when it covers the codepoint (this is how bold/mono text routes to its
    /// face); otherwise the fallback stack is scanned in order. 0 if none covers
    /// it (the primary then renders its .notdef box).
    fn fontFor(self: *FontAtlas, codepoint: u32, preferred: u32) u32 {
        if (preferred != 0 and preferred < self.fonts.items.len and
            self.fonts.items[preferred].covers(codepoint)) return preferred;
        for (self.fonts.items, 0..) |*f, i| {
            if (f.covers(codepoint)) return @intCast(i);
        }
        return 0;
    }

    fn glyphKey(font_index: u32, glyph_id: u32, size_px: u32) u64 {
        return (@as(u64, font_index) << 48) | (@as(u64, size_px) << 32) | glyph_id;
    }

    /// Returns the cached glyph, rasterizing it from `font_index`'s font into the
    /// shared atlas on first use. A glyph with no bitmap (e.g. space) is cached
    /// with w=h=0.
    pub fn getGlyph(self: *FontAtlas, font_index: u32, glyph_id: u32, physical_size: f32) ?Glyph {
        const fidx = if (font_index < self.fonts.items.len) font_index else 0;
        const size_clamped = @max(1.0, physical_size);
        const size_px = @as(u32, @intFromFloat(size_clamped));
        const key = glyphKey(fidx, glyph_id, size_px);
        if (self.glyphs.get(key)) |g| return g;

        const font = &self.fonts.items[fidx];
        const ref_scale = stb.stbtt_ScaleForMappingEmToPixels(&font.info, size_clamped);

        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stb.stbtt_GetGlyphBitmapBox(&font.info, @intCast(glyph_id), ref_scale, ref_scale, &x0, &y0, &x1, &y1);
        const w: u32 = @intCast(@max(0, x1 - x0));
        const h: u32 = @intCast(@max(0, y1 - y0));

        var glyph = Glyph{
            .s0 = 0,
            .t0 = 0,
            .s1 = 0,
            .t1 = 0,
            .ox = @floatFromInt(x0),
            .oy = @floatFromInt(y0),
            .w = w,
            .h = h,
        };

        if (w > 0 and h > 0) {
            // Shelf-pack: wrap to a new row when the glyph won't fit.
            if (self.pen_x + w + PAD > ATLAS_WIDTH) {
                self.pen_x = PAD;
                self.pen_y += self.row_h + PAD;
                self.row_h = 0;
            }
            if (self.pen_y + h + PAD > ATLAS_HEIGHT) {
                // Atlas full — cache as empty so we don't retry every frame.
                self.glyphs.put(key, .{ .s0 = 0, .t0 = 0, .s1 = 0, .t1 = 0, .ox = 0, .oy = 0, .w = 0, .h = 0 }) catch {};
                return self.glyphs.get(key);
            }
            const px = self.pen_x;
            const py = self.pen_y;
            // Rasterize directly into the atlas at (px, py) with the atlas stride.
            const dst = self.pixels.ptr + (py * ATLAS_WIDTH + px);
            stb.stbtt_MakeGlyphBitmap(&font.info, dst, @intCast(w), @intCast(h), ATLAS_WIDTH, ref_scale, ref_scale, @intCast(glyph_id));

            glyph.s0 = @as(f32, @floatFromInt(px)) / ATLAS_WIDTH;
            glyph.t0 = @as(f32, @floatFromInt(py)) / ATLAS_HEIGHT;
            glyph.s1 = @as(f32, @floatFromInt(px + w)) / ATLAS_WIDTH;
            glyph.t1 = @as(f32, @floatFromInt(py + h)) / ATLAS_HEIGHT;

            self.pen_x += w + PAD;
            self.row_h = @max(self.row_h, h);
            self.dirty = true;
        }

        self.glyphs.put(key, glyph) catch return glyph;
        return glyph;
    }

    /// Glyph index for a Unicode codepoint in the primary font (0 = .notdef).
    pub fn glyphIndex(self: *FontAtlas, codepoint: u32) u32 {
        return @intCast(stb.stbtt_FindGlyphIndex(&self.fonts.items[0].info, @intCast(codepoint)));
    }

    /// Advance width (px) of a single codepoint's glyph at `font_size` — used for
    /// line-wrapping decisions (HarfBuzz is used for final positioning/measuring).
    /// Uses the same fallback font that would render the codepoint.
    pub fn codepointAdvancePx(self: *FontAtlas, codepoint: u32, font_size: f32) f32 {
        return self.codepointAdvancePxPref(codepoint, font_size, 0, 0);
    }
    pub fn codepointAdvancePxPref(self: *FontAtlas, codepoint: u32, font_size: f32, preferred: u32, ls: f32) f32 {
        const font = &self.fonts.items[self.fontFor(codepoint, preferred)];
        const gi = stb.stbtt_FindGlyphIndex(&font.info, @intCast(codepoint));
        var adv: c_int = 0;
        var lsb: c_int = 0;
        stb.stbtt_GetGlyphHMetrics(&font.info, gi, &adv, &lsb);
        return @as(f32, @floatFromInt(adv)) * stb.stbtt_ScaleForMappingEmToPixels(&font.info, font_size) + ls;
    }

    /// Exact width (px) of a run via HarfBuzz shaping, segmenting across the
    /// fallback stack so fallback runs measure with their own font's metrics.
    pub fn measureWidth(self: *FontAtlas, text: []const u8, font_size: f32) f32 {
        return self.measureWidthPref(text, font_size, 0, 0);
    }
    pub fn measureWidthPref(self: *FontAtlas, text: []const u8, font_size: f32, preferred: u32, ls: f32) f32 {
        // With tracking the per-glyph advances shift, so measure off the shaped run
        // (which already carries the spacing) instead of HarfBuzz's raw run width.
        if (ls != 0) {
            var glyphs = std.array_list.Managed(ShapedGlyph).init(self.allocator);
            defer glyphs.deinit();
            self.shapePref(text, font_size, preferred, ls, &glyphs) catch return 0;
            var w: f32 = 0;
            for (glyphs.items) |sg| w += sg.x_advance;
            return w;
        }
        var total: f32 = 0;
        var i: usize = 0;
        var run_start: usize = 0;
        var run_font: u32 = 0;
        var have_run = false;
        while (i < text.len) {
            const cp_start = i;
            const cp = decodeNext(text, &i);
            const fidx = self.fontFor(cp, preferred);
            if (!have_run) {
                run_font = fidx;
                run_start = cp_start;
                have_run = true;
            } else if (fidx != run_font) {
                total += self.fonts.items[run_font].shaper.measureWidth(text[run_start..cp_start], font_size);
                run_font = fidx;
                run_start = cp_start;
            }
        }
        if (have_run and run_start < text.len) {
            total += self.fonts.items[run_font].shaper.measureWidth(text[run_start..], font_size);
        }
        return total;
    }

    /// Width (px) of a run, for callers that used to ask for physical-pixel
    /// snapping: `scale` is accepted and ignored, and the exact width is returned.
    ///
    /// Snapping used to accumulate `@round(adv * scale)` per glyph to mirror how the
    /// renderer advanced its pen. That drifted — up to ±6px on a 28-char label —
    /// which is why widths measured here disagreed with the box the layout sized,
    /// clipping the tail. The renderer now advances exactly and snaps only where each
    /// glyph is drawn, so exact is the one width everything agrees on.
    pub fn measureWidthSnapped(self: *FontAtlas, text: []const u8, font_size: f32, scale: f32) f32 {
        return self.measureWidthSnappedPref(text, font_size, scale, 0, 0);
    }
    pub fn measureWidthSnappedPref(self: *FontAtlas, text: []const u8, font_size: f32, scale: f32, preferred: u32, ls: f32) f32 {
        _ = scale;
        return self.measureWidthPref(text, font_size, preferred, ls);
    }

    /// Shapes a run via HarfBuzz, appending positioned glyphs to `out`. Segments
    /// the text into maximal runs each covered by a single font (preferring the
    /// primary, then fallbacks) and tags every glyph with its `font_index`.
    pub fn shape(self: *FontAtlas, text: []const u8, font_size: f32, out: *std.array_list.Managed(ShapedGlyph)) !void {
        return self.shapePref(text, font_size, 0, 0, out);
    }
    pub fn shapePref(self: *FontAtlas, text: []const u8, font_size: f32, preferred: u32, ls: f32, out: *std.array_list.Managed(ShapedGlyph)) !void {
        const before_all = out.items.len;
        var i: usize = 0;
        var run_start: usize = 0;
        var run_font: u32 = 0;
        var have_run = false;
        while (i < text.len) {
            const cp_start = i;
            const cp = decodeNext(text, &i);
            const fidx = self.fontFor(cp, preferred);
            if (!have_run) {
                run_font = fidx;
                run_start = cp_start;
                have_run = true;
            } else if (fidx != run_font) {
                try self.shapeRun(text[run_start..cp_start], run_font, run_start, font_size, out);
                run_font = fidx;
                run_start = cp_start;
            }
        }
        if (have_run and run_start < text.len) {
            try self.shapeRun(text[run_start..], run_font, run_start, font_size, out);
        }
        // Tracking: widen every glyph advance produced by this call.
        if (ls != 0) {
            for (out.items[before_all..]) |*g| g.x_advance += ls;
        }
    }

    fn shapeRun(self: *FontAtlas, sub: []const u8, font_index: u32, base_offset: usize, font_size: f32, out: *std.array_list.Managed(ShapedGlyph)) !void {
        const before = out.items.len;
        try self.fonts.items[font_index].shaper.shape(sub, font_size, out);
        for (out.items[before..]) |*g| {
            g.font_index = font_index;
            g.cluster += @intCast(base_offset); // HB clusters are run-local → map to source
        }
    }

    /// Splits text into lines by '\n' and word-wrapping at `max_width`.
    /// `NO_WRAP` (or 0, kept for C-ABI callers) = no soft wrap; any positive
    /// finite width wraps, breaking inside a word when nothing else fits.
    /// Line widths are measured exactly via HarfBuzz.
    pub fn measureTextMultiline(self: *FontAtlas, text: []const u8, font_size: f32, max_width: f32, allocator: std.mem.Allocator) !TextLayoutInfo {
        return self.measureTextMultilinePref(text, font_size, max_width, 0, 0, LINE_HEIGHT_FACTOR, allocator);
    }
    /// `measureTextMultiline` with the node's face (`preferred`), tracking (`ls`)
    /// and line-height multiplier (`lh_factor`, sanitized; see `lineHeightWith`).
    pub fn measureTextMultilinePref(self: *FontAtlas, text: []const u8, font_size: f32, max_width: f32, preferred: u32, ls: f32, lh_factor: f32, allocator: std.mem.Allocator) !TextLayoutInfo {
        var lines = std.array_list.Managed(TextLine).init(allocator);
        var max_w: f32 = 0;

        var line_start: usize = 0;
        var w: f32 = 0;
        var last_break: ?usize = null;

        // Iterate by codepoint (indices stay byte offsets). Wrapping uses UAX#14
        // break opportunities (linebreak.zig): break after spaces/hyphens and
        // around ideographs, never before closing punctuation or after an opening
        // bracket. `last_break` is the byte index where the next line would start
        // (the line ends right before it); a hard break is the fallback when no
        // opportunity exists in the line.
        var i: usize = 0;
        var prev_class: ?lb.Class = null;
        while (i < text.len) {
            const cp_start = i;
            const cp = decodeNext(text, &i); // advances i past this codepoint
            if (cp == '\n') {
                const lw = self.measureWidthPref(text[line_start..cp_start], font_size, preferred, ls);
                try lines.append(.{ .start_index = line_start, .end_index = cp_start, .width = lw });
                max_w = @max(max_w, lw);
                line_start = i; // first byte after the newline
                w = 0;
                last_break = null;
                prev_class = null;
                continue;
            }
            const cur_class = lb.classOf(@intCast(cp));
            const adv = self.codepointAdvancePxPref(cp, font_size, preferred, ls);

            if (max_width > 0 and w + adv > max_width and line_start < cp_start) {
                // Break at the most recent opportunity; else emergency-break before
                // cp — but NOT before closing punctuation or a space (UAX#14 forbids
                // it), in which case the line just overflows.
                var at: ?usize = null;
                if (last_break) |bp| {
                    if (bp > line_start) at = bp;
                }
                if (at == null and cur_class != .cl and cur_class != .sp) at = cp_start;
                if (at) |brk| {
                    const lw = self.measureWidthPref(text[line_start..brk], font_size, preferred, ls);
                    try lines.append(.{ .start_index = line_start, .end_index = brk, .width = lw });
                    max_w = @max(max_w, lw);
                    line_start = brk;
                    // Re-measure what now sits on the new line, before cp.
                    w = if (cp_start > brk) self.measureWidthPref(text[brk..cp_start], font_size, preferred, ls) else 0;
                    last_break = null;
                }
            }

            // Record a break opportunity before cp for a later overflow.
            if (prev_class) |pc| {
                if (cp_start > line_start and lb.canBreakBefore(pc, cur_class)) last_break = cp_start;
            }

            w += adv;
            prev_class = cur_class;
        }
        const lw = self.measureWidthPref(text[line_start..text.len], font_size, preferred, ls);
        try lines.append(.{ .start_index = line_start, .end_index = text.len, .width = lw });
        max_w = @max(max_w, lw);

        const lh = sanitizeLineHeight(lh_factor);
        const line_height = lineHeightWith(font_size, lh);
        return .{
            .lines = lines,
            .max_width = max_w,
            .total_height = @as(f32, @floatFromInt(lines.items.len)) * line_height,
            .font_size = font_size,
            .shaped = std.array_list.Managed(ShapedGlyph).init(allocator),
            .preferred_font = preferred,
            .letter_spacing = ls,
            .line_height_factor = lh,
        };
    }

    /// Populates `layout.shaped` (HarfBuzz) once and records each line's glyph range.
    /// Idempotent: a no-op after the first call, until the layout is rebuilt (which
    /// happens whenever the node is layout-dirty — i.e. its text or size changed).
    /// `content` must be the same string the layout's line indices refer to.
    pub fn ensureShaped(self: *FontAtlas, layout: *TextLayoutInfo, content: []const u8) void {
        if (layout.shaped_built) return;
        layout.shaped.clearRetainingCapacity();
        for (layout.lines.items) |*line| {
            line.glyph_start = layout.shaped.items.len;
            self.shapePref(content[line.start_index..line.end_index], layout.font_size, layout.preferred_font, layout.letter_spacing, &layout.shaped) catch {};
            line.glyph_count = layout.shaped.items.len - line.glyph_start;
        }
        layout.shaped_built = true;
    }

    pub const CaretMetrics = struct { x: f32, y: f32, line_height: f32, line_index: usize };

    pub fn getCaretMetrics(self: *FontAtlas, text: []const u8, layout: *const TextLayoutInfo, font_size: f32, char_index: usize, scale: f32) CaretMetrics {
        const line_height = lineHeightWith(font_size, layout.line_height_factor);
        if (layout.lines.items.len == 0) return .{ .x = 0, .y = 0, .line_height = line_height, .line_index = 0 };

        var target: usize = 0;
        var y: f32 = 0;
        for (layout.lines.items, 0..) |line, idx| {
            if (char_index >= line.start_index and char_index <= line.end_index) {
                target = idx;
                if (char_index < line.end_index or idx == layout.lines.items.len - 1) break;
            }
            y += line_height;
        }
        const line = layout.lines.items[target];
        const end = @min(char_index, line.end_index);
        const x = if (end > line.start_index) self.measureWidthSnappedPref(text[line.start_index..end], font_size, scale, layout.preferred_font, layout.letter_spacing) else 0;
        return .{ .x = x, .y = y, .line_height = line_height, .line_index = target };
    }

    pub fn getCharIndexAt(self: *FontAtlas, text: []const u8, layout: *const TextLayoutInfo, font_size: f32, local_x: f32, local_y: f32) usize {
        const line_height = lineHeightWith(font_size, layout.line_height_factor);
        if (layout.lines.items.len == 0 or line_height <= 0) return 0;

        var line_idx: usize = layout.lines.items.len - 1;
        if (local_y >= 0) {
            const fline = local_y / line_height;
            if (fline < @as(f32, @floatFromInt(layout.lines.items.len))) line_idx = @intFromFloat(fline);
        } else line_idx = 0;

        const line = layout.lines.items[line_idx];
        var x: f32 = 0;
        var i: usize = line.start_index;
        // Step by codepoint so the returned index always lands on a UTF-8 boundary
        // (never inside a multibyte char), and widths use the real glyph advance.
        while (i < line.end_index and i < text.len) {
            const cp_start = i;
            const cp = decodeNext(text, &i);
            const adv = self.codepointAdvancePxPref(cp, font_size, layout.preferred_font, layout.letter_spacing);
            if (local_x < x + adv / 2.0) return cp_start;
            x += adv;
        }
        return line.end_index;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn loadTestFont(allocator: std.mem.Allocator) ![]u8 {
    const candidates = [_][]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "C:/Windows/Fonts/arial.ttf",
    };
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for (candidates) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, allocator, .unlimited)) |data| return data else |_| {}
    }
    return error.SkipZigTest;
}

test "FontAtlas: rasterizes a glyph by index into the atlas with sane bbox + UVs" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    const gi = atlas.glyphIndex('A');
    try testing.expect(gi != 0);
    const g = atlas.getGlyph(0, gi, 64.0).?;
    try testing.expect(g.w > 0 and g.h > 0); // 'A' has a bitmap
    try testing.expect(g.s1 > g.s0 and g.t1 > g.t0); // non-empty UV rect
    try testing.expect(g.oy < 0); // 'A' sits above the baseline

    // Atlas got marked dirty and actually has ink for 'A'.
    try testing.expect(atlas.dirty);
    var ink: usize = 0;
    for (atlas.pixels) |p| {
        if (p != 0) ink += 1;
    }
    try testing.expect(ink > 0);

    // Caching: a second fetch returns the same entry, no new packing.
    const pen_before = atlas.pen_x;
    const g2 = atlas.getGlyph(0, gi, 64.0).?;
    try testing.expectEqual(g.s0, g2.s0);
    try testing.expectEqual(pen_before, atlas.pen_x);
}

test "FontAtlas: HarfBuzz measure agrees with shaped advances; wrapping splits lines" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    var glyphs = std.array_list.Managed(ShapedGlyph).init(testing.allocator);
    defer glyphs.deinit();
    try atlas.shape("Hello", 16, &glyphs);
    var sum: f32 = 0;
    for (glyphs.items) |gg| sum += gg.x_advance;
    try testing.expectApproxEqAbs(atlas.measureWidth("Hello", 16), sum, 0.01);

    // Explicit newline → two lines.
    var layout = try atlas.measureTextMultiline("ab\ncd", 16, 0, testing.allocator);
    defer layout.deinit();
    try testing.expectEqual(@as(usize, 2), layout.lines.items.len);
    try testing.expectEqual(@as(usize, 0), layout.lines.items[0].start_index);
    try testing.expectEqual(@as(usize, 2), layout.lines.items[0].end_index);
}

test "word-wrap uses UAX#14 breaks — wraps at spaces, no line starts with space/punct" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    // A tight width forces several wraps; UAX#14 breaks after the spaces, so the
    // commas stay attached to their word and no line begins with a space or comma.
    const s = "alpha, beta, gamma, delta, epsilon, zeta";
    var layout = try atlas.measureTextMultiline(s, 16, 70, testing.allocator);
    defer layout.deinit();

    try testing.expect(layout.lines.items.len > 1); // actually wrapped
    for (layout.lines.items) |line| {
        if (line.end_index > line.start_index) {
            const first = s[line.start_index];
            try testing.expect(first != ' '); // never start a line with a space
            try testing.expect(first != ','); // …or with closing punctuation
        }
    }
}

test "EnsureShaped caches glyphs per line once, no per-frame re-shaping" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    var layout = try atlas.measureTextMultiline("ab\ncd", 16, 0, testing.allocator);
    defer layout.deinit();
    try testing.expect(!layout.shaped_built);

    atlas.ensureShaped(&layout, "ab\ncd");
    try testing.expect(layout.shaped_built);

    // Per-line glyph ranges partition the shaped buffer exactly (no gaps/overlaps).
    const total = layout.shaped.items.len;
    try testing.expect(total > 0);
    var sum: usize = 0;
    var cursor: usize = 0;
    for (layout.lines.items) |line| {
        try testing.expectEqual(cursor, line.glyph_start);
        try testing.expect(line.glyph_start + line.glyph_count <= total);
        cursor += line.glyph_count;
        sum += line.glyph_count;
    }
    try testing.expectEqual(total, sum);

    // Idempotent: a second call is a no-op (the render path calls it every frame).
    atlas.ensureShaped(&layout, "ab\ncd");
    try testing.expectEqual(total, layout.shaped.items.len);
}

test "getCharIndexAt only returns UTF-8 codepoint boundaries (no mid-char split)" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    // "aé€b": 'a'=1B, 'é'=2B (0xC3 0xA9), '€'=3B (0xE2 0x82 0xAC), 'b'=1B → 7 bytes.
    // Valid codepoint boundaries are exactly {0,1,3,6,7}. Before the per-codepoint
    // fix, getCharIndexAt walked byte-by-byte and could return 2/4/5 — indices that
    // slice a multibyte char in half (invalid UTF-8 handed back to the caller).
    const s = "a\u{00E9}\u{20AC}b";
    try testing.expectEqual(@as(usize, 7), s.len);
    const boundaries = [_]usize{ 0, 1, 3, 6, 7 };

    var layout = try atlas.measureTextMultiline(s, 16, 0, testing.allocator);
    defer layout.deinit();
    try testing.expectEqual(@as(usize, 1), layout.lines.items.len);
    try testing.expectEqual(@as(usize, 7), layout.lines.items[0].end_index);

    // Sweep the click position across the whole line; every hit-tested index must
    // be a valid boundary.
    var px: f32 = -5;
    while (px <= 400) : (px += 1.0) {
        const idx = atlas.getCharIndexAt(s, &layout, 16, px, 0);
        var ok = false;
        for (boundaries) |b| {
            if (idx == b) ok = true;
        }
        try testing.expect(ok);
    }
}

test "FontRole: a registered role routes ASCII shaping to its face; unregistered degrades to primary" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    // No role registered yet: every role resolves to the primary (index 0).
    try testing.expectEqual(@as(u32, 0), atlas.fontIndexForRole(.mono));
    try testing.expectEqual(@as(u32, 0), atlas.fontIndexForRole(.mono_bold));

    // Register the same TTF as the mono face — it becomes a new stack index.
    try atlas.addRoleFont(.mono, ttf);
    const mono_idx = atlas.mono_font_index.?;
    try testing.expect(mono_idx != 0);
    try testing.expectEqual(mono_idx, atlas.fontIndexForRole(.mono));
    // mono_bold has no dedicated face → degrades to the mono face, not the primary.
    try testing.expectEqual(mono_idx, atlas.fontIndexForRole(.mono_bold));

    // Shaping ASCII with the mono preference tags every glyph with the mono index
    // (the face covers ASCII, so `fontFor` prefers it over the primary at 0).
    var glyphs = std.array_list.Managed(ShapedGlyph).init(testing.allocator);
    defer glyphs.deinit();
    try atlas.shapePref("abc", 16, mono_idx, 0, &glyphs);
    try testing.expect(glyphs.items.len > 0);
    for (glyphs.items) |g| try testing.expectEqual(mono_idx, g.font_index);

    // With no preference (default role) the same text stays on the primary.
    glyphs.clearRetainingCapacity();
    try atlas.shapePref("abc", 16, 0, 0, &glyphs);
    for (glyphs.items) |g| try testing.expectEqual(@as(u32, 0), g.font_index);
}

test "letter-spacing widens every glyph advance and travels on the layout" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    const base = atlas.measureWidthPref("abc", 16, 0, 0);
    const spaced = atlas.measureWidthPref("abc", 16, 0, 2);
    // Three glyphs × 2px of tracking.
    try testing.expectApproxEqAbs(base + 6.0, spaced, 0.01);

    // Negative tracking tightens by the same rule.
    const tight = atlas.measureWidthPref("abc", 16, 0, -1);
    try testing.expectApproxEqAbs(base - 3.0, tight, 0.01);

    // The spacing rides on the layout, so shaping it back gives the same advances.
    var layout = try atlas.measureTextMultilinePref("abc", 16, 0, 0, 2, LINE_HEIGHT_FACTOR, testing.allocator);
    defer layout.deinit();
    try testing.expectApproxEqAbs(@as(f32, 2.0), layout.letter_spacing, 0.001);
    atlas.ensureShaped(&layout, "abc");
    var sum: f32 = 0;
    for (layout.shaped.items) |g| sum += g.x_advance;
    try testing.expectApproxEqAbs(spaced, sum, 0.01);
}

test "FontRole: the preferred face travels on the layout so ensureShaped stays consistent" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();
    try atlas.addRoleFont(.mono, ttf);
    const mono_idx = atlas.mono_font_index.?;

    var layout = try atlas.measureTextMultilinePref("hello", 16, 0, mono_idx, 0, LINE_HEIGHT_FACTOR, testing.allocator);
    defer layout.deinit();
    try testing.expectEqual(mono_idx, layout.preferred_font);

    atlas.ensureShaped(&layout, "hello");
    try testing.expect(layout.shaped.items.len > 0);
    for (layout.shaped.items) |g| try testing.expectEqual(mono_idx, g.font_index);
}

test "FontAtlas: fallback stack — primary preferred, composite key keeps fonts apart" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    // Add the same font as a fallback. The primary still covers ASCII, so it
    // must be preferred: every shaped glyph stays font_index 0.
    try atlas.addFallback(ttf);
    try testing.expectEqual(@as(usize, 2), atlas.fonts.items.len);

    var glyphs = std.array_list.Managed(ShapedGlyph).init(testing.allocator);
    defer glyphs.deinit();
    try atlas.shape("Ab", 16, &glyphs);
    try testing.expectEqual(@as(usize, 2), glyphs.items.len);
    for (glyphs.items) |g| try testing.expectEqual(@as(u32, 0), g.font_index);

    // Same glyph index in two different fonts caches under distinct keys.
    const gi = atlas.glyphIndex('A');
    const g0 = atlas.getGlyph(0, gi, 64.0).?;
    const count_after_primary = atlas.glyphs.count();
    const g1 = atlas.getGlyph(1, gi, 64.0).?; // fallback font, same index → new entry
    try testing.expect(atlas.glyphs.count() == count_after_primary + 1);
    // Identical font ⇒ identical bitmap box, but stored at different atlas slots.
    try testing.expectEqual(g0.w, g1.w);
    try testing.expectEqual(g0.h, g1.h);
    try testing.expect(g0.s0 != g1.s0 or g0.t0 != g1.t0);

    // Out-of-range font index clamps to the primary (no crash).
    _ = atlas.getGlyph(99, gi, 64.0);
}

test "FontAtlas: a CJK codepoint routes to the fallback font and rasterizes" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    // A real CJK fallback from the system; skip when none is installed.
    const cjk_candidates = [_][]const u8{
        "C:/Windows/Fonts/msgothic.ttc",
        "C:/Windows/Fonts/simsun.ttc",
        "C:/Windows/Fonts/malgun.ttf",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    };
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var added = false;
    for (cjk_candidates) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, testing.allocator, .unlimited)) |fb| {
            defer testing.allocator.free(fb);
            atlas.addFallback(fb) catch continue;
            added = true;
            break;
        } else |_| {}
    }
    if (!added) return error.SkipZigTest;

    // The primary (Arial/DejaVu) lacks Hiragana あ (U+3042); it must route to the
    // fallback and produce a real bitmap.
    try testing.expect(!atlas.fonts.items[0].covers(0x3042));

    var glyphs = std.array_list.Managed(ShapedGlyph).init(testing.allocator);
    defer glyphs.deinit();
    try atlas.shape("\u{3042}", 16, &glyphs);
    try testing.expect(glyphs.items.len >= 1);
    try testing.expect(glyphs.items[0].font_index != 0); // routed to a fallback
    const gl = atlas.getGlyph(glyphs.items[0].font_index, glyphs.items[0].glyph_id, 16.0).?;
    try testing.expect(gl.w > 0 and gl.h > 0); // actually rasterized
}

test "BaselineInSlot centers the cap band — equal space above the caps and below the baseline" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    const size: f32 = 20.0;
    const line_height = lineHeight(size);
    const baseline = atlas.baselineInSlot(0, size, line_height);
    const cap = atlas.fonts.items[0].cap_ratio * size;

    // Optical centering (CSS `text-box-edge: cap alphabetic`): the space above the
    // capitals equals the space below the baseline. Descenders hang past the bottom
    // on purpose — the eye does not read them as the text's extent.
    try testing.expectApproxEqAbs(baseline - cap, line_height - baseline, 0.001);

    // The old rule hung the text off the top of the slot (baseline at the ascent),
    // which is what made every label in a tall box read high.
    try testing.expect(baseline > atlas.ascent_ratio * size);
}

test "The primary font's metrics are read at init, not left at the defaults" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    // Sane em-relative ranges for any text face; descent is stored positive.
    try testing.expect(atlas.ascent_ratio > 0.6 and atlas.ascent_ratio < 1.3);
    try testing.expect(atlas.descent_ratio > 0.05 and atlas.descent_ratio < 0.5);
}

test "One text has one width — measurement never depends on the DPI scale" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    // A long label is where the old per-glyph rounding drifted worst (±6px at 1.5×
    // on this string): the layout sized the box from the exact width while the caret
    // and the component layer measured a snapped one, so the tail fell outside.
    const s = "Adjuntar a proceso corriendo";
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        for ([_]f32{ 11.5, 13.0, 16.0 }) |size| {
            try testing.expectApproxEqAbs(
                atlas.measureWidth(s, size),
                atlas.measureWidthSnapped(s, size, scale),
                0.001,
            );
        }
    }
}

test "BUG: CVE-2026-18497 — a glyph whose declared point count can't fit the buffer is rejected, not read past" {
    // Direct reproduction of the disclosed shape (kb.cert.org/vuls/id/987105):
    // a glyf entry claims a huge numberOfContours/point count while the actual
    // font buffer is tiny/truncated. Upstream stbtt__GetGlyphShapeTT has no
    // buffer length to check against and walks a raw pointer that many points
    // forward. stbtt_InitFontBounded's info->data_end (vendor/stb_truetype.h)
    // is what lets it reject instead — this constructs the fontinfo directly
    // (not through a real .ttf) so the malformed field is exactly the one the
    // advisory names, with nothing else in the way.
    var buf: [150]u8 = std.mem.zeroes([150]u8);

    // loca table (short format) at offset 0: glyph 0 spans [0, 2) doubled ->
    // glyf offsets [glyf+0, glyf+4) — g1 != g2, so GetGlyfOffset returns g1.
    std.mem.writeInt(u16, buf[0..2], 0, .big);
    std.mem.writeInt(u16, buf[2..4], 1, .big);

    const glyf_off = 100;
    // numberOfContours at data+glyf_off: a wildly implausible value — real
    // fonts have single-digit contour counts per glyph.
    std.mem.writeInt(i16, buf[glyf_off..][0..2], 1000, .big);

    var info: stb.stbtt_fontinfo = std.mem.zeroes(stb.stbtt_fontinfo);
    info.data = &buf;
    info.data_end = @ptrCast(@as([*]u8, &buf) + buf.len);
    info.glyf = glyf_off;
    info.loca = 0;
    info.indexToLocFormat = 0;
    info.numGlyphs = 1;

    var vertices: [*c]stb.stbtt_vertex = null;
    const n = stb.stbtt_GetGlyphShape(&info, 0, &vertices);

    // Rejected (0 vertices, null out-param), not a crash and not a "success"
    // built on an out-of-bounds read.
    try testing.expectEqual(@as(c_int, 0), n);
    try testing.expectEqual(@as(?*stb.stbtt_vertex, null), vertices);

    // Sanity check the guard is actually load-bearing: without data_end (the
    // vanilla stbtt_InitFont default), the same malformed glyph is NOT
    // rejected here — it would instead go on to read/allocate off the bogus
    // `n`. This documents that the fix is opt-in via data_end, not a change
    // to unpatched upstream's own default behavior.
    //
    // The unbounded walk runs over a large zeroed copy of the same font bytes:
    // on the 150-byte stack buffer it was a genuine out-of-bounds read, whose
    // outcome (pass or segfault) depended on the test binary's stack layout.
    // 1000 contours of zeroed endPts need ~2 KB past the glyf header, so 8 KB
    // keeps the unpatched walk inside valid memory — same code path, no UB.
    var big: [8192]u8 = std.mem.zeroes([8192]u8);
    @memcpy(big[0..buf.len], &buf);
    info.data = &big;
    info.data_end = null;
    vertices = null;
    const n_unbounded = stb.stbtt_GetGlyphShape(&info, 0, &vertices);
    try testing.expect(n_unbounded != 0);
    if (vertices != null) stb.stbtt_FreeShape(&info, vertices);
}

test "lineHeightWith: explicit factor scales the slot; unusable factors fall back to the default" {
    try testing.expectApproxEqAbs(@as(f32, 20), lineHeightWith(16, 1.25), 0.0001);
    try testing.expectApproxEqAbs(lineHeight(16), lineHeightWith(16, LINE_HEIGHT_FACTOR), 0.0001);
    const bad = [_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    for (bad) |f| {
        try testing.expectApproxEqAbs(lineHeight(16), lineHeightWith(16, f), 0.0001);
    }
}

test "verticalLayoutWith: slot follows the factor and the cap band stays optically centered" {
    const m = FontMetrics{};
    const box: f32 = 40;
    for ([_]f32{ 1.0, 1.55, 2.0 }) |f| {
        const vl = verticalLayoutWith(m, 16, box, 1, f);
        try testing.expectApproxEqAbs(16 * f, vl.line_height, 0.0001);
        // Space above the caps == space below the baseline, whatever the leading.
        try testing.expectApproxEqAbs(vl.cap_top, box - vl.baseline, 0.0001);
    }
    // The default entry point is the default factor.
    const a = verticalLayoutFor(m, 16, box, 2);
    const b = verticalLayoutWith(m, 16, box, 2, LINE_HEIGHT_FACTOR);
    try testing.expectApproxEqAbs(a.baseline, b.baseline, 0.0001);
    try testing.expectApproxEqAbs(a.line_height, b.line_height, 0.0001);
}

test "line_height factor travels from measurement to total_height, caret and hit-testing" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    const s = "one\ntwo\nthree";
    var layout = try atlas.measureTextMultilinePref(s, 16, 0, 0, 0, 1.0, testing.allocator);
    defer layout.deinit();
    try testing.expectApproxEqAbs(@as(f32, 1.0), layout.line_height_factor, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 48), layout.total_height, 0.01);

    // Caret on line 3 sits at 2 × 16, not 2 × 24.8.
    const cm = atlas.getCaretMetrics(s, &layout, 16, 9, 1.0);
    try testing.expectEqual(@as(usize, 2), cm.line_index);
    try testing.expectApproxEqAbs(@as(f32, 32), cm.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 16), cm.line_height, 0.01);

    // y = 20 is inside line 2 at factor 1.0 (it would be line 1 at 1.55).
    const idx = atlas.getCharIndexAt(s, &layout, 16, 0, 20);
    try testing.expectEqual(@as(usize, 4), idx); // start of "two"

    // A bad factor is sanitized at measurement time.
    var dflt = try atlas.measureTextMultilinePref(s, 16, 0, 0, 0, std.math.nan(f32), testing.allocator);
    defer dflt.deinit();
    try testing.expectApproxEqAbs(LINE_HEIGHT_FACTOR, dflt.line_height_factor, 0.0001);
}
