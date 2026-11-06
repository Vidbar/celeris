//! Slider — reactive component migrated to the canonical Button pattern.
//!
//! Framework-owned via `ctx.mountOwned(Slider, .{ .initial_value = 0.7 })`: no
//! `init`/`register`/`deinit`/action-id in user code. `value` (0..1), `dragging` and
//! `hovered` are `Signal`s auto-created in `onMount`. An effect writes the fill width
//! and thumb position (layout) and the thumb's active border (render). A press
//! positions the value from the track geometry read straight from the registry.
//!
//! Drag-follow needs the engine's global mouse_move/up (they carry no node id), so
//! the slider registers a **global** handler in `build()` against its own `root_id`
//! — the registry's node-removed hook prunes it automatically when that node goes
//! away, so a stale handler can't fire into the freed instance after unmount.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;

pub const Slider = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    on_change: ?events.Handler = null,
    initial_value: f32 = 0,
    disabled: bool = false,

    // State (auto-created in onMount; preserved across rebuilds).
    value: signals.Signal(f32) = undefined,
    dragging: signals.Signal(bool) = undefined,
    hovered: signals.Signal(bool) = undefined,
    scope: signals.Scope = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    router: ?*events.EventRouter = null,
    root_id: reg.NodeId = reg.NULL_NODE,
    track_id: reg.NodeId = reg.NULL_NODE,
    fill_id: reg.NodeId = reg.NULL_NODE,
    thumb_id: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,

    pub fn onMount(self: *Slider, allocator: std.mem.Allocator) void {
        self.value = signals.Signal(f32).init(allocator, self.initial_value);
        self.dragging = signals.Signal(bool).init(allocator, false);
        self.hovered = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
    }

    pub fn deinit(self: *Slider) void {
        self.scope.deinit();
        self.value.deinit();
        self.dragging.deinit();
        self.hovered.deinit();
    }

    /// Removes the global drag handler before the instance is freed.
    fn onDown(self: *Slider, ev: events.Event) void {
        if (self.disabled) return;
        self.dragging.set(true);
        self.updateValueFromX(ev.x);
    }

    fn onUp(self: *Slider, ev: events.Event) void {
        _ = ev;
        self.dragging.set(false);
    }

    /// ←/→ step the value by 1% (10% with Shift) while the slider has focus.
    fn onKey(self: *Slider, ev: events.Event) void {
        if (self.disabled) return;
        const step: f32 = if (ev.shift) 0.10 else 0.01;
        const delta: f32 = switch (events.Key.fromCode(ev.key_code) orelse return) {
            .left => -step, // ←
            .right => step, // →
            else => return,
        };
        self.value.set(std.math.clamp(self.value.peek() + delta, 0, 1));
        if (self.on_change) |h| h.call(h.ptr, .{ .name = "value_changed", .id = "", .node_id = self.root_id });
    }

    fn onGlobal(self: *Slider, ev: events.Event) void {
        if (std.mem.eql(u8, ev.name, "mouse_up")) {
            self.dragging.set(false);
        } else if (std.mem.eql(u8, ev.name, "mouse_move") and self.dragging.peek()) {
            self.updateValueFromX(ev.x);
        }
    }

    fn updateValueFromX(self: *Slider, gx: f32) void {
        const store = self.store orelse return;
        const registry = store.registry orelse return;
        if (self.track_id == reg.NULL_NODE) return;
        const track = registry.getNode(self.track_id) orelse return;
        const tx = track.geometry.x;
        const tw = track.geometry.width;
        if (tw <= 0) return;
        const local = std.math.clamp(gx - tx, 0, tw);
        const v = local / tw;
        self.value.set(v);
        if (self.on_change) |h| h.call(h.ptr, .{ .name = "value_changed", .id = "", .node_id = self.root_id });
    }

    pub fn build(self: *Slider, ctx: *BuildContext) !void {
        const t = ctx.builder.theme;
        self.theme = t;
        self.store = ctx.builder.store;
        self.router = ctx.router;

        self.root_id = try ctx.boxNode(.{
            .width = component.pct(100),
            .height = 24,
            .direction = .row,
            .@"align" = .center,
            .focusable = !self.disabled,
            .role = "slider",
            .on_mouse_down = if (self.disabled) null else ctx.handler(self, onDown),
            .on_mouse_up = if (self.disabled) null else ctx.handler(self, onUp),
            .on_key = if (self.disabled) null else ctx.handler(self, onKey),
            .on_hover = if (self.disabled) null else ctx.signalSetter(&self.hovered),
        }, .{
            Body{ .sld = self },
        });

        // Unconditional every build: onGlobal replaces in place per owner (see
        // events.zig), and the node-removed hook prunes it on unmount.
        if (ctx.router) |r| try r.onGlobal(self.root_id, self, onGlobal);
        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn updateVisuals(self: *Slider) void {
        const store = self.store orelse return;
        if (self.fill_id == reg.NULL_NODE) return;
        const pct = std.math.clamp(self.value.get(), 0, 1) * 100.0;
        store.setLayout(self.fill_id, .width, .{ .dimension = .{ .value = pct, .unit = .percent } }) catch {};
        store.setLayout(self.thumb_id, .left, .{ .dimension = .{ .value = pct, .unit = .percent } }) catch {};

        const active = self.dragging.get() or self.hovered.get();
        if (active) {
            store.setStyle(self.thumb_id, .border_width, .{ .dimension = .{ .value = 2, .unit = .px } }) catch {};
            store.setStyle(self.thumb_id, .border_color, props.PropValue.colorA(self.theme.accent, 1.0)) catch {};
        } else {
            store.setStyle(self.thumb_id, .border_width, .{ .dimension = .{ .value = 0, .unit = .px } }) catch {};
        }
    }
};

