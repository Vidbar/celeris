const std = @import("std");
const BoundedArray = @import("../core/bounded_array.zig").BoundedArray;
const reg = @import("../core/registry.zig");
const props = @import("../core/properties.zig");
extern "c" fn celeris_measure_text(engine_id: i32, text: [*c]const u8, len: usize, font_size: f32) f32;

const text_mod = @import("../render/text.zig");
const path_mod = @import("../core/path.zig");
const builder = @import("../framework/builder.zig"); // test-only (reconciliation reuse)

// ── Layout enums (local to this file) ────────────────────────────────────────

const JustifyContent = enum { flex_start, center, flex_end, space_between, space_around, space_evenly };
const AlignItems = enum { flex_start, center, flex_end, stretch, baseline };
/// Fraction of font-size used as the text ascent for `baseline` alignment. Exact
/// per-font ascent isn't plumbed through the store yet; this approximation aligns
/// baselines of different font sizes well enough for the common case.
const BASELINE_ASCENT_RATIO: f32 = 0.8;

// ── LayoutEngine ──────────────────────────────────────────────────────────────

pub const LayoutEngine = struct {
    registry: *reg.UIRegistry,
    store: *const props.PropertyStore,
    atlas: ?*text_mod.FontAtlas,
    /// Current recursion depth, used to bound `measure`/`place` so a deeply
    /// nested tree cannot overflow the stack.
    depth: usize = 0,
    /// This solve's generation (copied from `registry.solve_generation`). Nodes
    /// re-measured this solve are stamped with it; `place` skips any node not
    /// stamped this gen whose origin is unchanged (its subtree is identical).
    gen: u64 = 0,

    pub fn init(registry: *reg.UIRegistry, store: *const props.PropertyStore, atlas: ?*text_mod.FontAtlas) LayoutEngine {
        return .{ .registry = registry, .store = store, .atlas = atlas };
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /// Two-pass layout: first measure (sets geometry.width / .height),
    /// then place (sets geometry.x / .y) and recurses into children.
    pub fn solve(
        self: *LayoutEngine,
        node_id: reg.NodeId,
        x_offset: f32,
        y_offset: f32,
        available_width: f32,
        available_height: f32,
    ) void {
        self.registry.solve_generation +%= 1;
        self.gen = self.registry.solve_generation;
        self.registry.dbg_measured = 0;
        self.registry.dbg_reshaped = 0;
        self.registry.dbg_placed = 0;
        self.registry.dbg_skipped = 0;
        _ = self.measure(node_id, available_width, available_height);
        self.place(node_id, x_offset, y_offset);
    }

    // ── Pass 1: measure ───────────────────────────────────────────────────────

    /// Sets `geometry.width` and `geometry.height` for the subtree rooted at
    /// `node_id`.  Returns the resolved (w, h) pair for the caller to use when
    /// computing parent shrink-to-content height.
    fn measure(self: *LayoutEngine, node_id: reg.NodeId, available_w: f32, available_h: f32) struct { w: f32, h: f32 } {
        if (self.depth >= reg.MAX_TREE_DEPTH) return .{ .w = 0, .h = 0 };
        self.depth += 1;
        defer self.depth -= 1;
        const node = self.registry.getNode(node_id) orelse return .{ .w = 0, .h = 0 };

        if (!node.layout_dirty and
            node.last_avail_w == available_w and
            node.last_avail_h == available_h)
        {
            return .{ .w = node.geometry.width, .h = node.geometry.height };
        }

        // Real measurement work below → this node's size may change this solve, so
        // `place` must not skip it (nor treat its subtree as untouched).
        node.measured_gen = self.gen;
        self.registry.dbg_measured += 1;

        node.last_avail_w = available_w;
        node.last_avail_h = available_h;
        // If we got here, either the node was already dirty or the available
        // space changed.  Mark dirty so downstream lazy caches (text layout)
        // know to recompute — they check `layout_dirty`, not `last_avail_*`.
        node.layout_dirty = true;

        // ── Width ─────────────────────────────────────────────────────────────
        // A hug-content box (no explicit width in a row) sizes to its children's
        // intrinsic extent, measured here against the REAL available width. We keep
        // that extent so the height pass can reuse its `.h` instead of re-measuring
        // the children against the now-hugged width — a second, tighter measure
        // would re-wrap text whose natural width equals the box width to within a
        // sub-pixel snapping error (the "DevTools" → "DevTool"/"s" bug).
        var hug_extent: ?struct { w: f32, h: f32 } = null;
        if (self.explicitSize(node_id, .width)) |w_prop| {
            node.geometry.width = resolveDim(w_prop, available_w);
        } else {
            if (node.node_type == .box) {
                if (node.parent != reg.NULL_NODE and self.isRow(node.parent)) {
                    const ext = self.measureChildrenExtent(node_id, available_w);
                    hug_extent = .{ .w = ext.w, .h = ext.h };
                    node.geometry.width = ext.w;
                } else {
                    node.geometry.width = available_w; // fill parent width by default
                }
            } else if (node.node_type == .image) {
                node.geometry.width = if (available_w == std.math.floatMax(f32)) 0 else available_w;
            } else if (node.node_type == .path) {
                // Intrinsic width = the path's bounding box (author paths in
                // local coords starting near the origin; the stroke is drawn
                // translated by this node's geometry origin).
                node.geometry.width = if (self.store.getPath(node_id)) |v| @max(path_mod.bounds(v).max_x, 0) else 0;
            } else {
                node.geometry.width = self.updateTextLayout(node_id).w;
            }
        }

        // ── Height ────────────────────────────────────────────────────────────
        if (self.explicitSize(node_id, .height)) |h_prop| {
            node.geometry.height = resolveDim(h_prop, available_h);
            // Even with explicit height, children must be measured now so
            // placeChildren() can read their sizes for justify_content distribution.
            //
            // Skipped when `hug_extent` is set: this node's WIDTH was just computed
            // by hugging its children (measureChildrenExtent, above), which already
            // measures every child as a side effect — using the real, generous
            // `available_w` this node itself received, not its own just-computed
            // width. Calling `measureChildrenPass` here too would redo that
            // measurement using THIS node's own (now content-tight) width as the
            // children's available width — the self-referential trap this whole
            // hug mechanism exists to avoid: a hug-width, explicit-height box (a
            // MenuBar button under a caption row, say) would re-shape its own text
            // against a box sized to fit that exact text with zero slack, and
            // HarfBuzz shaping being narrower than the wrap loop's per-codepoint
            // advance sum can flip the wrap decision (e.g. "Ver" -> "Ve"/"r").
            if (node.node_type == .box and hug_extent == null) {
                self.measureChildrenPass(node_id);
            }
        } else {
            if (node.node_type == .text) {
                node.geometry.height = self.updateTextLayout(node_id).h;
            } else if (node.node_type == .image) {
                // Default image height if not specified. Avoid blocking I/O here.
                // It will just be a square or 0 if width is 0.
                node.geometry.height = node.geometry.width;
            } else if (node.node_type == .path) {
                node.geometry.height = if (self.store.getPath(node_id)) |v| @max(path_mod.bounds(v).max_y, 0) else 0;
            } else if (hug_extent) |ext| {
                // Width already hugged the children: reuse that same-generation
                // extent rather than re-measuring against the derived width.
                node.geometry.height = ext.h;
            } else {
                // Box without explicit height: shrink-to-content.
                // measureChildrenExtent measures children as a side-effect.
                const extent = self.measureChildrenExtent(node_id, node.geometry.width);
                node.geometry.height = extent.h;
            }
        }

        // Max first, then min — CSS 2.1 §10.4: when the two conflict, min wins. The
        // stretch path (`placeChildren`) already clamps in this order; doing it the
        // other way here made the same min/max pair resolve differently depending on
        // whether a node got its cross size from measurement or from stretch.
        if (self.getMaxDim(node_id, .max_width, available_w)) |mw| node.geometry.width = @min(node.geometry.width, mw);
        if (self.getMaxDim(node_id, .max_height, available_h)) |mh| node.geometry.height = @min(node.geometry.height, mh);

        if (self.getMinDim(node_id, .min_width, available_w)) |mw| node.geometry.width = @max(node.geometry.width, mw);
        if (self.getMinDim(node_id, .min_height, available_h)) |mh| node.geometry.height = @max(node.geometry.height, mh);

        node.layout_dirty = false;
        // Record the measured size so `place` can tell whether flex later resized
        // this box (and its children need re-measuring) or left it at content size.
        node.layout_w = node.geometry.width;
        node.layout_h = node.geometry.height;
        return .{ .w = node.geometry.width, .h = node.geometry.height };
    }

    /// Measure children without computing parent height — used when the parent
    /// has an explicit height but children still need their sizes resolved.
    fn measureChildrenPass(self: *LayoutEngine, parent_id: reg.NodeId) void {
        const parent = self.registry.getNode(parent_id) orelse return;
        const pad_left = self.getDim(parent_id, .padding_left);
        const pad_right = self.getDim(parent_id, .padding_right);
        const border_w = self.getStyleDim(parent_id, .border_width);
        const available_w = @max(parent.geometry.width - pad_left - pad_right - border_w * 2, 0);

        var child_id = parent.first_child;
        while (child_id != reg.NULL_NODE) {
            _ = self.measure(child_id, available_w, parent.geometry.height);
            child_id = self.registry.getNode(child_id).?.next_sibling;
        }
    }

    fn measureChildrenExtent(self: *LayoutEngine, parent_id: reg.NodeId, parent_avail_w: f32) struct { w: f32, h: f32 } {
        const parent = self.registry.getNode(parent_id) orelse return .{ .w = 0, .h = 0 };

        const pad_top = self.getDim(parent_id, .padding_top);
        const pad_bottom = self.getDim(parent_id, .padding_bottom);
        const pad_left = self.getDim(parent_id, .padding_left);
        const pad_right = self.getDim(parent_id, .padding_right);
        const border_w = self.getStyleDim(parent_id, .border_width);
        const available_w = @max(parent_avail_w - pad_left - pad_right - border_w * 2, 0);

        const is_row = self.isRow(parent_id);
        const is_wrap = self.getFlexWrap(parent_id);
        const main_gap = self.getMainGap(parent_id, is_row);
        const cross_gap = self.getCrossGap(parent_id, is_row);

        var total_cross: f32 = 0;
        var max_main: f32 = 0;

        var line_main: f32 = 0;
        var line_cross: f32 = 0;
        var item_count: u32 = 0;

        var child_id = parent.first_child;
        while (child_id != reg.NULL_NODE) {
            if (self.isAbsolute(child_id)) {
                // An out-of-flow child contributes nothing to the container's content
                // size (CSS 9.3: it's excluded from the flow) — but it still has to be
                // SIZED, against this box as its containing block. Skipping the
                // `measure()` call entirely, as this loop used to, left every absolute
                // child of a hug-content box stuck at 0x0 no matter what width/height
                // it declared: a floating panel then measured correctly or not purely
                // by whether its parent happened to carry an explicit height (the only
                // other path, `measureChildrenPass`, measures every child). That is what
                // kept TooltipHost's panel invisible.
                _ = self.measure(child_id, parent.geometry.width, parent.geometry.height);
            } else {
                const size = self.measure(child_id, available_w, std.math.floatMax(f32));
                const m_top = self.getDim(child_id, .margin_top);
                const m_bottom = self.getDim(child_id, .margin_bottom);
                const m_left = self.getDim(child_id, .margin_left);
                const m_right = self.getDim(child_id, .margin_right);

                const child_main = if (is_row) size.w + m_left + m_right else size.h + m_top + m_bottom;
                const child_cross = if (is_row) size.h + m_top + m_bottom else size.w + m_left + m_right;

                if (is_wrap and item_count > 0 and line_main + main_gap + child_main > available_w) {
                    // Wrap to next line
                    max_main = @max(max_main, line_main);
                    total_cross += line_cross + cross_gap;

                    line_main = child_main;
                    line_cross = child_cross;
                    item_count = 1;
                } else {
                    if (item_count > 0) line_main += main_gap;
                    line_main += child_main;
                    line_cross = @max(line_cross, child_cross);
                    item_count += 1;
                }
            }
            child_id = self.registry.getNode(child_id).?.next_sibling;
        }

        max_main = @max(max_main, line_main);
        total_cross += line_cross;

        const padding_main = if (is_row) pad_left + pad_right + border_w * 2 else pad_top + pad_bottom + border_w * 2;
        const padding_cross = if (is_row) pad_top + pad_bottom + border_w * 2 else pad_left + pad_right + border_w * 2;

        return if (is_row)
            .{ .w = max_main + padding_main, .h = total_cross + padding_cross }
        else
            .{ .w = total_cross + padding_cross, .h = max_main + padding_main };
    }

    fn getFlexWrap(self: *const LayoutEngine, node_id: reg.NodeId) bool {
        if (self.store.getLayout(node_id, .flex_wrap)) |fw| {
            if (fw == .boolean) return fw.boolean;
        }
        return false;
    }

    fn getGap(self: *const LayoutEngine, node_id: reg.NodeId) f32 {
        if (self.store.getLayout(node_id, .gap)) |g| {
            if (g == .dimension and g.dimension.unit == .px) return g.dimension.value;
        }
        return 0.0;
    }

    /// Gap between items along the main axis — `column_gap` in a row, `row_gap`
    /// in a column. Falls back to the axis-agnostic `gap`.
    fn getMainGap(self: *const LayoutEngine, node_id: reg.NodeId, is_row: bool) f32 {
        return self.getAxisGap(node_id, if (is_row) .column_gap else .row_gap);
    }

    /// Gap between wrap lines along the cross axis — `row_gap` in a row,
    /// `column_gap` in a column. Falls back to the axis-agnostic `gap`.
    fn getCrossGap(self: *const LayoutEngine, node_id: reg.NodeId, is_row: bool) f32 {
        return self.getAxisGap(node_id, if (is_row) .row_gap else .column_gap);
    }

    fn getAxisGap(self: *const LayoutEngine, node_id: reg.NodeId, key: props.LayoutKey) f32 {
        if (self.store.getLayout(node_id, key)) |g| {
            if (g == .dimension and g.dimension.unit == .px) return g.dimension.value;
        }
        return self.getGap(node_id);
    }

    fn getFlexGrow(self: *const LayoutEngine, node_id: reg.NodeId) f32 {
        if (self.store.getLayout(node_id, .flex_grow)) |fg| {
            if (fg == .number) return fg.number;
        }
        return 0.0;
    }

    fn getFlexShrink(self: *const LayoutEngine, node_id: reg.NodeId) f32 {
        if (self.store.getLayout(node_id, .flex_shrink)) |fs| {
            if (fs == .number) return fs.number;
        }
        // Default 0 (Yoga-style), NOT the CSS initial value of 1. This is deliberate
        // and load-bearing: TreeView (and any scroll container) is a `height:100%`
        // flex-column whose fixed-height rows must OVERFLOW the viewport for the
        // spacer-based virtualization to place them — a default of 1 would shrink
        // every row to fit and collapse the scroll model. A cell that both grows and
        // must shrink-to-fit (a property-row value) opts in with `flex-shrink:1`.
        return 0.0;
    }

    /// flex-basis (px/percent against the main-axis size), or null when unset — in
    /// which case the item's measured/explicit main size is its base.
    fn getFlexBasis(self: *const LayoutEngine, node_id: reg.NodeId, main_avail: f32) ?f32 {
        if (self.store.getLayout(node_id, .flex_basis)) |b| {
            if (b == .dimension) return resolveDim(b, main_avail);
        }
        return null;
    }

    /// Resolved min-width/min-height (px/percent against `parent_size`), or null.
    fn getMinDim(self: *const LayoutEngine, node_id: reg.NodeId, key: props.LayoutKey, parent_size: f32) ?f32 {
        if (self.store.getLayout(node_id, key)) |p| {
            if (p == .dimension) return resolveDim(p, parent_size);
        }
        return null;
    }

    /// Resolved max-width/max-height (px/percent against `parent_size`), or null.
    fn getMaxDim(self: *const LayoutEngine, node_id: reg.NodeId, key: props.LayoutKey, parent_size: f32) ?f32 {
        if (self.store.getLayout(node_id, key)) |p| {
            if (p == .dimension) return resolveDim(p, parent_size);
        }
        return null;
    }

    /// Sum of the node's margins along the main axis.
    fn mainMargins(self: *const LayoutEngine, node_id: reg.NodeId, is_row: bool) f32 {
        return if (is_row)
            self.getDim(node_id, .margin_left) + self.getDim(node_id, .margin_right)
        else
            self.getDim(node_id, .margin_top) + self.getDim(node_id, .margin_bottom);
    }

    // ── Pass 2: place ─────────────────────────────────────────────────────────

    /// Sets `geometry.x` / `.y` for `node_id` and recursively places its children
    /// respecting `justify_content` and `align_items`.
    fn place(self: *LayoutEngine, node_id: reg.NodeId, x: f32, y: f32) void {
        if (self.depth >= reg.MAX_TREE_DEPTH) return;
        self.depth += 1;
        defer self.depth -= 1;
        const node = self.registry.getNode(node_id) orelse return;

        // Skip a subtree the measure pass left untouched (not re-measured this
        // solve) and that lands at the same origin: nothing in it could have
        // changed size or position, so its cached geometry is already correct.
        // This is the incremental-layout win — a keystroke re-places only the
        // dirty spine instead of the whole tree.
        if (node.measured_gen != self.gen and node.geometry.x == x and node.geometry.y == y) {
            self.registry.dbg_skipped += 1;
            return;
        }
        self.registry.dbg_placed += 1;
        node.geometry.x = x;
        node.geometry.y = y;

        if (node.node_type == .box) {
            // Re-measure children after the box has its final size so percentage
            // descendants resolve against a flex-grown/shrunk parent — but only when
            // the size actually changed since the measure pass. A hug-content box at
            // its content size would otherwise re-measure its text against the very
            // width that text produced, and HarfBuzz shaping being narrower than the
            // wrap loop's per-codepoint advances would spuriously wrap the last glyph.
            //
            // The height half of that condition needs one carve-out: a box whose
            // WIDTH came from the hug/intrinsic path (no width prop, row parent —
            // same test `measure`'s width branch uses) is exactly-fit to its own
            // content, by construction. If such a box's HEIGHT alone changes later —
            // typically a cross-axis `align_items: stretch` on a row parent sizing a
            // hug-width child to the row's full height — re-measuring hits the same
            // self-referential trap the width guard above prevents, just via the
            // other side of the OR: children get re-measured against this box's own
            // now-final (already content-tight) width, and HarfBuzz reshaping at
            // zero slack can flip the wrap decision (e.g. "Ver" -> "Ve"/"r").
            // A box with an EXPLICIT width (the percent-child-follows-flex-grown-
            // parent case this whole condition exists for) never has that self-
            // reference — its resolved width doesn't depend on its own children —
            // so a pure height change there still needs the re-measure to resolve
            // percentage-height descendants against it. Same goes for a row flex
            // item whose main size comes from the flex algorithm, not its content:
            // `flex-grow > 0` or an explicit `flex-basis`. Without this carve-out a
            // `flex-grow` slot in a row that only gains a definite HEIGHT via
            // cross-axis `align-items: stretch` never re-measures its children, so a
            // `height: 100%` descendant (e.g. a `mountReactiveFill` anchor) collapses.
            const width_is_hug = self.explicitSize(node_id, .width) == null and
                node.parent != reg.NULL_NODE and self.isRow(node.parent) and
                self.getFlexGrow(node_id) == 0 and
                self.store.getLayout(node_id, .flex_basis) == null;
            if (node.geometry.width != node.layout_w or
                (node.geometry.height != node.layout_h and !width_is_hug))
            {
                self.measureChildrenPass(node_id);
            }
            self.placeChildren(node_id);
        } else if (node.node_type == .text and node.geometry.width < node.layout_w) {
            // Flex SHRANK this text node's main axis AFTER it was shaped: the measure
            // pass wraps each child against the full available width, but a `flex-grow`
            // /`flex-shrink` sibling (the label in a property row) then leaves it a
            // narrower box. Re-wrap the glyphs at the width it actually got, so the
            // first line can't spill past the box over the container's padding.
            //
            // Only when it got NARROWER than it was measured at (`< layout_w`). Growing
            // a text box never makes a fitted line overflow — and re-wrapping at the
            // content width (`== layout_w`) is the DevTools-chip hug case that must NOT
            // re-measure, lest the sub-pixel wrap-loop-vs-HarfBuzz mismatch wrap the
            // last glyph. Width only, not height: geometry is untouched here
            // (updateTextLayout rewrites the cached wrapping in place), so the line the
            // parent already sized still holds.
            node.last_avail_w = node.geometry.width;
            node.layout_dirty = true;
            _ = self.updateTextLayout(node_id);
        }
    }

    fn placeChildren(self: *LayoutEngine, parent_id: reg.NodeId) void {
        const parent = self.registry.getNode(parent_id) orelse return;
        // A scrolled container places ALL its children shifted by its scroll
        // offset — a full solve lands the subtree exactly where the incremental
        // shift in PropertyStore.setLayout(.scroll_offset_{x,y}) already put it.
        // Folded into the origin before padding / is_row / wrap / justify, so it
        // is axis-agnostic (main vs cross is irrelevant to a container-origin
        // translation).
        const px = parent.geometry.x + self.getDim(parent_id, .scroll_offset_x);
        const py = parent.geometry.y + self.getDim(parent_id, .scroll_offset_y);
        const pw = parent.geometry.width;
        const ph = parent.geometry.height;

        const pad_left = self.getDim(parent_id, .padding_left);
        const pad_top = self.getDim(parent_id, .padding_top);
        const pad_right = self.getDim(parent_id, .padding_right);
        const pad_bottom = self.getDim(parent_id, .padding_bottom);
        const border_w = self.getStyleDim(parent_id, .border_width);

        const avail_w = @max(pw - pad_left - pad_right - border_w * 2, 0);
        const avail_h = @max(ph - pad_top - pad_bottom - border_w * 2, 0);

        const is_row = self.isRow(parent_id);
        const is_wrap = self.getFlexWrap(parent_id);
        const justify = self.justifyContent(parent_id);
        const align_val = self.alignItems(parent_id);
        // `explicit_gap` spaces items along the main axis; `cross_gap` spaces
        // wrap lines along the cross axis. Both fall back to the plain `gap`.
        const explicit_gap = self.getMainGap(parent_id, is_row);
        const cross_gap = self.getCrossGap(parent_id, is_row);

        const main_avail = if (is_row) avail_w else avail_h;
        const cross_avail = if (is_row) avail_h else avail_w;

        // Collect all non-absolute children
        var flow_children: BoundedArray(reg.NodeId, 1024) = .{}; // max 1024 children per container
        var child_id = parent.first_child;
        while (child_id != reg.NULL_NODE) {
            if (!self.isAbsolute(child_id)) {
                flow_children.append(child_id) catch break;
            } else {
                // Absolute: relative to parent origin
                const m_top = self.getDim(child_id, .margin_top);
                const m_left = self.getDim(child_id, .margin_left);
                const left = self.getDim(child_id, .left);
                const top = self.getDim(child_id, .top);
                self.place(child_id, px + left + m_left, py + top + m_top);
            }
            child_id = self.registry.getNode(child_id).?.next_sibling;
        }

        if (flow_children.len == 0) return;

        // Start every flow item's MAIN size from its measured base (`layout_w` /
        // `layout_h`), not from `geometry`. A clean child hits the measure cache,
        // which leaves `geometry` holding last solve's post-grow/shrink size; flex
        // distribution reading that would treat an old grown width as the base
        // and overflow the line when a sibling gets wider (a `grow` viewport kept
        // its full width when the scrollbar slot beside it gained a track). The
        // previous main size is kept so a size that ends up different still forces
        // a re-place.
        var prev_main: BoundedArray(f32, 1024) = .{};
        {
            var bi: usize = 0;
            while (bi < flow_children.len) : (bi += 1) {
                const child = self.registry.getNode(flow_children.get(bi)).?;
                const cur = if (is_row) child.geometry.width else child.geometry.height;
                prev_main.append(cur) catch {};
                const base = if (is_row) child.layout_w else child.layout_h;
                if (base >= 0) {
                    if (is_row) child.geometry.width = base else child.geometry.height = base;
                }
            }
        }

        // flex-basis: override each flow item's main-axis base size before the line
        // pass reads it (for wrapping decisions + grow/shrink distribution).
        {
            var bi: usize = 0;
            while (bi < flow_children.len) : (bi += 1) {
                const cid = flow_children.get(bi);
                if (self.getFlexBasis(cid, main_avail)) |basis| {
                    const child = self.registry.getNode(cid).?;
                    if (is_row) child.geometry.width = basis else child.geometry.height = basis;
                    child.measured_gen = self.gen; // resized → must be re-placed
                }
            }
        }

        var current_idx: usize = 0;
        var cross_cursor: f32 = 0;

        while (current_idx < flow_children.len) {
            // Find items in current line
            var line_main_size: f32 = 0;
            var line_cross_size: f32 = 0;
            var total_flex_grow: f32 = 0;
            var total_flex_shrink: f32 = 0;
            var line_count: usize = 0;

            var i = current_idx;
            while (i < flow_children.len) {
                const cid = flow_children.get(i);
                const child = self.registry.getNode(cid).?;
                const m_top = self.getDim(cid, .margin_top);
                const m_bottom = self.getDim(cid, .margin_bottom);
                const m_left = self.getDim(cid, .margin_left);
                const m_right = self.getDim(cid, .margin_right);

                const c_main = if (is_row) child.geometry.width + m_left + m_right else child.geometry.height + m_top + m_bottom;
                const c_cross = if (is_row) child.geometry.height + m_top + m_bottom else child.geometry.width + m_left + m_right;

                const item_gap = if (line_count > 0) explicit_gap else 0.0;

                if (is_wrap and line_count > 0 and line_main_size + item_gap + c_main > main_avail) {
                    break; // Wrap!
                }

                line_main_size += c_main + item_gap;
                line_cross_size = @max(line_cross_size, c_cross);
                total_flex_grow += self.getFlexGrow(cid);
                total_flex_shrink += self.getFlexShrink(cid);
                line_count += 1;
                i += 1;
            }

            // Flex Grow / Shrink
            var remaining = main_avail - line_main_size;
            if (remaining > 0 and total_flex_grow > 0) {
                line_main_size = 0;
                var j = current_idx;
                while (j < current_idx + line_count) {
                    const cid = flow_children.get(j);
                    const child = self.registry.getNode(cid).?;
                    const fg = self.getFlexGrow(cid);
                    const extra = (fg / total_flex_grow) * remaining;

                    if (is_row) {
                        child.geometry.width += extra;
                    } else {
                        child.geometry.height += extra;
                    }
                    child.measured_gen = self.gen; // grown → must be re-placed

                    const m_top = self.getDim(cid, .margin_top);
                    const m_bottom = self.getDim(cid, .margin_bottom);
                    const m_left = self.getDim(cid, .margin_left);
                    const m_right = self.getDim(cid, .margin_right);
                    const c_main = if (is_row) child.geometry.width + m_left + m_right else child.geometry.height + m_top + m_bottom;
                    const item_gap = if (j > current_idx) explicit_gap else 0.0;
                    line_main_size += c_main + item_gap;
                    j += 1;
                }
                remaining = 0;

                // Re-measure children of grown items so text nodes can
                // word-wrap at the new, wider available width.
                if (is_row) {
                    j = current_idx;
                    while (j < current_idx + line_count) {
                        const cid = flow_children.get(j);
                        const fg = self.getFlexGrow(cid);
                        // Only boxes recompute their cross size from wrapped
                        // children here. A grown *text* item has no children, so
                        // measureChildrenExtent would report ~0 height and clobber
                        // its line height (regression). Its content
                        // was already shaped at the full available width in the
                        // measure pass — a wider box only reduces wrapping — so its
                        // height needs no recompute.
                        if (fg > 0 and self.registry.getNode(cid).?.node_type == .box) {
                            const child = self.registry.getNode(cid).?;
                            const c_pad_l = self.getDim(cid, .padding_left);
                            const c_pad_r = self.getDim(cid, .padding_right);
                            const c_bw = self.getStyleDim(cid, .border_width);
                            const inner_w = @max(child.geometry.width - c_pad_l - c_pad_r - c_bw * 2, 0);
                            // Mark children dirty so they re-measure with new width
                            var gc_id = child.first_child;
                            while (gc_id != reg.NULL_NODE) {
                                if (self.registry.getNode(gc_id)) |gc| {
                                    gc.layout_dirty = true;
                                    _ = self.measure(gc_id, inner_w, child.geometry.height);
                                }
                                gc_id = self.registry.getNode(gc_id).?.next_sibling;
                            }
                            // Recompute height from children if no explicit height.
                            // Re-apply the same max-then-min clamp `measure` does —
                            // this path bypasses it, so a min-height-only box with a
                            // grown row parent would collapse below its min (and,
                            // once the early-out caches that, never recover).
                            if (self.explicitSize(cid, .height) == null) {
                                const extent = self.measureChildrenExtent(cid, child.geometry.width);
                                var h = extent.h;
                                if (self.getMaxDim(cid, .max_height, cross_avail)) |mx| h = @min(h, mx);
                                if (self.getMinDim(cid, .min_height, cross_avail)) |mn| h = @max(h, mn);
                                child.geometry.height = h;
                                child.layout_h = h; // keep the measure-pass cache honest
                            }
                        }
                        j += 1;
                    }
                }
            } else if (remaining < 0 and total_flex_shrink > 0) {
                // CSS-correct shrink: each item shrinks proportionally to
                // flex-shrink × base-size, items that hit 0 freeze, and the
                // remaining deficit is redistributed (multi-pass — §9.7).
                const MAX_FLEX = 256;
                var base: [MAX_FLEX]f32 = undefined;
                var frozen: [MAX_FLEX]bool = undefined;
                const n = @min(line_count, MAX_FLEX);
                var bi: usize = 0;
                while (bi < n) : (bi += 1) {
                    const cid = flow_children.get(current_idx + bi);
                    const child = self.registry.getNode(cid).?;
                    base[bi] = if (is_row) child.geometry.width else child.geometry.height;
                    frozen[bi] = self.getFlexShrink(cid) <= 0; // shrink:0 never shrinks
                }
                var pass: usize = 0;
                while (pass < n) : (pass += 1) {
                    var used: f32 = 0;
                    var gi: usize = 0;
                    while (gi < n) : (gi += 1) {
                        const cid = flow_children.get(current_idx + gi);
                        const child = self.registry.getNode(cid).?;
                        used += (if (is_row) child.geometry.width else child.geometry.height) + self.mainMargins(cid, is_row);
                        if (gi > 0) used += explicit_gap;
                    }
                    const deficit = used - main_avail;
                    if (deficit <= 0.01) break;
                    var sum_w: f32 = 0;
                    gi = 0;
                    while (gi < n) : (gi += 1) if (!frozen[gi]) {
                        sum_w += self.getFlexShrink(flow_children.get(current_idx + gi)) * base[gi];
                    };
                    if (sum_w <= 0) break;
                    var any_froze = false;
                    gi = 0;
                    while (gi < n) : (gi += 1) if (!frozen[gi]) {
                        const cid = flow_children.get(current_idx + gi);
                        const child = self.registry.getNode(cid).?;
                        const w = self.getFlexShrink(cid) * base[gi];
                        const cur = if (is_row) child.geometry.width else child.geometry.height;
                        // Floor at min-width/min-height (else 0) — items freeze there.
                        const min_main = self.getMinDim(cid, if (is_row) .min_width else .min_height, main_avail) orelse 0;
                        var target = cur - (w / sum_w) * deficit;
                        const floor = @max(min_main, 0);
                        if (target <= floor) {
                            target = floor;
                            frozen[gi] = true;
                            any_froze = true;
                        }
                        if (is_row) child.geometry.width = target else child.geometry.height = target;
                        child.measured_gen = self.gen; // shrunk → must be re-placed
                    };
                    if (!any_froze) break; // distribution converged with nothing newly clamped
                }
                // Recompute the line's main extent from the resolved sizes.
                line_main_size = 0;
                var ri: usize = 0;
                while (ri < line_count) : (ri += 1) {
                    const cid = flow_children.get(current_idx + ri);
                    const child = self.registry.getNode(cid).?;
                    line_main_size += (if (is_row) child.geometry.width else child.geometry.height) + self.mainMargins(cid, is_row);
                    if (ri > 0) line_main_size += explicit_gap;
                }
                remaining = main_avail - line_main_size;
            }

            // A line item whose final main size differs from last solve's must be
            // re-placed even if grow/shrink didn't touch it (e.g. it was shrunk
            // last solve and isn't now). Checked before placing this line.
            {
                var ci = current_idx;
                while (ci < current_idx + line_count and ci < prev_main.len) : (ci += 1) {
                    const child = self.registry.getNode(flow_children.get(ci)).?;
                    const now = if (is_row) child.geometry.width else child.geometry.height;
                    if (now != prev_main.get(ci)) child.measured_gen = self.gen; // resized → re-place
                }
            }

            // Justify Content
            const origin_main = if (is_row) px + pad_left + border_w else py + pad_top + border_w;
            var cursor = origin_main;
            var dynamic_gap = explicit_gap;

            switch (justify) {
                .flex_start => {},
                .flex_end => cursor += remaining,
                .center => cursor += remaining / 2.0,
                .space_between => {
                    if (line_count > 1) dynamic_gap += remaining / @as(f32, @floatFromInt(line_count - 1));
                },
                .space_around => {
                    if (line_count > 0) {
                        dynamic_gap += remaining / @as(f32, @floatFromInt(line_count));
                        cursor += dynamic_gap / 2.0;
                    }
                },
                .space_evenly => {
                    // Equal space before, between, and after every item: n items →
                    // (n+1) equal gaps carved from the free space.
                    if (line_count > 0) {
                        const slice = remaining / @as(f32, @floatFromInt(line_count + 1));
                        dynamic_gap += slice;
                        cursor += slice;
                    }
                },
            }

            // Cross extent used for align-items. Per §9.4 step 8, a SINGLE-line flex
            // container gives its line the container's inner cross size, full stop —
            // it is not max'd with the content. Taking the max let one oversized child
            // raise the line above the container and drag every stretched sibling up
            // with it (a 20px chip next to a 90px thumbnail became 90px tall).
            // A wrapping container with everything on one line is still a single-line
            // container, hence the check rather than a plain `is_wrap` test; only a
            // genuinely multi-line container keeps content-sized, top-stacked lines.
            // (Distributing leftover cross space across multiple lines is
            // `align-content: stretch`, which this engine does not implement — same as
            // Yoga, unlike CSS/Taffy.)
            const single_line = current_idx == 0 and line_count == flow_children.len;
            const align_cross = if (is_wrap and !single_line) line_cross_size else cross_avail;

            // Baseline: pre-compute the line's max ascent so each child can be
            // dropped to share one baseline. Only meaningful on a row's cross axis.
            // Computed for every row (not just align-items: baseline) because
            // align-self lets an individual child opt into baseline.
            var line_max_ascent: f32 = 0;
            if (is_row) {
                var bk = current_idx;
                while (bk < current_idx + line_count) : (bk += 1) {
                    line_max_ascent = @max(line_max_ascent, self.ascentOf(flow_children.get(bk)));
                }
            }

            // Place items in line
            var j = current_idx;
            while (j < current_idx + line_count) {
                const cid = flow_children.get(j);
                const child = self.registry.getNode(cid).?;
                const m_top = self.getDim(cid, .margin_top);
                const m_bottom = self.getDim(cid, .margin_bottom);
                const m_left = self.getDim(cid, .margin_left);
                const m_right = self.getDim(cid, .margin_right);

                // A child's own `align_self` overrides the parent's align_items.
                const child_align = self.alignSelf(cid) orelse align_val;

                if (is_row) {
                    const cross_origin = py + pad_top + border_w + cross_cursor;
                    var cross_pos: f32 = cross_origin + m_top;
                    switch (child_align) {
                        .flex_start => {},
                        .center => cross_pos = cross_origin + (align_cross - child.geometry.height) / 2.0,
                        .flex_end => cross_pos = cross_origin + align_cross - child.geometry.height - m_bottom,
                        .stretch => {
                            // No definite height → fill the line's cross size (clamped).
                            // A path node's size is its own geometry (vertex AABB) —
                            // never stretch it.
                            if (child.node_type != .path and !self.hasDefiniteDim(cid, .height)) {
                                var target = align_cross - m_top - m_bottom;
                                if (self.getMaxDim(cid, .max_height, cross_avail)) |mx| target = @min(target, mx);
                                if (self.getMinDim(cid, .min_height, cross_avail)) |mn| target = @max(target, mn);
                                // Only when the size actually CHANGES: `measured_gen`
                                // defeats the skip in `place`, and a placed parent
                                // marks its children, so marking on a no-op write
                                // cascades down every chain of cross-unsized boxes and
                                // re-places the whole tree each frame.
                                if (target > 0 and child.geometry.height != target) {
                                    child.geometry.height = target;
                                    child.measured_gen = self.gen; // resized → force re-place
                                }
                            }
                        },
                        .baseline => cross_pos = cross_origin + m_top + (line_max_ascent - self.ascentOf(cid)),
                    }
                    cursor += m_left;
                    self.place(cid, cursor, cross_pos);
                    cursor += child.geometry.width + m_right + dynamic_gap;
                } else {
                    const cross_origin = px + pad_left + border_w + cross_cursor;
                    var cross_pos: f32 = cross_origin + m_left;
                    switch (child_align) {
                        // baseline has no column meaning → treat as flex_start.
                        .flex_start, .baseline => {},
                        .center => cross_pos = cross_origin + (align_cross - child.geometry.width) / 2.0,
                        .flex_end => cross_pos = cross_origin + align_cross - child.geometry.width - m_right,
                        .stretch => {
                            if (child.node_type != .path and !self.hasDefiniteDim(cid, .width)) {
                                var target = align_cross - m_left - m_right;
                                if (self.getMaxDim(cid, .max_width, cross_avail)) |mx| target = @min(target, mx);
                                if (self.getMinDim(cid, .min_width, cross_avail)) |mn| target = @max(target, mn);
                                if (target > 0 and child.geometry.width != target) {
                                    child.geometry.width = target;
                                    child.measured_gen = self.gen; // resized → force re-place
                                }
                            }
                        },
                    }
                    cursor += m_top;
                    self.place(cid, cross_pos, cursor);
                    cursor += child.geometry.height + m_bottom + dynamic_gap;
                }
                j += 1;
            }

            cross_cursor += line_cross_size + cross_gap;
            current_idx += line_count;
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// The node's declared width/height, or null when it sizes from content: unset,
    /// or the `auto` keyword (a present property whose computed value is "from
    /// content" — see `hasDefiniteDim`). `fill` (`.fill_parent`) is declared: 100%.
    fn explicitSize(self: *const LayoutEngine, node_id: reg.NodeId, key: props.LayoutKey) ?props.PropValue {
        const v = self.store.getLayout(node_id, key) orelse return null;
        if (v == .keyword and v.keyword == .auto) return null;
        return v;
    }

    fn resolveDim(prop: props.PropValue, parent_size: f32) f32 {
        if (prop == .keyword and prop.keyword == .fill_parent) {
            return if (parent_size == std.math.floatMax(f32)) 0 else @max(parent_size, 0);
        }
        if (prop != .dimension) return 0;
        if (prop.dimension.unit == .percent and parent_size == std.math.floatMax(f32)) return 0;
        const raw = switch (prop.dimension.unit) {
            .px => prop.dimension.value,
            // A percentage resolves against a non-negative containing block: when
            // the parent's inner size is already negative (padding/border exceeds
            // its width) there is no space to take a fraction of.
            .percent => (prop.dimension.value / 100.0) * @max(parent_size, 0),
            .pt => prop.dimension.value, // pt fallback
        };
        // A used length is never negative in CSS — negative input just means the
        // box collapses, its content overflows.
        return @max(raw, 0);
    }

    fn getDim(self: *const LayoutEngine, node_id: reg.NodeId, key: props.LayoutKey) f32 {
        if (self.store.getLayout(node_id, key)) |p| {
            if (p == .dimension and p.dimension.unit == .px) return p.dimension.value;
        }
        return 0.0;
    }

    fn getStyleDim(self: *const LayoutEngine, node_id: reg.NodeId, key: props.StyleKey) f32 {
        if (self.store.getStyle(node_id, key)) |p| {
            if (p == .dimension and p.dimension.unit == .px) return p.dimension.value;
        }
        return 0.0;
    }

    fn isRow(self: *const LayoutEngine, node_id: reg.NodeId) bool {
        if (self.store.getLayout(node_id, .flex_direction)) |fd| {
            if (fd == .keyword) return fd.keyword == .row;
            if (fd == .string) return std.mem.eql(u8, fd.string, "row");
        }
        return false; // default: column
    }

    fn isAbsolute(self: *const LayoutEngine, node_id: reg.NodeId) bool {
        if (self.store.getLayout(node_id, .position)) |pos| {
            if (pos == .keyword) return pos.keyword == .absolute;
            if (pos == .string) return std.mem.eql(u8, pos.string, "absolute");
        }
        return false;
    }

    fn justifyContent(self: *const LayoutEngine, node_id: reg.NodeId) JustifyContent {
        if (self.store.getLayout(node_id, .justify_content)) |jc| {
            if (jc == .keyword) {
                return switch (jc.keyword) {
                    .center => .center,
                    .flex_end => .flex_end,
                    .space_between => .space_between,
                    .space_around => .space_around,
                    .space_evenly => .space_evenly,
                    else => .flex_start,
                };
            }
            if (jc == .string) {
                if (std.mem.eql(u8, jc.string, "space-between")) return .space_between;
                if (std.mem.eql(u8, jc.string, "space-around")) return .space_around;
                if (std.mem.eql(u8, jc.string, "space-evenly")) return .space_evenly;
                if (std.mem.eql(u8, jc.string, "flex-end")) return .flex_end;
                if (std.mem.eql(u8, jc.string, "center")) return .center;
            }
        }
        return .flex_start;
    }

    /// Whether `key` (.width/.height) is a DEFINITE size, which is what §9.4 step 11
    /// tests before stretching. A present-but-`auto` value is not definite: `auto`
    /// spells "size me from content", so treating it as declared would skip stretch
    /// and hand back the zero-size box the stretch default exists to prevent.
    fn hasDefiniteDim(self: *const LayoutEngine, node_id: reg.NodeId, key: props.LayoutKey) bool {
        const v = self.store.getLayout(node_id, key) orelse return false;
        if (v == .keyword and v.keyword == .auto) return false;
        return true;
    }

    fn alignItems(self: *const LayoutEngine, node_id: reg.NodeId) AlignItems {
        if (self.store.getLayout(node_id, .align_items)) |ai| {
            if (ai == .keyword) return switch (ai.keyword) {
                .center => .center,
                .flex_end => .flex_end,
                .stretch => .stretch,
                .baseline => .baseline,
                else => .flex_start,
            };
            if (ai == .string) {
                if (std.mem.eql(u8, ai.string, "center")) return .center;
                if (std.mem.eql(u8, ai.string, "flex-start")) return .flex_start;
                if (std.mem.eql(u8, ai.string, "flex-end")) return .flex_end;
                if (std.mem.eql(u8, ai.string, "stretch")) return .stretch;
                if (std.mem.eql(u8, ai.string, "baseline")) return .baseline;
            }
        }
        // Unset (and unrecognized) → `stretch`, matching CSS's initial `normal`,
        // Yoga and Taffy. A child that declares the cross dimension is skipped by
        // the stretch branch, so this never overrides an explicit size — but it
        // does mean a contentless box (divider, rule, spacer) fills its line
        // instead of collapsing to zero.
        return .stretch;
    }

    /// A child's `align_self`, or null when unset (→ inherit `align_items`).
    /// `auto` also means inherit. Shares the `AlignItems` keyword vocabulary.
    fn alignSelf(self: *const LayoutEngine, node_id: reg.NodeId) ?AlignItems {
        if (self.store.getLayout(node_id, .align_self)) |as| {
            if (as == .keyword) return switch (as.keyword) {
                .center => .center,
                .flex_end => .flex_end,
                .flex_start => .flex_start,
                .stretch => .stretch,
                .baseline => .baseline,
                else => null, // auto / unrelated keyword → inherit
            };
            if (as == .string) {
                if (std.mem.eql(u8, as.string, "center")) return .center;
                if (std.mem.eql(u8, as.string, "flex-end")) return .flex_end;
                if (std.mem.eql(u8, as.string, "flex-start")) return .flex_start;
                if (std.mem.eql(u8, as.string, "stretch")) return .stretch;
                if (std.mem.eql(u8, as.string, "baseline")) return .baseline;
            }
        }
        return null;
    }

    /// Approximate text ascent of a node for `baseline` alignment.
    fn ascentOf(self: *const LayoutEngine, node_id: reg.NodeId) f32 {
        return self.fontSize(node_id) * BASELINE_ASCENT_RATIO;
    }

    /// Updates and caches the text layout, returning the bounds
    fn updateTextLayout(self: *LayoutEngine, node_id: reg.NodeId) struct { w: f32, h: f32 } {
        const fs = self.fontSize(node_id);
        const node = self.registry.getNode(node_id) orelse return .{ .w = 0, .h = 0 };
        const pad_left = self.getDim(node_id, .padding_left);
        const pad_right = self.getDim(node_id, .padding_right);
        const pad_top = self.getDim(node_id, .padding_top);
        const pad_bottom = self.getDim(node_id, .padding_bottom);

        var w: f32 = pad_left + pad_right;
        var h: f32 = fs + pad_top + pad_bottom;

        if (self.store.getTextContent(node_id)) |c| {
            if (self.atlas) |atlas| {
                // Re-shape only when something that affects shaping changed: the
                // content/font (`text_dirty`) or the wrap width. A pure
                // available-height change leaves `last_shaped_w` untouched, so the
                // (expensive, HarfBuzz) shaping is skipped — this is what makes the
                // measure pass run twice per solve nearly free.
                const max_w = if (node.last_avail_w > 0) node.last_avail_w - pad_left - pad_right else 0;
                const alloc = self.registry.allocator;
                if (node.text_dirty or node.text_layout == null or max_w != node.last_shaped_w) {
                    const content_changed = node.text_dirty;
                    node.text_dirty = false;

                    // Content changed → the prev-width cache holds stale text; drop it.
                    if (content_changed) {
                        if (node.prev_text_layout) |p| {
                            p.deinit();
                            alloc.destroy(p);
                            node.prev_text_layout = null;
                            node.prev_shaped_w = -1.0;
                        }
                    }

                    if (!content_changed and node.prev_text_layout != null and max_w == node.prev_shaped_w) {
                        // Same content, and we already shaped this exact width last
                        // solve (the base<->grown ping-pong): swap it back in — no
                        // HarfBuzz. The displaced layout becomes the new prev slot.
                        const tmp_l = node.text_layout;
                        const tmp_w = node.last_shaped_w;
                        node.text_layout = node.prev_text_layout;
                        node.last_shaped_w = node.prev_shaped_w;
                        node.prev_text_layout = tmp_l;
                        node.prev_shaped_w = tmp_w;
                    } else {
                        // Re-shape. Keep the current layout as the prev slot (so a
                        // later swap back to its width is free), unless the content
                        // changed (then it's stale and must be freed).
                        if (content_changed) {
                            if (node.text_layout) |tl| {
                                tl.deinit();
                                alloc.destroy(tl);
                            }
                        } else {
                            if (node.prev_text_layout) |p| {
                                p.deinit();
                                alloc.destroy(p);
                            }
                            node.prev_text_layout = node.text_layout;
                            node.prev_shaped_w = node.last_shaped_w;
                        }
                        node.text_layout = null;
                        node.last_shaped_w = max_w;
                        self.registry.dbg_reshaped += 1;
                        const pref = atlas.fontIndexForRole(self.fontRole(node_id));
                        const ls = self.letterSpacing(node_id);
                        const lh = self.lineHeightFactor(node_id);
                        if (atlas.measureTextMultilinePref(c, fs, max_w, pref, ls, lh, alloc)) |layout| {
                            const tl_ptr = alloc.create(text_mod.TextLayoutInfo) catch null;
                            if (tl_ptr) |ptr| {
                                ptr.* = layout;
                                node.text_layout = ptr;
                            } else {
                                var mut_layout = layout;
                                mut_layout.deinit();
                            }
                        } else |_| {}
                    }
                }

                if (node.text_layout) |tl| {
                    w += tl.max_width;
                    h = @max(h, tl.total_height + pad_top + pad_bottom);
                }
            } else {
                // Fallback for when atlas is not provided (headless testing)
                // We don't have engine_id here, but we can pass 0 for now as a fallback since headless tests usually don't rely heavily on text measuring
                w += celeris_measure_text(0, c.ptr, c.len, fs);
                // Height stays `font_size + padding` here: an approximation that
                // ignores line count and `line_height`. Headless tests assert
                // geometry built on it, so it is left as is; real layout always has
                // an atlas and measures `lines × font_size × line_height`.
            }
        }
        return .{ .w = w, .h = h };
    }

    fn fontSize(self: *const LayoutEngine, node_id: reg.NodeId) f32 {
        if (self.store.getStyle(node_id, .font_size)) |fs| {
            if (fs == .dimension) return fs.dimension.value;
        }
        return 16.0;
    }

    fn letterSpacing(self: *const LayoutEngine, node_id: reg.NodeId) f32 {
        if (self.store.getStyle(node_id, .letter_spacing)) |v| {
            if (v == .number) return v.number;
        }
        return 0;
    }

    /// The node's `line_height` multiplier, or the engine default.
    fn lineHeightFactor(self: *const LayoutEngine, node_id: reg.NodeId) f32 {
        if (self.store.getStyle(node_id, .line_height)) |v| {
            if (v == .number) return text_mod.sanitizeLineHeight(v.number);
        }
        return text_mod.LINE_HEIGHT_FACTOR;
    }

    fn fontRole(self: *const LayoutEngine, node_id: reg.NodeId) text_mod.FontRole {
        if (self.store.getStyle(node_id, .font_role)) |v| {
            if (v == .number) return text_mod.roleFromOrdinal(v.number);
        }
        return .default;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Flexbox — align_items defaults to stretch (CSS initial), not flex_start" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root_id = try registry.createNode(.box);
    const bare_id = try registry.createNode(.box); // no cross dimension → stretches
    const sized_id = try registry.createNode(.box); // declares one → left alone
    registry.appendChild(root_id, bare_id);
    registry.appendChild(root_id, sized_id);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root_id);
    try store.registerNode(bare_id);
    try store.registerNode(sized_id);

    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 400, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .row });
    try store.setLayout(bare_id, .width, .{ .dimension = .{ .value = 4, .unit = .px } });
    try store.setLayout(sized_id, .width, .{ .dimension = .{ .value = 4, .unit = .px } });
    try store.setLayout(sized_id, .height, .{ .dimension = .{ .value = 20, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 400, 200);

    // The contentless box fills the line instead of collapsing to 0 — this is what
    // makes a divider/rule/spacer visible without the caller knowing to ask.
    try std.testing.expectApproxEqAbs(@as(f32, 200), registry.getNode(bare_id).?.geometry.height, 0.01);
    // Stretch never overrides an explicit cross size.
    try std.testing.expectApproxEqAbs(@as(f32, 20), registry.getNode(sized_id).?.geometry.height, 0.01);
}

test "Flexbox — stretch must not defeat incremental layout: one dirty leaf re-places almost nothing" {
    // The default being stretch means the stretch branch now runs on most of the
    // tree. It sets `measured_gen` to force a re-place — but if it does that even
    // when it assigns a size the node already had, the mark cascades down every
    // chain of cross-unsized boxes and one dirty leaf re-places the whole tree,
    // every frame. That is invisible to a geometry assertion, which is how it got
    // in; this asserts the skip counter instead.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const root_id = try b.openBox(); // column of rows, alignment left at the default
    try b.width(root_id, 400, .px);
    try b.height(root_id, 600, .px);
    var last_leaf: reg.NodeId = reg.NULL_NODE;
    var last_cell: reg.NodeId = reg.NULL_NODE;
    for (0..60) |_| {
        const row = try b.openBox();
        try b.height(row, 30, .px);
        try b.flexRow(row);
        for (0..3) |_| {
            const cell = try b.openBox(); // width only → stretch resizes its height
            try b.width(cell, 100, .px);
            // A child under the cell is what makes the cascade measurable: marking
            // the cell re-places its whole subtree, not just one node.
            const inner = try b.openBox();
            try b.width(inner, 20, .px);
            b.close();
            b.close();
            last_leaf = inner;
            last_cell = cell;
        }
        b.close();
    }
    b.close();

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 400, 600); // first solve
    engine.solve(root_id, 0, 0, 400, 600); // settle

    // Dirty a single leaf, then re-solve: the rest of the tree must still be skipped.
    registry.markLayoutDirty(last_leaf);
    engine.solve(root_id, 0, 0, 400, 600);

    // Settled tree, one dirty leaf: the 60 row subtrees get skipped wholesale and
    // only the dirty chain is re-placed. Verified to have teeth — dropping the
    // change-guard from the COLUMN branch (`.width`) makes this fail. The row
    // branch (`.height`) is guarded for the same reason but is not what this shape
    // exercises: a marked node deep enough to sit inside an already-skipped subtree
    // never gets visited, so the damage there depends on depth. The column branch is
    // the one that matters most anyway — `flex_direction` defaults to column, so
    // most containers cross-size on width.
    try std.testing.expect(registry.dbg_skipped >= 50);
    try std.testing.expect(registry.dbg_placed <= 10);
    // And the stretch still happened — the cells fill their row's height.
    try std.testing.expectApproxEqAbs(@as(f32, 30), registry.getNode(last_cell).?.geometry.height, 0.01);
}

test "Flexbox — an oversized sibling does not drag the rest of the line (single-line = container cross size)" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const row_id = try b.openBox(); // 300x44 bar, alignment left at the default
    try b.width(row_id, 300, .px);
    try b.height(row_id, 44, .px);
    try b.flexRow(row_id);
    const tall_id = try b.openBox(); // overflows the bar on purpose
    try b.width(tall_id, 10, .px);
    try b.height(tall_id, 100, .px);
    b.close();
    const chip_id = try b.openBox(); // content-sized on the cross axis
    try b.width(chip_id, 40, .px);
    b.close();
    b.close();

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(row_id, 0, 0, 300, 44);

    // The chip stretches to the BAR (44), not to its oversized sibling (100).
    try std.testing.expectApproxEqAbs(@as(f32, 44), registry.getNode(chip_id).?.geometry.height, 0.01);
    // The oversized child keeps its declared height and simply overflows, alone.
    try std.testing.expectApproxEqAbs(@as(f32, 100), registry.getNode(tall_id).?.geometry.height, 0.01);
}

test "Flexbox — min wins over max in the measure path too (CSS 2.1 §10.4)" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const row_id = try b.openBox();
    try b.width(row_id, 400, .px);
    try b.height(row_id, 200, .px);
    try b.flexRow(row_id);
    // Conflicting bounds. The node declares a height, so it is the MEASURE path that
    // resolves it (stretch skips definite sizes) — the two paths must now agree.
    const kid = try b.openBox();
    try b.width(kid, 50, .px);
    try b.height(kid, 10, .px);
    try store.setLayout(kid, .min_height, .{ .dimension = .{ .value = 120, .unit = .px } });
    try store.setLayout(kid, .max_height, .{ .dimension = .{ .value = 60, .unit = .px } });
    b.close();
    b.close();

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(row_id, 0, 0, 400, 200);

    try std.testing.expectApproxEqAbs(@as(f32, 120), registry.getNode(kid).?.geometry.height, 0.01);
}

