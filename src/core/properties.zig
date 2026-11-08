const std = @import("std");
const reg = @import("../core/registry.zig");
const path_mod = @import("../core/path.zig");

pub const DimUnit = enum { px, pt, percent };

/// Extended keyword set: includes flex/position values so we avoid
/// string comparisons in the hot layout path.
pub const Keyword = enum { auto, fill_parent, center, left, right, row, column, absolute, flex_start, flex_end, space_between, space_around, space_evenly, stretch, baseline };

/// A node id carried as an f32, or null if it is not a valid one (negative,
/// non-integral, NaN/Inf, or beyond NodeId's range).
pub fn nodeIdFromNumber(n: f32) ?reg.NodeId {
    if (!std.math.isFinite(n) or n < 0 or n != @floor(n)) return null;
    if (n >= @as(f32, @floatFromInt(std.math.maxInt(reg.NodeId)))) return null;
    return @intFromFloat(n);
}

pub const PropValue = union(enum) {
    dimension: struct { value: f32, unit: DimUnit },
    color: struct { r: f32, g: f32, b: f32, a: f32 },
    /// **The store takes ownership of this slice** — it frees it when the value is
    /// overwritten and again at `deinit`/`clear`. So it must come from the store's
    /// own allocator: build it with `PropertyStore.ownedString`, or dupe through
    /// `stringAllocator()`. Handing a literal (or a stack buffer) to any setter is
    /// a free of memory the store doesn't own, and it crashes at teardown, not at
    /// the call. Same contract as `setTextContent`.
    string: []const u8,
    keyword: Keyword,
    number: f32,
    boolean: bool,

    pub fn eql(a: PropValue, b: PropValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .dimension => |d| d.value == b.dimension.value and d.unit == b.dimension.unit,
            .color => |c| c.r == b.color.r and c.g == b.color.g and c.b == b.color.b and c.a == b.color.a,
            .string => |s| std.mem.eql(u8, s, b.string),
            .keyword => |k| k == b.keyword,
            .number => |n| n == b.number,
            .boolean => |v| v == b.boolean,
        };
    }

    /// Helper to create a color PropValue from 0-255 RGB and 0.0-1.0 alpha.
    pub fn rgbA(r: u8, g: u8, b: u8, a: f32) PropValue {
        return .{ .color = .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = a,
        } };
    }

    /// Helper to create a color PropValue from a theme Color and an alpha override.
    pub fn colorA(c: anytype, a: f32) PropValue {
        return rgbA(c.r, c.g, c.b, a);
    }
};

pub const LayoutKey = enum {
    width,
    height,
    margin_top,
    margin_bottom,
    margin_left,
    margin_right,
    padding_top,
    padding_bottom,
    padding_left,
    padding_right,
    justify_content,
    align_items,
    /// Per-child override of the parent's `align_items` on the cross axis.
    /// Unset → the child follows the parent's `align_items`.
    align_self,
    flex_direction,
    position,
    left,
    top,
    flex_grow,
    flex_shrink,
    flex_wrap,
    gap,
    /// Per-axis gap overrides. `row_gap` spaces items stacked vertically
    /// (between wrap lines in a row, between items in a column); `column_gap`
    /// spaces items side by side. Unset → fall back to `gap`.
    row_gap,
    column_gap,
    flex_basis,
    min_width,
    min_height,
    max_width,
    max_height,
    /// Vertical scroll offset applied to this node's CHILDREN at placement
    /// time (flexbox adds it to the children's y origin). Writing it does NOT
    /// invalidate layout: `setLayout` special-cases it into a subtree geometry
    /// shift + render-only dirty, so scrolling never triggers a global solve.
    scroll_offset_y,
    /// Horizontal counterpart of `scroll_offset_y` — added to the children's
    /// x origin at placement, same render-only subtree-shift treatment in
    /// `setLayout`. No `ScrollView` consumes it yet; `VirtualGrid` drives it
    /// directly for column virtualization.
    scroll_offset_x,
};

pub const StyleKey = enum {
    background,
    color,
    radius,
    opacity,
    font_size,
    /// Semantic font role (`text.FontRole` ordinal, stored as `.number`): selects
    /// the bold / monospace face for this text node. Affects shaping metrics, so
    /// it invalidates layout like `font_size`.
    font_role,
    /// Extra tracking (px) added to every glyph advance (`.number`). Changes the
    /// measured width, so it invalidates layout like `font_size`.
    letter_spacing,
    /// Line-height multiplier (`.number`, CSS unitless `line-height`): each line
    /// slot is `font_size × line_height`. Unset = `text.LINE_HEIGHT_FACTOR` (1.55).
    /// Changes the measured height, so it invalidates layout like `font_size`.
    line_height,
    text_align,
    border_width,
    border_color,
    /// Per-side border widths (px). Unset sides fall back to `border_width`. Paint
    /// only — thin decorations (dividers, a tab underline) that don't shift layout.
    border_top,
    border_right,
    border_bottom,
    border_left,
    /// Border style: 0 = solid (default), 1 = dashed. `.number`.
    border_style,
    shadow_color,
    shadow_blur,
    shadow_offset_x,
    shadow_offset_y,
    /// Inflation of the shadow rect before blurring — CSS box-shadow's third
    /// length. Negative shrinks it. `.dimension`.
    shadow_spread,
    gradient_color2,
    gradient_type,
    z_index,
};

pub const ModifierKey = enum {
    id,
    clickable,
    right_clickable,
    hoverable,
    focusable,
    scrollable,
    overflow_hidden,
    pointer_events_none,
    src,
    clickable_capture,
    right_clickable_capture,
    hoverable_capture,
    role,
    cursor,
    /// Explicit accessible name (aria-label). Overrides text-derived naming so
    /// icon-only controls (titlebar min/max/close, icon buttons) expose a name
    /// to UIA / screen readers instead of "".
    label,
    /// Marks an editable control read-only. Surfaced as UIA ValuePattern
    /// IsReadOnly; a read-only input still exposes its value but refuses SetValue.
    readonly,
    // Accessibility states (exposed in the a11y tree).
    disabled,
    checked,
    expanded,
    // Tooltip text shown after a hover dwell. Making a node carry this also
    // marks it hoverable so the TooltipHost observer sees its enter/leave.
    tooltip,
    /// Marks a node (and its subtree) as excluded from an ancestor's drag-region
    /// bubble handler — the ancestor equivalent of CSS's `app-region: no-drag`.
    /// Set on interactive content (e.g. a menu bar's buttons) embedded inside a
    /// custom window caption's draggable area, so clicking it opens the menu
    /// instead of starting a window drag. See `dispatchEvent`'s bubble phase.
    no_drag,
    /// redirects WHERE the focus ring paints (and, in UIA,
    /// where the focus-changed event fires) when THIS node holds real engine
    /// focus — value is a `.number` holding the target NodeId. A container
    /// with "virtual"/roving selection (a `Menu` panel highlighting one row
    /// via arrow keys, matching the ARIA `aria-activedescendant` pattern) sets
    /// this to the currently-highlighted row instead of moving real focus off
    /// itself — real focus stays on the container (so Tab-trapping and
    /// key_down routing keep working), only the ring/AT-visible target moves.
    /// Absent (or the value doesn't resolve to a live node) → no redirect, the
    /// ring paints on the real focused node as usual.
    virtual_focus_target,
    /// When THIS node holds focus, a plain Tab / Shift+Tab key_down is
    /// delivered to it instead of moving focus (opt-in for widgets that
    /// handle Tab themselves — VirtualGrid today; code editors later). Handle
    /// it on key_down: Linux never sends a char_input for Tab. Ctrl+Tab, or
    /// Escape followed by Tab, still traverses (within the active focus
    /// scope) — no keyboard trap (WCAG 2.1.2). Value: `.number = 1`.
    captures_tab,
};

