//! Button — the canonical reactive component.
//!
//! This is the reference pattern every other widget follows: the framework owns
//! the instance (`ctx.mountOwned(Button, .{ .label = "OK", .on_click = h })`), state
//! lives in `Signal`s auto-created in `onMount`, events are typed `Handler`s wired
//! through declarative `on_*` props (no string action-id, no `router.on`), and the
//! background is a fine-grained effect so a hover is one render-only property write —
//! never a relayout or a subtree rebuild. Theme colors come from tokens.
//!
//! Slots: a Button is `label` OR composed `content`. Pass `.content` a `Child`
//! — typically `component.slot(&.{ Icon{...}, Text{...} })` — and the widget renders
//! that in place of the text label. `content` is a stored prop, so it survives both
//! build paths (inline mount and isolated reactive rerun) unchanged. This is the
//! reference for the slot convention every composable widget follows.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const text_mod = @import("../render/text.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;
const EdgeInsets = component.EdgeInsets;
const Text = component.Text;
const Child = component.Child;

pub const Button = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    label: []const u8 = "",
    on_click: ?events.Handler = null,
    disabled: bool = false,
    /// Optional base background override (e.g. accent toolbar buttons). Hover and
    /// press derive brightened/darkened shades of it; theme tokens apply when null.
    background: ?theme_mod.Color = null,
    /// Composed slot content. When set, rendered instead of `label`.
    content: ?Child = null,
    /// Full typography override for the label; defaults to `theme.typography.label_large`.
    text_style: ?theme_mod.TextStyle = null,
    /// Label size in px. Shorthand that overrides only the size of the effective
    /// `text_style` — for fitting a label in a tight column without shortening it.
    font_size: ?f32 = null,
    /// Explicit label color. Overrides the contrast-derived default — reach for it
    /// only when the automatic on-color is wrong for a specific design.
    label_color: ?theme_mod.Color = null,
    /// Accessible name (aria-label) for a screen reader / UIA. Set this for icon-only
    /// buttons whose visible `label` is a glyph: without it the accessible name is the
    /// glyph itself ("▤"), which reads as meaningless. Ignored when null (a text button is
    /// already named by its label).
    aria_label: ?[]const u8 = null,
    /// Floating hover-text (`TooltipHost`), shown after a short dwell. Reuse
    /// `aria_label`'s text here for icon-only buttons — one source of truth for the
    /// button's name, both spoken and shown.
    tooltip: ?[]const u8 = null,

    // ── Box overrides (a design's button is rarely the default one) ────────────
    /// Fixed button height in px (the design's 40px control), instead of
    /// padding-derived height.
    height: ?f32 = null,
    /// Floor for a padding-derived height. Ignored when `height` is set.
    min_height: ?f32 = null,
    /// Padding override; defaults to the M3 16x6 box.
    padding: ?EdgeInsets = null,
    /// Outline width in px. With `border_color`, this is the `outlined` variant —
    /// no wrapper box needed.
    border_width: ?f32 = null,
    border_color: ?theme_mod.Color = null,
    /// Main-axis placement of the label/`content` inside the button — the same
    /// `justify` a `boxNode` takes. `.start` is a left-aligned header/list-style
    /// button. Visible only when the button is wider than its content (it fills
    /// its column by default; a `.hug` button has no slack). The whole box stays
    /// the click/hover target either way.
    justify: component.Justify = .center,

    // State (auto-created in onMount; preserved across rebuilds).
    hovered: signals.Signal(bool) = undefined,
    pressed: signals.Signal(bool) = undefined,
    scope: signals.Scope = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    root: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,

    /// The framework calls this on first mount, handing us an allocator to
    /// bring up our reactive state. No manual `init` in user code.
    pub fn onMount(self: *Button, allocator: std.mem.Allocator) void {
        self.hovered = signals.Signal(bool).init(allocator, false);
        self.pressed = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
    }

    /// Tears down reactive state on unmount. Does NOT free the instance —
    /// the framework owns and frees it.
    pub fn deinit(self: *Button) void {
        self.scope.deinit();
        self.hovered.deinit();
        self.pressed.deinit();
    }

    pub fn build(self: *Button, ctx: *BuildContext) !void {
        const t = ctx.builder.theme;
        self.theme = t;
        self.store = ctx.builder.store;

        self.root = try ctx.boxNode(.{
            .padding = self.padding orelse EdgeInsets.symmetric(16, 6),
            .direction = .row,
            .@"align" = .center,
            .justify = self.justify,
            .radius = t.radius_base,
            .focusable = !self.disabled,
            .role = "button",
            .on_click = if (self.disabled) null else self.on_click,
            .on_hover = if (self.disabled) null else ctx.hoverPressSetter(self),
            .on_press = if (self.disabled) null else ctx.signalSetter(&self.pressed),
        }, .{
            ButtonBody{ .btn = self },
        });

        // Box overrides, applied after the node exists so each stays optional
        // (a struct literal can't carry a conditionally-absent field).
        const b = ctx.builder;
        if (self.height) |h| try b.height(self.root, h, .px);
        if (self.min_height) |h| try b.minHeight(self.root, h, .px);
        if (self.border_width) |w| try b.borderWidth(self.root, w);
        if (self.border_color) |c| try b.borderColorOf(self.root, c);
        // An explicit accessible name wins over the glyph label for a screen reader — set on
        // the button node itself, which is the focusable element a UIA client lands on.
        if (self.aria_label) |name| try b.ariaLabel(self.root, name);
        if (self.tooltip) |t2| try b.tooltip(self.root, t2);

        // Background is a fine-grained effect (render-only on hover/press): created
        // once, and re-applied untracked after a structural rebuild clears the node.
        try component.bindVisuals(self, &self.scope, &self.bound, updateBackground);
    }

    /// The label color: an explicit `label_color`, else the theme's on-color for
    /// whatever fill this button actually has. A `background` override used to force
    /// `text_on_accent` regardless of luminance, which left a dark secondary button
    /// (e.g. `surface_low`) with near-black, unreadable text.
    fn labelColor(self: *Button) theme_mod.Color {
        if (self.label_color) |c| return c;
        if (self.background) |bg| return self.theme.onColorFor(bg);
        return self.theme.text_on_accent_container;
    }

    fn updateBackground(self: *Button) void {
        const store = self.store orelse return;
        if (self.root == reg.NULL_NODE) return;
        const t = self.theme;
        const Theme = theme_mod.Theme;
        const c = if (self.disabled)
            t.bg_disabled
        else if (self.background) |bg| blk: {
            // Override path: overlay white (dark) or black (light) as content color.
            const on = if (t.is_dark) theme_mod.Color{ .r = 255, .g = 255, .b = 255 } else theme_mod.Color{ .r = 0, .g = 0, .b = 0 };
            break :blk if (self.pressed.get()) Theme.stateLayer(bg, on, .pressed) else if (self.hovered.get()) Theme.stateLayer(bg, on, .hover) else bg;
        } else if (self.pressed.get())
            Theme.stateLayer(t.accent_container, t.text_on_accent_container, .pressed)
        else if (self.hovered.get())
            Theme.stateLayer(t.accent_container, t.text_on_accent_container, .hover)
        else
            t.accent_container;
        store.setStyle(self.root, .background, props.PropValue.rgbA(c.r, c.g, c.b, @as(f32, @floatFromInt(c.a)) / 255.0)) catch {};
    }
};

