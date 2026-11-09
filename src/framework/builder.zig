const std = @import("std");
const BoundedArray = @import("../core/bounded_array.zig").BoundedArray;
const reg = @import("../core/registry.zig");
const props = @import("../core/properties.zig");
const core_events = @import("../core/events.zig");
const text_mod = @import("../render/text.zig");
const animation = @import("../core/animation.zig");
const props_path = @import("../core/path.zig");

// Re-export types the caller needs so they don't have to import core directly.
pub const NodeId = reg.NodeId;
pub const DimUnit = props.DimUnit;
pub const Keyword = props.Keyword;
pub const FontRole = text_mod.FontRole;
const PropValue = props.PropValue;

/// A px-unit dimension value — the overwhelmingly common layout setter shape.
fn dimPx(value: f32) PropValue {
    return .{ .dimension = .{ .value = value, .unit = .px } };
}
/// A `theme.Color` (u8 RGBA) as a style PropValue, alpha included.
fn colorValue(c: theme_mod.Color) PropValue {
    return PropValue.rgbA(c.r, c.g, c.b, @as(f32, @floatFromInt(c.a)) / 255.0);
}
/// A dimension value with an explicit unit.
fn dim(value: f32, unit: DimUnit) PropValue {
    return .{ .dimension = .{ .value = value, .unit = unit } };
}

// ── UIBuilder ─────────────────────────────────────────────────────────────────
//
// The UIBuilder is Celeris's equivalent of React.createElement or the Jetpack
// Compose slot model. Widgets call it directly.
//
// Usage pattern:
//
//   const root = try b.openBox();    // push root onto parent stack
//   try b.width(root, 100, .percent);
//
//       const child = try b.openBox();  // push child (auto-parented to root)
//       try b.height(child, 40, .px);
//       b.close();                      // pop child
//
//   b.close();                          // pop root
//
// Rules:
//   • Every openBox() MUST have exactly one matching close().
//   • addText() is self-closing (no children, no close() needed).
//   • The NodeId returned by open*/addText is stable for the lifetime of the
//     current build pass — use it to set additional properties.

const theme_mod = @import("theme.zig");

const StackFrame = struct {
    parent_id: reg.NodeId,
    old_next_child: reg.NodeId,
    /// Set once the first keyed child appears in this parent. From then on the
    /// frame reconciles by key against `old_remaining` instead of by position.
    keyed: bool = false,
    /// Old children captured when entering keyed mode; entries are nulled as
    /// they get reused, and any survivors are deleted in `close()`.
    old_remaining: std.ArrayListUnmanaged(reg.NodeId) = .empty,
};

/// Type-erased text measurement, injected by the host (engine) so the component
/// layer can position carets exactly without depending on the font atlas / render
/// layer directly. Null in tests/headless → callers fall back to a monospace
/// estimate.
pub const TextMeasure = struct {
    ctx: *anyopaque,
    measureFn: *const fn (*anyopaque, text: []const u8, font_size: f32) f32,
    /// Vertical geometry from the engine's real font. Optional: a stub measure (tests,
    /// headless) leaves it null and `vertical` falls back to the same computation over
    /// default proportions — the same code, not a second rule.
    /// The last argument is the line-height multiplier (`text.LINE_HEIGHT_FACTOR`
    /// for the default).
    verticalFn: ?*const fn (*anyopaque, font_size: f32, box_height: f32, num_lines: usize, line_height_factor: f32) text_mod.VerticalLayout = null,
    /// Width with a font role and letter spacing — the same face and tracking the
    /// renderer draws a `b.fontMono` / `b.fontBold` / `b.letterSpacing` node with.
    /// Optional: when null, `widthStyled` falls back to `measureFn`, which **ignores
    /// the style** (default face, no tracking).
    measureStyledFn: ?*const fn (*anyopaque, text: []const u8, font_size: f32, style: MeasureStyle) f32 = null,
    /// `verticalFn` for a role's face (its own ascent/descent). Optional: when null,
    /// `verticalStyled` falls back to the default face's geometry.
    verticalStyledFn: ?*const fn (*anyopaque, font_size: f32, box_height: f32, num_lines: usize, line_height_factor: f32, role: FontRole) text_mod.VerticalLayout = null,

    /// How a run is drawn, for measuring it the same way. Mirror the node's
    /// `fontRole` and `letterSpacing` styles.
    pub const MeasureStyle = struct {
        role: FontRole = .default,
        letter_spacing: f32 = 0,
    };

    /// Width at the default face. Text drawn with another role or with letter
    /// spacing must use `widthStyled`, or carets and hit-tests drift.
    pub fn width(self: TextMeasure, text: []const u8, font_size: f32) f32 {
        return self.measureFn(self.ctx, text, font_size);
    }

    /// Width of `text` drawn with `style`. For a prefix of a line it equals the
    /// renderer's pen x for the next glyph (kerning and tracking included); the glyph
    /// is drawn snapped to the physical pixel, within half a physical px of it.
    pub fn widthStyled(self: TextMeasure, text: []const u8, font_size: f32, style: MeasureStyle) f32 {
        if (self.measureStyledFn) |f| return f(self.ctx, text, font_size, style);
        return self.measureFn(self.ctx, text, font_size);
    }

    /// Shorthand for `widthStyled` with just a role.
    pub fn widthRole(self: TextMeasure, text: []const u8, font_size: f32, role: FontRole) f32 {
        return self.widthStyled(text, font_size, .{ .role = role });
    }

    /// `verticalWith` for text drawn with `role`.
    pub fn verticalStyled(self: TextMeasure, font_size: f32, box_height: f32, num_lines: usize, line_height_factor: f32, role: FontRole) text_mod.VerticalLayout {
        if (self.verticalStyledFn) |f| return f(self.ctx, font_size, box_height, num_lines, line_height_factor, role);
        return self.verticalWith(font_size, box_height, num_lines, line_height_factor);
    }

    /// Where the baseline, the ink and the caret band land inside a `box_height`-tall
    /// box, at the default line height. The widget-side door to
    /// `text.verticalLayoutFor` — a widget that draws a caret, a selection band or an
    /// underline asks here instead of hardcoding px.
    pub fn vertical(self: TextMeasure, font_size: f32, box_height: f32, num_lines: usize) text_mod.VerticalLayout {
        return self.verticalWith(font_size, box_height, num_lines, text_mod.LINE_HEIGHT_FACTOR);
    }

    /// `vertical` for text with a `line_height` multiplier (the node's style, or a
    /// theme `TextStyle.line_height`). Pass the same factor the text node has, or the
    /// caret/selection band drifts from the glyphs line by line.
    pub fn verticalWith(self: TextMeasure, font_size: f32, box_height: f32, num_lines: usize, line_height_factor: f32) text_mod.VerticalLayout {
        if (self.verticalFn) |f| return f(self.ctx, font_size, box_height, num_lines, line_height_factor);
        return text_mod.verticalLayoutWith(.{}, font_size, box_height, num_lines, line_height_factor);
    }

    /// Height of one line slot at `font_size` — what a text node of that size
    /// measures per line with the default line height. Font-independent, so it is
    /// exact with or without an engine. See `fw.text.lineHeight`.
    pub fn lineHeight(_: TextMeasure, font_size: f32) f32 {
        return text_mod.lineHeight(font_size);
    }

    /// `lineHeight` with an explicit multiplier (sanitized like the style).
    pub fn lineHeightWith(_: TextMeasure, font_size: f32, line_height_factor: f32) f32 {
        return text_mod.lineHeightWith(font_size, line_height_factor);
    }
};

