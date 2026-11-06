//! Scrollbar — a standalone scrollbar driven entirely by caller-owned signals.
//!
//! The counterpart of Qt's `QScrollBar` / GTK's `GtkScrollbar`+`GtkAdjustment`:
//! the bar does not own or translate any content. It reads three lifted signals —
//! `offset`, `content_size`, `viewport_size` — paints a proportional thumb, and
//! writes `offset` back on drag, track click (page step) and wheel. That makes it
//! usable next to a view that only *draws* its visible slice (a virtualized
//! editor, a `VirtualList`) where `ScrollView` can't help, because the view knows
//! its logical sizes and the bar just mirrors them.
//!
//! ```zig
//! try ctx.mountOwned(fw.scrollbar.Scrollbar, .{
//!     .offset = &self.scroll_y,          // px, <= 0 (0 = start) — same as ScrollView.offset
//!     .content_size = &self.content_h,   // total logical size, px
//!     .viewport_size = &self.viewport_h, // visible size, px
//! });
//! ```
//!
//! Offset convention matches `ScrollView.offset` (a render translation in px,
//! `<= 0`), so one signal can be shared between the two. The bar clamps what it
//! writes; it never rewrites `offset` on its own when the sizes change — the owner
//! of the content re-clamps (it knows when its content shrank).
//!
//! The thumb's position is a render-only `scroll_offset_{x,y}` on the track, so
//! scrolling never triggers a layout solve. Drag-follow uses the engine's global
//! mouse_move/up (they carry no node id), registered in `build()` against the
//! root node and pruned by the node-removed hook on unmount — so the pointer can
//! leave the bar mid-drag.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;

pub const Orientation = enum { vertical, horizontal };

/// Inset between the track edge and the thumb, on every side.
pub const TRACK_PADDING: f32 = 2;

/// Pure scroll geometry, shared by the widget and its tests. All lengths in px;
/// `offset` is `<= 0`.
pub const Metrics = struct {
    /// Usable track length (track minus its padding).
    track: f32,
    thumb_len: f32,
    /// Thumb start, relative to the usable track.
    thumb_pos: f32,
    /// How far the content can scroll (`>= 0`); 0 = nothing to scroll.
    max_scroll: f32,

    pub fn compute(content: f32, viewport: f32, track: f32, offset: f32, min_thumb: f32) Metrics {
        const t = @max(0.0, track);
        const max_scroll = @max(0.0, content - viewport);
        if (max_scroll <= 0 or content <= 0 or t <= 0) {
            return .{ .track = t, .thumb_len = 0, .thumb_pos = 0, .max_scroll = 0 };
        }
        const prop_len = (viewport / content) * t;
        const thumb_len = @min(t, @max(@min(min_thumb, t), prop_len));
        const travel = t - thumb_len;
        const frac = std.math.clamp(-offset / max_scroll, 0, 1);
        return .{ .track = t, .thumb_len = thumb_len, .thumb_pos = frac * travel, .max_scroll = max_scroll };
    }

    /// Content px per track px of thumb movement (0 when the thumb can't move).
    pub fn contentPerTrackPx(self: Metrics) f32 {
        const travel = self.track - self.thumb_len;
        if (travel <= 0) return 0;
        return self.max_scroll / travel;
    }
};