/// The button's inner slot, built as a child of the button box so it reconciles in
/// place across rebuilds: renders the composed `content` when provided, else
/// the text `label`. Reads live off the `Button` instance, so the isolated reactive
/// rerun path (fresh builder, no children tuple) renders identical structure.
const ButtonBody = struct {
    btn: *Button,
    pub fn build(self: *ButtonBody, ctx: *BuildContext) !void {
        if (self.btn.content) |c| {
            try c.build(ctx);
        } else {
            const fg = self.btn.labelColor();
            var style = self.btn.text_style orelse self.btn.theme.typography.label_large;
            if (self.btn.font_size) |s| style.size = s;
            var txt = Text{ .content = self.btn.label, .color = colorOf(fg), .style = style };
            try txt.build(ctx);
        }
    }
};

// shade() removed — replaced by Theme.stateLayer (M3 state layers).

fn colorOf(c: theme_mod.Color) component.Color {
    return .{
        .r = @as(f32, @floatFromInt(c.r)) / 255.0,
        .g = @as(f32, @floatFromInt(c.g)) / 255.0,
        .b = @as(f32, @floatFromInt(c.b)) / 255.0,
        .a = @as(f32, @floatFromInt(c.a)) / 255.0,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const dark = theme_mod.Theme.dark();

/// Mounts a Button via the canonical mountOwned path and returns (instance, anchor).
fn mountButton(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    router: *events.EventRouter,
    mounts: *component.MountTable,
    init_props: anytype,
) !*Button {
    var b = component.UIBuilder.init(registry, store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = router, .mounts = mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(Button, init_props);
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
}

test "Button (mountOwned) builds a button subtree with a label — no init/register" {
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

    _ = try mountButton(&registry, &store, &router, &mounts, .{ .label = "OK" });

    // root(0) → anchor(1) → box(2) → text(3)
    const anchor = registry.getNode(0).?.first_child;
    const boxn = registry.getNode(anchor).?.first_child;
    try testing.expectEqualStrings("button", store.getModifier(boxn, .role).?.string);
    try testing.expect(store.getModifier(boxn, .focusable) != null); // focusable when enabled
    const txt = registry.getNode(boxn).?.first_child;
    try testing.expectEqualStrings("OK", store.getTextContent(txt).?);
    // Base background = bg_surface.
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(dark.accent_container.r)) / 255.0, store.getStyle(boxn, .background).?.color.r, 0.01);
}

test "Button hover is reactive and render-only (no relayout)" {
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

    const btn = try mountButton(&registry, &store, &router, &mounts, .{ .label = "OK" });
    const anchor = registry.getNode(0).?.first_child;
    const boxn = registry.getNode(anchor).?.first_child;

    // Settle dirty after the initial build.
    for (registry.nodes.items) |*n| {
        n.layout_dirty = false;
        n.render_dirty = false;
    }

    // Hover in → stateLayer(accent, text_on_accent, .hover), render-only (no layout_dirty).
    _ = router.route(.{ .name = "mouse_enter", .id = "", .node_id = boxn });
    try testing.expect(btn.hovered.peek());
    const expected_hover = theme_mod.Theme.stateLayer(dark.accent_container, dark.text_on_accent_container, .hover);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(expected_hover.r)) / 255.0, store.getStyle(boxn, .background).?.color.r, 0.01);
    try testing.expect(registry.getNode(boxn).?.render_dirty);
    var any_layout = false;
    for (registry.nodes.items) |*n| {
        if (n.alive and n.layout_dirty) any_layout = true;
    }
    try testing.expect(!any_layout);

    // Hover out → back to surface.
    _ = router.route(.{ .name = "mouse_leave", .id = "", .node_id = boxn });
    try testing.expect(!btn.hovered.peek());
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(dark.accent_container.r)) / 255.0, store.getStyle(boxn, .background).?.color.r, 0.01);
}

