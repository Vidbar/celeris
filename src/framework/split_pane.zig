//! SplitPane — reactive component migrated to the canonical pattern.
//!
//! Framework-owned via `ctx.mountOwned(SplitPane, .{ .fill = true, .left_child = …,
//! .right_child = …, .orientation = .horizontal })`: no `init`/`register`/`deinit`/
//! action-id in user code. The two children are `component.Child` props (the parent
//! owns whatever they wrap). `left_ratio`/`hovering` are `Signal`s auto-created in
//! `onMount`; resizing is a layout change driven by an effect (pane `flex_grow` +
//! sash hover). The split ratio can be **lifted to the caller** (same pattern as
//! `Tabs.active`): pass `.ratio` as a caller-owned `*Signal(f32)` to set/animate it
//! programmatically — e.g. a collapsible detail pane that opens on selection. Omit
//! it and the widget uses its internal `left_ratio` (seeded from `initial_ratio`).
//! The sash drag-follow uses a **global** handler (mouse_move/up carry no node id),
//! registered in `build()` against `container_id` — pruned automatically by the
//! node-removed hook when that node goes away. Pass `.fill = true` so the mount
//! anchor fills its parent.
//!
//! Cross-axis sizing is `align_items: stretch` on the container, deliberately —
//! NOT a `100%` on each child. A percentage needs an already-known parent size, so
//! inside a `flex_grow` chain it resolves to 0 and the contentless sash disappears.
//! `stretch` skips any child that declares the cross dimension, so the panes and the
//! sash must leave it unset. The sash is `sash_thickness` px of `sash_color`
//! (default `theme.border_color`), lightened by an M3 state layer on hover.
//!
//! Each pane has a `PaneCfg` (`.left` / `.right`): a px `min`, an optional
//! VS Code-style snap-collapse (`collapsible`, `collapse_threshold`,
//! `collapsed_size`) and a lifted `collapsed: ?*Signal(bool)`. The drag policy is
//! the pure `resolveDrag`; `updateVisuals` turns ratio + collapsed state into
//! flex_grow / flex_basis / min-size on the panes, so the layout engine — not the
//! drag — enforces the minimums (window resizes included).

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;
const Theme = theme_mod.Theme;

pub const Orientation = enum { horizontal, vertical };

/// Without a `min` on a side, a drag still keeps that pane at least this fraction.
const MIN_RATIO: f32 = 0.05;
const MAX_RATIO: f32 = 0.95;

/// Once a pane snapped shut, the pointer must pass the threshold by this many px
/// before it reopens, so a pointer resting on the threshold doesn't flicker.
pub const RESTORE_HYSTERESIS: f32 = 4;

/// Per-pane sizing rules. `left` / `right` name the first / second pane, which are
/// top / bottom when `orientation = .vertical` (same as `left_child`/`right_child`).
pub const PaneCfg = struct {
    /// Smallest size in px while the pane is open, on the main axis. A drag stops
    /// there, and the layout keeps it there when the window shrinks. 0 = no minimum.
    min: f32 = 0,
    /// Lets a drag snap the pane shut (VS Code's side-bar behavior): past `min` the
    /// pane stays at `min` until the pointer crosses `collapse_threshold`, then it
    /// collapses to `collapsed_size`; dragging back over the threshold reopens it
    /// at `min`.
    collapsible: bool = false,
    /// Pointer distance in px from this pane's outer edge below which it collapses.
    /// Default `min / 2`.
    collapse_threshold: ?f32 = null,
    /// Size in px while collapsed — e.g. 48 to keep an activity bar showing. 0 hides it.
    collapsed_size: f32 = 0,
    /// Optional caller-owned collapsed state (two-way, like `ratio`): a drag writes
    /// it, and setting it from a command collapses or reopens the pane. Reopening
    /// returns to the last open `ratio`. Omit it and the widget keeps its own.
    /// Works whether or not `collapsible` is set — that only gates the drag snap.
    collapsed: ?*signals.Signal(bool) = null,

    pub fn threshold(self: PaneCfg) f32 {
        return self.collapse_threshold orelse self.min / 2;
    }
};

/// Input to `resolveDrag`, along the main axis.
pub const DragState = struct {
    /// Pointer offset from the container's start edge, px.
    pos: f32,
    /// Container size, px.
    total: f32,
    left_collapsed: bool = false,
    right_collapsed: bool = false,
};

pub const DragResult = struct {
    /// New split ratio, or null when a pane is collapsed: the open ratio is kept so
    /// reopening returns to it.
    ratio: ?f32,
    left_collapsed: bool,
    right_collapsed: bool,
};