/// Vertical geometry without a measure handle at all (no engine, no stub): still the
/// one implementation, over default font proportions.
pub fn verticalFallback(font_size: f32, box_height: f32, num_lines: usize) text_mod.VerticalLayout {
    return text_mod.verticalLayoutFor(.{}, font_size, box_height, num_lines);
}

/// `verticalFallback` with a line-height multiplier.
pub fn verticalFallbackWith(font_size: f32, box_height: f32, num_lines: usize, line_height_factor: f32) text_mod.VerticalLayout {
    return text_mod.verticalLayoutWith(.{}, font_size, box_height, num_lines, line_height_factor);
}

/// Type-erased clipboard access injected by the engine (the platform layer's
/// clipboard). Null in tests/headless unless a stub is provided. `getFn` returns
/// allocator-owned UTF-8 (caller frees) or null; `setFn` returns success.
pub const Clipboard = struct {
    ctx: *anyopaque,
    getFn: *const fn (*anyopaque, std.mem.Allocator) ?[]u8,
    setFn: *const fn (*anyopaque, text: []const u8) bool,

    pub fn get(self: Clipboard, allocator: std.mem.Allocator) ?[]u8 {
        return self.getFn(self.ctx, allocator);
    }
    pub fn set(self: Clipboard, text: []const u8) bool {
        return self.setFn(self.ctx, text);
    }
};

/// Type-erased focus-scope control injected by the engine. Overlay widgets
/// (Menu, Dialog) capture it in `build()` and push a scope on their panel when
/// they open — Tab then cycles only inside — and pop it when they close (the
/// focus held before the push is restored). Null in tests/headless → no trap.
pub const FocusScopeHooks = struct {
    ctx: *anyopaque,
    pushFn: *const fn (*anyopaque, root: NodeId, origin: core_events.FocusOrigin) bool,
    popFn: *const fn (*anyopaque) bool,

    /// `origin` (focus-visible): why the scope is opening — a mouse click
    /// on a menu-bar button passes `.pointer` (no ring on the first row), a
    /// keyboard-driven open passes `.keyboard`. See `core_events.FocusOrigin`.
    pub fn push(self: FocusScopeHooks, root: NodeId, origin: core_events.FocusOrigin) bool {
        return self.pushFn(self.ctx, root, origin);
    }
    pub fn pop(self: FocusScopeHooks) bool {
        return self.popFn(self.ctx);
    }
};