const layout_count = @typeInfo(LayoutKey).@"enum".fields.len;
const style_count = @typeInfo(StyleKey).@"enum".fields.len;
const modifier_count = @typeInfo(ModifierKey).@"enum".fields.len;

// ── NodeProps ─────────────────────────────────────────────────────────────────
/// Per-node property bag stored directly in a contiguous array indexed by NodeId.
/// Each property domain is a small fixed array indexed *directly* by the key enum
/// (`@intFromEnum`), so get/set are O(1) with no scan and no per-node heap alloc.
/// An unset property is `null`. This replaces the old `BoundedArray` of {key,value}
/// pairs — it removes the linear scan, the length bookkeeping, and the fixed-cap
/// overflow footgun, and is smaller (no key bytes, no length field, sized to the
/// exact number of keys).
pub const NodeProps = struct {
    layout: [layout_count]?PropValue = [_]?PropValue{null} ** layout_count,
    style: [style_count]?PropValue = [_]?PropValue{null} ** style_count,
    modifier: [modifier_count]?PropValue = [_]?PropValue{null} ** modifier_count,
    text_content: ?[]const u8 = null,
    /// Vertices of a `NodeType.path` node. Store-owned (allocated by `setPath`,
    /// freed by `freeEntryStrings`), variable-length, per-node — the same
    /// contract as `text_content`, and preserved across a reused node's
    /// `clearProperties(keep_text = true)` for the same reason.
    path_data: ?[]path_mod.PathVertex = null,
};

/// What changed on a node, handed to the property-changed listener. Platform-
/// agnostic on purpose: the store never mentions UIA — the engine's listener maps
/// a `.checked`/`.expanded`/`.text` change onto the right accessibility event.
pub const ChangedProp = union(enum) {
    modifier: ModifierKey,
    text,
};