test "Flexbox — height: auto is not a definite size, so stretch still applies" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const row_id = try b.openBox();
    try b.width(row_id, 300, .px);
    try b.height(row_id, 80, .px);
    try b.flexRow(row_id);
    const kid = try b.openBox();
    try b.width(kid, 20, .px);
    // `auto` is a PRESENT property whose computed value is "size from content". A
    // presence check would read it as declared and skip stretch → zero-height box.
    try store.setLayout(kid, .height, .{ .keyword = .auto });
    b.close();
    b.close();

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(row_id, 0, 0, 300, 80);

    try std.testing.expectApproxEqAbs(@as(f32, 80), registry.getNode(kid).?.geometry.height, 0.01);
}

test "Flexbox — a wrapping container whose items fit on one line still stretches them" {
    // flex_wrap does not by itself make a container multi-line. When everything fits
    // on one line it is a single-line container and §9.4 step 8 applies, so a
    // contentless divider inside a wrapping toolbar must not collapse to zero.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const bar_id = try b.openBox();
    try b.width(bar_id, 300, .px);
    try b.height(bar_id, 40, .px);
    try b.flexRow(bar_id);
    try store.setLayout(bar_id, .flex_wrap, .{ .boolean = true });
    const sep_id = try b.openBox(); // the sash/divider shape: no content, no height
    try b.width(sep_id, 4, .px);
    b.close();
    b.close();

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(bar_id, 0, 0, 300, 40);

    try std.testing.expectApproxEqAbs(@as(f32, 40), registry.getNode(sep_id).?.geometry.height, 0.01);
}