pub const Scrollbar = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    /// Caller-owned scroll offset (px, `<= 0`; 0 = start, `-(content - viewport)`
    /// = end). Read to place the thumb, written on drag / track click / wheel.
    /// Omit to use the internal one (only useful in isolation).
    offset: ?*signals.Signal(f32) = null,
    /// Caller-owned total content length along the axis (px).
    content_size: ?*signals.Signal(f32) = null,
    /// Caller-owned visible length along the axis (px). Also the page step.
    viewport_size: ?*signals.Signal(f32) = null,
    orientation: Orientation = .vertical,
    /// Cross-axis thickness of the bar (px), padding included.
    thickness: f32 = 10,
    /// The thumb never gets shorter than this (px), however long the content.
    min_thumb: f32 = 20,
    /// Pixels per wheel notch over the bar (same factor as `ScrollView`).
    wheel_step: f32 = 20,

    // State (auto-created in onMount; preserved across rebuilds).
    own_offset: signals.Signal(f32) = undefined,
    own_content: signals.Signal(f32) = undefined,
    own_viewport: signals.Signal(f32) = undefined,
    /// Solved track length reported by `on_resize` (0 = not solved yet).
    track_len: signals.Signal(f32) = undefined,
    hovered: signals.Signal(bool) = undefined,
    dragging: signals.Signal(bool) = undefined,
    scope: signals.Scope = undefined,
    drag_start: f32 = 0,
    drag_start_offset: f32 = 0,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    registry: ?*reg.UIRegistry = null,
    root_node: reg.NodeId = reg.NULL_NODE,
    track_node: reg.NodeId = reg.NULL_NODE,
    thumb_node: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,

    pub fn onMount(self: *Scrollbar, allocator: std.mem.Allocator) void {
        self.own_offset = signals.Signal(f32).init(allocator, 0);
        self.own_content = signals.Signal(f32).init(allocator, 0);
        self.own_viewport = signals.Signal(f32).init(allocator, 0);
        self.track_len = signals.Signal(f32).init(allocator, 0);
        self.hovered = signals.Signal(bool).init(allocator, false);
        self.dragging = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
    }

    pub fn deinit(self: *Scrollbar) void {
        self.scope.deinit();
        self.dragging.deinit();
        self.hovered.deinit();
        self.track_len.deinit();
        self.own_viewport.deinit();
        self.own_content.deinit();
        self.own_offset.deinit();
    }

    fn offsetSig(self: *Scrollbar) *signals.Signal(f32) {
        return self.offset orelse &self.own_offset;
    }
    fn contentSig(self: *Scrollbar) *signals.Signal(f32) {
        return self.content_size orelse &self.own_content;
    }
    fn viewportSig(self: *Scrollbar) *signals.Signal(f32) {
        return self.viewport_size orelse &self.own_viewport;
    }

    fn vertical(self: *const Scrollbar) bool {
        return self.orientation == .vertical;
    }

    /// Usable track length: the solved track (reported or read from geometry),
    /// falling back to the viewport size before the first solve — a bar laid
    /// alongside its viewport is as long as it.
    fn trackLenNow(self: *Scrollbar) f32 {
        var len = self.track_len.peek();
        if (len <= 0) {
            if (self.registry) |r| {
                if (r.getNode(self.track_node)) |n| len = if (self.vertical()) n.geometry.height else n.geometry.width;
            }
        }
        if (len <= 0) len = self.viewportSig().peek();
        return @max(0.0, len - 2 * TRACK_PADDING);
    }

    fn metricsNow(self: *Scrollbar) Metrics {
        return Metrics.compute(self.contentSig().peek(), self.viewportSig().peek(), self.trackLenNow(), self.offsetSig().peek(), self.min_thumb);
    }

    fn setClamped(self: *Scrollbar, value: f32) void {
        const max_scroll = @max(0.0, self.contentSig().peek() - self.viewportSig().peek());
        self.offsetSig().set(std.math.clamp(value, -max_scroll, 0));
    }

    fn axis(self: *const Scrollbar, ev: events.Event) f32 {
        return if (self.vertical()) ev.y else ev.x;
    }

    fn onTrackResize(self: *Scrollbar, ev: events.Event) void {
        self.track_len.set(if (self.vertical()) ev.height else ev.width);
    }

    fn startDrag(self: *Scrollbar, pos: f32) void {
        self.drag_start = pos;
        self.drag_start_offset = self.offsetSig().peek();
        self.dragging.set(true);
    }

    fn onThumbDown(self: *Scrollbar, ev: events.Event) void {
        if (self.metricsNow().max_scroll <= 0) return;
        self.startDrag(self.axis(ev));
    }

    /// A press on the track: on the thumb starts a drag (covers hit-testing that
    /// lands on the track), before it pages toward the start, after it toward
    /// the end — one viewport per click.
    fn onTrackDown(self: *Scrollbar, ev: events.Event) void {
        const m = self.metricsNow();
        if (m.max_scroll <= 0) return;
        const registry = self.registry orelse return;
        const track = registry.getNode(self.track_node) orelse return;
        const origin = (if (self.vertical()) track.geometry.y else track.geometry.x) + TRACK_PADDING;
        const local = self.axis(ev) - origin;
        if (local >= m.thumb_pos and local <= m.thumb_pos + m.thumb_len) {
            if (!self.dragging.peek()) self.startDrag(self.axis(ev));
            return;
        }
        const page = self.viewportSig().peek();
        const cur = self.offsetSig().peek();
        self.setClamped(if (local < m.thumb_pos) cur + page else cur - page);
    }

    fn onWheel(self: *Scrollbar, ev: events.Event) void {
        self.setClamped(self.offsetSig().peek() + ev.scroll_delta * self.wheel_step);
    }

    fn onGlobal(self: *Scrollbar, ev: events.Event) void {
        if (std.mem.eql(u8, ev.name, "mouse_up")) {
            if (self.dragging.peek()) self.dragging.set(false);
        } else if (std.mem.eql(u8, ev.name, "mouse_move") and self.dragging.peek()) {
            const k = self.metricsNow().contentPerTrackPx();
            self.setClamped(self.drag_start_offset - (self.axis(ev) - self.drag_start) * k);
        }
    }

    fn onUp(self: *Scrollbar, _: events.Event) void {
        if (self.dragging.peek()) self.dragging.set(false);
    }

    pub fn build(self: *Scrollbar, ctx: *BuildContext) !void {
        self.store = ctx.builder.store;
        self.registry = ctx.builder.registry;
        self.theme = ctx.builder.theme;
        const v = self.vertical();

        self.root_node = try ctx.boxNode(.{
            .width = if (v) component.px(self.thickness) else component.pct(100),
            .height = if (v) component.pct(100) else component.px(self.thickness),
            .role = "scrollbar",
            .on_scroll = if (v) ctx.handler(self, onWheel) else null,
            .on_scroll_h = if (v) null else ctx.handler(self, onWheel),
        }, .{
            Body{ .bar = self },
        });
        // Along the axis the bar grows to its slot (a % length resolves to 0 under
        // the hugging mount anchor); across it, it is `thickness` wide.
        if (v) try growAlongColumn(ctx.builder.store, self.root_node);

        // Unconditional every build: onGlobal replaces in place per owner, and the
        // node-removed hook prunes it on unmount.
        if (ctx.router) |r| try r.onGlobal(self.root_node, self, onGlobal);
        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn thumbColor(self: *const Scrollbar, dragging: bool, hovered: bool) theme_mod.Color {
        const t = self.theme;
        // Themes that predate the state colors leave them transparent: fall back
        // to the resting thumb rather than make it vanish under the pointer.
        if (dragging and t.scrollbar_thumb_active.a != 0) return t.scrollbar_thumb_active;
        if ((dragging or hovered) and t.scrollbar_thumb_hover.a != 0) return t.scrollbar_thumb_hover;
        return t.scrollbar_thumb;
    }

    fn updateVisuals(self: *Scrollbar) void {
        const store = self.store orelse return;
        if (self.thumb_node == reg.NULL_NODE or self.track_node == reg.NULL_NODE) return;
        // Subscriptions: every input that moves or resizes the thumb.
        const offset = self.offsetSig().get();
        const content = self.contentSig().get();
        const viewport = self.viewportSig().get();
        _ = self.track_len.get();
        const dragging = self.dragging.get();
        const hovered = self.hovered.get();

        const m = Metrics.compute(content, viewport, self.trackLenNow(), offset, self.min_thumb);
        const len_key: props.LayoutKey = if (self.vertical()) .height else .width;
        const off_key: props.LayoutKey = if (self.vertical()) .scroll_offset_y else .scroll_offset_x;
        // Length only changes with the sizes (no-op filtered while scrolling); the
        // position rides the track's render-only offset.
        store.setLayout(self.thumb_node, len_key, .{ .dimension = .{ .value = m.thumb_len, .unit = .px } }) catch {};
        store.setLayout(self.track_node, off_key, .{ .dimension = .{ .value = m.thumb_pos, .unit = .px } }) catch {};
        const c = self.thumbColor(dragging, hovered);
        store.setStyle(self.thumb_node, .background, props.PropValue.rgbA(c.r, c.g, c.b, @as(f32, @floatFromInt(c.a)) / 255.0)) catch {};
    }
};

