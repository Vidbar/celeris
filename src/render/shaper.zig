//! Text shaping via HarfBuzz (vendored amalgamation, `vendor/harfbuzz/src`).
//!
//! Shaping turns a UTF-8 run into positioned glyph *indices* (handling ligatures,
//! kerning, RTL, complex scripts). It is self-contained (only `std` + the HarfBuzz
//! C API) and is wired into the render pipeline via `FontAtlas` (text.zig): the
//! atlas shapes each run here and rasterizes the resulting glyph indices with stb.
//!
//! Advances/offsets are returned in **pixels** (font units × font_size / upem).

const std = @import("std");
const prof = @import("../core/profiler.zig");

const c = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ot.h");
});

pub const ShapedGlyph = struct {
    /// Glyph index in the font (post-shaping), NOT a Unicode codepoint.
    glyph_id: u32,
    /// Byte offset of the source cluster this glyph came from (for caret/hit map).
    cluster: u32,
    x_advance: f32,
    x_offset: f32,
    y_offset: f32,
    /// Which font in the atlas's fallback stack produced this glyph. The Shaper
    /// itself always emits 0; the FontAtlas tags each run with its real index.
    font_index: u32 = 0,
};

/// One HarfBuzz-shaped glyph in **font units** (pre-scale), as it comes off
/// `hb_buffer_get_glyph_positions`. Cached form: multiply by `font_size / upem`
/// to get pixels for any size.
const RawGlyph = struct {
    glyph_id: u32,
    cluster: u32,
    x_advance: i32,
    x_offset: i32,
    y_offset: i32,
};

pub const Shaper = struct {
    blob: ?*c.hb_blob_t,
    face: ?*c.hb_face_t,
    font: ?*c.hb_font_t,
    upem: f32,
    allocator: std.mem.Allocator,
    /// Cache of raw HarfBuzz output keyed by the exact run bytes. `hb_shape`'s
    /// result here depends only on those bytes — no features are passed, and
    /// `hb_buffer_guess_segment_properties` derives script/direction/language
    /// deterministically from the text — and `init` never sets an hb scale, so
    /// advances come back in font units. One shaping therefore serves *every*
    /// `font_size` (scaled at read time), which is what makes a zoom step — the
    /// case where only `font_size` changes across ~1000 canvas text nodes —
    /// cost ~zero HarfBuzz work instead of one shape call per node per wheel
    /// click. Bounded: past `cache_max_runs` the whole map is dropped and
    /// re-warms over the next frame.
    cache: std.StringHashMap([]RawGlyph),

    const cache_max_runs = 8192;

    /// `ttf` must outlive the Shaper (HarfBuzz reads it as READONLY, no copy).
    pub fn init(allocator: std.mem.Allocator, ttf: []const u8) !Shaper {
        const blob = c.hb_blob_create(ttf.ptr, @intCast(ttf.len), c.HB_MEMORY_MODE_READONLY, null, null);
        const face = c.hb_face_create(blob, 0);
        const font = c.hb_font_create(face);
        c.hb_ot_font_set_funcs(font); // use HarfBuzz's built-in OpenType funcs (no FreeType)
        const upem: f32 = @floatFromInt(c.hb_face_get_upem(face));
        return .{
            .blob = blob,
            .face = face,
            .font = font,
            .upem = if (upem > 0) upem else 1000.0,
            .allocator = allocator,
            .cache = std.StringHashMap([]RawGlyph).init(allocator),
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.clearCache();
        self.cache.deinit();
        c.hb_font_destroy(self.font);
        c.hb_face_destroy(self.face);
        c.hb_blob_destroy(self.blob);
    }

    fn clearCache(self: *Shaper) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.cache.clearRetainingCapacity();
    }

    /// Raw (font-unit) glyphs for `text`, shaping and caching on a miss. The
    /// returned slice is owned by the cache; use it before the next `rawGlyphs`
    /// call, which may evict.
    fn rawGlyphs(self: *Shaper, text: []const u8) ![]const RawGlyph {
        if (self.cache.get(text)) |hit| return hit;

        const buf = c.hb_buffer_create();
        defer c.hb_buffer_destroy(buf);
        c.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_guess_segment_properties(buf);
        c.hb_shape(self.font, buf, null, 0);

        var n: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(buf, &n);
        const poss = c.hb_buffer_get_glyph_positions(buf, &n);
        const raw = try self.allocator.alloc(RawGlyph, n);
        errdefer self.allocator.free(raw);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            raw[i] = .{
                .glyph_id = @intCast(infos[i].codepoint),
                .cluster = @intCast(infos[i].cluster),
                .x_advance = @intCast(poss[i].x_advance),
                .x_offset = @intCast(poss[i].x_offset),
                .y_offset = @intCast(poss[i].y_offset),
            };
        }

        if (self.cache.count() >= cache_max_runs) self.clearCache();
        const key = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(key);
        try self.cache.put(key, raw);
        return raw;
    }

    /// Shapes one run of `text` at `font_size` px, appending glyphs to `out`.
    pub fn shape(self: *Shaper, text: []const u8, font_size: f32, out: *std.array_list.Managed(ShapedGlyph)) !void {
        const z = prof.zone(@src());
        defer z.end();
        const raw = try self.rawGlyphs(text);
        const scale = font_size / self.upem;
        try out.ensureUnusedCapacity(raw.len);
        for (raw) |r| {
            out.appendAssumeCapacity(.{
                .glyph_id = r.glyph_id,
                .cluster = r.cluster,
                .x_advance = @as(f32, @floatFromInt(r.x_advance)) * scale,
                .x_offset = @as(f32, @floatFromInt(r.x_offset)) * scale,
                .y_offset = @as(f32, @floatFromInt(r.y_offset)) * scale,
            });
        }
    }

    /// Total advance width of `text` at `font_size` px (shapes internally).
    pub fn measureWidth(self: *Shaper, text: []const u8, font_size: f32) f32 {
        const raw = self.rawGlyphs(text) catch return self.measureWidthUncached(text, font_size);
        var total: i64 = 0;
        for (raw) |r| total += r.x_advance;
        return @as(f32, @floatFromInt(total)) * (font_size / self.upem);
    }

    /// Fallback for `measureWidth` when the cache alloc fails: one transient
    /// shape, no caching.
    fn measureWidthUncached(self: *Shaper, text: []const u8, font_size: f32) f32 {
        const buf = c.hb_buffer_create();
        defer c.hb_buffer_destroy(buf);
        c.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_guess_segment_properties(buf);
        c.hb_shape(self.font, buf, null, 0);
        var n: c_uint = 0;
        const poss = c.hb_buffer_get_glyph_positions(buf, &n);
        var total: i64 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) total += poss[i].x_advance;
        return @as(f32, @floatFromInt(total)) * (font_size / self.upem);
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