test "Flexbox — an explicit align_items: flex-start still wins over the default" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root_id = try registry.createNode(.box);
    const child_id = try registry.createNode(.box);
    registry.appendChild(root_id, child_id);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root_id);
    try store.registerNode(child_id);

    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 400, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .row });
    try store.setLayout(child_id, .width, .{ .dimension = .{ .value = 4, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);

    // Both spellings of the opt-out: the keyword and the CSS string.
    try store.setLayout(root_id, .align_items, .{ .keyword = .flex_start });
    engine.solve(root_id, 0, 0, 400, 200);
    try std.testing.expectApproxEqAbs(@as(f32, 0), registry.getNode(child_id).?.geometry.height, 0.01);

    // The store takes ownership of `.string` values, so it needs one it may free.
    try store.setLayout(root_id, .align_items, try store.ownedString("flex-start"));
    registry.getNode(child_id).?.geometry.height = 0;
    engine.solve(root_id, 0, 0, 400, 200);
    try std.testing.expectApproxEqAbs(@as(f32, 0), registry.getNode(child_id).?.geometry.height, 0.01);
}

test "Flexbox — percent sizing and row positioning (flex_start)" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root_id = try registry.createNode(.box);
    const child1_id = try registry.createNode(.box);
    const child2_id = try registry.createNode(.box);

    registry.appendChild(root_id, child1_id);
    registry.appendChild(root_id, child2_id);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root_id);
    try store.registerNode(child1_id);
    try store.registerNode(child2_id);

    // Root: 1000×1000, flex-direction row
    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 1000, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 1000, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .row });

    // Child 1: 50% width
    try store.setLayout(child1_id, .width, .{ .dimension = .{ .value = 50, .unit = .percent } });
    try store.setLayout(child1_id, .height, .{ .dimension = .{ .value = 100, .unit = .px } });

    // Child 2: 25% width
    try store.setLayout(child2_id, .width, .{ .dimension = .{ .value = 25, .unit = .percent } });
    try store.setLayout(child2_id, .height, .{ .dimension = .{ .value = 50, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 10, 20, 1000, 1000);

    const root = registry.getNode(root_id).?;
    try std.testing.expectEqual(@as(f32, 10), root.geometry.x);
    try std.testing.expectEqual(@as(f32, 20), root.geometry.y);

    const c1 = registry.getNode(child1_id).?;
    try std.testing.expectEqual(@as(f32, 500), c1.geometry.width); // 50% of 1000
    try std.testing.expectEqual(@as(f32, 10), c1.geometry.x);
    try std.testing.expectEqual(@as(f32, 20), c1.geometry.y);

    const c2 = registry.getNode(child2_id).?;
    try std.testing.expectEqual(@as(f32, 250), c2.geometry.width); // 25% of 1000
    // c2.x = c1.x + c1.width = 10 + 500 = 510 (no gap in flex_start)
    try std.testing.expectEqual(@as(f32, 510), c2.geometry.x);
    try std.testing.expectEqual(@as(f32, 20), c2.geometry.y);
}

test "A path node intrinsically sizes to its vertex AABB, not a text layout" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const root = try registry.createNode(.box);
    const p = try registry.createNode(.path);
    registry.appendChild(root, p);
    try store.registerNode(root);
    try store.registerNode(p);

    var verts = [_]path_mod.PathVertex{
        .{ .x = 0, .y = 0 },
        .{ .x = 120, .y = 0 },
        .{ .x = 120, .y = 40, .c1x = 120, .c1y = 15, .c2x = 120, .c2y = 30 },
    };
    try store.setPath(p, &verts);

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 800, 600);

    // AABB max is (120, 40) — not 0 (measureChildrenExtent) and not a text size.
    try std.testing.expectEqual(@as(f32, 120), registry.getNode(p).?.geometry.width);
    try std.testing.expectEqual(@as(f32, 40), registry.getNode(p).?.geometry.height);

    // An explicit width still wins.
    try store.setLayout(p, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    engine.solve(root, 0, 0, 800, 600);
    try std.testing.expectEqual(@as(f32, 200), registry.getNode(p).?.geometry.width);
}