fn growAlongColumn(store: *props.PropertyStore, id: reg.NodeId) !void {
    try store.setLayout(id, .height, .{ .keyword = .auto });
    try store.setLayout(id, .flex_grow, .{ .number = 1 });
}

/// Track (padding + background, the page-click target) and thumb.
const Body = struct {
    bar: *Scrollbar,

    pub fn build(self: *Body, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const bar = self.bar;
        const t = b.theme;
        const v = bar.vertical();

        const track = try ctx.boxNode(.{
            .width = component.pct(100),
            .height = component.pct(100),
            .direction = @as(props.Keyword, if (v) .column else .row),
            .radius = t.radius_base,
            .on_mouse_down = ctx.handler(bar, Scrollbar.onTrackDown),
            .on_mouse_up = ctx.handler(bar, Scrollbar.onUp),
            .on_resize = ctx.handler(bar, Scrollbar.onTrackResize),
        }, .{
            Thumb{ .bar = bar },
        });
        bar.track_node = track;
        if (v) try growAlongColumn(b.store, track);
        try b.padding(track, TRACK_PADDING, TRACK_PADDING, TRACK_PADDING, TRACK_PADDING);
        try b.overflowHidden(track);
        try b.backgroundAlpha(track, t.scrollbar_track.r, t.scrollbar_track.g, t.scrollbar_track.b, @as(f32, @floatFromInt(t.scrollbar_track.a)) / 255.0);
    }
    pub fn deinit(_: *Body) void {}
};