test "Button click fires the typed on_click handler" {
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

    _ = try mountButton(&registry, &store, &router, &mounts, .{
        .label = "OK",
        .on_click = events.Handler{ .ptr = null, .call = Sink.onClick },
    });
    const anchor = registry.getNode(0).?.first_child;
    const boxn = registry.getNode(anchor).?.first_child;

    _ = router.route(.{ .name = "click", .id = "", .node_id = boxn });
    try testing.expectEqual(@as(u32, 1), Sink.clicks);
}

test "Button disabled: not focusable, no click handler" {
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

    _ = try mountButton(&registry, &store, &router, &mounts, .{
        .label = "No",
        .disabled = true,
        .on_click = events.Handler{ .ptr = null, .call = Sink.onClick },
    });
    const anchor = registry.getNode(0).?.first_child;
    const boxn = registry.getNode(anchor).?.first_child;

    try testing.expectEqual(@as(?props.PropValue, null), store.getModifier(boxn, .focusable));
    // Disabled → bg_disabled and a click does nothing.
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(dark.bg_disabled.r)) / 255.0, store.getStyle(boxn, .background).?.color.r, 0.01);
    _ = router.route(.{ .name = "click", .id = "", .node_id = boxn });
    try testing.expectEqual(@as(u32, 0), Sink.clicks);
}