test "A full solve places a scrolled container's children at the shifted origin" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const root_id = try registry.createNode(.box);
    const child_id = try registry.createNode(.box);
    registry.appendChild(root_id, child_id);
    try store.registerNode(root_id);
    try store.registerNode(child_id);

    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 600, .unit = .px } });
    try store.setLayout(child_id, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(child_id, .height, .{ .dimension = .{ .value = 1000, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 800, 600);
    try std.testing.expectEqual(@as(f32, 0), registry.getNode(child_id).?.geometry.y);

    // Incremental path: the store write shifts geometry without a solve.
    try store.setLayout(root_id, .scroll_offset_y, .{ .dimension = .{ .value = -150, .unit = .px } });
    try std.testing.expectEqual(@as(f32, -150), registry.getNode(child_id).?.geometry.y);

    // Full-solve path: re-solving from scratch lands at the exact same position,
    // so both paths agree (the child is placed from py + scroll_offset_y).
    engine.solve(root_id, 0, 0, 800, 600);
    try std.testing.expectEqual(@as(f32, -150), registry.getNode(child_id).?.geometry.y);
    try std.testing.expectEqual(@as(f32, 0), registry.getNode(root_id).?.geometry.y);

    // Same round-trip agreement on X for scroll_offset_x.
    try store.setLayout(root_id, .scroll_offset_x, .{ .dimension = .{ .value = -120, .unit = .px } });
    try std.testing.expectEqual(@as(f32, -120), registry.getNode(child_id).?.geometry.x);
    engine.solve(root_id, 0, 0, 800, 600);
    try std.testing.expectEqual(@as(f32, -120), registry.getNode(child_id).?.geometry.x);
    try std.testing.expectEqual(@as(f32, -150), registry.getNode(child_id).?.geometry.y);
    try std.testing.expectEqual(@as(f32, 0), registry.getNode(root_id).?.geometry.x);
}

test "Flexbox — align-items stretch expands a cross-unsized child to the line" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root_id = try registry.createNode(.box);
    const child_id = try registry.createNode(.box);
    registry.appendChild(root_id, child_id);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root_id);
    try store.registerNode(child_id);

    // Row root 300×200, align-items: stretch. Child has a width but NO height.
    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 300, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .row });
    try store.setLayout(root_id, .align_items, .{ .keyword = .stretch });
    try store.setLayout(child_id, .width, .{ .dimension = .{ .value = 100, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 300, 200);

    // The child stretched to the container's cross size (200), width unchanged.
    try std.testing.expectEqual(@as(f32, 200), registry.getNode(child_id).?.geometry.height);
    try std.testing.expectEqual(@as(f32, 100), registry.getNode(child_id).?.geometry.width);
}

test "Flexbox — a grown text flex-child keeps its text height (regression: TreeView root row name)" {
    // Regression repro: a text node that is itself a
    // flex_grow child of a row (e.g. the TreeView row `name`, tree_view.zig)
    // was having its height clobbered to ~0 by the grow re-measure step, which
    // recomputed height via measureChildrenExtent as if the text were a box.
    // A childless text node reports 0 content height there, so the name was
    // vertically centered against a 0px box → drawn below its row line. Only
    // rows whose content leaves free space (remaining > 0) grow, which is why
    // the client saw it on the widest/shallowest row (the root) and not on
    // deeper rows whose long decorators fill the width.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const row_id = try registry.createNode(.box);
    const name_id = try registry.createNode(.text);
    registry.appendChild(row_id, name_id);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(row_id);
    try store.registerNode(name_id);

    // Row: 300×22, flex row, align-items center (matches TreeView row).
    try store.setLayout(row_id, .width, .{ .dimension = .{ .value = 300, .unit = .px } });
    try store.setLayout(row_id, .height, .{ .dimension = .{ .value = 22, .unit = .px } });
    try store.setLayout(row_id, .flex_direction, .{ .keyword = .row });
    try store.setLayout(row_id, .align_items, .{ .keyword = .center });
    // Name: text node, flex_grow 1, no explicit height (like tree_view.zig:450).
    try store.setLayout(name_id, .flex_grow, .{ .number = 1 });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(row_id, 0, 0, 300, 22);

    const name = registry.getNode(name_id).?;
    // Grows to fill the row's main axis…
    try std.testing.expectApproxEqAbs(@as(f32, 300), name.geometry.width, 0.01);
    // …but keeps its text height (single line = font_size default 16), not 0.
    try std.testing.expectApproxEqAbs(@as(f32, 16), name.geometry.height, 0.01);
    // …and is therefore centered on the row line, not shoved to the bottom.
    try std.testing.expectApproxEqAbs(@as(f32, 3), name.geometry.y, 0.01);
}

test "Flexbox — a hug-content box keeps its text child on one line (intrinsic sizing; DevTools chip regression)" {
    // A box with no explicit width in a row hugs its text child's intrinsic width.
    // The place pass used to re-measure that child against the just-hugged width;
    // because HarfBuzz shaping is narrower than the wrap loop's per-codepoint stb
    // advances, the last glyph wrapped ("DevTools" → "DevTool" / "s"). The fix
    // skips the place re-measure when the box size is unchanged since the measure
    // pass, and reuses the width-pass extent for height. This locks that in.
    const ttf = try loadRegressionFont(std.testing.allocator);
    defer std.testing.allocator.free(ttf);
    var atlas = try text_mod.FontAtlas.init(std.testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    // Build via the UIBuilder so text content is owned by the store's arena.
    var b = builder.UIBuilder.init(&registry, &store);
    const bar_id = try b.openBox(); // wide row, fixed height — like the title bar
    try b.width(bar_id, 900, .px);
    try b.height(bar_id, 44, .px);
    try b.flexRow(bar_id);
    try b.alignItems(bar_id, .center);
    const chip_id = try b.openBox(); // no explicit width → hugs the text (the pill)
    try b.flexRow(chip_id);
    try b.padding(chip_id, 0, 9, 0, 9);
    const text_id = try b.addText("DevTools");
    try b.fontSize(text_id, 11);
    b.close(); // chip
    b.close(); // bar

    var engine = LayoutEngine.init(&registry, &store, &atlas);
    engine.solve(bar_id, 0, 0, 900, 44);

    const text_node = registry.getNode(text_id).?;
    try std.testing.expect(text_node.text_layout != null);
    // The whole point: the text stays on a single line — no spurious wrap.
    try std.testing.expectEqual(@as(usize, 1), text_node.text_layout.?.lines.items.len);
    // And the chip hugged the content (nowhere near the 900px bar width).
    try std.testing.expect(registry.getNode(chip_id).?.geometry.width < 200);
}

test "Flexbox — cross-axis stretch on a hug-width row box doesn't rewrap its text (three-letter MenuBar label regression)" {
    // Isolated repro for the "Ver" -> "Ve"/"r" wrap seen when embedding MenuBar in
    // a custom caption: THREE hug levels deep — row (hug, no explicit height) >
    // bar (hug width, explicit height=44, align_items:stretch) > btn (hug width,
    // NO explicit height — sized by bar's stretch instead) > text. One level
    // deeper than the "DevTools chip" test above, and critically using `stretch`
    // instead of `center` — `place`'s width-or-height re-measure guard used to
    // fire on the HEIGHT half of that OR whenever stretch changed a hug-width
    // box's cross size, re-measuring `btn`'s text against `btn`'s own already
    // content-tight width (zero slack) and flipping the wrap decision. Fixed by
    // scoping the height-triggered re-measure to boxes whose width did NOT come
    // from the hug/intrinsic path (see the `width_is_hug` comment in `place`).
    const ttf = try loadRegressionFont(std.testing.allocator);
    defer std.testing.allocator.free(ttf);
    var atlas = try text_mod.FontAtlas.init(std.testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var b = builder.UIBuilder.init(&registry, &store);
    const row_id = try b.openBox(); // caption content row: hug, no explicit height
    try b.flexRow(row_id);
    try b.alignItems(row_id, .center);

    const bar_id = try b.openBox(); // MenuBar.hug=true: hug width, explicit height
    try b.flexShrink(bar_id, 0);
    try b.height(bar_id, 44, .px);
    try b.flexRow(bar_id);
    try b.alignItems(bar_id, .stretch);

    const btn_id = try b.openBox(); // a menu button: hug width, NO explicit height
    try b.flexShrink(btn_id, 0);
    try b.padding(btn_id, 0, 12, 0, 12);
    try b.flexRow(btn_id);
    try b.alignItems(btn_id, .center);
    const text_id = try b.addText("Ver");
    try b.fontSize(text_id, 14);
    b.close(); // btn
    b.close(); // bar
    b.close(); // row

    var engine = LayoutEngine.init(&registry, &store, &atlas);
    engine.solve(row_id, 0, 0, 900, 44);

    const text_node = registry.getNode(text_id).?;
    try std.testing.expect(text_node.text_layout != null);
    try std.testing.expectEqual(@as(usize, 1), text_node.text_layout.?.lines.items.len);
    // And btn actually got stretched to the bar's full height, not left at the
    // text's intrinsic (short) hug height — the fix must not silently drop that.
    try std.testing.expectApproxEqAbs(@as(f32, 44), registry.getNode(btn_id).?.geometry.height, 0.01);
}

test "Flexbox — under the default stretch, a text node's BOX fills the line but its measured text does not grow" {
    // The blast radius of defaulting align_items to stretch lands here: a text node
    // with no explicit height is exactly the kind of child stretch resizes. What must
    // NOT change is the shaped text itself — same line count, same glyph height, same
    // top edge. Only the box grows, so a background or border on the text node now
    // paints the full row height instead of hugging the glyphs.
    const ttf = try loadRegressionFont(std.testing.allocator);
    defer std.testing.allocator.free(ttf);
    var atlas = try text_mod.FontAtlas.init(std.testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var b = builder.UIBuilder.init(&registry, &store);
    const row_id = try b.openBox(); // 300x44 row, alignment left at the default
    try b.width(row_id, 300, .px);
    try b.height(row_id, 44, .px);
    try b.flexRow(row_id);
    const text_id = try b.addText("Celeris");
    try b.fontSize(text_id, 16);
    b.close();

    var engine = LayoutEngine.init(&registry, &store, &atlas);
    engine.solve(row_id, 0, 0, 300, 44);

    const text_node = registry.getNode(text_id).?;
    // The shaped text is untouched: one line, and the layout's own height is the
    // font metric, not the row's 44.
    try std.testing.expect(text_node.text_layout != null);
    try std.testing.expectEqual(@as(usize, 1), text_node.text_layout.?.lines.items.len);
    try std.testing.expect(text_node.text_layout.?.total_height < 44);
    // The glyphs still start at the top of the row — stretch grows the box downward,
    // it does not re-position content.
    try std.testing.expectApproxEqAbs(@as(f32, 0), text_node.geometry.y, 0.01);
    // But the box now fills the cross axis.
    try std.testing.expectApproxEqAbs(@as(f32, 44), text_node.geometry.height, 0.01);
    // Width is still hugged to the measured text, not stretched (that is the main axis).
    try std.testing.expect(text_node.geometry.width > 0);
    try std.testing.expect(text_node.geometry.width < 300);
}

test "Flexbox — a text node with an explicit height opts out of stretch and keeps its measured wrap" {
    // The escape hatch, and the multi-line measurement it has to preserve: a narrow
    // wrap width forces >1 line, and the declared height must survive the stretch pass.
    const ttf = try loadRegressionFont(std.testing.allocator);
    defer std.testing.allocator.free(ttf);
    var atlas = try text_mod.FontAtlas.init(std.testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var b = builder.UIBuilder.init(&registry, &store);
    const row_id = try b.openBox();
    try b.width(row_id, 80, .px);
    try b.height(row_id, 200, .px);
    try b.flexRow(row_id);
    const text_id = try b.addText("Celeris layout engine wraps this");
    try b.fontSize(text_id, 16);
    try b.height(text_id, 30, .px); // declared → stretch must skip this child
    b.close();

    var engine = LayoutEngine.init(&registry, &store, &atlas);
    engine.solve(row_id, 0, 0, 80, 200);

    const text_node = registry.getNode(text_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 30), text_node.geometry.height, 0.01);
    // The narrow row wrapped the text: measurement still reports every line.
    try std.testing.expect(text_node.text_layout != null);
    try std.testing.expect(text_node.text_layout.?.lines.items.len > 1);
}

test "Flexbox — align-items baseline aligns text of different sizes on one baseline" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root_id = try registry.createNode(.box);
    const small_id = try registry.createNode(.box);
    const big_id = try registry.createNode(.box);
    registry.appendChild(root_id, small_id);
    registry.appendChild(root_id, big_id);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root_id);
    try store.registerNode(small_id);
    try store.registerNode(big_id);

    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 300, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .row });
    try store.setLayout(root_id, .align_items, .{ .keyword = .baseline });

    // Two boxes with explicit sizes but different font sizes (drives ascent).
    inline for (.{ .{ small_id, 10.0 }, .{ big_id, 20.0 } }) |pair| {
        try store.setLayout(pair[0], .width, .{ .dimension = .{ .value = 50, .unit = .px } });
        try store.setLayout(pair[0], .height, .{ .dimension = .{ .value = 30, .unit = .px } });
        try store.setStyle(pair[0], .font_size, .{ .dimension = .{ .value = pair[1], .unit = .px } });
    }

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 300, 100);

    // ascent = font_size * 0.8 → small 8, big 16; max = 16. Tops: small +8, big +0.
    const small_y = registry.getNode(small_id).?.geometry.y;
    const big_y = registry.getNode(big_id).?.geometry.y;
    try std.testing.expectApproxEqAbs(@as(f32, 8), small_y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), big_y, 0.001);
    // Baselines coincide: y + ascent is equal for both.
    try std.testing.expectApproxEqAbs(small_y + 8.0, big_y + 16.0, 0.001);
}