/// The track + absolutely-positioned fill and thumb. Built with the raw builder
/// (position/left/top aren't declarative props) inside a slot so the slider root can
/// use the declarative props path; captures the track/fill/thumb ids for the effect.
const Body = struct {
    sld: *Slider,
    pub fn build(self: *Body, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = self.sld.theme;

        const track = try b.openNodeKeyed(.box, null);
        self.sld.track_id = track;
        try b.width(track, 100, .percent);
        try b.height(track, 4, .px);
        try b.radius(track, 2);
        try b.backgroundAlpha(track, t.bg_input.r, t.bg_input.g, t.bg_input.b, 255);

        const fill = try b.openNodeKeyed(.box, null);
        self.sld.fill_id = fill;
        try b.store.setLayout(fill, .position, .{ .keyword = .absolute });
        try b.store.setLayout(fill, .left, .{ .dimension = .{ .value = 0, .unit = .px } });
        try b.store.setLayout(fill, .top, .{ .dimension = .{ .value = 0, .unit = .px } });
        try b.height(fill, 100, .percent);
        try b.radius(fill, 2);
        try b.backgroundAlpha(fill, t.accent.r, t.accent.g, t.accent.b, 255);
        b.close(); // fill

        const thumb = try b.openNodeKeyed(.box, null);
        self.sld.thumb_id = thumb;
        try b.store.setLayout(thumb, .position, .{ .keyword = .absolute });
        try b.store.setLayout(thumb, .top, .{ .dimension = .{ .value = -6, .unit = .px } });
        try b.store.setLayout(thumb, .margin_left, .{ .dimension = .{ .value = -8, .unit = .px } });
        try b.width(thumb, 16, .px);
        try b.height(thumb, 16, .px);
        try b.radius(thumb, 8);
        try b.backgroundAlpha(thumb, 255, 255, 255, 255);
        b.close(); // thumb

        b.close(); // track
    }
    pub fn deinit(_: *Body) void {}
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const dark = theme_mod.Theme.dark();

fn mountSlider(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    router: *events.EventRouter,
    mounts: *component.MountTable,
    init_props: anytype,
) !*Slider {
    var b = component.UIBuilder.init(registry, store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = router, .mounts = mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(Slider, init_props);
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
}

test "Slider (mountOwned) value binds to fill width; hover toggles thumb border" {
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

    const sld = try mountSlider(&registry, &store, &router, &mounts, .{ .initial_value = 0.5 });
    try testing.expectApproxEqAbs(@as(f32, 50.0), store.getLayout(sld.fill_id, .width).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getStyle(sld.thumb_id, .border_width).?.dimension.value, 0.001);

    _ = router.route(.{ .name = "mouse_enter", .id = "", .node_id = sld.root_id });
    try testing.expectApproxEqAbs(@as(f32, 2.0), store.getStyle(sld.thumb_id, .border_width).?.dimension.value, 0.001);
}

test "Slider press sets value from track-relative x; drag-follow via global move" {
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

    const sld = try mountSlider(&registry, &store, &router, &mounts, .{ .initial_value = 0.0 });
    // Simulate a solved layout: track at x=0, width=200.
    registry.getNode(sld.track_id).?.geometry = .{ .x = 0, .y = 0, .width = 200, .height = 4 };

    // Press at x=150 → value 0.75.
    _ = router.route(.{ .name = "mouse_down", .id = "", .node_id = sld.root_id, .x = 150.0, .y = 1.0 });
    try testing.expectApproxEqAbs(@as(f32, 0.75), sld.value.peek(), 0.001);

    // Drag past the edge → clamps to 1; global mouse_up ends the drag.
    _ = router.route(.{ .name = "mouse_move", .id = "", .x = 9999.0, .y = 1.0 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), sld.value.peek(), 0.001);
    _ = router.route(.{ .name = "mouse_up", .id = "" });
    _ = router.route(.{ .name = "mouse_move", .id = "", .x = 0.0, .y = 1.0 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), sld.value.peek(), 0.001); // ignored after release
}

test "Slider arrow keys step the value 1% (10% with Shift), clamped" {
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

    const sld = try mountSlider(&registry, &store, &router, &mounts, .{ .initial_value = 0.5 });

    _ = router.route(.{ .name = "key_down", .id = "", .node_id = sld.root_id, .key_code = events.Key.right.code() }); // →
    try testing.expectApproxEqAbs(@as(f32, 0.51), sld.value.peek(), 0.0001);
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = sld.root_id, .key_code = events.Key.left.code(), .shift = true }); // Shift+←
    try testing.expectApproxEqAbs(@as(f32, 0.41), sld.value.peek(), 0.0001);
    // Clamp at 0.
    var i: usize = 0;
    while (i < 60) : (i += 1) _ = router.route(.{ .name = "key_down", .id = "", .node_id = sld.root_id, .key_code = events.Key.left.code() });
    try testing.expectApproxEqAbs(@as(f32, 0.0), sld.value.peek(), 0.0001);
}

test "Slider removes its global handler on unmount (no dangling drag handler)" {
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

    var b = component.UIBuilder.init(&registry, &store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(Slider, .{ .initial_value = 0.0 });
    b.close();
    try testing.expectEqual(@as(usize, 1), router.global_handlers.items.len);

    // Rebuild the root empty → the slider anchor is reconciled away → onUnmount
    // removes the global handler (and the instance is freed without leak).
    try b.rootAt(root);
    b.close();
    try testing.expectEqual(@as(usize, 0), router.global_handlers.items.len);
}