test "Button mounted with .hug shrink-wraps its label instead of filling the column" {
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
    // Parent mirrors a wide column (a box defaults to the parent's width unless
    // its parent is a row — the .hug anchor is that row).
    const root = try b.openNodeKeyed(.box, null);
    try b.store.setLayout(root, .width, .{ .dimension = .{ .value = 400, .unit = .px } });
    try b.store.setLayout(root, .height, .{ .dimension = .{ .value = 300, .unit = .px } });
    try b.store.setLayout(root, .flex_direction, .{ .keyword = .column });
    try ctx.mountOwned(Button, .{ .hug = true, .label = "OK" });
    b.close();

    const flexbox = @import("../layout/flexbox.zig");
    var engine = flexbox.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 400, 300);

    const anchor = registry.getNode(root).?.first_child;
    const btn: *Button = @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
    const w = registry.getNode(btn.root).?.geometry.width;
    try testing.expect(w > 0);
    try testing.expect(w < 400); // hugs padding+label, not the full column width
}

test "Button aria_label is the accessible name, over the glyph label" {
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

    // An icon-only button: its visible label is a glyph, so without aria_label a screen
    // reader would announce the glyph. With it, the button's accessible name is the word.
    const btn = try mountButton(&registry, &store, &router, &mounts, .{
        .label = "\u{25A4}",
        .aria_label = "Explorer",
    });

    const accessibility = @import("../core/accessibility.zig");
    try testing.expectEqualStrings("Explorer", accessibility.accessibleName(&registry, &store, btn.root));
}

test "Button background override is the base color; hover uses a brightened shade" {
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

    _ = try mountButton(&registry, &store, &router, &mounts, .{
        .label = "Run",
        .background = theme_mod.Color{ .r = 60, .g = 160, .b = 90 },
    });
    const anchor = registry.getNode(0).?.first_child;
    const boxn = registry.getNode(anchor).?.first_child;

    // Base = the override, not bg_surface.
    try testing.expectApproxEqAbs(@as(f32, 160.0 / 255.0), store.getStyle(boxn, .background).?.color.g, 0.01);
    // Hover = stateLayer overlay of white (dark theme) on the override.
    // 160 * 0.92 + 255 * 0.08 = 147.2 + 20.4 = 167.6 → ~167
    _ = router.route(.{ .name = "mouse_enter", .id = "", .node_id = boxn });
    const white_on = theme_mod.Color{ .r = 255, .g = 255, .b = 255 };
    const expected_g = theme_mod.Theme.stateLayer(.{ .r = 60, .g = 160, .b = 90 }, white_on, .hover).g;
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(expected_g)) / 255.0, store.getStyle(boxn, .background).?.color.g, 0.01);
}

