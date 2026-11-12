//! WindowChrome — the custom-caption primitive for Celeris's borderless window.
//!
//! Celeris windows are borderless (WS_POPUP with WM_NCCALCSIZE stripped), so there
//! is no native title bar: the top strip is the app's to draw. This widget supplies
//! only the part an app *cannot* write from outside — the draggable caption region
//! wired to `window.startDrag()`, and the minimize / maximize / close controls with
//! their hover states and maximize/restore glyph.
//!
//! Everything visual beyond that is the consumer's: pass `content` (a `Child`, e.g.
//! `component.slot(&.{...})` or `component.childOf(T, &instance)`) and it is built
//! inside the draggable caption, left-aligned, ahead of the flexible drag spacer.
//! A wordmark, a logo, tabs, a status pill — the framework has no opinion.
//!
//! Layout: [ …content… ][ ……drag spacer…… ][ _ ▢ ✕ ]
//! With `content_fill`: [ ………content (fills the drag area)……… ][ _ ▢ ✕ ]
//!
//! Colors default to theme roles (`surface_low` / `text_secondary` / `border_color`);
//! `background`, `foreground` and `divider_color` override them for this bar only,
//! as explicit tokens, so an app can tint its caption without rewriting the theme.
//!
//! `runApp` mounts it for `app_bar_style = .custom`, forwarding `AppOptions.app_bar`
//! as the content slot and `app_bar_height` as the height.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const icons = @import("icons.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;

/// Default caption height in px — matches the classic `AppBar` so swapping styles
/// does not move the body. Override with `height`.
pub const DEFAULT_HEIGHT: f32 = 32;

