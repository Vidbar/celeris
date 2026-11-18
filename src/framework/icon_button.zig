//! IconButton — reactive component migrated to the canonical Button pattern.
//!
//! Framework-owned via `ctx.mountOwned(IconButton, .{ .icon = "O", .on_click = h })`:
//! no `init`/`register`/`deinit`/action-id in user code. State (hover/press) lives in
//! `Signal`s auto-created in `onMount`; events are typed `Handler`s wired through
//! declarative `on_*` props. The translucent white overlay is a fine-grained effect,
//! so a hover is one render-only property write — never a relayout or subtree rebuild.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;
const Text = component.Text;

/// Default button side and glyph size, in px.
pub const DEFAULT_SIZE: f32 = 32;
pub const DEFAULT_ICON_SIZE: f32 = 16;

pub const IconButton = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    icon: []const u8,
    on_click: ?events.Handler = null,
    disabled: bool = false,
    /// Side of the square button, in px. Default 32 (unchanged look). Smaller
    /// values fit dense strips, e.g. 26 inside a 35 px custom caption.
    size: f32 = DEFAULT_SIZE,
    /// Glyph size in px, independent of `size`; the glyph stays centered. Not
    /// clamped — keep it below `size`.
    icon_size: f32 = DEFAULT_ICON_SIZE,

    // State (auto-created in onMount; preserved across rebuilds).
    hovered: signals.Signal(bool) = undefined,
    pressed: signals.Signal(bool) = undefined,
    scope: signals.Scope = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    root: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,

    pub fn onMount(self: *IconButton, allocator: std.mem.Allocator) void {
        self.hovered = signals.Signal(bool).init(allocator, false);
        self.pressed = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
    }

    /// Tears down reactive state on unmount. The framework owns and frees the
    /// instance itself.
    pub fn deinit(self: *IconButton) void {
        self.scope.deinit();
        self.hovered.deinit();
        self.pressed.deinit();
    }

    pub fn build(self: *IconButton, ctx: *BuildContext) !void {
        const t = ctx.builder.theme;
        self.theme = t;
        self.store = ctx.builder.store;

        self.root = try ctx.boxNode(.{
            .width = self.size,
            .height = self.size,
            .direction = .row,
            .@"align" = .center,
            .justify = .center,
            .radius = t.radius_base,
            .focusable = !self.disabled,
            .role = "icon_button",
            .on_click = if (self.disabled) null else self.on_click,
            .on_hover = if (self.disabled) null else ctx.hoverPressSetter(self),
            .on_press = if (self.disabled) null else ctx.signalSetter(&self.pressed),
        }, .{
            Text{ .content = self.icon, .color = component.rgb(t.text.r, t.text.g, t.text.b), .size = self.icon_size },
        });

        // Overlay is a fine-grained render-only effect (created once, re-applied
        // untracked after a structural rebuild clears the node) — same as Button.
        try component.bindVisuals(self, &self.scope, &self.bound, updateBackground);
    }

    /// Translucent white overlay whose alpha tracks the interaction state.
    fn updateBackground(self: *IconButton) void {
        const store = self.store orelse return;
        if (self.root == reg.NULL_NODE) return;
        const a: f32 = if (self.disabled)
            0.0
        else if (self.pressed.get())
            40.0 / 255.0
        else if (self.hovered.get())
            25.0 / 255.0
        else
            0.0;
        store.setStyle(self.root, .background, .{ .color = .{ .r = 1, .g = 1, .b = 1, .a = a } }) catch {};
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const dark = theme_mod.Theme.dark();

fn mountIconButton(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    router: *events.EventRouter,
    mounts: *component.MountTable,
    init_props: anytype,
) !*IconButton {
    var b = component.UIBuilder.init(registry, store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = router, .mounts = mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(IconButton, init_props);
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
}

test "IconButton (mountOwned) reactive overlay: hover raises alpha, render-only" {
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

    _ = try mountIconButton(&registry, &store, &router, &mounts, .{ .icon = "O" });
    const anchor = registry.getNode(0).?.first_child;
    const boxn = registry.getNode(anchor).?.first_child;
    try testing.expectEqualStrings("icon_button", store.getModifier(boxn, .role).?.string);

    // Idle: transparent overlay.
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getStyle(boxn, .background).?.color.a, 0.001);

    for (registry.nodes.items) |*n| {
        n.layout_dirty = false;
        n.render_dirty = false;
    }

    // Hover → 25/255 overlay, render-only.
    _ = router.route(.{ .name = "mouse_enter", .id = "", .node_id = boxn });
    try testing.expectApproxEqAbs(@as(f32, 25.0 / 255.0), store.getStyle(boxn, .background).?.color.a, 0.001);
    try testing.expect(registry.getNode(boxn).?.render_dirty);
    var any_layout = false;
    for (registry.nodes.items) |*n| {
        if (n.alive and n.layout_dirty) any_layout = true;
    }
    try testing.expect(!any_layout);

    // Press → 40/255.
    _ = router.route(.{ .name = "mouse_down", .id = "", .node_id = boxn });
    try testing.expectApproxEqAbs(@as(f32, 40.0 / 255.0), store.getStyle(boxn, .background).?.color.a, 0.001);
}

test "IconButton click fires the typed on_click handler" {
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

    const Sink = struct {
        var clicks: u32 = 0;
        fn onClick(_: ?*anyopaque, _: events.Event) void {
            clicks += 1;
        }
    };
    Sink.clicks = 0;

    _ = try mountIconButton(&registry, &store, &router, &mounts, .{
        .icon = "O",
        .on_click = events.Handler{ .ptr = null, .call = Sink.onClick },
    });
    const anchor = registry.getNode(0).?.first_child;
    const boxn = registry.getNode(anchor).?.first_child;

    _ = router.route(.{ .name = "click", .id = "", .node_id = boxn });
    try testing.expectEqual(@as(u32, 1), Sink.clicks);
}

const ts = @import("test_support.zig");

const Solved = struct { box: reg.Geometry, glyph: reg.Geometry, glyph_size: f32, radius: f32 };

/// Mounts an IconButton under a fixed-size root and solves layout — assertions
/// are on resolved geometry, not just on what the store holds.
fn solvedIconButton(env: *ts.Harness, init_props: anytype) !Solved {
    return solvedIconButtonWith(env, null, init_props);
}

fn solvedIconButtonWith(env: *ts.Harness, atlas: ?*@import("../render/text.zig").FontAtlas, init_props: anytype) !Solved {
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try b.width(root, 200, .px);
    try b.height(root, 100, .px);
    try ctx.mountOwned(IconButton, init_props);
    b.close();
    if (atlas) |at| env.solveWith(at, root, 200, 100) else env.solve(root, 200, 100);
    const anchor = env.registry.getNode(root).?.first_child;
    const boxn = env.registry.getNode(anchor).?.first_child;
    const glyph = env.registry.getNode(boxn).?.first_child;
    return .{
        .box = env.geom(boxn),
        .glyph = env.geom(glyph),
        .glyph_size = env.store.getStyle(glyph, .font_size).?.dimension.value,
        .radius = env.store.getStyle(boxn, .radius).?.dimension.value,
    };
}

test "IconButton defaults: 32x32 box, 16px glyph, theme radius (regression)" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const r = try solvedIconButton(&env, .{ .icon = "O" });
    try testing.expectApproxEqAbs(@as(f32, 32), r.box.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 32), r.box.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 16), r.glyph_size, 0.01);
    try testing.expectApproxEqAbs(dark.radius_base, r.radius, 0.01);
}