test "Flexbox — shrink-to-content height for column box" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root_id = try registry.createNode(.box);
    const child1_id = try registry.createNode(.box);
    const child2_id = try registry.createNode(.box);
    registry.appendChild(root_id, child1_id);
    registry.appendChild(root_id, child2_id);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root_id);
    try store.registerNode(child1_id);
    try store.registerNode(child2_id);

    // Root has explicit width but NO explicit height → must shrink to children
    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 400, .unit = .px } });
    // children each 50px tall
    try store.setLayout(child1_id, .height, .{ .dimension = .{ .value = 50, .unit = .px } });
    try store.setLayout(child1_id, .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(child2_id, .height, .{ .dimension = .{ .value = 80, .unit = .px } });
    try store.setLayout(child2_id, .width, .{ .dimension = .{ .value = 100, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 400, 600);

    const root = registry.getNode(root_id).?;
    // Shrink-to-content: 50 + 80 = 130px total
    try std.testing.expectEqual(@as(f32, 130), root.geometry.height);
}

/// Builds a row container (no wrap) of fixed width with `n` children and returns
/// the ids so a test can set per-child flex props.
fn rowContainer(registry: *reg.UIRegistry, store: *props.PropertyStore, width: f32, ids: []reg.NodeId) !reg.NodeId {
    const root = try registry.createNode(.box);
    try store.registerNode(root);
    try store.setLayout(root, .width, .{ .dimension = .{ .value = width, .unit = .px } });
    try store.setLayout(root, .height, .{ .dimension = .{ .value = 50, .unit = .px } });
    try store.setLayout(root, .flex_direction, .{ .keyword = .row });
    for (ids) |*slot| {
        const c = try registry.createNode(.box);
        try store.registerNode(c);
        try store.setLayout(c, .height, .{ .dimension = .{ .value = 50, .unit = .px } });
        registry.appendChild(root, c);
        slot.* = c;
    }
    return root;
}

test "flex-basis: sets the base main size; grow fills from it" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var ids: [2]reg.NodeId = undefined;
    const root = try rowContainer(&registry, &store, 300, &ids);
    // Two items with flex-basis 100, no width.
    for (ids) |c| try store.setLayout(c, .flex_basis, .{ .dimension = .{ .value = 100, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 300, 50);
    try std.testing.expectApproxEqAbs(@as(f32, 100), registry.getNode(ids[0]).?.geometry.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), registry.getNode(ids[1]).?.geometry.width, 0.01);

    // Add grow 1 each → the 100px of free space splits evenly from the basis.
    for (ids) |c| try store.setLayout(c, .flex_grow, .{ .number = 1 });
    registry.getNode(root).?.layout_dirty = true;
    registry.getNode(ids[0]).?.layout_dirty = true;
    registry.getNode(ids[1]).?.layout_dirty = true;
    engine.solve(root, 0, 0, 300, 50);
    try std.testing.expectApproxEqAbs(@as(f32, 150), registry.getNode(ids[0]).?.geometry.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), registry.getNode(ids[1]).?.geometry.width, 0.01);
}

test "shrink is weighted by flex-shrink × base size" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var ids: [2]reg.NodeId = undefined;
    const root = try rowContainer(&registry, &store, 240, &ids); // deficit 60 (200+100-240)
    try store.setLayout(ids[0], .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(ids[1], .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(ids[0], .flex_shrink, .{ .number = 1 });
    try store.setLayout(ids[1], .flex_shrink, .{ .number = 1 });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 240, 50);
    // Weighted by base: A loses 60·200/300=40 → 160; B loses 60·100/300=20 → 80.
    // (Unweighted would give 170/70 — this asserts the CSS-correct split.)
    try std.testing.expectApproxEqAbs(@as(f32, 160), registry.getNode(ids[0]).?.geometry.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 80), registry.getNode(ids[1]).?.geometry.width, 0.5);
}

test "shrink freezes items at 0 and redistributes the deficit" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var ids: [2]reg.NodeId = undefined;
    const root = try rowContainer(&registry, &store, 30, &ids); // big deficit (110→30)
    try store.setLayout(ids[0], .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(ids[1], .width, .{ .dimension = .{ .value = 10, .unit = .px } });
    try store.setLayout(ids[0], .flex_shrink, .{ .number = 1 });
    try store.setLayout(ids[1], .flex_shrink, .{ .number = 5 }); // shrinks fast → hits 0

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 30, 50);
    // B (small + high shrink) bottoms out at 0; A absorbs the rest so the line fits.
    try std.testing.expectApproxEqAbs(@as(f32, 0), registry.getNode(ids[1]).?.geometry.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 30), registry.getNode(ids[0]).?.geometry.width, 0.5);
}