// ── PropertyStore ─────────────────────────────────────────────────────────────
/// Central property store.  NodeIds are dense u32 starting at 0, so we use a
/// direct-indexed ArrayList — O(1) lookup without any hash overhead.
///
/// String values (identifiers, text content) are allocated from
/// `stringAllocator()` (the store's general allocator). The setter that receives
/// one takes ownership and frees it when it is replaced, cleared, or on `deinit`.
pub const PropertyStore = struct {
    /// Indexed directly by NodeId. `props.items[id]` is always valid after
    /// `registerNode(id)` because we fill gaps with empty NodeProps.
    props: std.array_list.Managed(NodeProps),
    allocator: std.mem.Allocator,
    registry: ?*reg.UIRegistry = null,
    /// Single subscriber notified when a modifier or the text content of a node
    /// actually changes value (never on a no-op write). The engine uses it to raise
    /// UIA property-changed events off the one place state is mutated, so every
    /// origin — click, keyboard, UIA action, host code — flows through one funnel.
    prop_changed_ctx: ?*anyopaque = null,
    prop_changed_cb: ?*const fn (ctx: ?*anyopaque, node_id: reg.NodeId, changed: ChangedProp) void = null,

    pub fn init(allocator: std.mem.Allocator) PropertyStore {
        return .{
            .props = std.array_list.Managed(NodeProps).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn setRegistry(self: *PropertyStore, registry: *reg.UIRegistry) void {
        self.registry = registry;
    }

    /// Registers the (single) property-changed subscriber. Passing null cb detaches.
    pub fn setPropertyChangedListener(self: *PropertyStore, ctx: ?*anyopaque, cb: ?*const fn (ctx: ?*anyopaque, node_id: reg.NodeId, changed: ChangedProp) void) void {
        self.prop_changed_ctx = ctx;
        self.prop_changed_cb = cb;
    }

    fn firePropChanged(self: *PropertyStore, node_id: reg.NodeId, changed: ChangedProp) void {
        if (self.prop_changed_cb) |cb| cb(self.prop_changed_ctx, node_id, changed);
    }

    /// Frees every owned string in an entry (string-typed property values + text).
    fn freeEntryStrings(self: *PropertyStore, entry: *NodeProps) void {
        for (entry.layout) |maybe| if (maybe) |p| {
            if (p == .string) self.allocator.free(p.string);
        };
        for (entry.style) |maybe| if (maybe) |p| {
            if (p == .string) self.allocator.free(p.string);
        };
        for (entry.modifier) |maybe| if (maybe) |p| {
            if (p == .string) self.allocator.free(p.string);
        };
        if (entry.text_content) |t| self.allocator.free(t);
        if (entry.path_data) |p| self.allocator.free(p);
    }

    pub fn deinit(self: *PropertyStore) void {
        for (self.props.items) |*entry| self.freeEntryStrings(entry);
        self.props.deinit();
    }

    /// Call after clearing the registry to reuse the store for a new UI load.
    pub fn clear(self: *PropertyStore) void {
        for (self.props.items) |*entry| self.freeEntryStrings(entry);
        self.props.clearRetainingCapacity();
    }

    /// Resets a node's properties to "unset". `keep_text` preserves `text_content`
    /// (and, by the same argument, `path_data`) across the reset: the
    /// reconciliation reuse path (UIBuilder.openNodeKeyed) clears a reused node
    /// then re-applies its content via `setTextContent` / `setPath`, whose
    /// identical-content short-circuit can only fire if the OLD content
    /// is still there to compare against. Wiping it here would make every reused
    /// content node re-dirty on each rebuild → a full window re-shape / re-solve
    /// on every scroll. The node-removed listener passes `keep_text = false` so a
    /// truly freed node still releases both. (Reuse only matches same-type nodes,
    /// so a reused non-text node has `text_content == null` and vice versa —
    /// keeping the irrelevant one is a no-op.)
    pub fn clearProperties(self: *PropertyStore, node_id: reg.NodeId, keep_text: bool) void {
        if (node_id >= self.props.items.len) return;
        const entry = &self.props.items[node_id];

        // Detach the preserved content before freeEntryStrings so it is neither
        // freed here nor stranded by the `entry.* = .{}` reset below.
        const preserved_text = if (keep_text) entry.text_content else null;
        const preserved_path = if (keep_text) entry.path_data else null;
        if (keep_text) {
            entry.text_content = null;
            entry.path_data = null;
        }

        // Styles that shape text (see setStyle). Dropping one of them changes the
        // measured text, so the cached layout must be rebuilt — otherwise a reused
        // node that loses e.g. `line_height` keeps drawing at the old factor.
        const shaping_keys = [_]StyleKey{ .font_size, .font_role, .letter_spacing, .line_height };
        var had_shaping_style = false;
        for (shaping_keys) |k| {
            if (entry.style[@intFromEnum(k)] != null) had_shaping_style = true;
        }

        self.freeEntryStrings(entry);
        entry.* = .{}; // reset all domains to "unset" (every slot null)
        entry.text_content = preserved_text;
        entry.path_data = preserved_path;

        // Mark as dirty
        if (self.registry) |r| {
            if (had_shaping_style) {
                if (r.getNode(node_id)) |n| n.text_dirty = true;
            }
            r.global_layout_dirty = true;
            r.global_render_dirty = true;
            var curr_id = node_id;
            while (curr_id != reg.NULL_NODE) {
                if (r.getNode(curr_id)) |node| {
                    if (node.layout_dirty) break; // Optimization: ancestors are already dirty
                    node.layout_dirty = true;
                    node.render_dirty = true;
                    curr_id = node.parent;
                } else break;
            }
        }
    }

    /// Returns the allocator. Use this for all string duplication so nothing leaks.
    pub fn stringAllocator(self: *PropertyStore) std.mem.Allocator {
        return self.allocator;
    }

    /// A `.string` PropValue the store may take ownership of — the one-liner form of
    /// `.{ .string = try store.stringAllocator().dupe(u8, s) }`. Only hand a setter a
    /// string that came from here (or from `stringAllocator()`); see `PropValue.string`.
    pub fn ownedString(self: *PropertyStore, str: []const u8) !PropValue {
        return .{ .string = try self.allocator.dupe(u8, str) };
    }

    // ── Registration ──────────────────────────────────────────────────────────

    /// Must be called once per node immediately after `UIRegistry.createNode`.
    /// NodeIds must be registered in order (0, 1, 2 …) — the parser guarantees this.
    pub fn registerNode(self: *PropertyStore, node_id: reg.NodeId) !void {
        // A recycled id (from the registry's free_list, or reused after a full
        // `clear()`) already has a slot — and that slot still holds the *dead*
        // node's style, modifiers and owned strings. Left alone, the new node
        // inherits every property it doesn't explicitly set: a footer with only
        // `borderTop(1)` shows borders on all four sides because the id's previous
        // tenant had `border_width = 1`. Wipe it (freeing owned strings first) so a
        // registered node always starts from defaults, no matter the tree's history.
        if (node_id < self.props.items.len) {
            self.clearProperties(node_id, false);
            return;
        }
        // Fill any gap (defensive; normally ids are perfectly sequential)
        while (self.props.items.len <= node_id) {
            try self.props.append(.{});
        }
    }

    // ── Setters ───────────────────────────────────────────────────────────────

    /// Writes `value` into `slot`, freeing a replaced owned string (unless it is the
    /// very same pointer). Returns whether the stored value actually changed — the
    /// signal the dirty-tracking uses to skip work for no-op writes.
    ///
    /// This is where a `.string` value becomes the store's to free, so `value.string`
    /// must be store-allocated — see `PropValue.string`. The deliberate choice is to
    /// transfer, not to copy: most string values are built for the call anyway
    /// (`ownedString`, `std.fmt.allocPrint`), so copying here would allocate twice on
    /// the common path, and it keeps one ownership rule across the whole store rather
    /// than a copying `setLayout` next to a transferring `setTextContent`.
    /// Frees `value` if it owns a string — for the out-of-range early return in
    /// every setter below. Ownership of a `.string` PropValue transfers to the
    /// store at the call (same contract as `setTextContent`, see there): a
    /// setter that silently drops an unknown node id without this leaks
    /// whatever the caller just duped for it. Not currently reachable from the
    /// C-ABI (no export calls setStyle/setLayout/setModifier with a
    /// host-supplied node id yet — celeris_node_set_text_content is the one
    /// that is, and had exactly this leak), but the contract should hold
    /// uniformly rather than only where a fuzzer happened to reach it.
    fn discardUnowned(self: *PropertyStore, value: PropValue) void {
        if (value == .string) self.allocator.free(value.string);
    }

    fn writeSlot(self: *PropertyStore, slot: *?PropValue, value: PropValue) bool {
        var changed = true;
        if (slot.*) |old| {
            if (old.eql(value)) changed = false;
            if (old == .string) {
                const same = value == .string and old.string.ptr == value.string.ptr;
                if (!same) self.allocator.free(old.string);
            }
        }
        slot.* = value;
        return changed;
    }

    pub fn setLayout(self: *PropertyStore, node_id: reg.NodeId, key: LayoutKey, value: PropValue) !void {
        if (node_id >= self.props.items.len) return self.discardUnowned(value);

        // Scroll is a render-time translation, not a layout change. Shift the
        // already-resolved geometry of the subtree by the delta and mark render
        // dirty only — the next full solve recomputes the same positions (flexbox
        // adds the offset when placing this node's children), so both paths agree.
        if (key == .scroll_offset_y or key == .scroll_offset_x) {
            const slot = &self.props.items[node_id].layout[@intFromEnum(key)];
            const old_val: f32 = if (slot.*) |p| scrollOffsetValue(p) else 0.0;
            const changed = self.writeSlot(slot, value);
            if (changed) {
                const delta = scrollOffsetValue(value) - old_val;
                const dx: f32 = if (key == .scroll_offset_x) delta else 0.0;
                const dy: f32 = if (key == .scroll_offset_y) delta else 0.0;
                if (self.registry) |r| {
                    if (r.getNode(node_id)) |node| {
                        var child = node.first_child;
                        while (child != reg.NULL_NODE) {
                            shiftSubtree(r, child, dx, dy, 0);
                            child = if (r.getNode(child)) |c| c.next_sibling else reg.NULL_NODE;
                        }
                        node.render_dirty = true;
                    }
                    r.global_render_dirty = true;
                }
            }
            return;
        }

        const changed = self.writeSlot(&self.props.items[node_id].layout[@intFromEnum(key)], value);
        if (changed) {
            if (self.registry) |r| {
                r.global_layout_dirty = true;
                r.global_render_dirty = true;
                var curr_id = node_id;
                while (curr_id != reg.NULL_NODE) {
                    if (r.getNode(curr_id)) |node| {
                        if (node.layout_dirty) break;
                        node.layout_dirty = true;
                        node.render_dirty = true;
                        curr_id = node.parent;
                    } else break;
                }
            }
        }
    }

    pub fn setStyle(self: *PropertyStore, node_id: reg.NodeId, key: StyleKey, value: PropValue) !void {
        if (node_id >= self.props.items.len) return self.discardUnowned(value);
        const changed = self.writeSlot(&self.props.items[node_id].style[@intFromEnum(key)], value);
        if (changed) {
            if (self.registry) |r| {
                // font_size changes the measured text size, so it must invalidate
                // layout (and ancestors), not just paint — otherwise the cached
                // text dimensions go stale. Other style keys are paint-only.
                if (key == .font_size or key == .font_role or key == .letter_spacing or key == .line_height) {
                    r.global_layout_dirty = true;
                    r.global_render_dirty = true;
                    if (r.getNode(node_id)) |n| n.text_dirty = true; // font size changes shaping
                    var curr_id = node_id;
                    while (curr_id != reg.NULL_NODE) {
                        if (r.getNode(curr_id)) |node| {
                            if (node.layout_dirty) break;
                            node.layout_dirty = true;
                            node.render_dirty = true;
                            curr_id = node.parent;
                        } else break;
                    }
                } else if (r.getNode(node_id)) |node| {
                    r.global_render_dirty = true;
                    node.render_dirty = true;
                }
            }
        }
    }

    pub fn setModifier(self: *PropertyStore, node_id: reg.NodeId, key: ModifierKey, value: PropValue) !void {
        if (node_id >= self.props.items.len) return self.discardUnowned(value);
        const changed = self.writeSlot(&self.props.items[node_id].modifier[@intFromEnum(key)], value);
        if (changed) self.firePropChanged(node_id, .{ .modifier = key });
    }

    /// The content slice must be owned by the store's allocator (allocate through
    /// `stringAllocator()`); the store takes ownership and frees it. Setting
    /// content identical to the current text is a no-op — the incoming copy is
    /// freed and no dirty flag is touched (same short-circuit as setStyle/
    /// setLayout), so re-writing an unchanged string never forces a relayout,
    /// reshape, or render.
    pub fn setTextContent(self: *PropertyStore, node_id: reg.NodeId, content: []const u8) void {
        // Ownership of `content` transfers at the call, so an unknown node must
        // free it rather than drop it on the floor — otherwise every setter that
        // dupes first (the C API does) leaks on a stale id.
        if (node_id >= self.props.items.len) {
            self.allocator.free(content);
            return;
        }
        if (self.props.items[node_id].text_content) |old_content| {
            if (old_content.ptr == content.ptr and old_content.len == content.len) return;
            if (std.mem.eql(u8, old_content, content)) {
                self.allocator.free(content);
                return;
            }
            self.allocator.free(old_content);
        }
        self.props.items[node_id].text_content = content;
        self.firePropChanged(node_id, .text);

        if (self.registry) |r| {
            r.global_layout_dirty = true;
            r.global_render_dirty = true;
            if (r.getNode(node_id)) |n| n.text_dirty = true; // content changed → re-shape
            var curr_id = node_id;
            while (curr_id != reg.NULL_NODE) {
                if (r.getNode(curr_id)) |node| {
                    if (node.layout_dirty) break;
                    node.layout_dirty = true;
                    node.render_dirty = true;
                    curr_id = node.parent;
                } else break;
            }
        }
    }

    /// Sets a `NodeType.path` node's vertices. Unlike `setTextContent`, the
    /// store *copies* `verts` (callers hold a `[*]const f32` from the C-ABI or a
    /// builder-local slice — neither is store-allocated). A byte-identical write
    /// is a no-op, same short-circuit as the other setters. Marks layout dirty
    /// (the vertex AABB feeds intrinsic sizing) and render dirty.
    pub fn setPath(self: *PropertyStore, node_id: reg.NodeId, verts: []const path_mod.PathVertex) !void {
        if (node_id >= self.props.items.len) return;
        const entry = &self.props.items[node_id];

        if (entry.path_data) |old| {
            if (std.mem.eql(u8, std.mem.sliceAsBytes(old), std.mem.sliceAsBytes(verts))) return;
            self.allocator.free(old);
            entry.path_data = null;
        } else if (verts.len == 0) {
            return; // nothing set, nothing to set
        }

        entry.path_data = if (verts.len == 0) null else try self.allocator.dupe(path_mod.PathVertex, verts);
        // No firePropChanged: a path node carries no accessibility semantics, so
        // there is nothing for the UIA/AT-SPI listener to map.

        if (self.registry) |r| {
            r.global_layout_dirty = true;
            r.global_render_dirty = true;
            var curr_id = node_id;
            while (curr_id != reg.NULL_NODE) {
                if (r.getNode(curr_id)) |node| {
                    if (node.layout_dirty) break;
                    node.layout_dirty = true;
                    node.render_dirty = true;
                    curr_id = node.parent;
                } else break;
            }
        }
    }

    pub fn getPath(self: *const PropertyStore, node_id: reg.NodeId) ?[]const path_mod.PathVertex {
        if (node_id >= self.props.items.len) return null;
        return self.props.items[node_id].path_data;
    }

    /// The px value of a scroll_offset_{x,y} write (canonically a px dimension;
    /// tolerate a bare number so generic key sweeps don't trap on the union).
    fn scrollOffsetValue(p: PropValue) f32 {
        return switch (p) {
            .dimension => |d| d.value,
            .number => |n| n,
            else => 0.0,
        };
    }

    /// Translates the resolved geometry of `node_id` and all its descendants by
    /// `(dx, dy)` px. Depth-capped like every other tree walk so a pathological
    /// tree cannot overflow the stack.
    fn shiftSubtree(r: *reg.UIRegistry, node_id: reg.NodeId, dx: f32, dy: f32, depth: usize) void {
        if (depth >= reg.MAX_TREE_DEPTH) return;
        const node = r.getNode(node_id) orelse return;
        node.geometry.x += dx;
        node.geometry.y += dy;
        var child = node.first_child;
        while (child != reg.NULL_NODE) {
            shiftSubtree(r, child, dx, dy, depth + 1);
            child = if (r.getNode(child)) |c| c.next_sibling else reg.NULL_NODE;
        }
    }

    // ── Getters ───────────────────────────────────────────────────────────────

    pub fn getLayout(self: *const PropertyStore, node_id: reg.NodeId, key: LayoutKey) ?PropValue {
        if (node_id >= self.props.items.len) return null;
        return self.props.items[node_id].layout[@intFromEnum(key)];
    }

    pub fn getStyle(self: *const PropertyStore, node_id: reg.NodeId, key: StyleKey) ?PropValue {
        if (node_id >= self.props.items.len) return null;
        return self.props.items[node_id].style[@intFromEnum(key)];
    }

    pub fn getModifier(self: *const PropertyStore, node_id: reg.NodeId, key: ModifierKey) ?PropValue {
        if (node_id >= self.props.items.len) return null;
        return self.props.items[node_id].modifier[@intFromEnum(key)];
    }

    /// Reads an on/off modifier (`disabled`, `pointer_events_none`, `overflow_hidden`,
    /// `no_drag`, …) by VALUE: `.boolean = false` and `.number = 0` are off, absent is
    /// off, any other present value is on. Use this rather than `!= null` — widgets
    /// keep these in sync by writing `false`, not by removing them.
    /// Reads a modifier that holds a node id as a `.number` (`virtual_focus_target`):
    /// null when absent, negative ("no target"), non-integral, or out of NodeId range.
    /// Readers must use this instead of `@intFromFloat` on the raw value, which
    /// panics for any number that does not fit.
    pub fn modifierNodeRef(self: *const PropertyStore, node_id: reg.NodeId, key: ModifierKey) ?reg.NodeId {
        const m = self.getModifier(node_id, key) orelse return null;
        if (m != .number) return null;
        return nodeIdFromNumber(m.number);
    }

    pub fn modifierFlag(self: *const PropertyStore, node_id: reg.NodeId, key: ModifierKey) bool {
        const m = self.getModifier(node_id, key) orelse return false;
        return switch (m) {
            .boolean => |b| b,
            .number => |n| n != 0,
            else => true,
        };
    }

    pub fn getTextContent(self: *const PropertyStore, node_id: reg.NodeId) ?[]const u8 {
        if (node_id >= self.props.items.len) return null;
        return self.props.items[node_id].text_content;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "PropertyStore — separated domains and overwriting" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try store.registerNode(0);
    try store.setLayout(0, .width, .{ .dimension = .{ .value = 300, .unit = .px } });
    try store.setStyle(0, .background, .{ .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } });
    try store.setModifier(0, .clickable, .{ .string = try store.stringAllocator().dupe(u8, "btn") });

    // Initial value
    var w = store.getLayout(0, .width).?;
    try std.testing.expectEqual(@as(f32, 300), w.dimension.value);

    // Overwrite must update in-place (no duplicate entry)
    try store.setLayout(0, .width, .{ .dimension = .{ .value = 500, .unit = .px } });
    w = store.getLayout(0, .width).?;
    try std.testing.expectEqual(@as(f32, 500), w.dimension.value);

    const bg = store.getStyle(0, .background).?;
    try std.testing.expectEqual(@as(f32, 1.0), bg.color.r);

    // Missing property returns null
    try std.testing.expectEqual(@as(?PropValue, null), store.getLayout(0, .height));
}

test "PropertyStore — property-changed listener fires on real changes, not no-ops" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(0);

    const Sink = struct {
        var count: u32 = 0;
        var last_node: reg.NodeId = 0;
        var last: ChangedProp = .text;
        fn cb(_: ?*anyopaque, node_id: reg.NodeId, changed: ChangedProp) void {
            count += 1;
            last_node = node_id;
            last = changed;
        }
    };
    Sink.count = 0;
    store.setPropertyChangedListener(null, Sink.cb);

    // First set of a modifier is a change → one notification carrying the key.
    try store.setModifier(0, .checked, .{ .number = 1 });
    try std.testing.expectEqual(@as(u32, 1), Sink.count);
    try std.testing.expectEqual(@as(reg.NodeId, 0), Sink.last_node);
    try std.testing.expectEqual(ModifierKey.checked, Sink.last.modifier);

    // Re-writing the identical value is a no-op → no notification.
    try store.setModifier(0, .checked, .{ .number = 1 });
    try std.testing.expectEqual(@as(u32, 1), Sink.count);

    // A different value fires again.
    try store.setModifier(0, .checked, .{ .number = 0 });
    try std.testing.expectEqual(@as(u32, 2), Sink.count);

    // Text content: a real change fires .text; identical content is a no-op.
    store.setTextContent(0, try store.stringAllocator().dupe(u8, "hi"));
    try std.testing.expectEqual(@as(u32, 3), Sink.count);
    try std.testing.expectEqual(ChangedProp.text, Sink.last);
    store.setTextContent(0, try store.stringAllocator().dupe(u8, "hi"));
    try std.testing.expectEqual(@as(u32, 3), Sink.count);

    // Detaching stops notifications.
    store.setPropertyChangedListener(null, null);
    try store.setModifier(0, .expanded, .{ .number = 1 });
    try std.testing.expectEqual(@as(u32, 3), Sink.count);
}

test "PropertyStore — getTextContent" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try store.registerNode(0);
    store.setTextContent(0, try store.stringAllocator().dupe(u8, "Hello World"));
    try std.testing.expectEqualStrings("Hello World", store.getTextContent(0).?);
    try std.testing.expectEqual(@as(?[]const u8, null), store.getTextContent(1));
}