pub const UIBuilder = struct {
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    theme: theme_mod.Theme,
    /// Optional text measurement for exact caret/glyph positioning (null → est.).
    measure: ?TextMeasure = null,
    /// Optional clipboard access for copy/paste in text widgets (null → no-op).
    clipboard: ?Clipboard = null,
    /// Optional focus-scope control for overlays (null → Tab is not trapped).
    focus_scope: ?FocusScopeHooks = null,
    /// Optional per-frame animator (null → no smooth motion; a widget must then
    /// degrade to something static rather than fake motion off the tick channel,
    /// which is a coarse ~500ms heartbeat — see `events.TICK_MS`).
    animator: ?*animation.AnimationEngine = null,
    /// Stack of open ancestor NodeIds. Capacity is the engine-wide tree-depth
    /// cap so builder-driven construction is bounded the same way the parser and
    /// layout are — overflow returns an error instead of aborting the process.
    parent_stack: BoundedArray(StackFrame, reg.MAX_TREE_DEPTH) = .{},

    pub fn init(registry: *reg.UIRegistry, store: *props.PropertyStore) UIBuilder {
        return .{ .registry = registry, .store = store, .theme = theme_mod.Theme.empty() };
    }

    // ── Node creation ─────────────────────────────────────────────────────────

    /// Create a Box node, link it to the current parent, push it onto the stack.
    /// The caller MUST call close() after adding all children.
    pub fn openBox(self: *UIBuilder) !NodeId {
        return self.openNode(.box);
    }

    /// Create a Text node with content, link it to the current parent.
    /// Self-closing — no close() call required.
    pub fn addText(self: *UIBuilder, content: []const u8) !NodeId {
        const id = try self.openNode(.text);
        // Dupe via stringAllocator(); setTextContent takes ownership and frees it.
        const owned = try self.store.stringAllocator().dupe(u8, content);
        self.store.setTextContent(id, owned);
        self.close(); // text nodes never have children
        return id;
    }

    /// Set an explicit accessible name (aria-label) on `id`. Overrides
    /// text-derived naming, so icon-only controls (a titlebar close button whose
    /// only child is a glyph) expose a real name to UIA / screen readers.
    pub fn ariaLabel(self: *UIBuilder, id: NodeId, text: []const u8) !void {
        const owned = try self.store.stringAllocator().dupe(u8, text);
        try self.store.setModifier(id, .label, .{ .string = owned });
    }

    /// Create an Image node from a local file path (decoded with stb_image;
    /// URLs are not supported). Self-closing — no close() call required.
    pub fn image(self: *UIBuilder, src: []const u8) !NodeId {
        const id = try self.openNode(.image);
        const owned = try self.store.stringAllocator().dupe(u8, src);
        try self.store.setModifier(id, .src, .{ .string = owned });
        self.close(); // image nodes cannot have children
        return id;
    }

    /// Create a Path node from a vertex list (see `core/path.zig`). Style it
    /// with `borderColor` / `borderWidth` / `opacity` on the returned id.
    /// Self-closing — no close() call required.
    pub fn path(self: *UIBuilder, verts: []const props_path.PathVertex) !NodeId {
        const id = try self.openNode(.path);
        try self.store.setPath(id, verts);
        self.close(); // path nodes cannot have children
        return id;
    }

    /// Begin a partial rebuild rooted at an existing node: subsequent open* calls
    /// reconcile against `node_id`'s current children. Must be paired with a
    /// `close()`. Used to re-run a single component's build() without rebuilding
    /// the whole tree.
    pub fn rootAt(self: *UIBuilder, node_id: reg.NodeId) !void {
        const node = self.registry.getNode(node_id) orelse return error.InvalidNode;
        const old_first = node.first_child;
        // Detach the old children so appendChild rebuilds the list fresh; the old
        // ids are reconciled (reused) or deleted via the frame below.
        self.registry.nodes.items[node_id].first_child = reg.NULL_NODE;
        self.registry.nodes.items[node_id].last_child = reg.NULL_NODE;
        self.parent_stack.append(.{
            .parent_id = node_id,
            .old_next_child = old_first,
        }) catch return error.NestingTooDeep;
    }

    /// Pop the current node from the parent stack.
    pub fn close(self: *UIBuilder) void {
        var frame = self.parent_stack.pop() orelse return;
        // Positional leftovers (unkeyed fast path) — delete in sibling order.
        var child_to_delete = frame.old_next_child;
        while (child_to_delete != reg.NULL_NODE) {
            const node = self.registry.getNode(child_to_delete) orelse break;
            const next = node.next_sibling;
            self.registry.removeNode(child_to_delete);
            child_to_delete = next;
        }
        // Keyed leftovers: any old child not matched by key this pass is gone.
        if (frame.keyed) {
            for (frame.old_remaining.items) |cand| {
                if (cand != reg.NULL_NODE) self.registry.removeNode(cand);
            }
        }
        frame.old_remaining.deinit(self.registry.allocator);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    pub fn openNode(self: *UIBuilder, node_type: reg.NodeType) !NodeId {
        return self.openNodeKeyed(node_type, null);
    }

    /// Like `openNode` but with an optional reconciliation key. When `key` is
    /// non-null the node is matched across rebuilds by key (stable identity under
    /// reorder/insert); when null it uses the positional fast path. The two modes
    /// shouldn't be mixed within one parent — use keys for all children of a list.
    pub fn openNodeKeyed(self: *UIBuilder, node_type: reg.NodeType, key: ?u64) !NodeId {
        var id: reg.NodeId = reg.NULL_NODE;
        var reused = false;

        if (self.parent_stack.len > 0) {
            var frame = &self.parent_stack.slice()[self.parent_stack.len - 1];

            if (key) |k| {
                // Keyed reconciliation: capture old children once, then match by key.
                if (!frame.keyed) {
                    try self.captureOldChildren(frame);
                    frame.keyed = true;
                }
                for (frame.old_remaining.items, 0..) |cand, i| {
                    if (cand == reg.NULL_NODE) continue;
                    const node = self.registry.getNode(cand) orelse continue;
                    if (node.node_type == node_type and node.key != null and node.key.? == k) {
                        id = cand;
                        reused = true;
                        frame.old_remaining.items[i] = reg.NULL_NODE; // consumed
                        break;
                    }
                }
            } else if (frame.keyed) {
                // Unkeyed child while the parent is in keyed mode (mixed children).
                // Reuse the next still-unconsumed old child of the same type that was
                // itself unkeyed — positional matching among the remaining. Without
                // this, unkeyed siblings would be recreated every pass (identity/state
                // churn) and leave a dangling slot. They keep identity by position.
                for (frame.old_remaining.items, 0..) |cand, i| {
                    if (cand == reg.NULL_NODE) continue;
                    const node = self.registry.getNode(cand) orelse continue;
                    if (node.node_type == node_type and node.key == null) {
                        id = cand;
                        reused = true;
                        frame.old_remaining.items[i] = reg.NULL_NODE; // consumed
                        break;
                    }
                }
            } else {
                const old_child = frame.old_next_child;
                if (old_child != reg.NULL_NODE) {
                    const node = self.registry.getNode(old_child).?;
                    if (node.node_type == node_type) {
                        id = old_child;
                        frame.old_next_child = node.next_sibling;
                        reused = true;
                    }
                }
            }
        } else {
            // Root node
            if (self.registry.nodes.items.len > 0) {
                // Find the first LIVE root node. `nodes` is an index-addressed
                // slab with tombstones: any id the host removed stays in the
                // array with `alive = false`, and `getNode` returns null for it.
                // Unwrapping that with `.?` crashed the whole app on the first
                // rebuild after a `celeris_node_remove` of a low id (found by
                // fuzzing the C API).
                var first_valid_root: reg.NodeId = 0;
                const root_node: ?*reg.Node = while (first_valid_root < self.registry.nodes.items.len) : (first_valid_root += 1) {
                    const candidate = self.registry.getNode(first_valid_root) orelse continue;
                    if (candidate.parent == reg.NULL_NODE) break candidate;
                } else null;

                if (root_node) |node| {
                    if (node.node_type == node_type) {
                        id = first_valid_root;
                        reused = true;
                    }
                }
            }
        }

        if (!reused) {
            id = try self.registry.createNode(node_type);
            try self.store.registerNode(id);
        } else {
            // Reuse: keep the text so the following setTextContent can short-circuit
            // an unchanged reused node (no re-shape). Stale layout/style props are
            // still cleared. See PropertyStore.clearProperties.
            self.store.clearProperties(id, true);
        }

        const old_first_child = if (reused) self.registry.getNode(id).?.first_child else reg.NULL_NODE;

        // Clear the links so appendChild can rebuild the tree fresh
        self.registry.nodes.items[id].first_child = reg.NULL_NODE;
        self.registry.nodes.items[id].last_child = reg.NULL_NODE;
        self.registry.nodes.items[id].next_sibling = reg.NULL_NODE;
        self.registry.nodes.items[id].key = key;

        if (self.currentParent()) |parent_id| {
            self.registry.appendChild(parent_id, id);
        }

        self.parent_stack.append(.{
            .parent_id = id,
            .old_next_child = old_first_child,
        }) catch return error.NestingTooDeep;

        return id;
    }

    /// Snapshots the parent's still-unconsumed old children into the frame's
    /// keyed list and disables the positional cursor. Called lazily the first
    /// time a keyed child appears, before any positional reuse, so the sibling
    /// chain it walks is still intact.
    fn captureOldChildren(self: *UIBuilder, frame: *StackFrame) !void {
        var c = frame.old_next_child;
        while (c != reg.NULL_NODE) {
            const node = self.registry.getNode(c) orelse break;
            const next = node.next_sibling;
            try frame.old_remaining.append(self.registry.allocator, c);
            c = next;
        }
        frame.old_next_child = reg.NULL_NODE;
    }

    fn currentParent(self: *const UIBuilder) ?NodeId {
        const sl = self.parent_stack.constSlice();
        if (sl.len == 0) return null;
        return sl[sl.len - 1].parent_id;
    }

    // ── Layout properties ─────────────────────────────────────────────────────

    pub fn width(self: *UIBuilder, id: NodeId, value: f32, unit: DimUnit) !void {
        try self.store.setLayout(id, .width, dim(value, unit));
    }

    pub fn height(self: *UIBuilder, id: NodeId, value: f32, unit: DimUnit) !void {
        try self.store.setLayout(id, .height, dim(value, unit));
    }

    pub fn marginTop(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .margin_top, dimPx(value));
    }

    pub fn marginBottom(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .margin_bottom, dimPx(value));
    }

    /// Vertical scroll offset applied to this node's children (render-only —
    /// writing it shifts resolved geometry without triggering a layout solve).
    pub fn scrollOffsetY(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .scroll_offset_y, dimPx(value));
    }

    /// Horizontal counterpart of `scrollOffsetY` — same render-only
    /// subtree-shift, on X.
    pub fn scrollOffsetX(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .scroll_offset_x, dimPx(value));
    }

    pub fn marginLeft(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .margin_left, dimPx(value));
    }

    pub fn marginRight(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .margin_right, dimPx(value));
    }

    /// Set all four margins in one call (top, right, bottom, left).
    pub fn margin(self: *UIBuilder, id: NodeId, t: f32, r: f32, b_val: f32, l: f32) !void {
        try self.store.setLayout(id, .margin_top, dimPx(t));
        try self.store.setLayout(id, .margin_right, dimPx(r));
        try self.store.setLayout(id, .margin_bottom, dimPx(b_val));
        try self.store.setLayout(id, .margin_left, dimPx(l));
    }

    pub fn paddingTop(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .padding_top, dimPx(value));
    }

    pub fn paddingRight(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .padding_right, dimPx(value));
    }

    pub fn paddingBottom(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .padding_bottom, dimPx(value));
    }

    pub fn paddingLeft(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .padding_left, dimPx(value));
    }

    /// Set all four paddings in one call (top, right, bottom, left).
    pub fn padding(self: *UIBuilder, id: NodeId, t: f32, r: f32, b_val: f32, l: f32) !void {
        try self.store.setLayout(id, .padding_top, dimPx(t));
        try self.store.setLayout(id, .padding_right, dimPx(r));
        try self.store.setLayout(id, .padding_bottom, dimPx(b_val));
        try self.store.setLayout(id, .padding_left, dimPx(l));
    }

    pub fn flexRow(self: *UIBuilder, id: NodeId) !void {
        try self.store.setLayout(id, .flex_direction, .{ .keyword = .row });
    }

    pub fn flexColumn(self: *UIBuilder, id: NodeId) !void {
        try self.store.setLayout(id, .flex_direction, .{ .keyword = .column });
    }

    pub fn flexWrap(self: *UIBuilder, id: NodeId, wrap: bool) !void {
        try self.store.setLayout(id, .flex_wrap, .{ .boolean = wrap });
    }

    pub fn flexGrow(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .flex_grow, .{ .number = value });
    }

    pub fn flexShrink(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .flex_shrink, .{ .number = value });
    }

    pub fn flexBasis(self: *UIBuilder, id: NodeId, value: f32, unit: DimUnit) !void {
        try self.store.setLayout(id, .flex_basis, dim(value, unit));
    }

    /// Makes the node grow to fill all remaining available space in its parent flex container.
    /// This abstracts away flexbox details like setting width to 0.
    pub fn expanded(self: *UIBuilder, id: NodeId) !void {
        try self.flexGrow(id, 1);
        try self.width(id, 0, .px);
    }

    pub fn minWidth(self: *UIBuilder, id: NodeId, value: f32, unit: DimUnit) !void {
        try self.store.setLayout(id, .min_width, dim(value, unit));
    }

    pub fn minHeight(self: *UIBuilder, id: NodeId, value: f32, unit: DimUnit) !void {
        try self.store.setLayout(id, .min_height, dim(value, unit));
    }

    pub fn maxWidth(self: *UIBuilder, id: NodeId, value: f32, unit: DimUnit) !void {
        try self.store.setLayout(id, .max_width, dim(value, unit));
    }

    pub fn maxHeight(self: *UIBuilder, id: NodeId, value: f32, unit: DimUnit) !void {
        try self.store.setLayout(id, .max_height, dim(value, unit));
    }

    pub fn gap(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setLayout(id, .gap, dimPx(value));
    }

    pub fn justifyContent(self: *UIBuilder, id: NodeId, jc: Keyword) !void {
        try self.store.setLayout(id, .justify_content, .{ .keyword = jc });
    }

    pub fn alignItems(self: *UIBuilder, id: NodeId, ai: Keyword) !void {
        try self.store.setLayout(id, .align_items, .{ .keyword = ai });
    }

    /// Position the node absolutely relative to its nearest parent.
    pub fn positionAbsolute(self: *UIBuilder, id: NodeId, left: f32, top: f32) !void {
        try self.store.setLayout(id, .position, .{ .keyword = .absolute });
        try self.store.setLayout(id, .left, dimPx(left));
        try self.store.setLayout(id, .top, dimPx(top));
    }

    /// Opens an **overlay panel**: an out-of-flow box at `z` that floats above the
    /// app and whose `left`/`top` are in the coordinate space of the container the
    /// host was mounted into — for a `runApp`-mounted singleton, that is window
    /// coordinates. Pair with `close()` like any other `open*`.
    ///
    /// The reason this exists rather than each host writing `positionAbsolute` +
    /// `zIndex` itself: an overlay host mounted via `mountOwned` gets a wrapper
    /// ANCHOR box, and that anchor is an ordinary in-flow child. Under `runApp` it
    /// lands after `body` (which flex-grows to the full height), so the anchor sits
    /// at the very bottom of the window with zero height — and a panel positioned
    /// "absolutely" inside it is offset by that, landing a full window-height below
    /// the viewport. `TooltipHost` was invisible and `ToastHost` painted ~776px
    /// off-screen for exactly this reason. Taking the anchor out of flow too pins it
    /// at the mounting container's own origin, so parent-relative and
    /// container-relative coordinates finally agree.
    ///
    /// Only valid for a host whose anchor carries nothing but overlays — pinning the
    /// anchor removes it from the layout flow, so any in-flow sibling content inside
    /// it would be yanked out of the document with it.
    pub fn openOverlay(self: *UIBuilder, z: f32) !NodeId {
        const id = try self.openNode(.box);
        try self.positionAbsolute(id, 0, 0);
        try self.zIndex(id, z);
        if (self.registry.getNode(id)) |n| {
            if (n.parent != reg.NULL_NODE) {
                try self.store.setLayout(n.parent, .position, .{ .keyword = .absolute });
            }
        }
        return id;
    }

    // ── Style properties ──────────────────────────────────────────────────────

    /// Background color from 0-255 RGB components.
    pub fn background(self: *UIBuilder, id: NodeId, r: u8, g: u8, b_val: u8) !void {
        try self.store.setStyle(id, .background, props.PropValue.rgbA(r, g, b_val, 1.0));
    }

    pub fn backgroundAlpha(self: *UIBuilder, id: NodeId, r: u8, g: u8, b_val: u8, a: f32) !void {
        try self.store.setStyle(id, .background, props.PropValue.rgbA(r, g, b_val, a));
    }

    pub fn border(self: *UIBuilder, id: NodeId, r: u8, g: u8, b_val: u8, border_width_val: f32) !void {
        try self.store.setStyle(id, .border_color, props.PropValue.rgbA(r, g, b_val, 1.0));
        try self.store.setStyle(id, .border_width, dimPx(border_width_val));
    }

    /// Drop shadow, CSS `box-shadow` semantics: `blur` is the blur *radius* in px —
    /// the shadow fades out over that distance, half inside the shadow's edge and
    /// half outside — so a design token like `0 18px 40px rgba(0,0,0,.55)` is
    /// `shadow(id, 40, 0, 18, 0, 0, 0, 0.55)` and lands where the mockup shows it.
    /// `blur = 0` with an offset gives a hard-edged shadow, which some designs want.
    /// For spread, use `boxShadow`.
    pub fn shadow(self: *UIBuilder, id: NodeId, blur: f32, dx: f32, dy: f32, r: u8, g: u8, b_val: u8, a: f32) !void {
        try self.store.setStyle(id, .shadow_blur, dimPx(blur));
        try self.store.setStyle(id, .shadow_offset_x, dimPx(dx));
        try self.store.setStyle(id, .shadow_offset_y, dimPx(dy));
        try self.store.setStyle(id, .shadow_color, props.PropValue.rgbA(r, g, b_val, a));
    }

    /// A drop shadow in one CSS-shaped literal: `b.boxShadow(id, .{ .blur = 40,
    /// .dy = 18, .color = t.shadow })`. Same four lengths as `box-shadow`, in the
    /// same units, so a token translates field by field.
    pub const ShadowSpec = struct {
        /// Blur radius in px. 0 = hard edge.
        blur: f32 = 0,
        dx: f32 = 0,
        dy: f32 = 0,
        /// Inflates the shadow before the blur; negative pulls it in, which is how a
        /// tight shadow under a wide card is expressed.
        spread: f32 = 0,
        color: theme_mod.Color = .{ .r = 0, .g = 0, .b = 0, .a = 140 },
    };

    pub fn boxShadow(self: *UIBuilder, id: NodeId, spec: ShadowSpec) !void {
        const c = spec.color;
        try self.shadow(id, spec.blur, spec.dx, spec.dy, c.r, c.g, c.b, @as(f32, @floatFromInt(c.a)) / 255.0);
        try self.shadowSpread(id, spec.spread);
    }

    /// Inflation of the shadow before it is blurred — CSS box-shadow's third length.
    pub fn shadowSpread(self: *UIBuilder, id: NodeId, spread: f32) !void {
        try self.store.setStyle(id, .shadow_spread, dimPx(spread));
    }

    pub fn linearGradient(self: *UIBuilder, id: NodeId, r1: u8, g1: u8, b1: u8, a1: f32, r2: u8, g2: u8, b2: u8, a2: f32, vertical: bool) !void {
        try self.backgroundAlpha(id, r1, g1, b1, a1);
        try self.store.setStyle(id, .gradient_color2, props.PropValue.rgbA(r2, g2, b2, a2));
        // type 1 = horizontal, type 2 = vertical
        try self.store.setStyle(id, .gradient_type, .{ .number = if (vertical) 2.0 else 1.0 });
    }

    pub fn radialGradient(self: *UIBuilder, id: NodeId, r1: u8, g1: u8, b1: u8, a1: f32, r2: u8, g2: u8, b2: u8, a2: f32) !void {
        try self.backgroundAlpha(id, r1, g1, b1, a1);
        try self.store.setStyle(id, .gradient_color2, props.PropValue.rgbA(r2, g2, b2, a2));
        // type 3 = radial
        try self.store.setStyle(id, .gradient_type, .{ .number = 3.0 });
    }

    pub fn textColor(self: *UIBuilder, id: NodeId, r: u8, g: u8, b_val: u8) !void {
        try self.store.setStyle(id, .color, props.PropValue.rgbA(r, g, b_val, 1.0));
    }

    /// Text color at an explicit opacity (0..1) — the `backgroundAlpha` /
    /// `borderColorAlpha` counterpart, for tonal palettes (white at 87/60/38%).
    pub fn textColorAlpha(self: *UIBuilder, id: NodeId, r: u8, g: u8, b_val: u8, a: f32) !void {
        try self.store.setStyle(id, .color, props.PropValue.rgbA(r, g, b_val, a));
    }

    pub fn fontSize(self: *UIBuilder, id: NodeId, size: f32) !void {
        try self.store.setStyle(id, .font_size, dimPx(size));
    }

    /// Extra tracking (px) between glyphs. Negative tightens. Affects measurement,
    /// so it relayouts like a font-size change.
    pub fn letterSpacing(self: *UIBuilder, id: NodeId, px: f32) !void {
        try self.store.setStyle(id, .letter_spacing, .{ .number = px });
    }

    /// Line-height multiplier for a text node (CSS unitless `line-height`): each
    /// line slot is `font_size × factor`. Default `text.LINE_HEIGHT_FACTOR` (1.55);
    /// a non-positive factor means "default". Measurement, render, caret and
    /// hit-testing all use it, so it relayouts like a font-size change.
    pub fn lineHeight(self: *UIBuilder, id: NodeId, factor: f32) !void {
        try self.store.setStyle(id, .line_height, .{ .number = factor });
    }

    /// Lays a text node out on one line at its natural width, whatever width is
    /// available: it never soft-wraps, is never shrunk (flex-shrink) or stretched
    /// (cross-axis) below that width, and overflows a narrower parent — clip or
    /// scroll it there. Hard `\n` breaks still start new lines. A declared
    /// `min-width` (e.g. `0`) replaces that floor and a `max-width` caps the box;
    /// either way the line itself still never wraps — it overflows its own box
    /// towards the end, whatever the `text_align`. The standard
    /// single-line text mode: CSS `white-space: nowrap`, Compose
    /// `Text(softWrap = false)`, Flutter `Text(softWrap: false)`. For code
    /// editors and labels inside narrow or horizontally scrolled containers.
    pub fn noWrap(self: *UIBuilder, id: NodeId) !void {
        try self.textWrap(id, false);
    }

    /// Soft wrapping on (`true`, the default) or off (`false`; see `noWrap`).
    pub fn textWrap(self: *UIBuilder, id: NodeId, wrap: bool) !void {
        try self.store.setStyle(id, .text_wrap, .{ .boolean = wrap });
    }

    /// Horizontal alignment of a text node within its box (left / center / right).
    pub fn textAlign(self: *UIBuilder, id: NodeId, alignment: enum { left, center, right }) !void {
        const kw: Keyword = switch (alignment) {
            .left => .left,
            .center => .center,
            .right => .right,
        };
        try self.store.setStyle(id, .text_align, .{ .keyword = kw });
    }

    /// Selects the font face for a text node by semantic role (bold / monospace /
    /// mono-bold). Requires the corresponding face to have been registered on the
    /// atlas (`FontAtlas.addRoleFont`); an unregistered role renders as the primary.
    pub fn fontRole(self: *UIBuilder, id: NodeId, font_role: FontRole) !void {
        try self.store.setStyle(id, .font_role, .{ .number = @floatFromInt(@intFromEnum(font_role)) });
    }

    fn currentRole(self: *UIBuilder, id: NodeId) FontRole {
        if (self.store.getStyle(id, .font_role)) |v| {
            if (v == .number) return text_mod.roleFromOrdinal(v.number);
        }
        return .default;
    }

    /// Toggles bold on a text node, composing with its family (bold+mono →
    /// mono_bold). Orthogonal to `fontMono`, so the two may be called in any order.
    pub fn fontBold(self: *UIBuilder, id: NodeId, on: bool) !void {
        const is_mono = switch (self.currentRole(id)) {
            .mono, .mono_bold => true,
            else => false,
        };
        const r: FontRole = if (is_mono)
            (if (on) .mono_bold else .mono)
        else
            (if (on) .bold else .default);
        try self.fontRole(id, r);
    }

    /// Toggles the monospace family on a text node, composing with its weight.
    pub fn fontMono(self: *UIBuilder, id: NodeId, on: bool) !void {
        const is_bold = switch (self.currentRole(id)) {
            .bold, .mono_bold => true,
            else => false,
        };
        const r: FontRole = if (on)
            (if (is_bold) .mono_bold else .mono)
        else
            (if (is_bold) .bold else .default);
        try self.fontRole(id, r);
    }

    pub fn zIndex(self: *UIBuilder, id: NodeId, z: f32) !void {
        try self.store.setStyle(id, .z_index, .{ .number = z });
    }

    pub fn radius(self: *UIBuilder, id: NodeId, r: f32) !void {
        try self.store.setStyle(id, .radius, dimPx(r));
    }

    pub fn borderWidth(self: *UIBuilder, id: NodeId, w: f32) !void {
        try self.store.setStyle(id, .border_width, dimPx(w));
    }

    pub fn borderColor(self: *UIBuilder, id: NodeId, r: u8, g: u8, b_val: u8) !void {
        try self.store.setStyle(id, .border_color, props.PropValue.rgbA(r, g, b_val, 1.0));
    }

    pub fn borderColorAlpha(self: *UIBuilder, id: NodeId, r: u8, g: u8, b_val: u8, a: f32) !void {
        try self.store.setStyle(id, .border_color, props.PropValue.rgbA(r, g, b_val, a));
    }

    // ── Color-taking variants ─────────────────────────────────────────────────
    //
    // Widget props take a `theme.Color`, so the loose-channel setters above force
    // `t.text.r, t.text.g, t.text.b` at every call site. These take the token
    // directly and honor its alpha channel, so a tonal palette is just
    // `b.textColorOf(id, t.text.withAlpha(0.60))`.

    pub fn textColorOf(self: *UIBuilder, id: NodeId, c: theme_mod.Color) !void {
        try self.store.setStyle(id, .color, colorValue(c));
    }

    pub fn backgroundOf(self: *UIBuilder, id: NodeId, c: theme_mod.Color) !void {
        try self.store.setStyle(id, .background, colorValue(c));
    }

    pub fn borderColorOf(self: *UIBuilder, id: NodeId, c: theme_mod.Color) !void {
        try self.store.setStyle(id, .border_color, colorValue(c));
    }

    /// Per-side border widths (px). Each overrides `borderWidth` for that edge, so a
    /// single-edge rule is `borderTop(id, 2)` with no uniform border set. Paint only —
    /// unlike `borderWidth` these don't inset the content box.
    pub fn borderTop(self: *UIBuilder, id: NodeId, w: f32) !void {
        try self.store.setStyle(id, .border_top, dimPx(w));
    }
    pub fn borderRight(self: *UIBuilder, id: NodeId, w: f32) !void {
        try self.store.setStyle(id, .border_right, dimPx(w));
    }
    pub fn borderBottom(self: *UIBuilder, id: NodeId, w: f32) !void {
        try self.store.setStyle(id, .border_bottom, dimPx(w));
    }
    pub fn borderLeft(self: *UIBuilder, id: NodeId, w: f32) !void {
        try self.store.setStyle(id, .border_left, dimPx(w));
    }

    /// Border stroke style. Dashes apply to square rects; a rounded rect always
    /// strokes solid (per-side/dashed corner math is out of scope).
    pub fn borderStyle(self: *UIBuilder, id: NodeId, style: enum { solid, dashed }) !void {
        try self.store.setStyle(id, .border_style, .{ .number = switch (style) {
            .solid => 0.0,
            .dashed => 1.0,
        } });
    }

    pub fn opacity(self: *UIBuilder, id: NodeId, value: f32) !void {
        try self.store.setStyle(id, .opacity, .{ .number = value });
    }

    // ── Modifier properties ───────────────────────────────────────────────────

    pub fn clickable(self: *UIBuilder, id: NodeId, action_id: []const u8) !void {
        // action_id must outlive the build pass — dupe; setModifier takes ownership.
        const owned = try self.store.stringAllocator().dupe(u8, action_id);
        try self.store.setModifier(id, .clickable, .{ .string = owned });
    }

    pub fn rightClickable(self: *UIBuilder, id: NodeId, action_id: []const u8) !void {
        const owned = try self.store.stringAllocator().dupe(u8, action_id);
        try self.store.setModifier(id, .right_clickable, .{ .string = owned });
    }

    pub fn hoverable(self: *UIBuilder, id: NodeId, action_id: []const u8) !void {
        const owned = try self.store.stringAllocator().dupe(u8, action_id);
        try self.store.setModifier(id, .hoverable, .{ .string = owned });
    }

    /// Attach a `TooltipHost`-visible tooltip to `id`. Same effect as the
    /// `.tooltip` box prop — stores the text as a modifier and marks the node
    /// hoverable with an auto-generated action id — but callable after the node
    /// already exists, for widgets (like `Button`) that apply box overrides post-hoc.
    pub fn tooltip(self: *UIBuilder, id: NodeId, text: []const u8) !void {
        const owned = try self.store.stringAllocator().dupe(u8, text);
        try self.store.setModifier(id, .tooltip, .{ .string = owned });
        var idbuf: [16]u8 = undefined;
        const auto_id = std.fmt.bufPrint(&idbuf, "n{d}", .{id}) catch "n";
        try self.hoverable(id, auto_id);
    }

    pub fn focusable(self: *UIBuilder, id: NodeId, action_id: []const u8) !void {
        const owned = try self.store.stringAllocator().dupe(u8, action_id);
        try self.store.setModifier(id, .focusable, .{ .string = owned });
    }

    pub fn scrollable(self: *UIBuilder, id: NodeId, scroll_id: []const u8) !void {
        const owned = try self.store.stringAllocator().dupe(u8, scroll_id);
        try self.store.setModifier(id, .scrollable, .{ .string = owned });
    }

    pub fn overflowHidden(self: *UIBuilder, id: NodeId) !void {
        try self.store.setModifier(id, .overflow_hidden, .{ .number = 1 });
    }

    pub fn pointerEventsNone(self: *UIBuilder, id: NodeId) !void {
        try self.store.setModifier(id, .pointer_events_none, .{ .number = 1 });
    }

    /// Excludes this node from an ancestor drag-region's bubble handler (e.g. a
    /// menu bar button embedded in a custom caption's draggable area) — see
    /// `ModifierKey.no_drag`.
    pub fn noDrag(self: *UIBuilder, id: NodeId) !void {
        try self.store.setModifier(id, .no_drag, .{ .number = 1 });
    }

    /// Focused node receives Tab/Shift+Tab as key_down instead of the engine
    /// moving focus; Ctrl+Tab or Escape→Tab still leave — see
    /// `ModifierKey.captures_tab`.
    pub fn capturesTab(self: *UIBuilder, id: NodeId) !void {
        try self.store.setModifier(id, .captures_tab, .{ .number = 1 });
    }

    /// Node keeps focus, keyboard routing and accessibility but never paints
    /// the keyboard focus ring — for widgets that draw their own focus
    /// indicator (caret, active cell). See `ModifierKey.no_focus_ring`.
    pub fn noFocusRing(self: *UIBuilder, id: NodeId) !void {
        try self.store.setModifier(id, .no_focus_ring, .{ .number = 1 });
    }

    pub fn nodeId(self: *UIBuilder, id: NodeId, label: []const u8) !void {
        const owned = try self.store.stringAllocator().dupe(u8, label);
        try self.store.setModifier(id, .id, .{ .string = owned });
    }

    pub fn role(self: *UIBuilder, id: NodeId, role_str: []const u8) !void {
        const owned = try self.store.stringAllocator().dupe(u8, role_str);
        try self.store.setModifier(id, .role, .{ .string = owned });
    }

    /// Accessibility state flags (surfaced in the a11y tree). Set by widgets so a
    /// screen reader hears "checked"/"disabled"/"expanded".
    pub fn setDisabled(self: *UIBuilder, id: NodeId, value: bool) !void {
        try self.store.setModifier(id, .disabled, .{ .boolean = value });
    }
    pub fn setChecked(self: *UIBuilder, id: NodeId, value: bool) !void {
        try self.store.setModifier(id, .checked, .{ .boolean = value });
    }
    pub fn setExpanded(self: *UIBuilder, id: NodeId, value: bool) !void {
        try self.store.setModifier(id, .expanded, .{ .boolean = value });
    }

    /// Sets the hover cursor for this node: "pointer", "text", "resize_ew",
    /// "resize_ns", or "default".
    pub fn cursor(self: *UIBuilder, id: NodeId, kind: []const u8) !void {
        const owned = try self.store.stringAllocator().dupe(u8, kind);
        try self.store.setModifier(id, .cursor, .{ .string = owned });
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "UIBuilder — flat box with properties" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var b = UIBuilder.init(&registry, &store);

    const box = try b.openBox();
    try b.width(box, 200, .px);
    try b.height(box, 100, .px);
    try b.background(box, 255, 128, 0);
    b.close();

    try std.testing.expectEqual(@as(usize, 1), registry.nodes.items.len);
    const w = store.getLayout(box, .width).?;
    try std.testing.expectEqual(@as(f32, 200), w.dimension.value);
    const h = store.getLayout(box, .height).?;
    try std.testing.expectEqual(@as(f32, 100), h.dimension.value);
    const bg = store.getStyle(box, .background).?;
    try std.testing.expectEqual(@as(f32, 1.0), bg.color.r);
}