test "min-width: measure clamps a too-small size up to min-width" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    const box = try registry.createNode(.box);
    try store.registerNode(box);
    try store.setLayout(box, .width, .{ .dimension = .{ .value = 10, .unit = .px } });
    try store.setLayout(box, .min_width, .{ .dimension = .{ .value = 40, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(box, 0, 0, 400, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 40), registry.getNode(box).?.geometry.width, 0.01);
}

test "min-width floors shrink: a min item freezes and the deficit redistributes" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var ids: [2]reg.NodeId = undefined;
    const root = try rowContainer(&registry, &store, 100, &ids); // deficit 300 (200+200-100)
    try store.setLayout(ids[0], .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(ids[1], .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(ids[0], .flex_shrink, .{ .number = 1 });
    try store.setLayout(ids[1], .flex_shrink, .{ .number = 1 });
    try store.setLayout(ids[0], .min_width, .{ .dimension = .{ .value = 80, .unit = .px } }); // A can't go below 80

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 100, 50);
    // A floors at 80 (would be 50 unconstrained); B absorbs the rest → 20.
    try std.testing.expectApproxEqAbs(@as(f32, 80), registry.getNode(ids[0]).?.geometry.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 20), registry.getNode(ids[1]).?.geometry.width, 0.5);
}

test "Flexbox — justify_content center" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root_id = try registry.createNode(.box);
    const child_id = try registry.createNode(.box);
    registry.appendChild(root_id, child_id);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root_id);
    try store.registerNode(child_id);

    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 400, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .row });
    try store.setLayout(root_id, .justify_content, .{ .keyword = .center });

    try store.setLayout(child_id, .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(child_id, .height, .{ .dimension = .{ .value = 50, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 400, 100);

    const child = registry.getNode(child_id).?;
    // remaining = 400 - 100 = 300; center offset = 150
    try std.testing.expectEqual(@as(f32, 150), child.geometry.x);
}

test "Flexbox — percent children follow flex-grown parent size" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root_id = try registry.createNode(.box);
    const body_id = try registry.createNode(.box);
    const child_id = try registry.createNode(.box);
    registry.appendChild(root_id, body_id);
    registry.appendChild(body_id, child_id);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root_id);
    try store.registerNode(body_id);
    try store.registerNode(child_id);

    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .column });

    try store.setLayout(body_id, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
    try store.setLayout(body_id, .flex_grow, .{ .number = 1 });
    try store.setLayout(body_id, .flex_direction, .{ .keyword = .column });

    try store.setLayout(child_id, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
    try store.setLayout(child_id, .height, .{ .dimension = .{ .value = 100, .unit = .percent } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 200, 100);

    const body = registry.getNode(body_id).?;
    const child = registry.getNode(child_id).?;

    try std.testing.expectApproxEqAbs(@as(f32, 100), body.geometry.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), child.geometry.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), child.geometry.height, 0.01);
}

test "Flexbox — height:100% child of a flex-grow COLUMN slot (no explicit dims) resolves" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    // column root, definite 400x300
    const root = try b.openBox();
    try b.width(root, 400, .px);
    try b.height(root, 300, .px);
    // flex_direction column
    try store.setLayout(root, .flex_direction, .{ .keyword = .column });

    // fixed header
    const header = try b.openBox();
    try b.height(header, 40, .px);
    b.close();

    // flex-grow slot: NO explicit width/height, just grow:1 (regression case)
    const slot = try b.openBox();
    try store.setLayout(slot, .flex_grow, .{ .number = 1 });
    try store.setLayout(slot, .flex_direction, .{ .keyword = .column });

    // mountReactiveFill anchor: width/height 100%
    const anchor = try b.openBox();
    try store.setLayout(anchor, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
    try store.setLayout(anchor, .height, .{ .dimension = .{ .value = 100, .unit = .percent } });

    // component root: height 100%
    const inner = try b.openBox();
    try store.setLayout(inner, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
    try store.setLayout(inner, .height, .{ .dimension = .{ .value = 100, .unit = .percent } });
    b.close(); // inner
    b.close(); // anchor
    b.close(); // slot

    // fixed footer
    const footer = try b.openBox();
    try b.height(footer, 30, .px);
    b.close();
    b.close(); // root

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 400, 300);

    const slot_h = registry.getNode(slot).?.geometry.height;
    const anchor_h = registry.getNode(anchor).?.geometry.height;
    const inner_h = registry.getNode(inner).?.geometry.height;
    try std.testing.expectApproxEqAbs(@as(f32, 230), slot_h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 230), anchor_h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 230), inner_h, 0.5);
}

// Regression: a `flex-grow` slot in a ROW gets its width from the flex algorithm and
// its HEIGHT only from cross-axis `align-items: stretch`. `place()`'s "hug width" carve-out
// used to also match this node (no width prop + row parent) and suppress the post-stretch
// child re-measure, so a `height: 100%` descendant (a `mountReactiveFill` anchor) collapsed
// to 0. `getFlexGrow(node) == 0` in the carve-out is what keeps this case re-measuring.
test "Flexbox — height:100% child of a flex-grow ROW slot resolves via cross-axis stretch" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const root = try b.openBox();
    try b.width(root, 400, .px);
    try b.height(root, 300, .px);
    try store.setLayout(root, .flex_direction, .{ .keyword = .row });

    const sidebar = try b.openBox();
    try b.width(sidebar, 80, .px);
    b.close();

    const slot = try b.openBox();
    try store.setLayout(slot, .flex_grow, .{ .number = 1 });

    const anchor = try b.openBox();
    try store.setLayout(anchor, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
    try store.setLayout(anchor, .height, .{ .dimension = .{ .value = 100, .unit = .percent } });
    const inner = try b.openBox();
    try store.setLayout(inner, .height, .{ .dimension = .{ .value = 100, .unit = .percent } });
    b.close();
    b.close();
    b.close();
    b.close();

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 400, 300);
    const anchor_h = registry.getNode(anchor).?.geometry.height;
    const inner_h = registry.getNode(inner).?.geometry.height;
    try std.testing.expectApproxEqAbs(@as(f32, 300), anchor_h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 300), inner_h, 0.5);
}

test "Flexbox — box in row shrinks to fit its children's width" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root_id = try registry.createNode(.box);
    const row_box = try registry.createNode(.box);
    const content1 = try registry.createNode(.box);
    const content2 = try registry.createNode(.box);

    registry.appendChild(root_id, row_box);
    registry.appendChild(row_box, content1);
    registry.appendChild(row_box, content2);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root_id);
    try store.registerNode(row_box);
    try store.registerNode(content1);
    try store.registerNode(content2);

    // Root is row container
    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 1000, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .row });

    // row_box has NO explicit width, it should shrink to fit content1 + content2
    // It's a row layout itself to arrange the children horizontally
    try store.setLayout(row_box, .flex_direction, .{ .keyword = .row });

    // content1 and content2 have explicit widths
    try store.setLayout(content1, .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(content1, .height, .{ .dimension = .{ .value = 50, .unit = .px } });
    try store.setLayout(content2, .width, .{ .dimension = .{ .value = 150, .unit = .px } });
    try store.setLayout(content2, .height, .{ .dimension = .{ .value = 50, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 1000, 100);

    const box = registry.getNode(row_box).?;

    // The row_box should be EXACTLY 250px wide (100 + 150), NOT 1000px wide
    try std.testing.expectApproxEqAbs(@as(f32, 250), box.geometry.width, 0.01);
}

test "Incremental — a clean sibling is re-placed when an earlier sibling resizes" {
    // Guards the place-pruning skip: a node the measure pass left untouched
    // (measured_gen stale) is still re-placed when its origin moves. Here B never
    // changes, but growing A must push B down — if the skip ignored the x/y change
    // B would be stuck at its old y.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry); // so setLayout marks the dirty spine like the engine

    const root = try registry.createNode(.box);
    const a = try registry.createNode(.box);
    const b = try registry.createNode(.box);
    registry.appendChild(root, a);
    registry.appendChild(root, b);
    try store.registerNode(root);
    try store.registerNode(a);
    try store.registerNode(b);

    // Column root (explicit size), A then B stacked.
    try store.setLayout(root, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(root, .height, .{ .dimension = .{ .value = 500, .unit = .px } });
    try store.setLayout(a, .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(a, .height, .{ .dimension = .{ .value = 50, .unit = .px } });
    try store.setLayout(b, .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(b, .height, .{ .dimension = .{ .value = 60, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 200, 500);
    try std.testing.expectApproxEqAbs(@as(f32, 0), registry.getNode(a).?.geometry.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), registry.getNode(b).?.geometry.y, 0.01);

    // Grow A. Only A + ancestors are marked dirty; B stays clean (cache hit).
    try store.setLayout(a, .height, .{ .dimension = .{ .value = 120, .unit = .px } });
    try std.testing.expect(!registry.getNode(b).?.layout_dirty);
    engine.solve(root, 0, 0, 200, 500);

    try std.testing.expectApproxEqAbs(@as(f32, 120), registry.getNode(a).?.geometry.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), registry.getNode(b).?.geometry.y, 0.01);
    // B's own size is untouched.
    try std.testing.expectApproxEqAbs(@as(f32, 60), registry.getNode(b).?.geometry.height, 0.01);
}

test "Incremental — an unchanged subtree keeps correct geometry across a re-solve" {
    // A second solve with nothing dirty must leave geometry identical (the skip is
    // a no-op that can't corrupt a clean tree).
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const root = try registry.createNode(.box);
    const child = try registry.createNode(.box);
    registry.appendChild(root, child);
    try store.registerNode(root);
    try store.registerNode(child);
    try store.setLayout(root, .width, .{ .dimension = .{ .value = 300, .unit = .px } });
    try store.setLayout(root, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(root, .flex_direction, .{ .keyword = .row });
    try store.setLayout(root, .justify_content, .{ .keyword = .center });
    try store.setLayout(child, .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(child, .height, .{ .dimension = .{ .value = 40, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 300, 100);
    const g0 = registry.getNode(child).?.geometry;
    try std.testing.expectApproxEqAbs(@as(f32, 100), g0.x, 0.01); // centered: (300-100)/2

    engine.solve(root, 0, 0, 300, 100); // nothing dirty → skip path
    const g1 = registry.getNode(child).?.geometry;
    try std.testing.expectEqual(g0.x, g1.x);
    try std.testing.expectEqual(g0.y, g1.y);
    try std.testing.expectEqual(g0.width, g1.width);
    try std.testing.expectEqual(g0.height, g1.height);
}

test "Flexbox — box in row with flexGrow sibling is pushed right and maintains shrink-to-fit" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root_id = try registry.createNode(.box);
    const spacer = try registry.createNode(.box);
    const bubble = try registry.createNode(.box);
    const text_mock = try registry.createNode(.box);

    registry.appendChild(root_id, spacer);
    registry.appendChild(root_id, bubble);
    registry.appendChild(bubble, text_mock);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root_id);
    try store.registerNode(spacer);
    try store.registerNode(bubble);
    try store.registerNode(text_mock);

    // Root is row container, 500px wide (like a message list)
    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 500, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .row });

    // Spacer has flex-grow 1 and no explicit width
    try store.setLayout(spacer, .flex_grow, .{ .number = 1 });

    // Bubble has no explicit width (should shrink-to-fit text_mock)
    // Padding on bubble to test that extent includes padding
    try store.setLayout(bubble, .padding_left, .{ .dimension = .{ .value = 10, .unit = .px } });
    try store.setLayout(bubble, .padding_right, .{ .dimension = .{ .value = 10, .unit = .px } });

    // Mock text content with 100px width
    try store.setLayout(text_mock, .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(text_mock, .height, .{ .dimension = .{ .value = 20, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 500, 100);

    const s = registry.getNode(spacer).?;
    const b = registry.getNode(bubble).?;

    // Bubble should be exactly 120px wide (100 content + 10L + 10R)
    try std.testing.expectApproxEqAbs(@as(f32, 120), b.geometry.width, 0.01);

    // Spacer should take the rest (500 - 120 = 380px)
    try std.testing.expectApproxEqAbs(@as(f32, 380), s.geometry.width, 0.01);

    // Bubble should be positioned after the spacer (at x=380)
    try std.testing.expectApproxEqAbs(@as(f32, 380), b.geometry.x, 0.01);
}

test "Justify-content space-evenly gives equal space before/between/after items" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var ids: [2]reg.NodeId = undefined;
    const root = try rowContainer(&registry, &store, 300, &ids);
    try store.setLayout(root, .justify_content, .{ .keyword = .space_evenly });
    for (ids) |c| try store.setLayout(c, .width, .{ .dimension = .{ .value = 60, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 300, 50);

    // free = 300 - 120 = 180; 3 equal slices of 60 → x0 = 60, x1 = 60+60+60 = 180.
    try std.testing.expectApproxEqAbs(@as(f32, 60), registry.getNode(ids[0]).?.geometry.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 180), registry.getNode(ids[1]).?.geometry.x, 0.01);
}

test "An explicit width is border-box — a bordered row's grown children fit inside it" {
    var reg_ = reg.UIRegistry.init(std.testing.allocator);
    defer reg_.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    // A 300px row with a 1px border hosting two flex-basis-0 / grow-1 buttons and a
    // 10px gap — the shape that was reported as overflowing and clipping.
    const root = try reg_.createNode(.box);
    try store.registerNode(root);
    try store.setLayout(root, .width, .{ .dimension = .{ .value = 300, .unit = .px } });
    try store.setLayout(root, .flex_direction, .{ .keyword = .row });
    try store.setLayout(root, .gap, .{ .dimension = .{ .value = 10, .unit = .px } });
    try store.setStyle(root, .border_width, .{ .dimension = .{ .value = 1, .unit = .px } });

    var kids: [2]reg.NodeId = undefined;
    for (&kids) |*k| {
        k.* = try reg_.createNode(.box);
        try store.registerNode(k.*);
        reg_.appendChild(root, k.*);
        try store.setLayout(k.*, .flex_basis, .{ .dimension = .{ .value = 0, .unit = .px } });
        try store.setLayout(k.*, .flex_grow, .{ .number = 1 });
    }

    var engine = LayoutEngine.init(&reg_, &store, null);
    engine.solve(root, 0, 0, 300, 50);

    // The border is subtracted from the declared width, not added outside it:
    // content = 300 - 2*1 = 298, minus the 10px gap = 288, split evenly = 144 each.
    const a = reg_.getNode(kids[0]).?.geometry;
    const b = reg_.getNode(kids[1]).?.geometry;
    try std.testing.expectApproxEqAbs(@as(f32, 144), a.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 144), b.width, 0.01);
    // And the pair ends inside the border, so nothing is clipped.
    try std.testing.expect(b.x + b.width <= 300 - 1 + 0.01);
}

test "An intrinsic (hug) width adds the border outside the content, like CSS width:auto" {
    var reg_ = reg.UIRegistry.init(std.testing.allocator);
    defer reg_.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    const root = try reg_.createNode(.box);
    try store.registerNode(root);
    try store.setLayout(root, .flex_direction, .{ .keyword = .row });

    // Hug wrapper (no width) with a 1px border around a fixed 100px child.
    const wrapper = try reg_.createNode(.box);
    try store.registerNode(wrapper);
    reg_.appendChild(root, wrapper);
    try store.setStyle(wrapper, .border_width, .{ .dimension = .{ .value = 1, .unit = .px } });
    const child = try reg_.createNode(.box);
    try store.registerNode(child);
    reg_.appendChild(wrapper, child);
    try store.setLayout(child, .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(child, .height, .{ .dimension = .{ .value = 20, .unit = .px } });

    var engine = LayoutEngine.init(&reg_, &store, null);
    engine.solve(root, 0, 0, 400, 100);

    // 100 + 2*1 = 102. This is the CSS `width: auto` rule, not a bug: give the
    // wrapper an explicit width (or let it grow) and the border comes out of it.
    try std.testing.expectApproxEqAbs(@as(f32, 102), reg_.getNode(wrapper).?.geometry.width, 0.01);
}

test "Align-self overrides the parent's align-items per child" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    const root = try registry.createNode(.box);
    const a = try registry.createNode(.box);
    const b = try registry.createNode(.box);
    registry.appendChild(root, a);
    registry.appendChild(root, b);
    try store.registerNode(root);
    try store.registerNode(a);
    try store.registerNode(b);

    // Row 300×200, align-items: flex-start. Both children 40 tall.
    try store.setLayout(root, .width, .{ .dimension = .{ .value = 300, .unit = .px } });
    try store.setLayout(root, .height, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(root, .flex_direction, .{ .keyword = .row });
    try store.setLayout(root, .align_items, .{ .keyword = .flex_start });
    inline for (.{ a, b }) |c| {
        try store.setLayout(c, .width, .{ .dimension = .{ .value = 50, .unit = .px } });
        try store.setLayout(c, .height, .{ .dimension = .{ .value = 40, .unit = .px } });
    }
    // b opts into flex-end on the cross axis via align-self.
    try store.setLayout(b, .align_self, .{ .keyword = .flex_end });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 300, 200);

    // a follows the parent (flex-start → y = 0); b overrides to flex-end (200 - 40).
    try std.testing.expectApproxEqAbs(@as(f32, 0), registry.getNode(a).?.geometry.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 160), registry.getNode(b).?.geometry.y, 0.01);
}

test "Row-gap/column-gap space the two axes independently under wrap" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    const root = try registry.createNode(.box);
    var ids: [3]reg.NodeId = undefined;
    for (&ids) |*slot| {
        const c = try registry.createNode(.box);
        registry.appendChild(root, c);
        slot.* = c;
    }
    try store.registerNode(root);
    for (ids) |c| try store.registerNode(c);

    // Wrapping row, 100px wide. column-gap 10 (between items on a line),
    // row-gap 30 (between wrap lines). Each item 40×40 → 2 per line, then wrap.
    try store.setLayout(root, .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(root, .height, .{ .dimension = .{ .value = 300, .unit = .px } });
    try store.setLayout(root, .flex_direction, .{ .keyword = .row });
    try store.setLayout(root, .flex_wrap, .{ .boolean = true });
    try store.setLayout(root, .column_gap, .{ .dimension = .{ .value = 10, .unit = .px } });
    try store.setLayout(root, .row_gap, .{ .dimension = .{ .value = 30, .unit = .px } });
    for (ids) |c| {
        try store.setLayout(c, .width, .{ .dimension = .{ .value = 40, .unit = .px } });
        try store.setLayout(c, .height, .{ .dimension = .{ .value = 40, .unit = .px } });
    }

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 100, 300);

    // Line 1: item0 x=0, item1 x = 40 + 10 (column-gap) = 50, both y=0.
    try std.testing.expectApproxEqAbs(@as(f32, 0), registry.getNode(ids[0]).?.geometry.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), registry.getNode(ids[1]).?.geometry.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), registry.getNode(ids[1]).?.geometry.y, 0.01);
    // Item2 wraps to line 2: x back to 0, y = 40 + 30 (row-gap) = 70.
    try std.testing.expectApproxEqAbs(@as(f32, 0), registry.getNode(ids[2]).?.geometry.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 70), registry.getNode(ids[2]).?.geometry.y, 0.01);
}

test "Flexbox — a shrunk text flex-child re-wraps at its final width (property-row first-line overflow)" {
    // Repro of the property-panel bug: a long `value` text in a flex row shrinks to
    // the space left by a fixed `label`, but was WRAPPED against the full row width
    // it was measured at — before the shrink — so its first line packed one word too
    // many and spilled past the box's right edge (over the container's padding).
    // Following lines fell correctly because they were re-measured from the break.
    const ttf = try loadRegressionFont(std.testing.allocator);
    defer std.testing.allocator.free(ttf);
    var atlas = try text_mod.FontAtlas.init(std.testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var b = builder.UIBuilder.init(&registry, &store);
    const container = try b.openBox(); // column, 400 wide, 16px L/R padding
    try b.width(container, 400, .px);
    try b.padding(container, 0, 16, 0, 16);
    const row = try b.openBox();
    try b.width(row, 100, .percent);
    try b.flexRow(row);
    const label = try b.addText("Automation Name"); // fixed: never shrinks
    try b.fontSize(label, 13);
    try b.flexShrink(label, 0);
    const value = try b.addText("System Windows Forms Control Main Window Button Text");
    try b.fontSize(value, 13);
    try b.flexGrow(value, 1);
    try b.flexShrink(value, 1);
    try b.minWidth(value, 0, .px);
    b.close(); // row
    b.close(); // container

    var engine = LayoutEngine.init(&registry, &store, &atlas);
    engine.solve(container, 0, 0, 400, 800);

    const v = registry.getNode(value).?;
    try std.testing.expect(v.text_layout != null);
    const tl = v.text_layout.?;
    // The value did shrink below the full row width, and the text actually wrapped —
    // otherwise this test would pass vacuously.
    try std.testing.expect(v.geometry.width < 368);
    try std.testing.expect(tl.lines.items.len > 1);
    // The fix's mechanism, independent of exact font metrics: the value was RE-SHAPED
    // at the width it actually got (== its box width; it has no padding), not the
    // wider width it was first measured at. Pre-fix `last_shaped_w` kept the full
    // pre-shrink row inner width (368), so this assertion is what has teeth.
    try std.testing.expectApproxEqAbs(v.geometry.width, v.last_shaped_w, 0.5);
    // The invariant that was violated: NO line may be wider than the box it wraps in.
    // (1px slack for sub-pixel snapping between the wrap loop and HarfBuzz.)
    for (tl.lines.items) |line| {
        try std.testing.expect(line.width <= v.geometry.width + 1.0);
    }
}

test "Flexbox — shrink arithmetic: a fixed label + flex value exactly fill the content box (no font)" {
    // The pure-math half of the property-row fix: with explicit widths there is no
    // shaping at all, so the shrink distribution is deterministic and checkable to
    // the pixel. This is what guarantees the value's right edge lands ON the content
    // box (over the padding) rather than past it — the geometry the text then wraps
    // inside. A null atlas keeps this independent of any installed font.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const container = try b.openBox(); // column, 400 wide, 16px L/R padding → inner 368
    try b.width(container, 400, .px);
    try b.padding(container, 0, 16, 0, 16);
    const row = try b.openBox();
    try b.width(row, 100, .percent);
    try b.flexRow(row);
    const label = try b.openBox(); // fixed 200, never shrinks
    try b.width(label, 200, .px);
    try b.flexShrink(label, 0);
    b.close();
    const value = try b.openBox(); // base 300, absorbs the whole 132px deficit
    try b.width(value, 300, .px);
    try b.flexGrow(value, 1);
    try b.flexShrink(value, 1);
    try b.minWidth(value, 0, .px);
    b.close();
    b.close(); // row
    b.close(); // container

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(container, 0, 0, 400, 800);

    const l = registry.getNode(label).?;
    const v = registry.getNode(value).?;
    // label 200 + value 168 = 368 (the content box). value = 300 − (500−368).
    try std.testing.expectApproxEqAbs(@as(f32, 200), l.geometry.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 168), v.geometry.width, 0.01);
    // value's right edge sits exactly on the content box's right edge: 16 (pad) +
    // 200 + 168 = 384 = 400 − 16. Never over the padding.
    try std.testing.expectApproxEqAbs(@as(f32, 216), v.geometry.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 384), v.geometry.x + v.geometry.width, 0.01);
}

test "Flexbox — a flex-grow value with NO flex-shrink keeps its width (Yoga default = 0)" {
    // Documents the engine's deliberate deviation from CSS and why the property-row
    // value cell MUST declare flex-shrink:1. flex-shrink defaults to 0 (not CSS's 1)
    // because scroll containers rely on overflow — so a `flex-grow:1` cell with no
    // flex-shrink does NOT shrink: the shrink pass never runs (`total_flex_shrink==0`)
    // and the value keeps its base width, spilling past the content box. This is the
    // exact shape of examples/property_panel.zig before it set flexShrink(val,1); this
    // test pins the trap so a future "make it CSS-default" change has to face it (and
    // the TreeView scroll model) head-on rather than silently.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const container = try b.openBox(); // column, 400 wide, 16px L/R padding → inner 368
    try b.width(container, 400, .px);
    try b.padding(container, 0, 16, 0, 16);
    const row = try b.openBox();
    try b.width(row, 100, .percent);
    try b.flexRow(row);
    const label = try b.openBox();
    try b.width(label, 200, .px);
    try b.flexShrink(label, 0);
    b.close();
    const value = try b.openBox(); // base 300, grows — but no flex-shrink declared
    try b.width(value, 300, .px);
    try b.flexGrow(value, 1);
    b.close();
    b.close(); // row
    b.close(); // container

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(container, 0, 0, 400, 800);

    const v = registry.getNode(value).?;
    // No shrink: value stays 300, right edge at 16+200+300 = 516, 132px past the
    // content box (384). The fix is at the consumer — declare flex-shrink:1 (see the
    // "exactly fill the content box" test above), not a global default flip.
    try std.testing.expectApproxEqAbs(@as(f32, 300), v.geometry.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 516), v.geometry.x + v.geometry.width, 0.01);
}