/// The whole sash-drag policy as a pure function: min clamp, snap-collapse with
/// hysteresis, reopen at min. When both minimums can't fit, the left one wins; at
/// most one pane is collapsed at a time (the one that already was, else the left).
pub fn resolveDrag(left: PaneCfg, right: PaneCfg, s: DragState) DragResult {
    if (!(s.total > 0)) return .{ .ratio = null, .left_collapsed = s.left_collapsed, .right_collapsed = s.right_collapsed };
    const pos = std.math.clamp(s.pos, 0, s.total);
    const far = s.total - pos; // pointer distance from the right pane's outer edge

    var lc = s.left_collapsed;
    var rc = s.right_collapsed;
    if (left.collapsible) {
        const t = left.threshold();
        if (!lc and pos < t) lc = true else if (lc and pos > t + RESTORE_HYSTERESIS) lc = false;
    }
    if (right.collapsible) {
        const t = right.threshold();
        if (!rc and far < t) rc = true else if (rc and far > t + RESTORE_HYSTERESIS) rc = false;
    }
    if (lc and rc) {
        if (s.right_collapsed and !s.left_collapsed) lc = false else rc = false;
    }
    if (lc or rc) return .{ .ratio = null, .left_collapsed = lc, .right_collapsed = rc };

    // Right minimum first, then left: if they overlap, the left one wins.
    var p = @min(pos, s.total - right.min);
    p = @max(p, left.min);
    var r = p / s.total;
    if (left.min <= 0) r = @max(r, MIN_RATIO);
    if (right.min <= 0) r = @min(r, MAX_RATIO);
    return .{ .ratio = std.math.clamp(r, 0, 1), .left_collapsed = false, .right_collapsed = false };
}