test "Shaper: shapes a run into glyphs with positive, consistent advances" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);

    var sh = try Shaper.init(testing.allocator, ttf);
    defer sh.deinit();

    var glyphs = std.array_list.Managed(ShapedGlyph).init(testing.allocator);
    defer glyphs.deinit();
    try sh.shape("ABC", 16, &glyphs);

    try testing.expectEqual(@as(usize, 3), glyphs.items.len);
    var sum: f32 = 0;
    for (glyphs.items) |g| {
        try testing.expect(g.x_advance > 0);
        sum += g.x_advance;
    }
    // measureWidth must agree with the per-glyph advance sum.
    try testing.expectApproxEqAbs(sh.measureWidth("ABC", 16), sum, 0.01);
    // Clusters map back to source byte offsets (LTR run → 0,1,2).
    try testing.expectEqual(@as(u32, 0), glyphs.items[0].cluster);
    try testing.expectEqual(@as(u32, 2), glyphs.items[2].cluster);
}

test "Shaper: width scales with font size" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var sh = try Shaper.init(testing.allocator, ttf);
    defer sh.deinit();
    const w16 = sh.measureWidth("Hello", 16);
    const w32 = sh.measureWidth("Hello", 32);
    try testing.expect(w16 > 0);
    try testing.expectApproxEqAbs(w32, w16 * 2.0, 0.05);
}

test "Shaper: one cached shaping serves every font size" {
    const ttf = try loadTestFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var sh = try Shaper.init(testing.allocator, ttf);
    defer sh.deinit();

    // First shape at 16 populates the cache; a second call at 32 must not shape
    // again (cache count stays at 1) yet return glyphs scaled exactly 2×.
    var g16 = std.array_list.Managed(ShapedGlyph).init(testing.allocator);
    defer g16.deinit();
    try sh.shape("Zoom!", 16, &g16);
    try testing.expectEqual(@as(usize, 1), sh.cache.count());

    var g32 = std.array_list.Managed(ShapedGlyph).init(testing.allocator);
    defer g32.deinit();
    try sh.shape("Zoom!", 32, &g32);
    try testing.expectEqual(@as(usize, 1), sh.cache.count()); // hit, no re-shape

    try testing.expectEqual(g16.items.len, g32.items.len);
    for (g16.items, g32.items) |a, b| {
        try testing.expectEqual(a.glyph_id, b.glyph_id);
        try testing.expectEqual(a.cluster, b.cluster);
        try testing.expectApproxEqAbs(a.x_advance * 2.0, b.x_advance, 0.01);
    }

    // measureWidth reads the same cache entry and agrees with the shaped sum.
    var sum32: f32 = 0;
    for (g32.items) |g| sum32 += g.x_advance;
    try testing.expectApproxEqAbs(sh.measureWidth("Zoom!", 32), sum32, 0.01);
    try testing.expectEqual(@as(usize, 1), sh.cache.count());

    // A distinct run adds exactly one entry.
    try sh.shape("other", 16, &g16);
    try testing.expectEqual(@as(usize, 2), sh.cache.count());
}