pub const WindowChrome = struct {
    // Props.
    /// Caption height in px. A taller bar is a design choice; the primitive has none.
    height: f32 = DEFAULT_HEIGHT,
    /// Content built inside the draggable caption, before the spacer. Caller-owned:
    /// it must outlive the mount, and the chrome never deinits it.
    content: ?component.Child = null,
    /// Wrap `content` in a box that takes the whole drag area (`flexGrow(1)`) instead
    /// of placing it ahead of a spacer, so the content has the full caption width to
    /// lay out in (e.g. to center a title). The wrapper only centers vertically;
    /// horizontal placement is the content's. It sits inside the drag region, so it drags.
    content_fill: bool = false,
    /// Draw the 1px bottom hairline separating the caption from the body.
    divider: bool = true,
    /// Caption background. Null = theme `surface_low`.
    background: ?theme_mod.Color = null,
    /// Control glyph color, and the "on" color the hover state layer is mixed from.
    /// Null = glyphs in theme `text_secondary`, hover layer from theme `text`.
    /// The close button's hover stays the theme's `danger` color regardless.
    foreground: ?theme_mod.Color = null,
    /// Hairline color when `divider` is on. Null = theme `border_color`.
    divider_color: ?theme_mod.Color = null,
    /// Accessible names of the caption buttons; override to localize.
    control_labels: component.WindowControlLabels = .{},
    on_close: ?*const fn (ctx: ?*anyopaque) void = null,
    on_maximize: ?*const fn (ctx: ?*anyopaque) void = null,
    on_minimize: ?*const fn (ctx: ?*anyopaque) void = null,
    is_maximized: ?*const fn (ctx: ?*anyopaque) bool = null,
    on_drag: ?*const fn (ctx: ?*anyopaque) void = null,
    context: ?*anyopaque = null,
    window: ?*const @import("window.zig").Window = null,

    // State.
    hover_min: signals.Signal(bool) = undefined,
    hover_max: signals.Signal(bool) = undefined,
    hover_close: signals.Signal(bool) = undefined,
    scope: signals.Scope = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    drag_area: reg.NodeId = reg.NULL_NODE,
    /// The `content_fill` wrapper; NULL_NODE otherwise.
    content_box: reg.NodeId = reg.NULL_NODE,
    min_btn: reg.NodeId = reg.NULL_NODE,
    max_btn: reg.NodeId = reg.NULL_NODE,
    close_btn: reg.NodeId = reg.NULL_NODE,
    close_hover_bg: props.PropValue = .{ .color = .{ .r = 232.0 / 255.0, .g = 17.0 / 255.0, .b = 35.0 / 255.0, .a = 1.0 } },
    bound: bool = false,
    theme: theme_mod.Theme = .{},

    pub fn onMount(self: *WindowChrome, allocator: std.mem.Allocator) void {
        self.hover_min = signals.Signal(bool).init(allocator, false);
        self.hover_max = signals.Signal(bool).init(allocator, false);
        self.hover_close = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
    }

    pub fn deinit(self: *WindowChrome) void {
        self.scope.deinit();
        self.hover_min.deinit();
        self.hover_max.deinit();
        self.hover_close.deinit();
    }

    fn queryMaximized(self: *WindowChrome) bool {
        if (self.window) |w| return @constCast(w).isMaximized();
        if (self.is_maximized) |f| return f(self.context);
        return false;
    }

    fn onDragDown(self: *WindowChrome, _: events.Event) void {
        if (self.window) |w| @constCast(w).startDrag();
        if (self.on_drag) |cb| cb(self.context);
    }
    fn onMinClick(self: *WindowChrome, _: events.Event) void {
        if (self.window) |w| @constCast(w).minimize();
        if (self.on_minimize) |cb| cb(self.context);
    }
    fn onMaxClick(self: *WindowChrome, _: events.Event) void {
        if (self.window) |w| @constCast(w).maximize();
        if (self.on_maximize) |cb| cb(self.context);
    }
    fn onCloseClick(self: *WindowChrome, _: events.Event) void {
        if (self.window) |w| @constCast(w).close();
        if (self.on_close) |cb| cb(self.context);
    }

    pub fn build(self: *WindowChrome, ctx: *BuildContext) !void {
        const b = ctx.builder;
        self.store = b.store;
        self.theme = b.theme;
        const t = b.theme;

        const bar = try b.openNodeKeyed(.box, null);
        try b.width(bar, 100, .percent);
        try b.height(bar, self.height, .px);
        try b.flexRow(bar);
        try b.alignItems(bar, .center);
        try b.backgroundOf(bar, self.background orelse t.surface_low);
        try b.role(bar, "app_bar");
        if (self.divider) {
            try b.borderBottom(bar, 1);
            try b.borderColorOf(bar, self.divider_color orelse t.border_color);
        }

        // Close-hover background follows the theme's danger role.
        if (t.danger.a > 0) {
            self.close_hover_bg = props.PropValue.rgbA(t.danger.r, t.danger.g, t.danger.b, 1.0);
        }

        // Draggable region: the app's content plus the flexible spacer. The whole
        // left/center stretch drags the window, like a native caption.
        self.drag_area = try b.openNodeKeyed(.box, null);
        try b.flexRow(self.drag_area);
        try b.flexGrow(self.drag_area, 1);
        try b.height(self.drag_area, 100, .percent);
        try b.alignItems(self.drag_area, .center);
        try wireHit(b, self.drag_area, true, false);
        if (ctx.router) |r| try r.onNode(self.drag_area, .mouse_down, ctx.handler(self, onDragDown));

        if (self.content_fill) {
            // The slot may emit several nodes, so the fill is a wrapper the chrome
            // owns rather than a style forced onto the app's own nodes.
            self.content_box = try b.openNodeKeyed(.box, null);
            try b.flexRow(self.content_box);
            try b.flexGrow(self.content_box, 1);
            try b.height(self.content_box, 100, .percent);
            try b.alignItems(self.content_box, .center);
            if (self.content) |child| try child.build(ctx);
            b.close(); // content_box
        } else {
            self.content_box = reg.NULL_NODE;
            if (self.content) |child| try child.build(ctx);

            // Flexible drag spacer fills the remaining width.
            const spacer = try b.openNodeKeyed(.box, null);
            try b.flexGrow(spacer, 1);
            try b.height(spacer, 100, .percent);
            b.close(); // spacer
        }

        b.close(); // drag_area

        // ── Window controls ─────────────────────────────────────────────────
        const controls = try b.openNodeKeyed(.box, null);
        try b.flexRow(controls);
        try b.height(controls, 100, .percent);
        try b.alignItems(controls, .center);

        const max_glyph = if (self.queryMaximized()) icons.chrome_restore else icons.chrome_maximize;
        const max_label = if (self.queryMaximized()) self.control_labels.restore else self.control_labels.maximize;
        self.min_btn = try self.controlButton(ctx, icons.chrome_minimize, self.control_labels.minimize, ctx.handler(self, onMinClick), &self.hover_min);
        self.max_btn = try self.controlButton(ctx, max_glyph, max_label, ctx.handler(self, onMaxClick), &self.hover_max);
        self.close_btn = try self.controlButton(ctx, icons.chrome_close, self.control_labels.close, ctx.handler(self, onCloseClick), &self.hover_close);
        b.close(); // controls

        b.close(); // bar

        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn controlButton(
        self: *WindowChrome,
        ctx: *BuildContext,
        glyph: []const u8,
        label: []const u8,
        on_click: events.Handler,
        hover: *signals.Signal(bool),
    ) !reg.NodeId {
        const b = ctx.builder;
        const btn = try b.openNodeKeyed(.box, null);
        try b.width(btn, 46, .px);
        try b.height(btn, self.height, .px);
        try b.alignItems(btn, .center);
        try b.justifyContent(btn, .center);
        try wireHit(b, btn, true, true);
        // Icon-only control: the glyph child is not a readable name, so expose an
        // explicit accessible name for UIA / screen readers.
        try b.ariaLabel(btn, label);
        if (ctx.router) |r| {
            try r.onNode(btn, .click, on_click);
            const hh = ctx.signalSetter(hover);
            try r.onNode(btn, .mouse_enter, hh);
            try r.onNode(btn, .mouse_leave, hh);
        }
        const glyph_txt = try b.addText(glyph);
        try b.fontSize(glyph_txt, 16);
        try b.textColorOf(glyph_txt, self.foreground orelse b.theme.text_secondary);
        b.close();
        return btn;
    }

    fn wireHit(b: *component.UIBuilder, id: reg.NodeId, click: bool, hover: bool) !void {
        var idbuf: [16]u8 = undefined;
        const auto_id = std.fmt.bufPrint(&idbuf, "n{d}", .{id}) catch "n";
        if (click) try b.clickable(id, auto_id);
        if (hover) try b.hoverable(id, auto_id);
    }

    fn updateVisuals(self: *WindowChrome) void {
        const store = self.store orelse return;
        if (self.min_btn == reg.NULL_NODE) return;
        const Theme = theme_mod.Theme;
        const t = self.theme;
        // Min/Max: M3 hover state layer over the bar's own surface.
        const hl = Theme.stateLayer(self.background orelse t.surface_low, self.foreground orelse t.text, .hover);
        const hl_bg = props.PropValue.rgbA(hl.r, hl.g, hl.b, @as(f32, @floatFromInt(hl.a)) / 255.0);
        const transparent_bg = props.PropValue{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };
        store.setStyle(self.min_btn, .background, if (self.hover_min.get()) hl_bg else transparent_bg) catch {};
        store.setStyle(self.max_btn, .background, if (self.hover_max.get()) hl_bg else transparent_bg) catch {};
        const close_bg: props.PropValue = if (self.hover_close.get()) self.close_hover_bg else transparent_bg;
        store.setStyle(self.close_btn, .background, close_bg) catch {};
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mountChrome(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    router: *events.EventRouter,
    mounts: *component.MountTable,
    init_props: anytype,
) !*WindowChrome {
    var b = component.UIBuilder.init(registry, store);
    b.theme = theme_mod.Theme.dark();
    var ctx = BuildContext{ .builder = &b, .router = router, .mounts = mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(WindowChrome, init_props);
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
}

test "WindowChrome: close hover turns the close button danger-colored; click fires on_close" {
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

    const Holder = struct {
        var closed: u32 = 0;
        fn onClose(_: ?*anyopaque) void {
            closed += 1;
        }
    };
    Holder.closed = 0;

    const bar = try mountChrome(&registry, &store, &router, &mounts, .{ .on_close = Holder.onClose });

    // Idle close button: transparent.
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getStyle(bar.close_btn, .background).?.color.a, 0.001);

    _ = router.route(.{ .name = "mouse_enter", .id = "", .node_id = bar.close_btn });
    const dark = theme_mod.Theme.dark();
    const bg = store.getStyle(bar.close_btn, .background).?.color;
    try testing.expectApproxEqAbs(@as(f32, @as(f32, @floatFromInt(dark.danger.r)) / 255.0), bg.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), bg.a, 0.001);

    _ = router.route(.{ .name = "click", .id = "", .node_id = bar.close_btn });
    try testing.expectEqual(@as(u32, 1), Holder.closed);
}

/// Number of direct children of the caption area (slot content + spacer).
fn captionChildCount(registry: *reg.UIRegistry, drag_area: reg.NodeId) usize {
    var n: usize = 0;
    var child = registry.getNode(drag_area).?.first_child;
    while (child != reg.NULL_NODE) : (child = registry.getNode(child).?.next_sibling) n += 1;
    return n;
}

test "WindowChrome: the caption holds only the spacer without content, and the slot with it" {
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

    // No content → the drag spacer alone; the framework draws nothing of its own.
    const bare = try mountChrome(&registry, &store, &router, &mounts, .{});
    try testing.expectEqual(@as(usize, 1), captionChildCount(&registry, bare.drag_area));

    // With a content slot → the app's nodes sit ahead of the spacer.
    var r2 = reg.UIRegistry.init(a);
    defer r2.deinit();
    var s2 = props.PropertyStore.init(a);
    defer s2.deinit();
    s2.setRegistry(&r2);
    var m2 = component.MountTable.init(a);
    defer m2.deinit();
    r2.addNodeRemovedListener(&m2, component.MountTable.nodeRemovedListener);

    const caption = .{component.Text{ .content = "My App" }};
    const filled = try mountChrome(&r2, &s2, &router, &m2, .{ .content = component.slot(&caption) });
    try testing.expectEqual(@as(usize, 2), captionChildCount(&r2, filled.drag_area));
    const first = r2.getNode(filled.drag_area).?.first_child;
    try testing.expectEqualStrings("My App", s2.getTextContent(first).?);
}

test "WindowChrome: drag fires on_drag on mouse_down over the caption area" {
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

    const Holder = struct {
        var dragged: u32 = 0;
        fn onDrag(_: ?*anyopaque) void {
            dragged += 1;
        }
    };
    Holder.dragged = 0;

    const bar = try mountChrome(&registry, &store, &router, &mounts, .{ .on_drag = Holder.onDrag });
    _ = router.route(.{ .name = "mouse_down", .id = "", .node_id = bar.drag_area });
    try testing.expectEqual(@as(u32, 1), Holder.dragged);
}

// Regression: the caption buttons' accessible names were hard-coded in Spanish
// ("Minimizar" / "Maximizar" / "Cerrar"), so screen readers announced Spanish in
// every app. They now default to English and come from `control_labels`.
test "WindowChrome: caption buttons expose English names by default and localized names on request" {
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

    const bar = try mountChrome(&registry, &store, &router, &mounts, .{});
    try testing.expectEqualStrings("Minimize", store.getModifier(bar.min_btn, .label).?.string);
    try testing.expectEqualStrings("Maximize", store.getModifier(bar.max_btn, .label).?.string);
    try testing.expectEqualStrings("Close", store.getModifier(bar.close_btn, .label).?.string);

    var registry2 = reg.UIRegistry.init(a);
    defer registry2.deinit();
    var store2 = props.PropertyStore.init(a);
    defer store2.deinit();
    store2.setRegistry(&registry2);
    var router2 = events.EventRouter.init(a);
    defer router2.deinit();
    var mounts2 = component.MountTable.init(a);
    defer mounts2.deinit();
    registry2.addNodeRemovedListener(&mounts2, component.MountTable.nodeRemovedListener);
    const es = try mountChrome(&registry2, &store2, &router2, &mounts2, .{ .control_labels = component.WindowControlLabels{
        .minimize = "Minimizar",
        .maximize = "Maximizar",
        .restore = "Restaurar",
        .close = "Cerrar",
    } });
    try testing.expectEqualStrings("Cerrar", store2.getModifier(es.close_btn, .label).?.string);
}

test "WindowChrome: background, foreground and divider_color override the theme roles" {
    var h = @import("test_support.zig").Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();

    // Translucent background: the token's alpha must reach the bar and the hover layer.
    const bg = theme_mod.Color{ .r = 10, .g = 20, .b = 30, .a = 128 };
    const fg = theme_mod.Color{ .r = 200, .g = 210, .b = 220 };
    const dv = theme_mod.Color{ .r = 90, .g = 0, .b = 0 };
    const bar = try mountChrome(&h.registry, &h.store, &h.router, &h.mounts, .{
        .background = bg,
        .foreground = fg,
        .divider_color = dv,
    });
    const bar_node = h.registry.getNode(bar.drag_area).?.parent;
    try expectColor(bg, h.store.getStyle(bar_node, .background).?);
    try expectColor(dv, h.store.getStyle(bar_node, .border_color).?);
    const glyph = h.registry.getNode(bar.min_btn).?.first_child;
    try expectColor(fg, h.store.getStyle(glyph, .color).?);

    // Hover layer is mixed from the overrides, not from surface_low / text.
    h.route(.{ .name = "mouse_enter", .id = "", .node_id = bar.min_btn });
    try expectColor(theme_mod.Theme.stateLayer(bg, fg, .hover), h.store.getStyle(bar.min_btn, .background).?);
}

/// Asserts a stored color equals a theme token, alpha included.
fn expectColor(c: theme_mod.Color, v: props.PropValue) !void {
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(c.r)) / 255.0, v.color.r, 0.002);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(c.g)) / 255.0, v.color.g, 0.002);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(c.b)) / 255.0, v.color.b, 0.002);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(c.a)) / 255.0, v.color.a, 0.002);
}