pub const SplitPane = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    left_child: component.Child = undefined,
    right_child: component.Child = undefined,
    orientation: Orientation = .horizontal,
    initial_ratio: f32 = 0.25,
    /// Optional caller-owned split ratio (two-way, left fraction in [0, 1]). The
    /// widget reads it to size the panes and writes it while dragging the sash; the
    /// caller can set/animate it. Pane minimums still apply on top of it. While a
    /// pane is collapsed the ratio is kept, not written. Omit to use the internal
    /// `left_ratio` seeded from `initial_ratio`.
    ratio: ?*signals.Signal(f32) = null,
    /// Sizing rules for the first / second pane: minimum, snap-collapse, collapsed
    /// size and collapsed state. See `PaneCfg`.
    left: PaneCfg = .{},
    right: PaneCfg = .{},
    /// Sash thickness on the main axis, in px.
    sash_thickness: f32 = 4,
    /// Sash fill. Defaults to `theme.border_color`; an unset (transparent) token
    /// falls back to the built-in grey, same convention as StatusBar's dots. The
    /// hover shade is an M3 state layer over whichever base ends up in effect. A
    /// fully transparent color (alpha 0) gets no hover layer either: the sash stays
    /// invisible but still takes hover, the resize cursor and drags.
    sash_color: ?theme_mod.Color = null,

    // State (auto-created in onMount; preserved across rebuilds). `left_ratio` and
    // the `*_collapsed_state` signals are the fallbacks when the caller passes none.
    left_ratio: signals.Signal(f32) = undefined,
    left_collapsed_state: signals.Signal(bool) = undefined,
    right_collapsed_state: signals.Signal(bool) = undefined,
    hovering: signals.Signal(bool) = undefined,
    scope: signals.Scope = undefined,
    dragging: bool = false, // plain: only gates the global move handler
    theme: Theme = .{}, // captured from the builder in build()

    // Captured during build().
    store: ?*props.PropertyStore = null,
    router: ?*events.EventRouter = null,
    container_id: reg.NodeId = reg.NULL_NODE,
    sash_id: reg.NodeId = reg.NULL_NODE,
    left_pane_id: reg.NodeId = reg.NULL_NODE,
    right_pane_id: reg.NodeId = reg.NULL_NODE,
    bound: bool = false,

    pub fn onMount(self: *SplitPane, allocator: std.mem.Allocator) void {
        self.left_ratio = signals.Signal(f32).init(allocator, self.initial_ratio);
        self.left_collapsed_state = signals.Signal(bool).init(allocator, false);
        self.right_collapsed_state = signals.Signal(bool).init(allocator, false);
        self.hovering = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
    }

    pub fn deinit(self: *SplitPane) void {
        self.scope.deinit();
        self.left_ratio.deinit();
        self.left_collapsed_state.deinit();
        self.right_collapsed_state.deinit();
        self.hovering.deinit();
    }

    /// The active ratio signal: caller-owned if provided, else the internal one.
    fn ratioSig(self: *SplitPane) *signals.Signal(f32) {
        return self.ratio orelse &self.left_ratio;
    }
    /// The active collapsed signals: caller-owned if provided, else internal.
    fn leftCollapsedSig(self: *SplitPane) *signals.Signal(bool) {
        return self.left.collapsed orelse &self.left_collapsed_state;
    }
    fn rightCollapsedSig(self: *SplitPane) *signals.Signal(bool) {
        return self.right.collapsed orelse &self.right_collapsed_state;
    }

    fn onSashDown(self: *SplitPane, ev: events.Event) void {
        _ = ev;
        self.dragging = true;
    }
    fn onSashUp(self: *SplitPane, ev: events.Event) void {
        _ = ev;
        self.dragging = false;
    }

    fn onGlobal(self: *SplitPane, ev: events.Event) void {
        if (std.mem.eql(u8, ev.name, "mouse_up")) {
            self.dragging = false;
        } else if (std.mem.eql(u8, ev.name, "mouse_move") and self.dragging) {
            self.updateRatioFromPos(ev.x, ev.y);
        }
    }

    fn updateRatioFromPos(self: *SplitPane, x: f32, y: f32) void {
        const store = self.store orelse return;
        const registry = store.registry orelse return;
        if (self.container_id == reg.NULL_NODE) return;
        const c = registry.getNode(self.container_id) orelse return;
        const g = c.geometry;
        const st: DragState = switch (self.orientation) {
            .horizontal => .{ .pos = x - g.x, .total = g.width },
            .vertical => .{ .pos = y - g.y, .total = g.height },
        };
        const res = resolveDrag(self.left, self.right, .{
            .pos = st.pos,
            .total = st.total,
            .left_collapsed = self.leftCollapsedSig().peek(),
            .right_collapsed = self.rightCollapsedSig().peek(),
        });
        if (res.ratio) |r| self.ratioSig().set(r);
        self.leftCollapsedSig().set(res.left_collapsed);
        self.rightCollapsedSig().set(res.right_collapsed);
    }

    pub fn build(self: *SplitPane, ctx: *BuildContext) !void {
        const b = ctx.builder;
        self.store = b.store;
        self.router = ctx.router;
        self.theme = b.theme;
        const horizontal = self.orientation == .horizontal;

        const container = try b.openNodeKeyed(.box, null);
        self.container_id = container;
        try b.width(container, 100, .percent);
        try b.height(container, 100, .percent);
        try b.flexGrow(container, 1);
        if (horizontal) try b.flexRow(container) else try b.flexColumn(container);
        // The cross axis is owned by `stretch`, not by a `100%` on each child: a
        // percentage only resolves against an already-known parent size, and inside
        // a `flex_grow` chain (the normal IDE-shell case) it resolves to 0 — which
        // collapsed the contentless sash to an invisible zero-thickness line. Note
        // that `stretch` only sizes children that DON'T declare the cross dimension,
        // so none of the three children below may set it.
        try b.alignItems(container, .stretch);

        // Left pane.
        const left_pane = try b.openNodeKeyed(.box, null);
        self.left_pane_id = left_pane;
        try b.flexBasis(left_pane, 0, .px);
        try self.left_child.build(ctx);
        b.close();

        // Resizer (sash) — declarative hover/press; the drag-follow is the global handler.
        self.sash_id = try ctx.boxNode(.{
            .on_hover = ctx.signalSetter(&self.hovering),
            .on_mouse_down = ctx.handler(self, onSashDown),
            .on_mouse_up = ctx.handler(self, onSashUp),
        }, .{});
        if (horizontal) {
            try b.width(self.sash_id, self.sash_thickness, .px);
            try b.role(self.sash_id, "resizer_h");
        } else {
            try b.height(self.sash_id, self.sash_thickness, .px);
            try b.role(self.sash_id, "resizer_v");
        }
        try b.cursor(self.sash_id, if (horizontal) "resize_ew" else "resize_ns");

        // Right pane.
        const right_pane = try b.openNodeKeyed(.box, null);
        self.right_pane_id = right_pane;
        try b.flexBasis(right_pane, 0, .px);
        try self.right_child.build(ctx);
        b.close();

        b.close(); // container

        // Unconditional every build: onGlobal replaces in place per owner (see
        // events.zig), and the node-removed hook prunes it on unmount.
        if (ctx.router) |r| try r.onGlobal(self.container_id, self, onGlobal);
        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn updateVisuals(self: *SplitPane) void {
        const store = self.store orelse return;
        if (self.left_pane_id == reg.NULL_NODE) return;
        const ratio = self.ratioSig().get();
        const lc = self.leftCollapsedSig().get();
        const rc = self.rightCollapsedSig().get();
        // A collapsed pane is a fixed `collapsed_size` (grow 0) and the other takes
        // the rest; open panes split by ratio, floored at their `min` by the layout
        // itself (so a shrinking window can't push them under it either).
        if (lc) {
            self.sizePane(store, self.left_pane_id, 0, self.left.collapsed_size, 0);
            self.sizePane(store, self.right_pane_id, 1, 0, self.right.min);
        } else if (rc) {
            self.sizePane(store, self.left_pane_id, 1, 0, self.left.min);
            self.sizePane(store, self.right_pane_id, 0, self.right.collapsed_size, 0);
        } else {
            self.sizePane(store, self.left_pane_id, ratio, 0, self.left.min);
            self.sizePane(store, self.right_pane_id, 1.0 - ratio, 0, self.right.min);
        }

        const base = self.sashBase();
        // A transparent sash stays invisible on hover too (no state layer).
        const fill = if (self.hovering.get() and base.a > 0)
            Theme.stateLayer(base, if (self.theme.is_dark)
                theme_mod.Color{ .r = 255, .g = 255, .b = 255 }
            else
                theme_mod.Color{ .r = 0, .g = 0, .b = 0 }, .hover)
        else
            base;
        store.setStyle(self.sash_id, .background, props.PropValue.rgbA(fill.r, fill.g, fill.b, @as(f32, @floatFromInt(fill.a)) / 255.0)) catch {};
    }

    fn sizePane(self: *const SplitPane, store: *props.PropertyStore, id: reg.NodeId, grow: f32, basis: f32, min: f32) void {
        const min_key: props.LayoutKey = if (self.orientation == .horizontal) .min_width else .min_height;
        store.setLayout(id, .flex_grow, .{ .number = grow }) catch {};
        store.setLayout(id, .flex_basis, .{ .dimension = .{ .value = basis, .unit = .px } }) catch {};
        store.setLayout(id, min_key, .{ .dimension = .{ .value = min, .unit = .px } }) catch {};
    }

    /// Explicit override → theme border → built-in grey (for an unset token).
    fn sashBase(self: *const SplitPane) theme_mod.Color {
        if (self.sash_color) |c| return c;
        if (self.theme.border_color.a > 0) return self.theme.border_color;
        return .{ .r = 60, .g = 60, .b = 60 };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const StubPane = struct {
    pub fn build(_: *StubPane, ctx: *BuildContext) !void {
        _ = try ctx.builder.openNodeKeyed(.box, null);
        ctx.builder.close();
    }
    pub fn deinit(_: *StubPane) void {}
};

test "SplitPane (mountOwned) sash hover and drag update flex_grow from container geometry" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
    registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);

    var l = StubPane{};
    var r = StubPane{};
    var b = component.UIBuilder.init(&registry, &store);
    var ctx = BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(SplitPane, .{
        .left_child = component.childOf(StubPane, &l),
        .right_child = component.childOf(StubPane, &r),
        .orientation = .horizontal,
    });
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    const sp: *SplitPane = @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));

    // Initial ratio 0.25 → panes 0.25 / 0.75.
    try testing.expectApproxEqAbs(@as(f32, 0.25), store.getLayout(sp.left_pane_id, .flex_grow).?.number, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.75), store.getLayout(sp.right_pane_id, .flex_grow).?.number, 0.001);

    // Hover lightens the sash (M3 state layer over the fallback grey).
    _ = router.route(.{ .name = "mouse_enter", .id = "", .node_id = sp.sash_id });
    const hovered = theme_mod.Theme.stateLayer(.{ .r = 60, .g = 60, .b = 60 }, .{ .r = 255, .g = 255, .b = 255 }, .hover);
    try testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(hovered.r)) / 255.0,
        store.getStyle(sp.sash_id, .background).?.color.r,
        0.005,
    );

    // Solved layout: container at x=0, width=1000.
    registry.getNode(sp.container_id).?.geometry = .{ .x = 0, .y = 0, .width = 1000, .height = 600 };

    // Move without press is ignored; press + drag to x=600 → ratio 0.6.
    _ = router.route(.{ .name = "mouse_move", .id = "", .x = 600.0, .y = 10.0 });
    try testing.expectApproxEqAbs(@as(f32, 0.25), sp.left_ratio.peek(), 0.001);
    _ = router.route(.{ .name = "mouse_down", .id = "", .node_id = sp.sash_id });
    _ = router.route(.{ .name = "mouse_move", .id = "", .x = 600.0, .y = 10.0 });
    try testing.expectApproxEqAbs(@as(f32, 0.6), sp.left_ratio.peek(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.6), store.getLayout(sp.left_pane_id, .flex_grow).?.number, 0.001);

    // Global mouse_up ends the drag; further moves ignored.
    _ = router.route(.{ .name = "mouse_up", .id = "" });
    _ = router.route(.{ .name = "mouse_move", .id = "", .x = 100.0, .y = 10.0 });
    try testing.expectApproxEqAbs(@as(f32, 0.6), sp.left_ratio.peek(), 0.001);
}