test "PropertyStore — setPath copies, dedups, and clearProperties(keep) preserves / (no-keep) frees" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const id = try registry.createNode(.path);
    try store.registerNode(id);

    var verts = [_]path_mod.PathVertex{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 100, .y = 50, .c1x = 100, .c1y = 20, .c2x = 100, .c2y = 40 },
    };
    try store.setPath(id, &verts);

    // Copied, not aliased.
    const got = store.getPath(id).?;
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expect(got.ptr != &verts);
    try std.testing.expectEqual(@as(f32, 100), got[1].x);

    // Byte-identical re-write is a no-op: pointer unchanged.
    registry.global_layout_dirty = false;
    try store.setPath(id, &verts);
    try std.testing.expectEqual(got.ptr, store.getPath(id).?.ptr);
    try std.testing.expect(!registry.global_layout_dirty);

    // A different path replaces (and frees the old — no leak under testing alloc).
    verts[0].x = 5;
    try store.setPath(id, &verts);
    try std.testing.expectEqual(@as(f32, 5), store.getPath(id).?[0].x);

    // Reuse path keeps it; a genuine clear frees it.
    store.clearProperties(id, true);
    try std.testing.expect(store.getPath(id) != null);
    store.clearProperties(id, false);
    try std.testing.expectEqual(@as(?[]const path_mod.PathVertex, null), store.getPath(id));

    // Setting an empty path clears without allocating.
    try store.setPath(id, &verts);
    try store.setPath(id, &[_]path_mod.PathVertex{});
    try std.testing.expectEqual(@as(?[]const path_mod.PathVertex, null), store.getPath(id));
}