test "UIBuilder — nested hierarchy via open/close" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var b = UIBuilder.init(&registry, &store);

    const outer = try b.openBox(); // id=0
    const inner = try b.openBox(); // id=1, parent=0
    b.close();
    b.close();

    try std.testing.expectEqual(@as(usize, 2), registry.nodes.items.len);
    const outer_node = registry.getNode(outer).?;
    try std.testing.expectEqual(inner, outer_node.first_child);
    const inner_node = registry.getNode(inner).?;
    try std.testing.expectEqual(outer, inner_node.parent);
}

test "UIBuilder — addText sets content and is self-closing" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var b = UIBuilder.init(&registry, &store);

    const root = try b.openBox();
    const txt = try b.addText("Hello Celeris");
    b.close();

    _ = root;
    try std.testing.expectEqual(@as(usize, 2), registry.nodes.items.len);
    try std.testing.expectEqualStrings("Hello Celeris", store.getTextContent(txt).?);
    // After addText the stack should be back to only root — verify by adding a sibling
    const txt2 = try b.addText("World");
    _ = txt2;
    // Still only 3 nodes total (root + txt + txt2)
    try std.testing.expectEqual(@as(usize, 3), registry.nodes.items.len);
    b.close(); // root
}

test "UIBuilder — sibling nodes share same parent" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var b = UIBuilder.init(&registry, &store);

    const root = try b.openBox(); // id=0
    const c1 = try b.openBox(); // id=1
    b.close();
    const c2 = try b.openBox(); // id=2
    b.close();
    b.close(); // root

    const root_node = registry.getNode(root).?;
    try std.testing.expectEqual(c1, root_node.first_child);
    const c1_node = registry.getNode(c1).?;
    try std.testing.expectEqual(c2, c1_node.next_sibling);
}