test "Button: font_size overrides only the label size; text_style replaces the whole style" {
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

    const labelSize = struct {
        fn get(r: *reg.UIRegistry, s: *props.PropertyStore) f32 {
            const anchor = r.getNode(0).?.first_child;
            const boxn = r.getNode(anchor).?.first_child;
            return s.getStyle(r.getNode(boxn).?.first_child, .font_size).?.dimension.value;
        }
    }.get;

    // Default: label_large.
    _ = try mountButton(&registry, &store, &router, &mounts, .{ .label = "Attach" });
    try testing.expectApproxEqAbs(dark.typography.label_large.size, labelSize(&registry, &store), 0.01);

    // font_size: a tight two-button row fits its real label instead of an abbreviation.
    var r2 = reg.UIRegistry.init(a);
    defer r2.deinit();
    var s2 = props.PropertyStore.init(a);
    defer s2.deinit();
    s2.setRegistry(&r2);
    var m2 = component.MountTable.init(a);
    defer m2.deinit();
    r2.addNodeRemovedListener(&m2, component.MountTable.nodeRemovedListener);
    _ = try mountButton(&r2, &s2, &router, &m2, .{
        .label = "Adjuntar a proceso corriendo",
        .font_size = 13.5,
    });
    try testing.expectApproxEqAbs(@as(f32, 13.5), labelSize(&r2, &s2), 0.01);

    // text_style wins wholesale; font_size still overrides its size if both are set.
    var r3 = reg.UIRegistry.init(a);
    defer r3.deinit();
    var s3 = props.PropertyStore.init(a);
    defer s3.deinit();
    s3.setRegistry(&r3);
    var m3 = component.MountTable.init(a);
    defer m3.deinit();
    r3.addNodeRemovedListener(&m3, component.MountTable.nodeRemovedListener);
    _ = try mountButton(&r3, &s3, &router, &m3, .{
        .label = "Attach",
        .text_style = theme_mod.TextStyle{ .size = 20, .weight = .medium },
    });
    try testing.expectApproxEqAbs(@as(f32, 20), labelSize(&r3, &s3), 0.01);
}

test "Button: the label color is derived from the given background's luminance" {
    const a = testing.allocator;
    const labelColor = struct {
        fn get(r: *reg.UIRegistry, s: *props.PropertyStore) @FieldType(props.PropValue, "color") {
            const anchor = r.getNode(0).?.first_child;
            const boxn = r.getNode(anchor).?.first_child;
            return s.getStyle(r.getNode(boxn).?.first_child, .color).?.color;
        }
    }.get;

    var router = events.EventRouter.init(a);
    defer router.deinit();

    // A dark secondary fill must NOT get `text_on_accent` (near-black on near-black);
    // the contrast-derived on-color is light.
    var r1 = reg.UIRegistry.init(a);
    defer r1.deinit();
    var s1 = props.PropertyStore.init(a);
    defer s1.deinit();
    s1.setRegistry(&r1);
    var m1 = component.MountTable.init(a);
    defer m1.deinit();
    r1.addNodeRemovedListener(&m1, component.MountTable.nodeRemovedListener);
    _ = try mountButton(&r1, &s1, &router, &m1, .{ .label = "Cancel", .background = dark.surface_low });
    const on_dark = labelColor(&r1, &s1);
    try testing.expect(theme_mod.Theme.lightness(dark.surface_low) < 50); // premise
    try testing.expect(on_dark.r > 0.5 and on_dark.g > 0.5 and on_dark.b > 0.5);

    // A light fill flips to dark ink.
    var r2 = reg.UIRegistry.init(a);
    defer r2.deinit();
    var s2 = props.PropertyStore.init(a);
    defer s2.deinit();
    s2.setRegistry(&r2);
    var m2 = component.MountTable.init(a);
    defer m2.deinit();
    r2.addNodeRemovedListener(&m2, component.MountTable.nodeRemovedListener);
    _ = try mountButton(&r2, &s2, &router, &m2, .{
        .label = "Run",
        .background = theme_mod.Color{ .r = 235, .g = 235, .b = 235 },
    });
    const on_light = labelColor(&r2, &s2);
    try testing.expect(on_light.r < 0.5 and on_light.g < 0.5 and on_light.b < 0.5);

    // An explicit label_color always wins.
    var r3 = reg.UIRegistry.init(a);
    defer r3.deinit();
    var s3 = props.PropertyStore.init(a);
    defer s3.deinit();
    s3.setRegistry(&r3);
    var m3 = component.MountTable.init(a);
    defer m3.deinit();
    r3.addNodeRemovedListener(&m3, component.MountTable.nodeRemovedListener);
    _ = try mountButton(&r3, &s3, &router, &m3, .{
        .label = "Run",
        .background = theme_mod.Color{ .r = 235, .g = 235, .b = 235 },
        .label_color = theme_mod.Color{ .r = 255, .g = 0, .b = 0 },
    });
    const forced = labelColor(&r3, &s3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), forced.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.0), forced.g, 0.01);
}