test "Property store is O(1) direct-indexed across every key, smaller footprint" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(0);

    // Every layout key is independently settable/readable by direct index (no scan,
    // no fixed-cap overflow possible).
    inline for (0..layout_count) |i| {
        const k: LayoutKey = @enumFromInt(i);
        try store.setLayout(0, k, .{ .number = @floatFromInt(i) });
    }
    inline for (0..layout_count) |i| {
        const k: LayoutKey = @enumFromInt(i);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i)), store.getLayout(0, k).?.number);
    }

    // Unset properties in the other domains read back null.
    try std.testing.expectEqual(@as(?PropValue, null), store.getStyle(0, .background));
    try std.testing.expectEqual(@as(?PropValue, null), store.getModifier(0, .id));

    // Dense store: exactly one slot per key (+ the text_content pointer + a little
    // padding) — no per-entry key bytes or length fields like the old BoundedArray.
    // This bound auto-tracks key additions (the win is O(1) + simplicity, not a
    // fixed byte budget — see the audit memory).
    const slots = layout_count + style_count + modifier_count;
    try std.testing.expect(@sizeOf(NodeProps) <= slots * @sizeOf(?PropValue) + 64);
}

test "PropertyStore — out-of-order node id is safe" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    // Register node 5 without registering 0-4 first
    try store.registerNode(5);
    try store.setLayout(5, .width, .{ .dimension = .{ .value = 42, .unit = .px } });
    try std.testing.expectEqual(@as(f32, 42), store.getLayout(5, .width).?.dimension.value);
    // Nodes 0-4 were auto-initialised to empty — no crash
    try std.testing.expectEqual(@as(?PropValue, null), store.getLayout(0, .width));
}