const Thumb = struct {
    bar: *Scrollbar,

    pub fn build(self: *Thumb, ctx: *BuildContext) !void {
        const bar = self.bar;
        const v = bar.vertical();
        const m = bar.metricsNow();
        const t = ctx.builder.theme;
        const thumb = try ctx.boxNode(.{
            .width = if (v) component.pct(100) else component.px(m.thumb_len),
            .height = if (v) component.px(m.thumb_len) else component.pct(100),
            .radius = t.radius_base,
            .on_mouse_down = ctx.handler(bar, Scrollbar.onThumbDown),
            .on_mouse_up = ctx.handler(bar, Scrollbar.onUp),
            .on_hover = ctx.signalSetter(&bar.hovered),
        }, .{});
        bar.thumb_node = thumb;
        // Without a definite flex-basis the thumb would shrink to the track.
        try ctx.builder.store.setLayout(thumb, .flex_shrink, .{ .number = 0 });
        const c = t.scrollbar_thumb;
        try ctx.builder.backgroundAlpha(thumb, c.r, c.g, c.b, @as(f32, @floatFromInt(c.a)) / 255.0);
    }
    pub fn deinit(_: *Thumb) void {}
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Harness = @import("test_support.zig").Harness;

test "Metrics: proportional thumb, min length, end position, nothing to scroll" {
    // 1000 content, 250 viewport, 200 track → 50px thumb, 150 travel, 750 max.
    const m = Metrics.compute(1000, 250, 200, 0, 20);
    try testing.expectApproxEqAbs(@as(f32, 50), m.thumb_len, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), m.thumb_pos, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), m.contentPerTrackPx(), 0.001);
    // At the end the thumb sits flush with the track's end.
    const end = Metrics.compute(1000, 250, 200, -750, 20);
    try testing.expectApproxEqAbs(@as(f32, 150), end.thumb_pos, 0.001);
    // Huge content: thumb clamps to min_thumb and still ends flush.
    const huge = Metrics.compute(1_000_000, 250, 200, -999_750, 20);
    try testing.expectApproxEqAbs(@as(f32, 20), huge.thumb_len, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 180), huge.thumb_pos, 0.001);
    // Content fits → no thumb.
    try testing.expectEqual(@as(f32, 0), Metrics.compute(100, 250, 200, 0, 20).thumb_len);
}