test "SplitPane binds a caller-owned ratio signal: set drives the panes, drag writes it back" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();

    // Caller owns the ratio; declared before `mounts` so LIFO defers tear the
    // widget's effect down (unsubscribing) before the signal is freed.
    var ratio = signals.Signal(f32).init(a, 0.3);
    defer ratio.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
    registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);

    var l = StubPane{};
    var r = StubPane{};
    var b = component.UIBuilder.init(&registry, &store);
    var ctx = BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(SplitPane, .{
        .left_child = component.childOf(StubPane, &l),
        .right_child = component.childOf(StubPane, &r),
        .orientation = .horizontal,
        .ratio = &ratio,
    });
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    const sp: *SplitPane = @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));

    // Initial layout comes from the caller's signal (0.3), not initial_ratio.
    try testing.expectApproxEqAbs(@as(f32, 0.3), store.getLayout(sp.left_pane_id, .flex_grow).?.number, 0.001);

    // Caller sets the ratio → panes resize reactively (collapsible-pane path).
    ratio.set(0.6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), store.getLayout(sp.left_pane_id, .flex_grow).?.number, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), store.getLayout(sp.right_pane_id, .flex_grow).?.number, 0.001);

    // Dragging the sash writes back into the caller's signal.
    registry.getNode(sp.container_id).?.geometry = .{ .x = 0, .y = 0, .width = 1000, .height = 600 };
    _ = router.route(.{ .name = "mouse_down", .id = "", .node_id = sp.sash_id });
    _ = router.route(.{ .name = "mouse_move", .id = "", .x = 250.0, .y = 10.0 });
    try testing.expectApproxEqAbs(@as(f32, 0.25), ratio.peek(), 0.001);
}