test "BUG: setTextContent on an unregistered node frees the content it was handed" {
    // Ownership transfers at the call, so dropping an unknown id used to leak
    // the caller's copy. Found by fuzzing the C API with stale node ids:
    // celeris_node_set_text_content dupes first and had no way to reclaim it.
    // std.testing.allocator fails this test if the early return leaks.
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try store.registerNode(0);
    store.setTextContent(9999, try store.stringAllocator().dupe(u8, "orphan"));
    try std.testing.expectEqual(@as(?[]const u8, null), store.getTextContent(0));
}

test "BUG: setStyle/setLayout/setModifier on an unregistered node free a .string value they were handed" {
    // Same ownership-transfer contract as setTextContent, same defect shape:
    // the early return for an out-of-range node id dropped the value instead
    // of freeing it. Not reachable through the C ABI today (no export calls
    // these three with a host-supplied node id), but the contract should hold
    // uniformly — std.testing.allocator fails this test if any of the three
    // early-return paths leaks.
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(0);

    try store.setStyle(9999, .background, .{ .string = try store.stringAllocator().dupe(u8, "orphan-style") });
    try store.setLayout(9999, .width, .{ .string = try store.stringAllocator().dupe(u8, "orphan-layout") });
    try store.setModifier(9999, .cursor, .{ .string = try store.stringAllocator().dupe(u8, "orphan-modifier") });
}

// ── Dirty-tracking tests ────────────────────────────────────────────────────
// These pin down the contract the declarative/signals layer will rely on: a
// property write only re-dirties when the value actually changes, layout vs
// render dirtiness are tracked independently, and layout changes propagate up
// the ancestor chain. A regression here would surface as subtle reactivity
// bugs once signals drive the UI, so they are tested directly.

fn clearDirty(registry: *reg.UIRegistry, id: reg.NodeId) void {
    const node = registry.getNode(id).?;
    node.layout_dirty = false;
    node.render_dirty = false;
}

test "dirty-tracking — setLayout with a new value dirties layout + render" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const id = try registry.createNode(.box);
    try store.registerNode(id);
    clearDirty(&registry, id);

    try store.setLayout(id, .width, .{ .dimension = .{ .value = 100, .unit = .px } });
    try std.testing.expect(registry.getNode(id).?.layout_dirty);
    try std.testing.expect(registry.getNode(id).?.render_dirty);
}

test "Global dirty flags are an O(1) superset of per-node flags for the loop" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    // createNode marks the frame dirty (a new node is created dirty).
    const id = try registry.createNode(.box);
    try store.registerNode(id);
    try std.testing.expect(registry.global_layout_dirty);
    try std.testing.expect(registry.global_render_dirty);

    // Loop clears both after solving layout + rendering.
    registry.global_layout_dirty = false;
    registry.global_render_dirty = false;

    // Paint-only style change (color) → render dirty, NOT layout dirty.
    try store.setStyle(id, .background, .{ .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } });
    try std.testing.expect(registry.global_render_dirty);
    try std.testing.expect(!registry.global_layout_dirty);
    registry.global_render_dirty = false;

    // Layout change → both dirty.
    try store.setLayout(id, .width, .{ .dimension = .{ .value = 10, .unit = .px } });
    try std.testing.expect(registry.global_layout_dirty);
    try std.testing.expect(registry.global_render_dirty);

    // Per-node flags remain intact (the verification suite relies on them).
    try std.testing.expect(registry.getNode(id).?.render_dirty);
    try std.testing.expect(registry.getNode(id).?.layout_dirty);
}