const Fixture = struct {
    env: Harness,
    offset: signals.Signal(f32),
    content: signals.Signal(f32),
    viewport: signals.Signal(f32),

    /// Heap-allocated so the signal pointers handed to the widget stay put.
    fn create(orientation: Orientation) !*Fixture {
        const a = testing.allocator;
        const f = try a.create(Fixture);
        f.offset = signals.Signal(f32).init(a, 0);
        f.content = signals.Signal(f32).init(a, 1000);
        f.viewport = signals.Signal(f32).init(a, 250);
        f.env = Harness.init(a);
        f.env.wire();
        var b = component.UIBuilder.init(&f.env.registry, &f.env.store);
        b.theme = theme_mod.Theme.dark();
        var ctx = BuildContext{ .builder = &b, .router = &f.env.router, .mounts = &f.env.mounts };
        const root = try b.openNodeKeyed(.box, null);
        // The bar sits beside its view: a row for a vertical bar, a column for a
        // horizontal one — the cross-axis stretch gives it its length.
        try b.store.setLayout(root, .flex_direction, .{ .keyword = if (orientation == .vertical) .row else .column });
        if (orientation == .vertical) {
            try b.width(root, 10, .px);
            try b.height(root, 204, .px);
        } else {
            try b.width(root, 204, .px);
            try b.height(root, 10, .px);
        }
        try ctx.mountOwned(Scrollbar, .{
            .offset = &f.offset,
            .content_size = &f.content,
            .viewport_size = &f.viewport,
            .orientation = orientation,
        });
        b.close();
        // Two frames: the first reports the track size, the second lays out
        // the thumb length that report produced.
        _ = try f.env.frame(0, 400, 400);
        _ = try f.env.frame(0, 400, 400);
        return f;
    }

    fn destroy(f: *Fixture) void {
        // Widget first (its effect unsubscribes), then the signals it reads.
        f.env.deinit();
        f.viewport.deinit();
        f.content.deinit();
        f.offset.deinit();
        testing.allocator.destroy(f);
    }

    fn bar(f: *Fixture) *Scrollbar {
        const anchor = f.env.registry.getNode(0).?.first_child;
        return @ptrCast(@alignCast(f.env.mounts.get(anchor).?.component_ptr));
    }
};

test "Scrollbar: thumb geometry follows the caller's offset and sizes" {
    const f = try Fixture.create(.vertical);
    defer f.destroy();
    const sb = f.bar();

    // 204 track - 4 padding = 200 usable → 50px thumb at the top.
    var g = f.env.geom(sb.thumb_node);
    try testing.expectApproxEqAbs(@as(f32, 50), g.height, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 2), g.y, 0.5);

    // Caller scrolls to the end → thumb flush with the bottom (2 + 150).
    f.offset.set(-750);
    try testing.expectApproxEqAbs(@as(f32, 152), f.env.geom(sb.thumb_node).y, 0.5);

    // Content grows → thumb shrinks (no rebuild needed).
    f.offset.set(0);
    f.content.set(2000);
    f.env.solve(0, 400, 400);
    g = f.env.geom(sb.thumb_node);
    try testing.expectApproxEqAbs(@as(f32, 25), g.height, 0.5);
}

test "Scrollbar: dragging the thumb writes offset, follows the pointer off the bar, clamps" {
    const f = try Fixture.create(.vertical);
    defer f.destroy();
    const sb = f.bar();

    f.env.route(.{ .name = "mouse_down", .id = "", .node_id = sb.thumb_node, .x = 5, .y = 10 });
    try testing.expect(sb.dragging.peek());
    // 30 track px × (750 / 150) = 150 content px. x far outside the bar: global.
    f.env.route(.{ .name = "mouse_move", .id = "", .x = 900, .y = 40 });
    try testing.expectApproxEqAbs(@as(f32, -150), f.offset.peek(), 0.01);
    // Way past the end clamps at -(content - viewport).
    f.env.route(.{ .name = "mouse_move", .id = "", .x = 900, .y = 5000 });
    try testing.expectApproxEqAbs(@as(f32, -750), f.offset.peek(), 0.01);
    f.env.route(.{ .name = "mouse_up", .id = "" });
    try testing.expect(!sb.dragging.peek());
    // No drag → moves are ignored.
    f.env.route(.{ .name = "mouse_move", .id = "", .y = 0 });
    try testing.expectApproxEqAbs(@as(f32, -750), f.offset.peek(), 0.01);
}