test "UIBuilder — flexRow sets keyword" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    var b = UIBuilder.init(&registry, &store);
    const box = try b.openBox();
    try b.flexRow(box);
    b.close();

    const fd = store.getLayout(box, .flex_direction).?;
    try std.testing.expectEqual(Keyword.row, fd.keyword);
}

// ── Keyed reconciliation tests ────────────────────────────────────────────────

/// Builds a root box whose children are keyed boxes in the given key order.
/// A fresh builder reconciles against whatever tree already exists.
fn buildKeyedList(registry: *reg.UIRegistry, store: *props.PropertyStore, keys: []const u64) !void {
    var b = UIBuilder.init(registry, store);
    _ = try b.openBox(); // root (reused on later passes)
    for (keys) |k| {
        _ = try b.openNodeKeyed(.box, k);
        b.close();
    }
    b.close();
}

/// Returns the child NodeId under `root` that carries reconciliation key `k`.
fn childByKey(registry: *reg.UIRegistry, root: reg.NodeId, k: u64) ?reg.NodeId {
    var c = registry.getNode(root).?.first_child;
    while (c != reg.NULL_NODE) {
        const node = registry.getNode(c).?;
        if (node.key != null and node.key.? == k) return c;
        c = node.next_sibling;
    }
    return null;
}