test "Scroll_offset_y is render-only and shifts the subtree geometry" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    // viewport → wrapper → item (plus a sibling of the viewport that must not move)
    const viewport = try registry.createNode(.box);
    const wrapper = try registry.createNode(.box);
    const item = try registry.createNode(.box);
    const sibling = try registry.createNode(.box);
    registry.appendChild(viewport, wrapper);
    registry.appendChild(wrapper, item);
    for ([_]reg.NodeId{ viewport, wrapper, item, sibling }) |id| try store.registerNode(id);

    registry.getNode(viewport).?.geometry = .{ .x = 0, .y = 0, .width = 200, .height = 600 };
    registry.getNode(wrapper).?.geometry = .{ .x = 0, .y = 0, .width = 200, .height = 1000 };
    registry.getNode(item).?.geometry = .{ .x = 0, .y = 100, .width = 200, .height = 50 };
    registry.getNode(sibling).?.geometry = .{ .x = 0, .y = 600, .width = 200, .height = 50 };

    for ([_]reg.NodeId{ viewport, wrapper, item, sibling }) |id| clearDirty(&registry, id);
    registry.global_layout_dirty = false;
    registry.global_render_dirty = false;

    // Scroll down 50px: descendants shift, the node itself and outsiders don't.
    try store.setLayout(viewport, .scroll_offset_y, .{ .dimension = .{ .value = -50, .unit = .px } });
    try std.testing.expectEqual(@as(f32, 0), registry.getNode(viewport).?.geometry.y);
    try std.testing.expectEqual(@as(f32, -50), registry.getNode(wrapper).?.geometry.y);
    try std.testing.expectEqual(@as(f32, 50), registry.getNode(item).?.geometry.y);
    try std.testing.expectEqual(@as(f32, 600), registry.getNode(sibling).?.geometry.y);

    // Render-only dirty: NO layout invalidation anywhere.
    try std.testing.expect(!registry.global_layout_dirty);
    try std.testing.expect(registry.global_render_dirty);
    try std.testing.expect(registry.getNode(viewport).?.render_dirty);
    try std.testing.expect(!registry.getNode(viewport).?.layout_dirty);
    try std.testing.expect(!registry.getNode(wrapper).?.layout_dirty);

    // Delta semantics: a further write shifts by the difference only.
    try store.setLayout(viewport, .scroll_offset_y, .{ .dimension = .{ .value = -30, .unit = .px } });
    try std.testing.expectEqual(@as(f32, -30), registry.getNode(wrapper).?.geometry.y);

    // No-op write: no shift, no dirty.
    registry.global_render_dirty = false;
    try store.setLayout(viewport, .scroll_offset_y, .{ .dimension = .{ .value = -30, .unit = .px } });
    try std.testing.expectEqual(@as(f32, -30), registry.getNode(wrapper).?.geometry.y);
    try std.testing.expect(!registry.global_render_dirty);
}

test "Scroll_offset_x shifts the subtree on X only, render-only, delta semantics" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const viewport = try registry.createNode(.box);
    const wrapper = try registry.createNode(.box);
    const item = try registry.createNode(.box);
    const sibling = try registry.createNode(.box);
    registry.appendChild(viewport, wrapper);
    registry.appendChild(wrapper, item);
    for ([_]reg.NodeId{ viewport, wrapper, item, sibling }) |id| try store.registerNode(id);

    registry.getNode(viewport).?.geometry = .{ .x = 0, .y = 0, .width = 600, .height = 200 };
    registry.getNode(wrapper).?.geometry = .{ .x = 0, .y = 0, .width = 2000, .height = 200 };
    registry.getNode(item).?.geometry = .{ .x = 100, .y = 20, .width = 50, .height = 50 };
    registry.getNode(sibling).?.geometry = .{ .x = 600, .y = 0, .width = 50, .height = 50 };

    for ([_]reg.NodeId{ viewport, wrapper, item, sibling }) |id| clearDirty(&registry, id);
    registry.global_layout_dirty = false;
    registry.global_render_dirty = false;

    try store.setLayout(viewport, .scroll_offset_x, .{ .dimension = .{ .value = -80, .unit = .px } });
    // Descendants shift on X; Y is untouched; the node itself and outsiders don't move.
    try std.testing.expectEqual(@as(f32, 0), registry.getNode(viewport).?.geometry.x);
    try std.testing.expectEqual(@as(f32, -80), registry.getNode(wrapper).?.geometry.x);
    try std.testing.expectEqual(@as(f32, 0), registry.getNode(wrapper).?.geometry.y);
    try std.testing.expectEqual(@as(f32, 20), registry.getNode(item).?.geometry.x);
    try std.testing.expectEqual(@as(f32, 20), registry.getNode(item).?.geometry.y);
    try std.testing.expectEqual(@as(f32, 600), registry.getNode(sibling).?.geometry.x);

    try std.testing.expect(!registry.global_layout_dirty);
    try std.testing.expect(registry.global_render_dirty);
    try std.testing.expect(!registry.getNode(wrapper).?.layout_dirty);

    // Delta only, and independent of scroll_offset_y on the same node.
    try store.setLayout(viewport, .scroll_offset_x, .{ .dimension = .{ .value = -50, .unit = .px } });
    try std.testing.expectEqual(@as(f32, -50), registry.getNode(wrapper).?.geometry.x);
    try store.setLayout(viewport, .scroll_offset_y, .{ .dimension = .{ .value = -10, .unit = .px } });
    try std.testing.expectEqual(@as(f32, -50), registry.getNode(wrapper).?.geometry.x);
    try std.testing.expectEqual(@as(f32, -10), registry.getNode(wrapper).?.geometry.y);
}

test "dirty-tracking — setLayout with the SAME value does not re-dirty" {
    // The core optimization the signals strategy depends on: writing an
    // unchanged value must not schedule any work.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const id = try registry.createNode(.box);
    try store.registerNode(id);

    const w = PropValue{ .dimension = .{ .value = 100, .unit = .px } };
    try store.setLayout(id, .width, w);
    clearDirty(&registry, id);

    // Identical value → no-op for dirty tracking.
    try store.setLayout(id, .width, w);
    try std.testing.expect(!registry.getNode(id).?.layout_dirty);
    try std.testing.expect(!registry.getNode(id).?.render_dirty);

    // A different value re-dirties.
    try store.setLayout(id, .width, .{ .dimension = .{ .value = 101, .unit = .px } });
    try std.testing.expect(registry.getNode(id).?.layout_dirty);
}

test "dirty-tracking — setStyle dirties render only, not layout" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const id = try registry.createNode(.box);
    try store.registerNode(id);
    clearDirty(&registry, id);

    const red = PropValue{ .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } };
    try store.setStyle(id, .background, red);
    try std.testing.expect(registry.getNode(id).?.render_dirty);
    try std.testing.expect(!registry.getNode(id).?.layout_dirty);

    // Same color again → no re-dirty.
    clearDirty(&registry, id);
    try store.setStyle(id, .background, red);
    try std.testing.expect(!registry.getNode(id).?.render_dirty);
}

test "dirty-tracking — child layout change propagates to ancestors" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const root = try registry.createNode(.box);
    try store.registerNode(root);
    const child = try registry.createNode(.box);
    try store.registerNode(child);
    registry.appendChild(root, child);

    clearDirty(&registry, root);
    clearDirty(&registry, child);

    // Changing the child's layout must dirty the child AND its root ancestor.
    try store.setLayout(child, .height, .{ .dimension = .{ .value = 20, .unit = .px } });
    try std.testing.expect(registry.getNode(child).?.layout_dirty);
    try std.testing.expect(registry.getNode(root).?.layout_dirty);
}