test "IconButton .size = 26: 26x26 box, glyph centered, same radius" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const ttf = try ts.loadSystemFont(testing.allocator);
    defer testing.allocator.free(ttf);
    var atlas = try @import("../render/text.zig").FontAtlas.init(testing.allocator, ttf, 72.0);
    defer atlas.deinit();
    const r = try solvedIconButtonWith(&env, &atlas, .{ .icon = "O", .size = 26 });
    try testing.expectApproxEqAbs(@as(f32, 26), r.box.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 26), r.box.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 16), r.glyph_size, 0.01);
    try testing.expectApproxEqAbs(dark.radius_base, r.radius, 0.01);
    try testing.expect(r.glyph.width > 0 and r.glyph.height > 0);
    const left = r.glyph.x - r.box.x;
    const right = (r.box.x + r.box.width) - (r.glyph.x + r.glyph.width);
    const top = r.glyph.y - r.box.y;
    const bottom = (r.box.y + r.box.height) - (r.glyph.y + r.glyph.height);
    try testing.expectApproxEqAbs(left, right, 0.5);
    try testing.expectApproxEqAbs(top, bottom, 0.5);
}

test "IconButton .icon_size changes the glyph, not the box" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const r = try solvedIconButton(&env, .{ .icon = "O", .icon_size = 12 });
    try testing.expectApproxEqAbs(@as(f32, 32), r.box.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 32), r.box.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 12), r.glyph_size, 0.01);
}