fn childKeyOrder(registry: *reg.UIRegistry, root: reg.NodeId, out: *std.array_list.Managed(u64)) !void {
    var c = registry.getNode(root).?.first_child;
    while (c != reg.NULL_NODE) {
        const node = registry.getNode(c).?;
        if (node.key) |k| try out.append(k);
        c = node.next_sibling;
    }
}

test "UIBuilder keyed — reorder reuses node ids, recreates nothing" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try buildKeyedList(&registry, &store, &.{ 1, 2, 3 });
    const id1 = childByKey(&registry, 0, 1).?;
    const id2 = childByKey(&registry, 0, 2).?;
    const id3 = childByKey(&registry, 0, 3).?;
    try std.testing.expectEqual(@as(usize, 4), registry.nodes.items.len);

    // Reorder to 3,1,2.
    try buildKeyedList(&registry, &store, &.{ 3, 1, 2 });

    // Same ids reused — nothing recreated, free list empty.
    try std.testing.expectEqual(id1, childByKey(&registry, 0, 1).?);
    try std.testing.expectEqual(id2, childByKey(&registry, 0, 2).?);
    try std.testing.expectEqual(id3, childByKey(&registry, 0, 3).?);
    try std.testing.expectEqual(@as(usize, 4), registry.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.free_list.items.len);

    // New sibling order matches the rebuild order.
    var order = std.array_list.Managed(u64).init(std.testing.allocator);
    defer order.deinit();
    try childKeyOrder(&registry, 0, &order);
    try std.testing.expectEqualSlices(u64, &.{ 3, 1, 2 }, order.items);
}