// ── Reshape regression (scroll perf) ──────────────────────────────────────────────────────────────────
//
// The keyed-reconciliation reuse path (UIBuilder.openNodeKeyed → clearProperties →
// addText → setTextContent) must NOT re-shape a reused text node whose content is
// unchanged. Before the `keep_text` fix, clearProperties wiped `text_content`, which
// defeated setTextContent's identical-content short-circuit and set `text_dirty` on
// every reused text node → a full window re-shape on each scroll. These count
// `dbg_reshaped` after a rebuild (a real FontAtlas is required — a null atlas skips
// the shaping path entirely).

/// Loads a system font (as text.zig does at runtime). Skips the
/// test when no font is available rather than failing.
fn loadRegressionFont(alloc: std.mem.Allocator) ![]u8 {
    const candidates = [_][]const u8{
        "C:/Windows/Fonts/arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for (candidates) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .unlimited)) |data| return data else |_| {}
    }
    return error.SkipZigTest;
}

/// Column root of keyed rows (flex-row, 100% wide, 22px) each with a fixed-width
/// caret + icon and a `flex-grow:1` name text — the node shape a scrolled TreeView window
/// measured. The root is reused across passes, so keyed rows reconcile by key.
fn buildTreeWindow(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    keys: []const u64,
    names: []const []const u8,
) !void {
    var b = builder.UIBuilder.init(registry, store);
    const root = try b.openBox(); // reused on later passes
    try b.width(root, 300, .px);
    try b.flexColumn(root);
    for (keys, names) |k, name| {
        const row = try b.openNodeKeyed(.box, k);
        try b.width(row, 100, .percent);
        try b.height(row, 22, .px);
        try b.flexRow(row);
        const caret = try b.addText("+");
        try b.width(caret, 16, .px);
        const icon = try b.addText("F");
        try b.width(icon, 16, .px);
        const name_node = try b.addText(name);
        try b.flexGrow(name_node, 1);
        b.close(); // row
    }
    b.close(); // root
}

test "reshape: identical window rebuild re-shapes no reused text" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const font = try loadRegressionFont(std.testing.allocator);
    defer std.testing.allocator.free(font);
    var atlas = try text_mod.FontAtlas.init(std.testing.allocator, font, 16);
    defer atlas.deinit();
    var engine = LayoutEngine.init(&registry, &store, &atlas);

    const keys = [_]u64{ 0, 1, 2, 3, 4, 5 };
    const names = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot" };

    try buildTreeWindow(&registry, &store, &keys, &names);
    engine.solve(0, 0, 0, 300, 800);
    try std.testing.expect(registry.dbg_reshaped > 0); // sanity: it did shape

    try buildTreeWindow(&registry, &store, &keys, &names); // identical rebuild
    registry.markLayoutDirty(0);
    engine.solve(0, 0, 0, 300, 800);
    try std.testing.expectEqual(@as(u32, 0), registry.dbg_reshaped);
}

test "reshape: a one-row window shift re-shapes only the entering row" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const font = try loadRegressionFont(std.testing.allocator);
    defer std.testing.allocator.free(font);
    var atlas = try text_mod.FontAtlas.init(std.testing.allocator, font, 16);
    defer atlas.deinit();
    var engine = LayoutEngine.init(&registry, &store, &atlas);

    const keys_a = [_]u64{ 0, 1, 2, 3, 4, 5 };
    const names_a = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot" };
    const keys_b = [_]u64{ 1, 2, 3, 4, 5, 6 };
    const names_b = [_][]const u8{ "bravo", "charlie", "delta", "echo", "foxtrot", "golf" };

    try buildTreeWindow(&registry, &store, &keys_a, &names_a);
    engine.solve(0, 0, 0, 300, 800);

    try buildTreeWindow(&registry, &store, &keys_b, &names_b);
    registry.markLayoutDirty(0);
    engine.solve(0, 0, 0, 300, 800);

    // Only the single entering row's 3 fresh text nodes shape; the 5 reused rows
    // (15 text nodes) do not. Before the fix this was ~18 (whole window re-shaped).
    try std.testing.expectEqual(@as(u32, 3), registry.dbg_reshaped);
}

// ── Out-of-flow children get sized (the TooltipHost/ToastHost 0x0 panel bug) ──
//
// CSS 9.3: an absolutely positioned box is taken out of the flow — excluded from its
// container's content-size calculation — but it is still LAID OUT, against that
// container as its containing block. `measureChildrenExtent` used to conflate the
// two and skip abspos children entirely, never calling `measure()` on them, so their
// declared width/height was never resolved and they stayed 0x0. The only path that
// did measure them was `measureChildrenPass`, reached solely when the parent carried
// an explicit height — which made every floating panel in the framework work or not
// by luck of its parent's shape.

test "Flexbox — an absolute child is sized even when its parent hugs content" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    const root_id = try registry.createNode(.box);
    const abs_id = try registry.createNode(.box);
    registry.appendChild(root_id, abs_id);

    try store.registerNode(root_id);
    try store.registerNode(abs_id);

    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 1214, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 814, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .column });

    try store.setLayout(abs_id, .position, .{ .keyword = .absolute });
    try store.setLayout(abs_id, .left, .{ .dimension = .{ .value = 0, .unit = .px } });
    try store.setLayout(abs_id, .top, .{ .dimension = .{ .value = 0, .unit = .px } });
    try store.setLayout(abs_id, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(abs_id, .height, .{ .dimension = .{ .value = 100, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 1214, 814);

    const g = registry.getNode(abs_id).?.geometry;
    try std.testing.expectApproxEqAbs(@as(f32, 200), g.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), g.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), g.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), g.y, 0.01);
}