test "SplitPane sash is visible inside a flex_grow chain (no resolvable percent height)" {
    const flexbox = @import("../layout/flexbox.zig");
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
    registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);

    var l = StubPane{};
    var r = StubPane{};
    var b = component.UIBuilder.init(&registry, &store);
    var ctx = BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };

    // screen (column, 800x600) > row (flex_grow: 1, height: 100%) > SplitPane(.fill)
    const screen = try b.openNodeKeyed(.box, null);
    try b.width(screen, 800, .px);
    try b.height(screen, 600, .px);
    try b.flexColumn(screen);
    const row = try b.openNodeKeyed(.box, null);
    try b.flexGrow(row, 1);
    try b.height(row, 100, .percent);
    try b.flexRow(row);
    try ctx.mountOwned(SplitPane, .{
        .fill = true,
        .left_child = component.childOf(StubPane, &l),
        .right_child = component.childOf(StubPane, &r),
        .orientation = .horizontal,
    });
    b.close(); // row
    b.close(); // screen

    const anchor = registry.getNode(row).?.first_child;
    const sp: *SplitPane = @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));

    var engine = flexbox.LayoutEngine.init(&registry, &store, null);
    engine.solve(screen, 0, 0, 800, 600);

    // The sash keeps its 4px main-axis thickness and is stretched on the cross axis
    // — before the `align_items: stretch` fix it solved to height 0 (invisible).
    const sash = registry.getNode(sp.sash_id).?;
    try testing.expectApproxEqAbs(@as(f32, 4), sash.geometry.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 600), sash.geometry.height, 0.01);
}

test "SplitPane removes its global handler on unmount" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
    registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);

    var l = StubPane{};
    var r = StubPane{};
    var b = component.UIBuilder.init(&registry, &store);
    var ctx = BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(SplitPane, .{
        .left_child = component.childOf(StubPane, &l),
        .right_child = component.childOf(StubPane, &r),
    });
    b.close();
    try testing.expectEqual(@as(usize, 1), router.global_handlers.items.len);

    try b.rootAt(root);
    b.close(); // reconcile the SplitPane anchor away → onUnmount
    try testing.expectEqual(@as(usize, 0), router.global_handlers.items.len);
}

// ── Minimum size and snap-collapse ────────────────────────────────────────────

test "resolveDrag: min clamp, collapse past the threshold, hysteresis, reopen at min" {
    const side = PaneCfg{ .min = 200, .collapsible = true, .collapsed_size = 48 }; // threshold 100
    const none = PaneCfg{};
    const Case = struct { pos: f32, lc_in: bool, ratio: ?f32, lc: bool };
    const cases = [_]Case{
        .{ .pos = 500, .lc_in = false, .ratio = 0.5, .lc = false }, // free drag
        .{ .pos = 150, .lc_in = false, .ratio = 0.2, .lc = false }, // held at min
        .{ .pos = 100, .lc_in = false, .ratio = 0.2, .lc = false }, // exactly at threshold: still open
        .{ .pos = 99, .lc_in = false, .ratio = null, .lc = true }, // past it: collapse, ratio kept
        .{ .pos = 0, .lc_in = true, .ratio = null, .lc = true },
        .{ .pos = 104, .lc_in = true, .ratio = null, .lc = true }, // inside the hysteresis band
        .{ .pos = 105, .lc_in = true, .ratio = 0.2, .lc = false }, // reopened at min, not at pos
        .{ .pos = 700, .lc_in = true, .ratio = 0.7, .lc = false }, // a big jump reopens at pos
    };
    for (cases) |c| {
        const res = resolveDrag(side, none, .{ .pos = c.pos, .total = 1000, .left_collapsed = c.lc_in });
        try testing.expectEqual(c.lc, res.left_collapsed);
        try testing.expect(!res.right_collapsed);
        if (c.ratio) |r| try testing.expectApproxEqAbs(r, res.ratio.?, 0.0001) else try testing.expectEqual(@as(?f32, null), res.ratio);
    }
}

test "resolveDrag: the right pane mirrors the left, measured from its own edge" {
    const side = PaneCfg{ .min = 150, .collapsible = true, .collapse_threshold = 60 };
    const none = PaneCfg{};
    // 1000px: right min 150 → ratio never above 0.85.
    try testing.expectApproxEqAbs(@as(f32, 0.85), resolveDrag(none, side, .{ .pos = 900, .total = 1000 }).ratio.?, 0.0001);
    const shut = resolveDrag(none, side, .{ .pos = 950, .total = 1000 }); // 50 from the edge < 60
    try testing.expect(shut.right_collapsed);
    try testing.expectEqual(@as(?f32, null), shut.ratio);
    try testing.expect(resolveDrag(none, side, .{ .pos = 937, .total = 1000, .right_collapsed = true }).right_collapsed); // 63 ≤ 64
    const back = resolveDrag(none, side, .{ .pos = 930, .total = 1000, .right_collapsed = true });
    try testing.expect(!back.right_collapsed);
    try testing.expectApproxEqAbs(@as(f32, 0.85), back.ratio.?, 0.0001);
}

