//! Checkbox — reactive component migrated to the canonical Button pattern.
//!
//! Framework-owned via `ctx.mountOwned(Checkbox, .{ .label = "On", .initial_checked = true })`:
//! no `init`/`register`/`deinit`/action-id in user code. `checked`/`hovered` are
//! `Signal`s auto-created in `onMount` (the initial checked value comes from the
//! `initial_checked` prop, applied before `onMount` runs). Toggling is render-only:
//! the checkmark is always present and an effect drives its color alpha plus the box
//! background/border — no relayout, no subtree rebuild. `on_change` (a typed
//! `Handler`) fires on toggle; the new state is on the instance's `checked` signal.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;
const Text = component.Text;
const EdgeInsets = component.EdgeInsets;

pub const Checkbox = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    label: []const u8 = "",
    on_change: ?events.Handler = null,
    initial_checked: bool = false,
    disabled: bool = false,

    // State (auto-created in onMount; preserved across rebuilds).
    checked: signals.Signal(bool) = undefined,
    hovered: signals.Signal(bool) = undefined,
    scope: signals.Scope = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    root_id: reg.NodeId = reg.NULL_NODE,
    box_id: reg.NodeId = reg.NULL_NODE,
    check_id: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,

    pub fn onMount(self: *Checkbox, allocator: std.mem.Allocator) void {
        self.checked = signals.Signal(bool).init(allocator, self.initial_checked);
        self.hovered = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
    }

    pub fn deinit(self: *Checkbox) void {
        self.scope.deinit();
        self.checked.deinit();
        self.hovered.deinit();
    }

    /// Toggles the checked state on click and notifies `on_change`. The visuals
    /// effect repaints render-only; the new value is `self.checked`.
    fn onClickToggle(self: *Checkbox, ev: events.Event) void {
        if (self.disabled) return;
        self.checked.set(!self.checked.peek());
        if (self.on_change) |h| h.call(h.ptr, ev);
    }

    pub fn build(self: *Checkbox, ctx: *BuildContext) !void {
        const t = ctx.builder.theme;
        self.theme = t;
        self.store = ctx.builder.store;

        self.root_id = try ctx.boxNode(.{
            .direction = .row,
            .@"align" = .center,
            .focusable = !self.disabled,
            .role = "checkbox",
            .on_click = if (self.disabled) null else ctx.handler(self, onClickToggle),
            .on_hover = if (self.disabled) null else ctx.signalSetter(&self.hovered),
        }, .{
            Indicator{ .cb = self },
            Text{ .content = self.label, .color = component.rgb(t.text.r, t.text.g, t.text.b), .style = t.typography.body_medium },
        });
        // Name from the label, not the check glyph: the indicator renders a "✓"
        // text node that would otherwise win as the accessible name.
        if (self.label.len > 0) try ctx.builder.ariaLabel(self.root_id, self.label);

        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn updateVisuals(self: *Checkbox) void {
        const store = self.store orelse return;
        if (self.box_id == reg.NULL_NODE) return;
        const t = self.theme;
        const checked = self.checked.get();
        const hovered = self.hovered.get();

        if (checked) {
            store.setStyle(self.box_id, .background, props.PropValue.colorA(t.accent, 1.0)) catch {};
            store.setStyle(self.box_id, .border_color, props.PropValue.colorA(t.accent, 1.0)) catch {};
        } else {
            store.setStyle(self.box_id, .background, props.PropValue.colorA(t.bg_input, 1.0)) catch {};
            const border = if (hovered) props.PropValue.colorA(t.accent, 150.0 / 255.0) else props.PropValue.rgbA(t.border_color.r, t.border_color.g, t.border_color.b, @as(f32, @floatFromInt(t.border_color.a)) / 255.0);
            store.setStyle(self.box_id, .border_color, border) catch {};
        }
        store.setStyle(self.check_id, .color, props.PropValue.rgbA(255, 255, 255, if (checked) 1.0 else 0.0)) catch {};
        if (self.root_id != reg.NULL_NODE) store.setModifier(self.root_id, .checked, .{ .boolean = checked }) catch {};
    }
};