test "WindowChrome: null color props keep the theme roles" {
    var h = @import("test_support.zig").Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();

    const t = theme_mod.Theme.dark(); // what mountChrome sets on the builder
    const bar = try mountChrome(&h.registry, &h.store, &h.router, &h.mounts, .{});
    const bar_node = h.registry.getNode(bar.drag_area).?.parent;
    try expectColor(t.surface_low, h.store.getStyle(bar_node, .background).?);
    try expectColor(t.border_color, h.store.getStyle(bar_node, .border_color).?);
    const glyph = h.registry.getNode(bar.min_btn).?.first_child;
    try expectColor(t.text_secondary, h.store.getStyle(glyph, .color).?);

    h.route(.{ .name = "mouse_enter", .id = "", .node_id = bar.min_btn });
    try expectColor(theme_mod.Theme.stateLayer(t.surface_low, t.text, .hover), h.store.getStyle(bar.min_btn, .background).?);
}

test "WindowChrome: content_fill makes the content as wide as the drag area" {
    var h = @import("test_support.zig").Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();

    const caption = .{component.Text{ .content = "Title" }};
    const bar = try mountChrome(&h.registry, &h.store, &h.router, &h.mounts, .{
        .content = component.slot(&caption),
        .content_fill = true,
    });
    // No spacer: the wrapper is the drag area's only child, so it takes all of it,
    // and it sits inside the drag region, so the caption still drags over it.
    try testing.expectEqual(@as(usize, 1), captionChildCount(&h.registry, bar.drag_area));
    try testing.expectEqual(bar.drag_area, h.registry.getNode(bar.content_box).?.parent);
    h.solve(0, 800, 40);
    const area = h.geom(bar.drag_area);
    try testing.expect(area.width > 0);
    try testing.expectApproxEqAbs(area.width, h.geom(bar.content_box).width, 0.5);
}

test "WindowChrome: with content_fill, a press on the content still drags the window" {
    var h = @import("test_support.zig").Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();

    const Holder = struct {
        var dragged: u32 = 0;
        fn onDrag(_: ?*anyopaque) void {
            dragged += 1;
        }
    };
    Holder.dragged = 0;

    const caption = .{component.Text{ .content = "Title" }};
    const bar = try mountChrome(&h.registry, &h.store, &h.router, &h.mounts, .{
        .content = component.slot(&caption),
        .content_fill = true,
        .on_drag = Holder.onDrag,
    });
    // The engine's hit-test returns the topmost drawn node — the title text — and
    // `c_api.hitAndDispatch` delivers mouse_down to every clickable node on its
    // ancestor path. Mirror that walk: the fill wrapper must not break the path.
    const title = h.registry.getNode(bar.content_box).?.first_child;
    try testing.expect(title != reg.NULL_NODE);
    var cur = title;
    while (cur != reg.NULL_NODE) : (cur = h.registry.getNode(cur).?.parent) {
        if (h.store.getModifier(cur, .clickable) != null)
            h.route(.{ .name = "mouse_down", .id = "", .node_id = cur });
    }
    try testing.expectEqual(@as(u32, 1), Holder.dragged);
}
