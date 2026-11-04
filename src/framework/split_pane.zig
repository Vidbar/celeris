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

const MIN_RATIO: f32 = 0.05;
const MAX_RATIO: f32 = 0.95;

pub const SplitPane = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    left_child: component.Child = undefined,
    right_child: component.Child = undefined,
    orientation: Orientation = .horizontal,
    initial_ratio: f32 = 0.25,
    /// Optional caller-owned split ratio (two-way, left fraction in [0.05, 0.95]).
    /// The widget reads it to size the panes and writes it while dragging the sash;
    /// the caller can set/animate it to open/collapse a pane. Omit to use the
    /// internal `left_ratio` seeded from `initial_ratio`.
    ratio: ?*signals.Signal(f32) = null,
    /// Sash thickness on the main axis, in px.
    sash_thickness: f32 = 4,
    /// Sash fill. Defaults to `theme.border_color`; an unset (transparent) token
    /// falls back to the built-in grey, same convention as StatusBar's dots. The
    /// hover shade is an M3 state layer over whichever base ends up in effect.
    sash_color: ?theme_mod.Color = null,

    // State (auto-created in onMount; preserved across rebuilds). `left_ratio` is
    // the fallback when the caller passes no `ratio` signal.
    left_ratio: signals.Signal(f32) = undefined,
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
        self.hovering = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
    }

    pub fn deinit(self: *SplitPane) void {
        self.scope.deinit();
        self.left_ratio.deinit();
        self.hovering.deinit();
    }

    /// The active ratio signal: caller-owned if provided, else the internal one.
    fn ratioSig(self: *SplitPane) *signals.Signal(f32) {
        return self.ratio orelse &self.left_ratio;
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
        const ratio = switch (self.orientation) {
            .horizontal => blk: {
                if (c.geometry.width <= 0) return;
                break :blk (x - c.geometry.x) / c.geometry.width;
            },
            .vertical => blk: {
                if (c.geometry.height <= 0) return;
                break :blk (y - c.geometry.y) / c.geometry.height;
            },
        };
        self.ratioSig().set(std.math.clamp(ratio, MIN_RATIO, MAX_RATIO));
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
        store.setLayout(self.left_pane_id, .flex_grow, .{ .number = ratio }) catch {};
        store.setLayout(self.right_pane_id, .flex_grow, .{ .number = 1.0 - ratio }) catch {};

        const base = self.sashBase();
        const fill = if (self.hovering.get())
            Theme.stateLayer(base, if (self.theme.is_dark)
                theme_mod.Color{ .r = 255, .g = 255, .b = 255 }
            else
                theme_mod.Color{ .r = 0, .g = 0, .b = 0 }, .hover)
        else
            base;
        store.setStyle(self.sash_id, .background, props.PropValue.rgbA(fill.r, fill.g, fill.b, @as(f32, @floatFromInt(fill.a)) / 255.0)) catch {};
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