test "Scrollbar: clicking the track pages by one viewport toward the click" {
    const f = try Fixture.create(.vertical);
    defer f.destroy();
    const sb = f.bar();

    // Below the thumb (thumb spans y 2..52) → one page down.
    f.env.route(.{ .name = "mouse_down", .id = "", .node_id = sb.track_node, .y = 180 });
    try testing.expectApproxEqAbs(@as(f32, -250), f.offset.peek(), 0.01);
    try testing.expect(!sb.dragging.peek());
    // Thumb now at 2 + 50 = 52..102; click above it → back up a page.
    f.env.route(.{ .name = "mouse_down", .id = "", .node_id = sb.track_node, .y = 20 });
    try testing.expectApproxEqAbs(@as(f32, 0), f.offset.peek(), 0.01);
    // A track press that lands on the thumb starts a drag instead of paging.
    f.env.route(.{ .name = "mouse_down", .id = "", .node_id = sb.track_node, .y = 30 });
    try testing.expect(sb.dragging.peek());
    try testing.expectApproxEqAbs(@as(f32, 0), f.offset.peek(), 0.01);
}

test "Scrollbar: hover and press paint the theme's thumb states" {
    const f = try Fixture.create(.vertical);
    defer f.destroy();
    const sb = f.bar();
    const t = theme_mod.Theme.dark();
    const bg = struct {
        fn get(fx: *Fixture, id: reg.NodeId) f32 {
            return fx.env.store.getStyle(id, .background).?.color.r * 255.0;
        }
    }.get;

    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(t.scrollbar_thumb.r)), bg(f, sb.thumb_node), 0.5);
    f.env.route(.{ .name = "mouse_enter", .id = "", .node_id = sb.thumb_node });
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(t.scrollbar_thumb_hover.r)), bg(f, sb.thumb_node), 0.5);
    f.env.route(.{ .name = "mouse_down", .id = "", .node_id = sb.thumb_node, .y = 10 });
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(t.scrollbar_thumb_active.r)), bg(f, sb.thumb_node), 0.5);
    f.env.route(.{ .name = "mouse_up", .id = "" });
    f.env.route(.{ .name = "mouse_leave", .id = "", .node_id = sb.thumb_node });
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(t.scrollbar_thumb.r)), bg(f, sb.thumb_node), 0.5);
}

test "Scrollbar: horizontal orientation lays the thumb along x and wheels with scroll_h" {
    const f = try Fixture.create(.horizontal);
    defer f.destroy();
    const sb = f.bar();

    const g = f.env.geom(sb.thumb_node);
    try testing.expectApproxEqAbs(@as(f32, 50), g.width, 0.5);
    f.offset.set(-750);
    try testing.expectApproxEqAbs(@as(f32, 152), f.env.geom(sb.thumb_node).x, 0.5);

    f.env.route(.{ .name = "scroll_h", .id = "", .node_id = sb.root_node, .scroll_delta = 2 });
    try testing.expectApproxEqAbs(@as(f32, -710), f.offset.peek(), 0.01);
}

test "Scrollbar: global drag handler is removed on unmount" {
    const f = try Fixture.create(.vertical);
    defer f.destroy();
    try testing.expectEqual(@as(usize, 1), f.env.router.global_handlers.items.len);
    var b = component.UIBuilder.init(&f.env.registry, &f.env.store);
    try b.rootAt(0);
    b.close();
    try testing.expectEqual(@as(usize, 0), f.env.router.global_handlers.items.len);
}