test "UIBuilder keyed — insert at front keeps existing ids" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try buildKeyedList(&registry, &store, &.{ 2, 3 });
    const id2 = childByKey(&registry, 0, 2).?;
    const id3 = childByKey(&registry, 0, 3).?;

    try buildKeyedList(&registry, &store, &.{ 1, 2, 3 });
    try std.testing.expectEqual(id2, childByKey(&registry, 0, 2).?);
    try std.testing.expectEqual(id3, childByKey(&registry, 0, 3).?);
    try std.testing.expect(childByKey(&registry, 0, 1) != null); // new node for key 1

    var order = std.array_list.Managed(u64).init(std.testing.allocator);
    defer order.deinit();
    try childKeyOrder(&registry, 0, &order);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, order.items);
}

test "UIBuilder keyed — remove middle drops only that node" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try buildKeyedList(&registry, &store, &.{ 1, 2, 3 });
    const id1 = childByKey(&registry, 0, 1).?;
    const id3 = childByKey(&registry, 0, 3).?;

    try buildKeyedList(&registry, &store, &.{ 1, 3 });
    try std.testing.expectEqual(id1, childByKey(&registry, 0, 1).?);
    try std.testing.expectEqual(id3, childByKey(&registry, 0, 3).?);
    try std.testing.expectEqual(@as(?reg.NodeId, null), childByKey(&registry, 0, 2));
    // The removed node's slot went to the free list.
    try std.testing.expectEqual(@as(usize, 1), registry.free_list.items.len);
}