test "dirty-tracking — setTextContent dirties layout (text affects sizing)" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const id = try registry.createNode(.text);
    try store.registerNode(id);
    clearDirty(&registry, id);

    store.setTextContent(id, try store.stringAllocator().dupe(u8, "hi"));
    try std.testing.expect(registry.getNode(id).?.layout_dirty);
    try std.testing.expect(registry.getNode(id).?.render_dirty);
}

test "dirty-tracking — setTextContent with identical content is a no-op (no dirty, no leak)" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const id = try registry.createNode(.text);
    try store.registerNode(id);
    store.setTextContent(id, try store.stringAllocator().dupe(u8, "FPS: 60"));
    clearDirty(&registry, id);
    registry.global_layout_dirty = false;
    registry.global_render_dirty = false;

    // Same content, distinct allocation: freed by the store, nothing dirtied.
    // (The testing allocator fails the test on a leak or double-free.)
    store.setTextContent(id, try store.stringAllocator().dupe(u8, "FPS: 60"));
    try std.testing.expect(!registry.getNode(id).?.layout_dirty);
    try std.testing.expect(!registry.getNode(id).?.render_dirty);
    try std.testing.expect(!registry.global_layout_dirty);
    try std.testing.expect(!registry.global_render_dirty);

    // Re-setting the SAME slice (old.ptr == new.ptr) must not free-then-use it.
    store.setTextContent(id, store.getTextContent(id).?);
    try std.testing.expect(!registry.global_render_dirty);

    // Actually different content still dirties layout + render.
    store.setTextContent(id, try store.stringAllocator().dupe(u8, "FPS: 59"));
    try std.testing.expect(registry.getNode(id).?.layout_dirty);
    try std.testing.expect(registry.global_layout_dirty);
    try std.testing.expectEqualStrings("FPS: 59", store.getTextContent(id).?);
}

test "A recycled node id starts from defaults, not the dead node's style" {
    // The bug this pins: createNode reuses an id from the free_list, and registerNode
    // must reset the slot or the new node inherits every property the old one set but
    // the new one doesn't (borders, background, radius, text color…). Drive it through
    // the real registry so the recycle path is exactly the engine's.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    // Wire the engine's own remove→clear listener so the test exercises what ships.
    registry.addNodeRemovedListener(&store, struct {
        fn cb(ctx: ?*anyopaque, id: reg.NodeId) void {
            const s: *PropertyStore = @ptrCast(@alignCast(ctx.?));
            s.clearProperties(id, false);
        }
    }.cb);

    // Node A: a full uniform border, a background, a radius, a text color.
    const a = try registry.createNode(.box);
    try store.registerNode(a);
    try store.setStyle(a, .border_width, .{ .dimension = .{ .value = 1, .unit = .px } });
    try store.setStyle(a, .background, .{ .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } });
    try store.setStyle(a, .radius, .{ .dimension = .{ .value = 8, .unit = .px } });
    try store.setStyle(a, .color, .{ .color = .{ .r = 0, .g = 1, .b = 0, .a = 1 } });

    registry.removeNode(a);

    // Node B reuses A's id (free_list is LIFO, so the next createNode returns it).
    const b = try registry.createNode(.box);
    try std.testing.expectEqual(a, b); // the id really was recycled — the test has teeth
    try store.registerNode(b);
    // B sets ONLY the top border, like the footer in the report.
    try store.setStyle(b, .border_top, .{ .dimension = .{ .value = 1, .unit = .px } });

    // Everything B didn't set is a default, not A's value.
    try std.testing.expectEqual(@as(?PropValue, null), store.getStyle(b, .border_width));
    try std.testing.expectEqual(@as(?PropValue, null), store.getStyle(b, .background));
    try std.testing.expectEqual(@as(?PropValue, null), store.getStyle(b, .radius));
    try std.testing.expectEqual(@as(?PropValue, null), store.getStyle(b, .color));
    try std.testing.expectEqual(@as(f32, 1), store.getStyle(b, .border_top).?.dimension.value);
}

test "Reuse after a full clear() also starts from defaults (no listener involved)" {
    // clear() resets nodes+free_list but not the store, and the next createNode
    // returns id 0 as a *new* node — so registerNode(0) hits the recycled-slot branch
    // with no remove listener to have cleaned it. registerNode must stand on its own.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const a = try registry.createNode(.box);
    try store.registerNode(a);
    try store.setStyle(a, .background, .{ .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } });

    registry.clear();

    const b = try registry.createNode(.box);
    try std.testing.expectEqual(@as(reg.NodeId, 0), b);
    try store.registerNode(b);
    try std.testing.expectEqual(@as(?PropValue, null), store.getStyle(b, .background));
}

test "Recycling frees the dead node's owned strings (no leak)" {
    // An owned string (role, tooltip, text) on the dead node must be freed when the id
    // is recycled, or it leaks. The testing allocator fails the test if it isn't.
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try store.registerNode(0);
    const role = try store.stringAllocator().dupe(u8, "button");
    try store.setModifier(0, .role, .{ .string = role });
    const txt = try store.stringAllocator().dupe(u8, "hello");
    store.setTextContent(0, txt);

    // Recycle id 0: registerNode must free both owned strings before resetting.
    try store.registerNode(0);
    try std.testing.expectEqual(@as(?PropValue, null), store.getModifier(0, .role));
    try std.testing.expectEqual(@as(?[]const u8, null), store.getTextContent(0));
}

test "ownedString hands the store a slice it may free — overwrite and teardown, no leak" {
    // The testing allocator fails this test on either a leak or a double free, which
    // is the whole point: it pins the transfer-of-ownership contract on `.string`.
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(0);

    try store.setModifier(0, .role, try store.ownedString("button"));
    try std.testing.expectEqualStrings("button", store.getModifier(0, .role).?.string);

    // Overwriting frees the first string; the last one is freed by deinit.
    try store.setModifier(0, .role, try store.ownedString("checkbox"));
    try std.testing.expectEqualStrings("checkbox", store.getModifier(0, .role).?.string);

    // Same content, fresh allocation: the old slice is still freed (not leaked) even
    // though the value compares equal and the write reports "unchanged".
    try store.setModifier(0, .role, try store.ownedString("checkbox"));
    try std.testing.expectEqualStrings("checkbox", store.getModifier(0, .role).?.string);

    // Layout and style slots own their strings on the same terms.
    try store.setLayout(0, .align_items, try store.ownedString("flex-start"));
    try store.setStyle(0, .background, try store.ownedString("#fff"));
}