test "Button: height and outline are settable as props — no wrapper box needed" {
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

    _ = try mountButton(&registry, &store, &router, &mounts, .{
        .label = "Open Project",
        .height = 40,
        .border_width = 1,
        .border_color = dark.border_color,
        .padding = component.EdgeInsets.symmetric(20, 0),
    });
    const anchor = registry.getNode(0).?.first_child;
    const boxn = registry.getNode(anchor).?.first_child;

    try testing.expectApproxEqAbs(@as(f32, 40), store.getLayout(boxn, .height).?.dimension.value, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), store.getStyle(boxn, .border_width).?.dimension.value, 0.01);
    try testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(dark.border_color.r)) / 255.0,
        store.getStyle(boxn, .border_color).?.color.r,
        0.01,
    );
    try testing.expectApproxEqAbs(@as(f32, 20), store.getLayout(boxn, .padding_left).?.dimension.value, 0.01);

    // The layout engine resolves the fixed height (a 40px design control).
    const flexbox = @import("../layout/flexbox.zig");
    var engine = flexbox.LayoutEngine.init(&registry, &store, null);
    engine.solve(0, 0, 0, 400, 300);
    try testing.expectApproxEqAbs(@as(f32, 40), registry.getNode(boxn).?.geometry.height, 0.01);
}

test "Button renders slotted content instead of the label; click still works" {
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

    // Composed content: an icon-ish glyph + a text, passed as one slot Child. The
    // tuple must outlive the button (the parent owns composed content).
    const kids = .{
        Text{ .content = "\u{2605}" }, // ★, stand-in for an Icon
        Text{ .content = "Save" },
    };
    _ = try mountButton(&registry, &store, &router, &mounts, .{
        .content = component.slot(&kids),
        .on_click = events.Handler{ .ptr = null, .call = Sink.onClick },
    });

    // anchor(1) → box(2, "button") → [text "★", text "Save"] — no single label node.
    const anchor = registry.getNode(0).?.first_child;
    const boxn = registry.getNode(anchor).?.first_child;
    try testing.expectEqualStrings("button", store.getModifier(boxn, .role).?.string);
    const first = registry.getNode(boxn).?.first_child;
    try testing.expectEqualStrings("\u{2605}", store.getTextContent(first).?);
    const second = registry.getNode(first).?.next_sibling;
    try testing.expectEqualStrings("Save", store.getTextContent(second).?);
    try testing.expectEqual(@as(reg.NodeId, reg.NULL_NODE), registry.getNode(second).?.next_sibling);

    // Click routes through the same typed handler as a plain-label button.
    _ = router.route(.{ .name = "click", .id = "", .node_id = boxn });
    try testing.expectEqual(@as(u32, 1), Sink.clicks);
}

