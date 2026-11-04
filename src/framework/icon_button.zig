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

pub const IconButton = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    icon: []const u8,
    on_click: ?events.Handler = null,
    disabled: bool = false,

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
            .width = 32,
            .height = 32,
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
            Text{ .content = self.icon, .color = component.rgb(t.text.r, t.text.g, t.text.b), .size = 16 },
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