/// The 18×18 indicator box with the always-present checkmark inside. Split into its
/// own slot so the checkbox root can be built through the declarative props path;
/// captures the box/check node ids back onto the Checkbox for the visuals effect.
const Indicator = struct {
    cb: *Checkbox,
    pub fn build(self: *Indicator, ctx: *BuildContext) !void {
        const box = try ctx.boxNode(.{
            .width = 18,
            .height = 18,
            .radius = 4,
            .border_width = 1,
            .@"align" = .center,
            .justify = .center,
            .margin = EdgeInsets.only(0, 8, 0, 0),
        }, .{
            Text{ .content = "v", .size = 12 },
        });
        self.cb.box_id = box;
        self.cb.check_id = ctx.builder.registry.getNode(box).?.first_child;
    }
    pub fn deinit(_: *Indicator) void {}
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const dark = theme_mod.Theme.dark();

fn mountCheckbox(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    router: *events.EventRouter,
    mounts: *component.MountTable,
    init_props: anytype,
) !*Checkbox {
    var b = component.UIBuilder.init(registry, store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = router, .mounts = mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(Checkbox, init_props);
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
}

test "Checkbox (mountOwned) toggle is render-only and flips checkmark alpha + checked state" {
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

    const chk = try mountCheckbox(&registry, &store, &router, &mounts, .{ .label = "Enable", .initial_checked = false });
    const root = chk.root_id;
    const box_id = chk.box_id;
    const check_id = chk.check_id;

    // Unchecked: checkmark transparent.
    try testing.expectEqualStrings("checkbox", store.getModifier(root, .role).?.string);
    try testing.expect(!chk.checked.peek());
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getStyle(check_id, .color).?.color.a, 0.001);

    for (registry.nodes.items) |*n| {
        n.layout_dirty = false;
        n.render_dirty = false;
    }

    // Click → checked, checkmark opaque, checked modifier set, render-only.
    _ = router.route(.{ .name = "click", .id = "", .node_id = root });
    try testing.expect(chk.checked.peek());
    try testing.expectApproxEqAbs(@as(f32, 1.0), store.getStyle(check_id, .color).?.color.a, 0.001);
    try testing.expect(store.getModifier(root, .checked).?.boolean);
    try testing.expect(registry.getNode(box_id).?.render_dirty);
    var any_layout = false;
    for (registry.nodes.items) |*n| {
        if (n.alive and n.layout_dirty) any_layout = true;
    }
    try testing.expect(!any_layout);
}

test "Checkbox (diagnostic) mountOwned anchor keeps content height in a stretch column" {
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

    var b = component.UIBuilder.init(&registry, &store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    // Parent mirrors dashboard's ComponentsTab root: a column, align-items stretch.
    const root = try b.openNodeKeyed(.box, null);
    try b.store.setLayout(root, .width, .{ .dimension = .{ .value = 400, .unit = .px } });
    try b.store.setLayout(root, .height, .{ .dimension = .{ .value = 300, .unit = .px } });
    try b.store.setLayout(root, .flex_direction, .{ .keyword = .column });
    try b.store.setLayout(root, .align_items, .{ .keyword = .stretch });
    try ctx.mountOwned(Checkbox, .{ .label = "Enable", .initial_checked = true });
    b.close();

    const flexbox = @import("../layout/flexbox.zig");
    var engine = flexbox.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 400, 300);

    const anchor = registry.getNode(root).?.first_child;
    const cb: *Checkbox = @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
    // The 18px indicator must have real height; the anchor must not collapse to 0.
    try testing.expect(registry.getNode(cb.box_id).?.geometry.height >= 18);
    try testing.expect(registry.getNode(cb.root_id).?.geometry.height >= 18);
    try testing.expect(registry.getNode(anchor).?.geometry.height >= 18);
}

test "Checkbox initial_checked seeds the checked state; on_change fires on toggle" {
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
        var changes: u32 = 0;
        fn onChange(_: ?*anyopaque, _: events.Event) void {
            changes += 1;
        }
    };
    Sink.changes = 0;

    const chk = try mountCheckbox(&registry, &store, &router, &mounts, .{
        .label = "On",
        .initial_checked = true,
        .on_change = events.Handler{ .ptr = null, .call = Sink.onChange },
    });
    try testing.expect(chk.checked.peek()); // seeded from initial_checked

    _ = router.route(.{ .name = "click", .id = "", .node_id = chk.root_id });
    try testing.expect(!chk.checked.peek()); // toggled off
    try testing.expectEqual(@as(u32, 1), Sink.changes);
}