test "A Button's label is optically centered in the *button* box, padding and anchors included" {
    // The end-to-end check the per-slot test can't make: it walks the real widget —
    // button root → mount anchor → text node — and asks where the ink lands relative
    // to the button's own box, so a stray padding, an anchor that doesn't center, or
    // a border would show up here as asymmetry.
    const a = testing.allocator;
    const ttf = try @import("test_support.zig").loadSystemFont(a);
    defer a.free(ttf);
    var atlas = try text_mod.FontAtlas.init(a, ttf, 72.0);
    defer atlas.deinit();

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

    // A label with both capitals and descenders — the case that reads wrong when the
    // centering is off, and the one measured against the real window.
    _ = try mountButton(&registry, &store, &router, &mounts, .{
        .label = "Adjuntar a proceso corriendo",
        .height = 40,
        .text_style = .{ .size = 13 },
    });

    const flexbox = @import("../layout/flexbox.zig");
    var engine = flexbox.LayoutEngine.init(&registry, &store, &atlas);
    engine.solve(0, 0, 0, 600, 300);

    const anchor = registry.getNode(0).?.first_child;
    const btn_id = registry.getNode(anchor).?.first_child;
    const btn = registry.getNode(btn_id).?.geometry;
    try testing.expectApproxEqAbs(@as(f32, 40), btn.height, 0.01);

    // Walk down to the text node (the button wraps its body in a mount anchor).
    const text_id = firstTextNode(&registry, &store, btn_id).?;
    const txt = registry.getNode(text_id).?.geometry;
    const lines = if (registry.getNode(text_id).?.text_layout) |tl| tl.lines.items.len else 1;
    const vl = atlas.verticalLayout(0, 13, txt.height, lines);

    // Gaps measured against the BUTTON's box, not the text node's.
    const gap_top = (txt.y + vl.cap_top) - btn.y;
    const gap_bottom = (btn.y + btn.height) - (txt.y + vl.baseline);
    try testing.expectApproxEqAbs(gap_top, gap_bottom, 0.5);

    // And the descenders hang below the baseline without leaving the button.
    try testing.expect(txt.y + vl.ink_bottom < btn.y + btn.height);
}

/// First `.text` node in `root`'s subtree, depth-first.
fn firstTextNode(registry: *reg.UIRegistry, store: *props.PropertyStore, root: reg.NodeId) ?reg.NodeId {
    if (store.getTextContent(root) != null) return root;
    var child = registry.getNode(root).?.first_child;
    while (child != reg.NULL_NODE) : (child = registry.getNode(child).?.next_sibling) {
        if (firstTextNode(registry, store, child)) |found| return found;
    }
    return null;
}

test "Button justify: .start puts the label at the button's x; the default still centers it" {
    const a = testing.allocator;
    const flexbox = @import("../layout/flexbox.zig");
    const ttf = try @import("test_support.zig").loadSystemFont(a);
    defer a.free(ttf);
    var atlas = try text_mod.FontAtlas.init(a, ttf, 72.0);
    defer atlas.deinit();
    for ([_]component.Justify{ .start, .center }) |j| {
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

        _ = try mountButton(&registry, &store, &router, &mounts, .{
            .label = "DOCUMENTS",
            .padding = EdgeInsets{},
            .justify = j,
        });
        var engine = flexbox.LayoutEngine.init(&registry, &store, &atlas);
        engine.solve(0, 0, 0, 200, 100);

        const anchor = registry.getNode(0).?.first_child;
        const btn_id = registry.getNode(anchor).?.first_child;
        const btn = registry.getNode(btn_id).?.geometry;
        try testing.expectApproxEqAbs(@as(f32, 200), btn.width, 0.01); // full width: all of it clickable
        const txt = registry.getNode(firstTextNode(&registry, &store, btn_id).?).?.geometry;
        try testing.expect(txt.width > 0 and txt.width < 200);
        switch (j) {
            .start => try testing.expectApproxEqAbs(btn.x, txt.x, 0.01),
            else => try testing.expectApproxEqAbs(btn.x + (btn.width - txt.width) / 2, txt.x, 0.5),
        }
    }
}