/// Builds `runApp`'s overlay-host shape — root(column,1214x814) → [body(flexGrow 1),
/// anchor → panel(absolute 200x100)] — with the anchor configured per
/// `anchor_absolute`/`anchor_height`, and asserts the panel resolved to its declared
/// size regardless of which combination the host happened to use.
///
/// Each call gets a FRESH registry on purpose. Reusing one across configurations
/// silently lies: `registry.markLayoutDirty` only walks UP to ancestors, never down
/// to children, so a re-solved tree keeps handing back cached 0x0 geometry no matter
/// what the test changed in between. That false signal is what made this bug look
/// unfixable for several rounds.
fn expectAbsPanelSized(anchor_absolute: bool, anchor_height: ?f32) !void {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    const root_id = try registry.createNode(.box);
    const body_id = try registry.createNode(.box);
    const anchor_id = try registry.createNode(.box);
    const panel_id = try registry.createNode(.box);
    registry.appendChild(root_id, body_id);
    registry.appendChild(root_id, anchor_id);
    registry.appendChild(anchor_id, panel_id);

    try store.registerNode(root_id);
    try store.registerNode(body_id);
    try store.registerNode(anchor_id);
    try store.registerNode(panel_id);

    try store.setLayout(root_id, .width, .{ .dimension = .{ .value = 1214, .unit = .px } });
    try store.setLayout(root_id, .height, .{ .dimension = .{ .value = 814, .unit = .px } });
    try store.setLayout(root_id, .flex_direction, .{ .keyword = .column });

    try store.setLayout(body_id, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
    try store.setLayout(body_id, .flex_grow, .{ .number = 1 });

    if (anchor_absolute) try store.setLayout(anchor_id, .position, .{ .keyword = .absolute });
    if (anchor_height) |h| try store.setLayout(anchor_id, .height, .{ .dimension = .{ .value = h, .unit = .px } });

    try store.setLayout(panel_id, .position, .{ .keyword = .absolute });
    try store.setLayout(panel_id, .left, .{ .dimension = .{ .value = 0, .unit = .px } });
    try store.setLayout(panel_id, .top, .{ .dimension = .{ .value = 0, .unit = .px } });
    try store.setLayout(panel_id, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(panel_id, .height, .{ .dimension = .{ .value = 100, .unit = .px } });

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(root_id, 0, 0, 1214, 814);

    const pg = registry.getNode(panel_id).?.geometry;
    try std.testing.expectApproxEqAbs(@as(f32, 200), pg.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), pg.height, 0.01);

    // An absolute anchor is additionally pinned at the container's origin, which is
    // what makes a host's window-coordinate math (`b.openOverlay`) hold.
    if (anchor_absolute) try std.testing.expectApproxEqAbs(@as(f32, 0), pg.y, 0.01);
}

test "Flexbox — an absolute panel is sized under every overlay-anchor shape" {
    // All four combinations must size the panel. Before the fix only the two with an
    // explicit anchor height did, which is why TooltipHost/ToastHost were invisible:
    // `mountOwned` anchors carry no height.
    try expectAbsPanelSized(false, null); // anchor in flow, hugging content
    try expectAbsPanelSized(true, null); // anchor out of flow (what openOverlay does)
    try expectAbsPanelSized(true, 0);
    try expectAbsPanelSized(false, 0);
}

// ── Property-based fuzz: random trees, structural invariants ───────────────────
//
// Hand-written scene tests pin specific geometry. These instead generate random
// trees and assert properties that must hold for *every* layout: finiteness,
// non-negative sizes, settle stability, available-size reversibility, and
// incremental-vs-from-scratch equivalence (a full re-solve of a dirtied tree
// must reproduce what a fresh solve produced — the class of bug a geometry
// assertion can't see because the numbers still "look plausible").

const PropFuzz = struct {
    fn rf(r: std.Random, m: u32) f32 {
        return @floatFromInt(r.uintLessThan(u32, m) + 1);
    }

    fn buildNode(b: *builder.UIBuilder, r: std.Random, depth: u32, budget: *u32) !void {
        const id = try b.openBox();
        if (budget.* > 0) budget.* -= 1;

        if (r.boolean()) try b.flexRow(id) else try b.flexColumn(id);

        switch (r.uintLessThan(u8, 5)) {
            0 => try b.width(id, rf(r, 400), .px),
            1 => try b.width(id, rf(r, 100), .percent),
            2 => try b.store.setLayout(id, .width, .{ .keyword = .auto }),
            3 => try b.store.setLayout(id, .width, .{ .keyword = .fill_parent }),
            else => {},
        }
        switch (r.uintLessThan(u8, 5)) {
            0 => try b.height(id, rf(r, 400), .px),
            1 => try b.height(id, rf(r, 100), .percent),
            2 => try b.store.setLayout(id, .height, .{ .keyword = .auto }),
            3 => try b.store.setLayout(id, .height, .{ .keyword = .fill_parent }),
            else => {},
        }
        // Margins in px, and in % — which the solver ignores (px only); generated so
        // the fuzz pins that an unsupported unit stays inert and layout stays stable.
        const margin_keys = [_]props.LayoutKey{ .margin_left, .margin_right, .margin_top, .margin_bottom };
        for (margin_keys) |mk| switch (r.uintLessThan(u8, 6)) {
            0 => try b.store.setLayout(id, mk, .{ .dimension = .{ .value = rf(r, 20), .unit = .px } }),
            1 => try b.store.setLayout(id, mk, .{ .dimension = .{ .value = rf(r, 30), .unit = .percent } }),
            else => {},
        };
        if (r.boolean()) try b.flexGrow(id, @floatFromInt(r.uintLessThan(u32, 3)));
        if (r.boolean()) try b.flexShrink(id, @floatFromInt(r.uintLessThan(u32, 3)));
        if (r.boolean()) try b.padding(id, rf(r, 20), rf(r, 20), rf(r, 20), rf(r, 20));
        if (r.boolean()) try b.gap(id, rf(r, 20));
        if (r.boolean()) {
            const kws = [_]props.Keyword{ .flex_start, .center, .flex_end, .space_between, .space_around, .space_evenly };
            try b.justifyContent(id, kws[r.uintLessThan(usize, kws.len)]);
        }
        if (r.boolean()) {
            const kws = [_]props.Keyword{ .flex_start, .center, .flex_end, .stretch };
            try b.alignItems(id, kws[r.uintLessThan(usize, kws.len)]);
        }
        if (r.uintLessThan(u8, 4) == 0) try b.minWidth(id, rf(r, 60), .px);
        if (r.uintLessThan(u8, 4) == 0) try b.maxWidth(id, rf(r, 300) + 20, .px);
        if (r.uintLessThan(u8, 4) == 0) try b.minHeight(id, rf(r, 60), .px);
        if (r.uintLessThan(u8, 4) == 0) try b.maxHeight(id, rf(r, 300) + 20, .px);

        if (depth < 5 and budget.* > 0) {
            const n = r.uintLessThan(u8, 4);
            var i: u8 = 0;
            while (i < n and budget.* > 0) : (i += 1) try buildNode(b, r, depth + 1, budget);
        }
        b.close();
    }

    /// Hard invariant: a layout must never produce NaN or infinity, whatever the
    /// input tree. (Non-negative width/height is *also* an invariant CSS-wise,
    /// non-negative width/height is checked separately by `checkNonNegative`.)
    fn checkFinite(registry: *reg.UIRegistry, count: reg.NodeId) !void {
        var id: reg.NodeId = 0;
        while (id < count) : (id += 1) {
            const g = (registry.getNode(id) orelse continue).geometry;
            if (!(std.math.isFinite(g.x) and std.math.isFinite(g.y) and
                std.math.isFinite(g.width) and std.math.isFinite(g.height)))
            {
                std.debug.print("checkFinite: node {d} geometry x{d} y{d} w{d} h{d}\n", .{ id, g.x, g.y, g.width, g.height });
                return error.NonFiniteGeometry;
            }
        }
    }

    fn checkNonNegative(registry: *reg.UIRegistry, count: reg.NodeId) !void {
        var id: reg.NodeId = 0;
        while (id < count) : (id += 1) {
            const g = (registry.getNode(id) orelse continue).geometry;
            if (g.width < -0.01 or g.height < -0.01) {
                std.debug.print("checkNonNegative: node {d} w{d} h{d}\n", .{ id, g.width, g.height });
                return error.NegativeSize;
            }
        }
    }

    fn snapshot(a: std.mem.Allocator, registry: *reg.UIRegistry, count: reg.NodeId) ![]reg.Geometry {
        const out = try a.alloc(reg.Geometry, count);
        var id: reg.NodeId = 0;
        while (id < count) : (id += 1) out[id] = if (registry.getNode(id)) |nd| nd.geometry else .{};
        return out;
    }

    fn expectSame(prev: []const reg.Geometry, registry: *reg.UIRegistry, comptime label: []const u8) !void {
        for (prev, 0..) |p, id| {
            const g = (registry.getNode(@intCast(id)) orelse continue).geometry;
            std.testing.expectApproxEqAbs(p.x, g.x, 0.05) catch |e| {
                std.debug.print("{s}: node {d} x {d} -> {d}\n", .{ label, id, p.x, g.x });
                return e;
            };
            std.testing.expectApproxEqAbs(p.y, g.y, 0.05) catch |e| {
                std.debug.print("{s}: node {d} y {d} -> {d}\n", .{ label, id, p.y, g.y });
                return e;
            };
            std.testing.expectApproxEqAbs(p.width, g.width, 0.05) catch |e| {
                std.debug.print("{s}: node {d} w {d} -> {d}\n", .{ label, id, p.width, g.width });
                return e;
            };
            std.testing.expectApproxEqAbs(p.height, g.height, 0.05) catch |e| {
                std.debug.print("{s}: node {d} h {d} -> {d}\n", .{ label, id, p.height, g.height });
                return e;
            };
        }
    }

    fn markAllDirty(registry: *reg.UIRegistry, count: reg.NodeId) void {
        var id: reg.NodeId = 0;
        while (id < count) : (id += 1) {
            if (registry.getNode(id)) |nd| nd.layout_dirty = true;
        }
        registry.global_layout_dirty = true;
    }
};

test "Flexbox property-fuzz: random trees are finite, non-negative, settle-stable, and round-trip reversible" {
    const a = std.testing.allocator;
    var seed: u64 = 0;
    while (seed < 300) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();

        var registry = reg.UIRegistry.init(a);
        defer registry.deinit();
        var store = props.PropertyStore.init(a);
        defer store.deinit();
        store.setRegistry(&registry);

        var b = builder.UIBuilder.init(&registry, &store);
        var budget: u32 = r.uintLessThan(u32, 40) + 4;
        try PropFuzz.buildNode(&b, r, 0, &budget);
        const root: reg.NodeId = 0;
        const count: reg.NodeId = @intCast(registry.nodes.items.len);

        var engine = LayoutEngine.init(&registry, &store, null);

        // 1. A fresh solve must never produce NaN/Inf, whatever the input tree.
        engine.solve(root, 0, 0, 800, 600);
        PropFuzz.checkFinite(&registry, count) catch |e| {
            std.debug.print("  ^ seed {d}\n", .{seed});
            return e;
        };
        const base = try PropFuzz.snapshot(a, &registry, count);
        defer a.free(base);

        // 2. Settle: re-solving a clean tree must not move anything.
        engine.solve(root, 0, 0, 800, 600);
        PropFuzz.expectSame(base, &registry, "settle") catch |e| {
            std.debug.print("  ^ seed {d}\n", .{seed});
            return e;
        };

        // 3. Two solves at a second viewport still agree with each other
        //    (intra-size stability — distinct from the round-trip check below).
        engine.solve(root, 0, 0, 517, 383);
        PropFuzz.checkFinite(&registry, count) catch |e| {
            std.debug.print("  ^ seed {d} @517\n", .{seed});
            return e;
        };
        const small = try PropFuzz.snapshot(a, &registry, count);
        defer a.free(small);
        engine.solve(root, 0, 0, 517, 383);
        PropFuzz.expectSame(small, &registry, "settle @517") catch |e| {
            std.debug.print("  ^ seed {d}\n", .{seed});
            return e;
        };

        // 4. Viewport round-trip: back to the original size reproduces the
        //    original layout exactly (incremental layout must be reversible).
        engine.solve(root, 0, 0, 800, 600);
        PropFuzz.expectSame(base, &registry, "viewport round-trip") catch |e| {
            std.debug.print("  ^ seed {d}\n", .{seed});
            return e;
        };

        // 5. A full re-solve of a fully-dirtied tree reproduces the incremental
        //    result — no state leaked into geometry that a from-scratch solve
        //    wouldn't produce.
        PropFuzz.markAllDirty(&registry, count);
        engine.solve(root, 0, 0, 800, 600);
        PropFuzz.expectSame(base, &registry, "full re-solve") catch |e| {
            std.debug.print("  ^ seed {d}\n", .{seed});
            return e;
        };

        // 6. Non-negative sizes on every solve state visited above.
        PropFuzz.checkNonNegative(&registry, count) catch |e| {
            std.debug.print("  ^ seed {d}\n", .{seed});
            return e;
        };
    }
}

test "Flexbox repro — a hug sibling gaining a child via rootAt shrinks the grow sibling" {
    // Isolated repro of the ScrollView bar flip: row [grow viewport][hug slot].
    // The slot is emptied and later refilled through a `rootAt` rebuild +
    // markLayoutDirty(slot); the grow sibling must give the channel back.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const row = try b.openBox();
    try b.flexRow(row);
    try b.width(row, 400, .px);
    try b.height(row, 400, .px);
    const vp = try b.openBox();
    try b.width(vp, 0, .px);
    try b.flexGrow(vp, 1);
    try b.height(vp, 100, .percent);
    b.close();
    const slot = try b.openBox();
    try b.height(slot, 100, .percent);
    const t = try b.openBox();
    try b.width(t, 14, .px);
    b.close();
    b.close();
    b.close();

    var engine = LayoutEngine.init(&registry, &store, null);
    engine.solve(row, 0, 0, 400, 400);
    try std.testing.expectApproxEqAbs(@as(f32, 386), registry.getNode(vp).?.geometry.width, 0.5);

    // Empty the slot.
    try b.rootAt(slot);
    b.close();
    registry.markLayoutDirty(slot);
    engine.solve(row, 0, 0, 400, 400);
    try std.testing.expectApproxEqAbs(@as(f32, 400), registry.getNode(vp).?.geometry.width, 0.5);

    // Refill it.
    try b.rootAt(slot);
    const t2 = try b.openBox();
    try b.width(t2, 14, .px);
    b.close();
    b.close();
    registry.markLayoutDirty(slot);
    engine.solve(row, 0, 0, 400, 400);
    try std.testing.expectApproxEqAbs(@as(f32, 14), registry.getNode(slot).?.geometry.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 386), registry.getNode(vp).?.geometry.width, 0.5);
}

test "Flexbox — line_height scales each line slot and relayouts when changed" {
    const ttf = try loadRegressionFont(std.testing.allocator);
    defer std.testing.allocator.free(ttf);
    var atlas = try text_mod.FontAtlas.init(std.testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const col = try b.openBox();
    try b.width(col, 400, .px);
    try b.height(col, 400, .px);
    try b.flexColumn(col);
    const deflt = try b.addText("one\ntwo");
    try b.fontSize(deflt, 16);
    const tight = try b.addText("one\ntwo");
    try b.fontSize(tight, 16);
    try b.lineHeight(tight, 1.0);
    b.close();

    var engine = LayoutEngine.init(&registry, &store, &atlas);
    engine.solve(col, 0, 0, 400, 400);

    // Two lines each: default slot is 16 × 1.55, the override's is 16 × 1.0.
    try std.testing.expectApproxEqAbs(@as(f32, 2 * text_mod.lineHeight(16)), registry.getNode(deflt).?.geometry.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 32), registry.getNode(tight).?.geometry.height, 0.01);
    // The factor travels on the layout, so caret metrics step by the same slot.
    const tl = registry.getNode(tight).?.text_layout.?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), tl.line_height_factor, 0.0001);
    const cm = atlas.getCaretMetrics("one\ntwo", tl, 16, 5, 1.0);
    try std.testing.expectEqual(@as(usize, 1), cm.line_index);
    try std.testing.expectApproxEqAbs(@as(f32, 16), cm.y, 0.01);

    // Changing the style is a layout change, not paint-only.
    try b.lineHeight(tight, 2.0);
    engine.solve(col, 0, 0, 400, 400);
    try std.testing.expectApproxEqAbs(@as(f32, 64), registry.getNode(tight).?.geometry.height, 0.01);

    // A nonsense factor falls back to the default instead of collapsing the text.
    try b.lineHeight(tight, 0);
    engine.solve(col, 0, 0, 400, 400);
    try std.testing.expectApproxEqAbs(@as(f32, 2 * text_mod.lineHeight(16)), registry.getNode(tight).?.geometry.height, 0.01);
}

test "Flexbox — a reused text node that loses line_height on rebuild re-measures at the default" {
    const ttf = try loadRegressionFont(std.testing.allocator);
    defer std.testing.allocator.free(ttf);
    var atlas = try text_mod.FontAtlas.init(std.testing.allocator, ttf, 72.0);
    defer atlas.deinit();

    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    var b = builder.UIBuilder.init(&registry, &store);
    const col = try b.openBox();
    try b.width(col, 400, .px);
    try b.height(col, 400, .px);
    try b.flexColumn(col);
    const t1 = try b.addText("one\ntwo");
    try b.lineHeight(t1, 1.0);
    b.close();

    var engine = LayoutEngine.init(&registry, &store, &atlas);
    engine.solve(col, 0, 0, 400, 400);
    try std.testing.expectApproxEqAbs(@as(f32, 32), registry.getNode(t1).?.geometry.height, 0.01);

    // Rebuild: same content, same position — the node is reused — but no line_height.
    try b.rootAt(col);
    const t2 = try b.addText("one\ntwo");
    b.close();
    try std.testing.expectEqual(t1, t2);
    engine.solve(col, 0, 0, 400, 400);

    try std.testing.expectApproxEqAbs(@as(f32, 2 * text_mod.lineHeight(16)), registry.getNode(t2).?.geometry.height, 0.01);
    try std.testing.expectApproxEqAbs(text_mod.LINE_HEIGHT_FACTOR, registry.getNode(t2).?.text_layout.?.line_height_factor, 0.0001);
}