test "resolveDrag: edge cases — no mins keeps the old 5%..95% clamp, overlapping mins favor left, one collapse at a time" {
    const none = PaneCfg{};
    try testing.expectApproxEqAbs(MIN_RATIO, resolveDrag(none, none, .{ .pos = 0, .total = 1000 }).ratio.?, 0.0001);
    try testing.expectApproxEqAbs(MAX_RATIO, resolveDrag(none, none, .{ .pos = 1000, .total = 1000 }).ratio.?, 0.0001);
    // 600 + 600 > 1000: the left minimum wins.
    const big = PaneCfg{ .min = 600 };
    try testing.expectApproxEqAbs(@as(f32, 0.6), resolveDrag(big, big, .{ .pos = 500, .total = 1000 }).ratio.?, 0.0001);
    // Both collapsible and the pointer past both thresholds (tiny container): only one shuts.
    const c = PaneCfg{ .min = 100, .collapsible = true };
    const res = resolveDrag(c, c, .{ .pos = 20, .total = 60 });
    try testing.expect(res.left_collapsed != res.right_collapsed);
    // Zero-size container: nothing changes.
    const z = resolveDrag(c, c, .{ .pos = 0, .total = 0, .left_collapsed = true });
    try testing.expect(z.left_collapsed and z.ratio == null);
}

test "SplitPane: PaneCfg takes a plain nested literal in mountOwned props" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();
    var l = StubPane{};
    var r = StubPane{};
    var b = component.UIBuilder.init(&h.registry, &h.store);
    var ctx = BuildContext{ .builder = &b, .router = &h.router, .mounts = &h.mounts };
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(SplitPane, .{
        .left_child = component.childOf(StubPane, &l),
        .right_child = component.childOf(StubPane, &r),
        .left = .{ .min = 180, .collapsible = true }, // no `PaneCfg{` spelled out
    });
    b.close();
    const anchor = h.registry.getNode(0).?.first_child;
    const sp: *SplitPane = @ptrCast(@alignCast(h.mounts.get(anchor).?.component_ptr));
    try testing.expectApproxEqAbs(@as(f32, 180), sp.left.min, 0.0001);
    try testing.expect(sp.left.collapsible);
    try testing.expectApproxEqAbs(@as(f32, 0), sp.left.collapsed_size, 0.0001); // default kept
}

const Harness = @import("test_support.zig").Harness;

/// screen (fixed size) > SplitPane(.fill); returns the widget.
fn mountSplit(h: *Harness, w: f32, hgt: f32, init_props: anytype) !*SplitPane {
    const S = struct {
        var l = StubPane{};
        var r = StubPane{};
    };
    var b = component.UIBuilder.init(&h.registry, &h.store);
    var ctx = BuildContext{ .builder = &b, .router = &h.router, .mounts = &h.mounts };
    const screen = try b.openNodeKeyed(.box, null);
    try b.width(screen, w, .px);
    try b.height(screen, hgt, .px);
    var p = init_props;
    p.fill = true;
    p.left_child = component.childOf(StubPane, &S.l);
    p.right_child = component.childOf(StubPane, &S.r);
    try ctx.mountOwned(SplitPane, p);
    b.close();
    const anchor = h.registry.getNode(screen).?.first_child;
    return @ptrCast(@alignCast(h.mounts.get(anchor).?.component_ptr));
}

const TestProps = struct {
    fill: bool = true,
    left_child: component.Child = undefined,
    right_child: component.Child = undefined,
    orientation: Orientation = .horizontal,
    initial_ratio: f32 = 0.25,
    ratio: ?*signals.Signal(f32) = null,
    left: PaneCfg = .{},
    right: PaneCfg = .{},
    sash_color: ?theme_mod.Color = null,
};

fn dragTo(h: *Harness, sp: *SplitPane, x: f32, y: f32) void {
    h.route(.{ .name = "mouse_down", .id = "", .node_id = sp.sash_id });
    h.route(.{ .name = "mouse_move", .id = "", .x = x, .y = y });
    h.route(.{ .name = "mouse_up", .id = "" });
    h.solve(0, 1000, 600);
}

test "SplitPane (horizontal): left pane holds its min, collapses past the threshold, reopens at min — in solved geometry" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();
    const sp = try mountSplit(&h, 1000, 600, TestProps{
        .initial_ratio = 0.3,
        .left = .{ .min = 200, .collapsible = true, .collapsed_size = 48 },
    });
    h.solve(0, 1000, 600);
    // ratio × (1000 - 4px sash)
    try testing.expectApproxEqAbs(@as(f32, 298.8), h.geom(sp.left_pane_id).width, 0.1);

    dragTo(&h, sp, 150, 10); // under the 200px minimum
    try testing.expectApproxEqAbs(@as(f32, 200), h.geom(sp.left_pane_id).width, 0.1);
    try testing.expect(!sp.left_collapsed_state.peek());

    dragTo(&h, sp, 90, 10); // past the 100px threshold → collapsed to 48px
    try testing.expect(sp.left_collapsed_state.peek());
    try testing.expectApproxEqAbs(@as(f32, 48), h.geom(sp.left_pane_id).width, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 48), h.geom(sp.sash_id).x, 0.1); // sash moved to that edge
    try testing.expectApproxEqAbs(@as(f32, 1000 - 48 - 4), h.geom(sp.right_pane_id).width, 0.1);

    dragTo(&h, sp, 120, 10); // back over the threshold → reopens at its minimum
    try testing.expect(!sp.left_collapsed_state.peek());
    try testing.expectApproxEqAbs(@as(f32, 200), h.geom(sp.left_pane_id).width, 0.1);
}

