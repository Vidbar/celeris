//! Radio — reactive component migrated to the canonical Button pattern.
//!
//! Framework-owned via `ctx.mountOwned(Radio, .{ .label = "A", .initial_checked = true })`:
//! no `init`/`register`/`deinit`/action-id in user code. Like Checkbox, the inner dot
//! is always present and its alpha (plus the outer ring border/background) is driven
//! by a render-only effect off the `checked`/`hovered` signals — selection never
//! relays out. A radio doesn't toggle itself off; `on_select` (typed `Handler`) fires
//! on click. `setChecked` lets a group clear peers programmatically.

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

pub const Radio = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    label: []const u8 = "",
    on_select: ?events.Handler = null,
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
    dot_id: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,

    pub fn onMount(self: *Radio, allocator: std.mem.Allocator) void {
        self.checked = signals.Signal(bool).init(allocator, self.initial_checked);
        self.hovered = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
    }

    pub fn deinit(self: *Radio) void {
        self.scope.deinit();
        self.checked.deinit();
        self.hovered.deinit();
    }

    /// Sets the checked state programmatically (e.g. a radio group clearing peers).
    pub fn setChecked(self: *Radio, v: bool) void {
        self.checked.set(v);
    }

    fn onClickSelect(self: *Radio, ev: events.Event) void {
        if (self.disabled) return;
        self.checked.set(true); // a radio doesn't toggle itself off
        if (self.on_select) |h| h.call(h.ptr, ev);
    }

    pub fn build(self: *Radio, ctx: *BuildContext) !void {
        const t = ctx.builder.theme;
        self.theme = t;
        self.store = ctx.builder.store;

        self.root_id = try ctx.boxNode(.{
            .direction = .row,
            .@"align" = .center,
            .focusable = !self.disabled,
            .role = "radio",
            .on_click = if (self.disabled) null else ctx.handler(self, onClickSelect),
            .on_hover = if (self.disabled) null else ctx.signalSetter(&self.hovered),
        }, .{
            Indicator{ .rad = self },
            Text{ .content = self.label, .color = component.rgb(t.text.r, t.text.g, t.text.b), .style = t.typography.body_medium },
        });

        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn updateVisuals(self: *Radio) void {
        const store = self.store orelse return;
        if (self.box_id == reg.NULL_NODE) return;
        const t = self.theme;
        const checked = self.checked.get();
        const hovered = self.hovered.get();

        // Surface selection state for accessibility (UIA SelectionItemPattern's
        // get_IsSelected reads `.checked` on the radio node).
        store.setModifier(self.root_id, .checked, .{ .boolean = checked }) catch {};

        store.setStyle(self.box_id, .background, props.PropValue.colorA(t.bg_input, 1.0)) catch {};
        const border = if (checked)
            props.PropValue.colorA(t.accent, 1.0)
        else if (hovered)
            props.PropValue.colorA(t.accent, 150.0 / 255.0)
        else
            props.PropValue.rgbA(t.border_color.r, t.border_color.g, t.border_color.b, @as(f32, @floatFromInt(t.border_color.a)) / 255.0);
        store.setStyle(self.box_id, .border_color, border) catch {};
        store.setStyle(self.dot_id, .background, props.PropValue.colorA(t.accent, if (checked) 1.0 else 0.0)) catch {};
    }
};

/// The 18×18 ring with the always-present inner dot. Built as its own slot so the
/// radio root can use the declarative props path; captures the box/dot node ids.
const Indicator = struct {
    rad: *Radio,
    pub fn build(self: *Indicator, ctx: *BuildContext) !void {
        const box = try ctx.boxNode(.{
            .width = 18,
            .height = 18,
            .radius = 9,
            .border_width = 1,
            .@"align" = .center,
            .justify = .center,
            .margin = EdgeInsets.only(0, 8, 0, 0),
        }, .{
            Dot{},
        });
        self.rad.box_id = box;
        self.rad.dot_id = ctx.builder.registry.getNode(box).?.first_child;
    }
    pub fn deinit(_: *Indicator) void {}
};

/// The 10×10 inner dot (its fill alpha encodes selection, painted by the effect).
const Dot = struct {
    pub fn build(_: *Dot, ctx: *BuildContext) !void {
        try ctx.boxLeaf(.{ .width = 10, .height = 10, .radius = 5 });
    }
    pub fn deinit(_: *Dot) void {}
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const dark = theme_mod.Theme.dark();

fn mountRadio(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    router: *events.EventRouter,
    mounts: *component.MountTable,
    init_props: anytype,
) !*Radio {
    var b = component.UIBuilder.init(registry, store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = router, .mounts = mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(Radio, init_props);
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
}

test "Radio (mountOwned) select fills the dot (render-only) and stays selected" {
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
        var selects: u32 = 0;
        fn onSelect(_: ?*anyopaque, _: events.Event) void {
            selects += 1;
        }
    };
    Sink.selects = 0;

    const rad = try mountRadio(&registry, &store, &router, &mounts, .{
        .label = "Pick",
        .on_select = events.Handler{ .ptr = null, .call = Sink.onSelect },
    });
    const dot_id = rad.dot_id;
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getStyle(dot_id, .background).?.color.a, 0.001);

    registry.getNode(rad.box_id).?.layout_dirty = false;
    registry.getNode(rad.box_id).?.render_dirty = false;

    _ = router.route(.{ .name = "click", .id = "", .node_id = rad.root_id });
    try testing.expect(rad.checked.peek());
    try testing.expectApproxEqAbs(@as(f32, 1.0), store.getStyle(dot_id, .background).?.color.a, 0.001);
    try testing.expect(!registry.getNode(rad.box_id).?.layout_dirty);
    try testing.expectEqual(@as(u32, 1), Sink.selects);

    // Clicking again keeps it selected.
    _ = router.route(.{ .name = "click", .id = "", .node_id = rad.root_id });
    try testing.expect(rad.checked.peek());
}