test "UIBuilder mixed — unkeyed child AFTER keyed keeps identity across rebuilds, no leak" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    const Build = struct {
        fn run(r: *reg.UIRegistry, s: *props.PropertyStore) !void {
            var b = UIBuilder.init(r, s);
            _ = try b.openBox(); // root id 0
            _ = try b.openNodeKeyed(.box, 1);
            b.close(); // keyed child
            const u = try b.openBox();
            try b.width(u, 5, .px); // unkeyed sibling AFTER the keyed one
            b.close();
            b.close(); // root
        }
    };

    try Build.run(&registry, &store);
    const keyed_id = childByKey(&registry, 0, 1).?;
    const unkeyed_id = registry.getNode(keyed_id).?.next_sibling;
    const n0 = registry.nodes.items.len;

    for (0..4) |_| try Build.run(&registry, &store);

    try std.testing.expectEqual(n0, registry.nodes.items.len); // no slot growth
    try std.testing.expectEqual(keyed_id, childByKey(&registry, 0, 1).?); // keyed stable
    // Unkeyed sibling must also keep its identity (regression: it churned before).
    try std.testing.expectEqual(unkeyed_id, registry.getNode(keyed_id).?.next_sibling);

    var count: usize = 0;
    var c = registry.getNode(0).?.first_child;
    while (c != reg.NULL_NODE) : (c = registry.getNode(c).?.next_sibling) count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "UIBuilder mixed — positional child BEFORE keyed child both stay stable, no leak" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    const Build = struct {
        fn run(r: *reg.UIRegistry, s: *props.PropertyStore) !void {
            var b = UIBuilder.init(r, s);
            _ = try b.openBox(); // root
            const u = try b.openBox();
            try b.width(u, 5, .px); // unkeyed sibling BEFORE the keyed one
            b.close();
            _ = try b.openNodeKeyed(.box, 7);
            b.close(); // keyed child
            b.close(); // root
        }
    };

    try Build.run(&registry, &store);
    const unkeyed_id = registry.getNode(0).?.first_child;
    const keyed_id = childByKey(&registry, 0, 7).?;
    const n0 = registry.nodes.items.len;

    for (0..4) |_| try Build.run(&registry, &store);

    try std.testing.expectEqual(n0, registry.nodes.items.len);
    try std.testing.expectEqual(unkeyed_id, registry.getNode(0).?.first_child);
    try std.testing.expectEqual(keyed_id, childByKey(&registry, 0, 7).?);
}

test "UIBuilder — rootAt rebuilds an arbitrary subtree in place" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    // Build root -> container -> [A]
    var b = UIBuilder.init(&registry, &store);
    _ = try b.openBox(); // root id 0
    const container = try b.openBox(); // id 1
    _ = try b.addText("A");
    b.close(); // container
    b.close(); // root
    try std.testing.expectEqual(@as(usize, 3), registry.nodes.items.len);

    // Partial rebuild: re-run only the container's children with new content.
    var b2 = UIBuilder.init(&registry, &store);
    try b2.rootAt(container);
    _ = try b2.addText("B");
    b2.close();

    // Container still has exactly one text child, now "B"; root untouched.
    const cont = registry.getNode(container).?;
    const child = registry.getNode(cont.first_child).?;
    try std.testing.expectEqual(reg.NodeType.text, child.node_type);
    try std.testing.expectEqualStrings("B", store.getTextContent(cont.first_child).?);
    try std.testing.expectEqual(reg.NULL_NODE, child.next_sibling);
}

test "BUG: rebuilding after the root id was removed must not panic on a tombstone" {
    // `registry.nodes` is an index-addressed slab: a removed id stays in the
    // array as a dead entry and `getNode` returns null for it. The root scan in
    // `openNodeKeyed` unwrapped that with `.?`, so a host that removed a low id
    // through the C node API crashed the process on the very next rebuild.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    {
        var b = UIBuilder.init(&registry, &store);
        const root = try b.openBox();
        _ = root;
        b.close();
    }

    registry.removeNode(0); // the whole tree, root included, becomes tombstones

    // Rebuilding must fall back to a fresh root rather than dereferencing the
    // dead entry at index 0.
    var b = UIBuilder.init(&registry, &store);
    const root = try b.openBox();
    b.close();
    try std.testing.expect(registry.getNode(root) != null);
    try std.testing.expectEqual(reg.NULL_NODE, registry.getNode(root).?.parent);
}

test "TextMeasure.verticalWith / lineHeightWith honour the factor, with or without an engine" {
    const Stub = struct {
        fn w(_: *anyopaque, _: []const u8, _: f32) f32 {
            return 0;
        }
    };
    var dummy: u8 = 0;
    const m = TextMeasure{ .ctx = @ptrCast(&dummy), .measureFn = Stub.w };
    try std.testing.expectApproxEqAbs(@as(f32, 20), m.lineHeightWith(16, 1.25), 0.0001);
    try std.testing.expectApproxEqAbs(text_mod.lineHeight(16), m.lineHeight(16), 0.0001);
    const vl = m.verticalWith(16, 40, 2, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 16), vl.line_height, 0.0001);
    const fb = verticalFallbackWith(16, 40, 2, 1.0);
    try std.testing.expectApproxEqAbs(vl.baseline, fb.baseline, 0.0001);
    try std.testing.expectApproxEqAbs(text_mod.lineHeight(16), m.vertical(16, 40, 1).line_height, 0.0001);
}