test "SplitPane (vertical): bottom pane holds its min, collapses to 0, reopens — in solved geometry" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();
    const sp = try mountSplit(&h, 1000, 600, TestProps{
        .orientation = .vertical,
        .initial_ratio = 0.5,
        .right = .{ .min = 150, .collapsible = true }, // threshold 75, collapsed_size 0
    });
    h.solve(0, 1000, 600);
    try testing.expectApproxEqAbs(@as(f32, 298), h.geom(sp.right_pane_id).height, 0.1);

    dragTo(&h, sp, 10, 500); // 100px from the bottom: held at 150
    try testing.expectApproxEqAbs(@as(f32, 150), h.geom(sp.right_pane_id).height, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 600 - 150 - 4), h.geom(sp.left_pane_id).height, 0.1);

    dragTo(&h, sp, 10, 540); // 60px from the bottom < 75 → collapsed
    try testing.expect(sp.right_collapsed_state.peek());
    try testing.expectApproxEqAbs(@as(f32, 0), h.geom(sp.right_pane_id).height, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 596), h.geom(sp.left_pane_id).height, 0.1);

    dragTo(&h, sp, 10, 515); // 85px from the bottom → reopened at 150
    try testing.expect(!sp.right_collapsed_state.peek());
    try testing.expectApproxEqAbs(@as(f32, 150), h.geom(sp.right_pane_id).height, 0.1);
}

test "SplitPane: a caller-owned collapsed signal collapses and reopens from a command, back to the last ratio" {
    var collapsed = signals.Signal(bool).init(testing.allocator, false);
    defer collapsed.deinit();
    var h = Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();
    const sp = try mountSplit(&h, 1000, 600, TestProps{
        .initial_ratio = 0.4,
        .left = .{ .min = 200, .collapsible = true, .collapsed_size = 48, .collapsed = &collapsed },
    });
    h.solve(0, 1000, 600);
    try testing.expectApproxEqAbs(@as(f32, 398.4), h.geom(sp.left_pane_id).width, 0.1);

    collapsed.set(true); // e.g. "Toggle Side Bar"
    h.solve(0, 1000, 600);
    try testing.expectApproxEqAbs(@as(f32, 48), h.geom(sp.left_pane_id).width, 0.1);

    collapsed.set(false);
    h.solve(0, 1000, 600);
    try testing.expectApproxEqAbs(@as(f32, 398.4), h.geom(sp.left_pane_id).width, 0.1);

    // And a drag writes the caller's signal.
    dragTo(&h, sp, 30, 10);
    try testing.expect(collapsed.peek());
}

test "SplitPane: the layout keeps a pane's minimum when the window shrinks" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();
    const sp = try mountSplit(&h, 1000, 600, TestProps{ .initial_ratio = 0.25, .left = .{ .min = 240 } });
    h.solve(0, 1000, 600);
    try testing.expectApproxEqAbs(@as(f32, 249), h.geom(sp.left_pane_id).width, 0.1);
    h.registry.getNode(0).?.geometry = .{};
    try h.store.setLayout(0, .width, .{ .dimension = .{ .value = 600, .unit = .px } });
    h.solve(0, 600, 600);
    // 25% of 596 would be 149: the pane stays at 240 and the right pane takes the rest.
    try testing.expectApproxEqAbs(@as(f32, 240), h.geom(sp.left_pane_id).width, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 600 - 240 - 4), h.geom(sp.right_pane_id).width, 0.1);
}

test "SplitPane: a transparent sash stays invisible on hover but still drags" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();
    const sp = try mountSplit(&h, 1000, 600, TestProps{ .sash_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } });
    h.solve(0, 1000, 600);
    h.route(.{ .name = "mouse_enter", .id = "", .node_id = sp.sash_id });
    try testing.expect(sp.hovering.peek());
    try testing.expectApproxEqAbs(@as(f32, 0), h.store.getStyle(sp.sash_id, .background).?.color.a, 0.0001);
    dragTo(&h, sp, 500, 10);
    try testing.expectApproxEqAbs(@as(f32, 0.5), sp.left_ratio.peek(), 0.001);
}

const renderer = @import("../render/renderer.zig");

/// A bordered card filling its pane: `#2B2B2B` 1px border over a `#1E1E1E` fill,
/// optionally rounded with `overflowHidden` (the Albesi side-bar card).
const CardPane = struct {
    rounded: bool = false,
    card_id: reg.NodeId = reg.NULL_NODE,
    pub fn build(self: *CardPane, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const card = try b.openNodeKeyed(.box, null);
        try b.height(card, 200, .px);
        try b.background(card, 0x1E, 0x1E, 0x1E);
        try b.borderWidth(card, 1);
        try b.borderColor(card, 0x2B, 0x2B, 0x2B);
        if (self.rounded) {
            try b.radius(card, 6);
            try b.overflowHidden(card);
        }
        b.close();
        self.card_id = card;
    }
    pub fn deinit(_: *CardPane) void {}
};

/// Composites every baked rect over a black window at pixel center (px+.5, y),
/// the way the GPU blends them (straight-alpha "over", in draw order).
fn pixelAt(prims: []const renderer.RectPrimitive, clips: []const renderer.ClipEntry, px: usize, y: f32) [3]f32 {
    var dst = [3]f32{ 0, 0, 0 };
    const x = @as(f32, @floatFromInt(px)) + 0.5;
    for (prims) |p| {
        if (p.is_shadow != 0) continue;
        const e = clips[@intFromFloat(p.clip_id)];
        const c = renderer.shadeRect(p, .{ e.a, e.b }, x, y);
        for (0..3) |i| dst[i] = c[i] * c[3] + dst[i] * (1 - c[3]);
    }
    return dst;
}

test "SplitPane at a fractional ratio: every card border column is exactly the border color, rounded or not" {
    for ([_]bool{ false, true }) |rounded| {
        var h = Harness.init(testing.allocator);
        defer h.deinit();
        h.wire();
        var l = CardPane{ .rounded = rounded };
        var r = CardPane{ .rounded = rounded };
        var b = component.UIBuilder.init(&h.registry, &h.store);
        var ctx = BuildContext{ .builder = &b, .router = &h.router, .mounts = &h.mounts };
        const screen = try b.openNodeKeyed(.box, null);
        try b.width(screen, 1182, .px);
        try b.height(screen, 600, .px);
        try ctx.mountOwned(SplitPane, TestProps{
            .initial_ratio = 0.25,
            .left_child = component.childOf(CardPane, &l),
            .right_child = component.childOf(CardPane, &r),
        });
        b.close();
        h.solve(0, 1182, 600);
        // The layout itself stays fractional: (1182 - 4) * 0.25 = 294.5.
        const lg = h.geom(l.card_id);
        try testing.expectApproxEqAbs(@as(f32, 294.5), lg.x + lg.width, 0.01);

        var prims = std.array_list.Managed(renderer.RectPrimitive).init(testing.allocator);
        defer prims.deinit();
        var images = std.array_list.Managed(renderer.ImagePrimitive).init(testing.allocator);
        defer images.deinit();
        var paths = std.array_list.Managed(renderer.PathSegPrim).init(testing.allocator);
        defer paths.deinit();
        var hits = std.array_list.Managed(renderer.HitNode).init(testing.allocator);
        defer hits.deinit();
        var clips = renderer.ClipTable.init(testing.allocator);
        defer clips.deinit();
        try renderer.bakeRegistry(&h.registry, &h.store, &prims, &images, &paths, &hits, &clips, null, null, .pointer, testing.allocator, 1);

        const border: f32 = 0x2B / @as(f32, 255);
        const fill: f32 = 0x1E / @as(f32, 255);
        const y: f32 = 100.5; // mid-card, clear of the corners
        for ([_]reg.NodeId{ l.card_id, r.card_id }) |card| {
            const g = renderer.snapGeometry(h.geom(card), 1);
            const left: usize = @intFromFloat(g.x);
            const right: usize = @intFromFloat(g.x + g.width - 1);
            for ([_]usize{ left, right }) |col| {
                const c = pixelAt(prims.items, clips.items, col, y);
                for (c) |ch| try testing.expectApproxEqAbs(border, ch, 0.0005);
            }
            // One pixel thick: the next column in is the card's fill.
            const inner = pixelAt(prims.items, clips.items, left + 1, y);
            for (inner) |ch| try testing.expectApproxEqAbs(fill, ch, 0.0005);
            const inner_r = pixelAt(prims.items, clips.items, right - 1, y);
            for (inner_r) |ch| try testing.expectApproxEqAbs(fill, ch, 0.0005);
        }
        // Snapping rounds edges, not widths: the left pane (and card) end where the sash begins.
        const pane = renderer.snapGeometry(h.geom(h.registry.getNode(l.card_id).?.parent), 1);
        try testing.expectEqual(@as(f32, 295), pane.x + pane.width);
    }
}

test "snapGeometry rounds edges, so abutting boxes keep sharing their edge at any scale" {
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |s| {
        const a = renderer.snapGeometry(.{ .x = 10.3, .y = 0, .width = 284.2, .height = 10 }, s);
        const b2 = renderer.snapGeometry(.{ .x = 294.5, .y = 0, .width = 100.37, .height = 10 }, s);
        try testing.expectEqual(a.x + a.width, b2.x);
        // Every edge is on the device-pixel grid.
        try testing.expectEqual(@round(a.x * s), a.x * s);
        try testing.expectEqual(@round((b2.x + b2.width) * s), (b2.x + b2.width) * s);
    }
}
