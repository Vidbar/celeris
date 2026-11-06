//! ScrollView — reactive component migrated to the canonical pattern.
//!
//! Framework-owned via `ctx.mountOwned(ScrollView, .{ .fill = true, .content = …,
//! .content_height = … })`: no `init`/`register`/`deinit`/action-id in user code.
//! `content` is a caller-owned `component.Child` prop (ScrollView hosts any
//! component, e.g. TextArea or TreeList — the caller frees what it wraps).
//! `scroll_offset` is a `Signal(f32)` auto-created in `onMount`; an effect writes
//! the viewport's (and track's) `scroll_offset_y` — a render-only translation of
//! the resolved geometry — so scrolling never triggers a global layout solve.
//!
//! The wheel arrives through the new typed `on_scroll` prop (`EventKind.scroll`,
//! routed by node id — the engine walks the hit chain to the nearest `scrollable`
//! node and emits with that node's id). The scrollbar is a mounted
//! `fw.scrollbar.Scrollbar` sharing the offset signal (thumb drag, track paging,
//! hover/pressed states live there); this view feeds it the effective heights.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");
const scrollbar_mod = @import("scrollbar.zig");

const BuildContext = component.BuildContext;

/// Thickness of the mounted `Scrollbar`; the rest of `SCROLLBAR_WIDTH` is its gap.
const BAR_THICKNESS: f32 = 10;

/// Total width the scrollbar channel occupies: a 10px track plus its 4px gap. The
/// track is a flex SIBLING of the viewport, so this width is subtracted from the
/// content — the thumb never overlaps a row.
pub const SCROLLBAR_WIDTH: f32 = 14;

/// `ScrollView.viewport_height`'s default; leaving it untouched means "use the
/// solved viewport height".
pub const DEFAULT_VIEWPORT_HEIGHT: f32 = 600;

/// How the scrollbar channel is reserved (CSS `scrollbar-gutter`).
pub const Gutter = enum {
    /// Reserve the channel only while the content actually overflows. Content is
    /// wider when it fits, and reflows by `SCROLLBAR_WIDTH` when it starts to.
    auto,
    /// Always reserve the channel, scrollbar or not, so the content width never
    /// shifts as rows come and go.
    stable,
};

pub const ScrollView = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    /// Hosted content (caller-owned; ScrollView never frees it).
    content: ?component.Child = null,
    /// Estimated total content height (px). Caller updates when content changes
    /// (re-applied on rebuild). A future version may read it from resolved geometry instead.
    content_height: f32 = 1000,
    /// Visible viewport height (px) used for scroll clamping and the thumb. When
    /// `fill` is set, or this is left at its default, the viewport's **solved**
    /// height wins once a layout has run (like `content_height`) — so a fill slot
    /// shorter than 600px still scrolls its last rows into view. An explicit
    /// value without `fill` is honored as-is (backward compatible).
    viewport_height: f32 = DEFAULT_VIEWPORT_HEIGHT,
    /// Mirrors the reserved `.fill` mount prop (which also sizes the anchor to
    /// fill its parent): the viewport's real size is its solved geometry.
    fill: bool = false,
    /// Optional caller-owned scroll offset (two-way, translation in px; `<= 0`,
    /// 0 = top, `-(content_h - viewport_h)` = bottom). The widget reads it to
    /// translate the viewport and writes it on wheel/drag; the caller can set it to
    /// scroll programmatically (e.g. share it with a TreeView's `.scroll_offset` for
    /// ensure-visible). The widget clamps what it writes; a value the caller pushes
    /// out of range is re-clamped on the next wheel/drag. Omit to use the internal
    /// `scroll_offset`.
    offset: ?*signals.Signal(f32) = null,
    /// Whether the scrollbar channel is reserved when there is nothing to scroll.
    /// `.stable` keeps content-box width constant across content changes.
    gutter: Gutter = .auto,

    // State (auto-created in onMount; preserved across rebuilds). `scroll_offset` is
    // the fallback when the caller passes no `offset` signal.
    scroll_offset: signals.Signal(f32) = undefined,
    /// Solved heights reported by `on_resize` (0 = not solved yet). The visuals
    /// effect subscribes to both, so a window resize or content growth updates
    /// the thumb and re-clamps the offset without waiting for a wheel event.
    viewport_h_sig: signals.Signal(f32) = undefined,
    content_h_sig: signals.Signal(f32) = undefined,
    /// The effective content / viewport heights (solved when known, else the
    /// props), mirrored for the `Scrollbar` this view mounts — it reads sizes
    /// from signals, and the raw `on_resize` ones are 0 until the first solve.
    bar_content_sig: signals.Signal(f32) = undefined,
    bar_viewport_sig: signals.Signal(f32) = undefined,
    scope: signals.Scope = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    registry: ?*reg.UIRegistry = null,
    router: ?*events.EventRouter = null,
    viewport_node: reg.NodeId = reg.NULL_NODE,
    wrapper_node: reg.NodeId = reg.NULL_NODE,
    track_node: reg.NodeId = reg.NULL_NODE,
    thumb_node: reg.NodeId = reg.NULL_NODE,
    bar_slot: reg.NodeId = reg.NULL_NODE,
    /// Mount anchor of the `Scrollbar` (NULL while the content fits).
    bar_anchor: reg.NodeId = reg.NULL_NODE,
    mounts: ?*component.MountTable = null,
    theme: theme_mod.Theme = undefined,
    bound: bool = false,
    bar_bound: bool = false,

    pub fn onMount(self: *ScrollView, allocator: std.mem.Allocator) void {
        self.scroll_offset = signals.Signal(f32).init(allocator, 0);
        self.viewport_h_sig = signals.Signal(f32).init(allocator, 0);
        self.content_h_sig = signals.Signal(f32).init(allocator, 0);
        self.bar_content_sig = signals.Signal(f32).init(allocator, 0);
        self.bar_viewport_sig = signals.Signal(f32).init(allocator, 0);
        self.scope = signals.Scope.init(allocator);
    }

    pub fn deinit(self: *ScrollView) void {
        self.scope.deinit();
        self.bar_viewport_sig.deinit();
        self.bar_content_sig.deinit();
        self.content_h_sig.deinit();
        self.viewport_h_sig.deinit();
        self.scroll_offset.deinit();
    }

    fn onViewportResize(self: *ScrollView, ev: events.Event) void {
        self.viewport_h_sig.set(ev.height);
        self.syncBarSizes();
        self.setScrollClamped(self.offsetSig().peek());
    }

    fn onContentResize(self: *ScrollView, ev: events.Event) void {
        // Safe to observe this hug-sized node: the handler only writes the thumb
        // and the render-only offset, neither of which changes the content's size.
        self.content_h_sig.set(ev.height);
        self.syncBarSizes();
        self.setScrollClamped(self.offsetSig().peek());
    }

    /// Pushes the effective heights to the scrollbar's size signals (only on change).
    fn syncBarSizes(self: *ScrollView) void {
        const c = self.contentHeightNow();
        const v = self.viewportHeightNow();
        if (self.bar_content_sig.peek() != c) self.bar_content_sig.set(c);
        if (self.bar_viewport_sig.peek() != v) self.bar_viewport_sig.set(v);
    }

    /// The active offset signal: caller-owned if provided, else the internal one.
    fn offsetSig(self: *ScrollView) *signals.Signal(f32) {
        return self.offset orelse &self.scroll_offset;
    }

    fn onScroll(self: *ScrollView, ev: events.Event) void {
        self.setScrollClamped(self.offsetSig().peek() + ev.scroll_delta * 20.0);
    }

    /// The mounted scrollbar (null while the content fits).
    pub fn bar(self: *ScrollView) ?*scrollbar_mod.Scrollbar {
        const mounts = self.mounts orelse return null;
        if (self.bar_anchor == reg.NULL_NODE) return null;
        const rec = mounts.get(self.bar_anchor) orelse return null;
        return @ptrCast(@alignCast(rec.component_ptr));
    }

    /// Prefers the resolved layout height of the content wrapper over the
    /// caller's `content_height` estimate (available once a solve has run).
    fn contentHeightNow(self: *const ScrollView) f32 {
        const reported = self.content_h_sig.peek();
        if (reported > 0) return reported;
        if (self.registry) |r| {
            if (r.getNode(self.wrapper_node)) |node| {
                if (node.geometry.height > 0) return node.geometry.height;
            }
        }
        return self.content_height;
    }

    /// The height the viewport actually occupies. With `fill` (or the
    /// default prop) it's the solved geometry of the viewport box once a solve
    /// has run; otherwise, and before the first solve, the `viewport_height` prop.
    fn viewportHeightNow(self: *const ScrollView) f32 {
        if (self.fill or self.viewport_height == DEFAULT_VIEWPORT_HEIGHT) {
            const reported = self.viewport_h_sig.peek();
            if (reported > 0) return reported;
            if (self.registry) |r| {
                if (r.getNode(self.viewport_node)) |node| {
                    if (node.geometry.height > 0) return node.geometry.height;
                }
            }
        }
        return self.viewport_height;
    }

    fn setScrollClamped(self: *ScrollView, value: f32) void {
        var next = value;
        if (next > 0) next = 0;
        const min_scroll = @min(0.0, self.viewportHeightNow() - self.contentHeightNow());
        if (next < min_scroll) next = min_scroll;
        self.offsetSig().set(next);
    }

    /// Reads the exact layout height of the content from the resolved geometry
    /// and jumps the scroll position to the bottom. Must be called after the
    /// layout phase completes (e.g. in a next-frame postTask).
    pub fn scrollToEnd(self: *ScrollView) void {
        if (self.registry) |r| {
            if (r.getNode(self.wrapper_node)) |node| {
                self.content_height = node.geometry.height;
                self.syncBarSizes();
                const max_offset = -(@max(self.content_height - self.viewportHeightNow(), 0));
                self.offsetSig().set(max_offset);
            }
        }
    }

    fn hasScrollbar(self: *const ScrollView) bool {
        return self.contentHeightNow() > self.viewportHeightNow();
    }

    /// Effect: when a resize (window or content) flips whether a scrollbar is
    /// needed, rebuild just the bar slot — never the viewport or the hosted
    /// content. Subscribes to the two `on_resize` signals only.
    fn syncBar(self: *ScrollView) void {
        _ = self.viewport_h_sig.get();
        _ = self.content_h_sig.get();
        const want = self.hasScrollbar();
        const have = self.bar_anchor != reg.NULL_NODE;
        if (want == have) return;
        const store = self.store orelse return;
        const registry = self.registry orelse return;
        if (self.bar_slot == reg.NULL_NODE) return;

        const prev = signals.untrackedBegin();
        defer signals.untrackedEnd(prev);
        var b = component.UIBuilder.init(registry, store);
        b.theme = self.theme;
        b.rootAt(self.bar_slot) catch return;
        var ctx = BuildContext{ .builder = &b, .router = self.router, .mounts = self.mounts };
        buildBar(self, &ctx) catch {};
        b.close();
        registry.markLayoutDirty(self.bar_slot);
        self.updateVisuals();
    }

    pub fn build(self: *ScrollView, ctx: *BuildContext) !void {
        self.store = ctx.builder.store;
        self.registry = ctx.builder.registry;
        self.router = ctx.router;
        self.mounts = ctx.mounts;
        self.theme = ctx.builder.theme;
        // Props may have changed the fallbacks (content_height / viewport_height).
        self.syncBarSizes();

        // Outer row: viewport + scrollbar side-by-side.
        try ctx.box(.{
            .width = component.pct(100),
            .height = component.pct(100),
            .direction = .row,
        }, .{
            Body{ .sv = self },
        });

        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
        if (!self.bar_bound) {
            _ = try self.scope.createEffect(self, syncBar);
            self.bar_bound = true;
        }
    }

    fn updateVisuals(self: *ScrollView) void {
        const store = self.store orelse return;
        if (self.viewport_node == reg.NULL_NODE) return;
        const offset = self.offsetSig().get();
        // Scroll is a render-only translation — `scroll_offset_y` shifts the
        // viewport's children (wrapper + content) without a global layout solve.
        // The thumb is the mounted `Scrollbar`'s own effect.
        store.setLayout(self.viewport_node, .scroll_offset_y, .{ .dimension = .{ .value = offset, .unit = .px } }) catch {};
    }
};

/// Viewport (clips + owns the typed `on_scroll`), offset wrapper, hosted content,
/// and scrollbar track/thumb. The scroll-driven pieces (wrapper margin, thumb
/// height/position) are written by the effect; structure lives here. The thumb's
/// press handlers use the same declarative props path as the viewport's wheel.
const Body = struct {
    sv: *ScrollView,

    pub fn build(self: *Body, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const sv = self.sv;

        // Viewport — clips overflow; the wheel routes here by node id.
        const viewport = try ctx.boxNode(.{
            .width = 0,
            .grow = 1,
            .height = component.pct(100),
            .on_scroll = ctx.handler(sv, ScrollView.onScroll),
            .on_resize = ctx.handler(sv, ScrollView.onViewportResize),
        }, .{
            Wrapper{ .sv = sv },
        });
        sv.viewport_node = viewport;
        try b.overflowHidden(viewport);

        // Scrollbar slot: hugs whatever `buildBar` puts in it (track, stable-gutter
        // spacer, or nothing) and is the root `syncBar` rebuilds on a flip.
        const slot = try b.openNodeKeyed(.box, null);
        sv.bar_slot = slot;
        try b.height(slot, 100, .percent);
        try buildBar(sv, ctx);
        b.close();
    }
    pub fn deinit(_: *Body) void {}
};

/// The scrollbar track + thumb, the stable-gutter spacer, or nothing — into the
/// currently open parent (the bar slot).
fn buildBar(sv: *ScrollView, ctx: *BuildContext) !void {
    const b = ctx.builder;
    {
        sv.track_node = reg.NULL_NODE;
        sv.thumb_node = reg.NULL_NODE;
        sv.bar_anchor = reg.NULL_NODE;
        if (sv.hasScrollbar()) {
            // `.fill` sizes the Scrollbar's mount anchor to this holder, so its
            // length is definite (a hugging anchor would collapse onto the thumb).
            // The 4px gap plus the bar's thickness is the SCROLLBAR_WIDTH channel.
            const holder = try b.openNodeKeyed(.box, null);
            try b.width(holder, BAR_THICKNESS, .px);
            try b.store.setLayout(holder, .flex_grow, .{ .number = 1 });
            try b.marginLeft(holder, SCROLLBAR_WIDTH - BAR_THICKNESS);
            try ctx.mountOwned(scrollbar_mod.Scrollbar, .{
                .fill = true,
                .offset = sv.offsetSig(),
                .content_size = &sv.bar_content_sig,
                .viewport_size = &sv.bar_viewport_sig,
                .thickness = BAR_THICKNESS,
            });
            b.close(); // holder
            if (b.registry.getNode(holder)) |n| sv.bar_anchor = n.first_child;
            if (sv.bar()) |sb| {
                sv.track_node = sb.track_node;
                sv.thumb_node = sb.thumb_node;
            }
        } else if (sv.gutter == .stable) {
            // No scrollbar, but the caller asked for a stable content width: hold the
            // channel open with an empty (transparent) spacer of the same width.
            const spacer = try b.openNodeKeyed(.box, null);
            try b.width(spacer, SCROLLBAR_WIDTH, .px);
            try b.height(spacer, 100, .percent);
            b.close();
        }
    }
}

/// The scroll-offset wrapper — its `margin_top` (effect-driven) is the scroll.
const Wrapper = struct {
    sv: *ScrollView,
    pub fn build(self: *Wrapper, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const wrapper = try b.openNodeKeyed(.box, null);
        self.sv.wrapper_node = wrapper;
        try b.width(wrapper, 100, .percent);
        // Observe the content's solved height.
        try ctx.onResize(wrapper, ctx.handler(self.sv, ScrollView.onContentResize));
        // No scrollbar padding here: the track is a sibling of the viewport, so the
        // channel is already outside this box. The 20px that used to live here
        // double-counted it and shaved that much off every full-width row.
        if (self.sv.content) |c| try c.build(ctx);
        b.close(); // wrapper
    }
    pub fn deinit(_: *Wrapper) void {}
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A minimal stub component (fixed-height box) hosted as a `component.Child`.
const StubChild = struct {
    pub fn build(_: *StubChild, ctx: *BuildContext) !void {
        const n = try ctx.builder.openNodeKeyed(.box, null);
        try ctx.builder.height(n, 100, .px);
        ctx.builder.close();
    }
    pub fn deinit(_: *StubChild) void {}
};

const TestEnv = @import("test_support.zig").Harness;

fn mountScrollView(env: *TestEnv, init_props: anytype) !*ScrollView {
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = theme_mod.Theme.dark();
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(ScrollView, init_props);
    b.close();
    const anchor = env.registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));
}

test "ScrollView (mountOwned) typed wheel updates wrapper and thumb margin_top, clamped" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var stub = StubChild{};
    const sv = try mountScrollView(&env, .{
        .content = component.childOf(StubChild, &stub),
        .content_height = 1000,
        .viewport_height = 600,
    });

    // Scrollbar present (1000 > 600), thumb created.
    try testing.expect(sv.thumb_node != reg.NULL_NODE);
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getLayout(sv.viewport_node, .scroll_offset_y).?.dimension.value, 0.001);

    // Acceptance: scrolling must not trigger a global layout solve. Clear the
    // dirty flags left by the build, then wheel.
    env.registry.global_layout_dirty = false;
    env.registry.global_render_dirty = false;
    const wrapper_y0 = env.registry.getNode(sv.wrapper_node).?.geometry.y;

    // Wheel down (delta -1), routed by node id — no strings.
    _ = env.router.route(.{ .name = "scroll", .id = "", .node_id = sv.viewport_node, .scroll_delta = -1.0 });
    try testing.expectApproxEqAbs(@as(f32, -20.0), env.store.getLayout(sv.viewport_node, .scroll_offset_y).?.dimension.value, 0.001);
    // Render-only: geometry shifted incrementally, no layout invalidation.
    try testing.expect(!env.registry.global_layout_dirty);
    try testing.expect(env.registry.global_render_dirty);
    try testing.expectApproxEqAbs(wrapper_y0 - 20.0, env.registry.getNode(sv.wrapper_node).?.geometry.y, 0.001);
    // Thumb rides the track's offset proportionally: (20/1000)*(600 - 4) = 11.92.
    try testing.expectApproxEqAbs(@as(f32, 11.92), env.store.getLayout(sv.track_node, .scroll_offset_y).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 11.92), env.registry.getNode(sv.thumb_node).?.geometry.y, 0.001);

    // Wheel up past the top clamps at 0.
    _ = env.router.route(.{ .name = "scroll", .id = "", .node_id = sv.viewport_node, .scroll_delta = 5.0 });
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getLayout(sv.viewport_node, .scroll_offset_y).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(wrapper_y0, env.registry.getNode(sv.wrapper_node).?.geometry.y, 0.001);

    // Wheel far down clamps at viewport-content = -400.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = env.router.route(.{ .name = "scroll", .id = "", .node_id = sv.viewport_node, .scroll_delta = -1.0 });
    }
    try testing.expectApproxEqAbs(@as(f32, -400.0), sv.scroll_offset.peek(), 0.001);
}

test "ScrollView binds a caller-owned offset signal: set drives the viewport, wheel writes it back" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();

    // Caller owns the offset; declared before `mounts` so LIFO defers tear the
    // widget's effect down (unsubscribing) before the signal is freed.
    var offset = signals.Signal(f32).init(a, -40);
    defer offset.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    var stub = StubChild{};
    var b = component.UIBuilder.init(&registry, &store);
    b.theme = theme_mod.Theme.dark();
    var ctx = BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(ScrollView, .{
        .content = component.childOf(StubChild, &stub),
        .content_height = 1000,
        .viewport_height = 600,
        .offset = &offset,
    });
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    const sv: *ScrollView = @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));

    // Initial viewport translation comes from the caller's signal (-40), not 0.
    try testing.expectApproxEqAbs(@as(f32, -40.0), store.getLayout(sv.viewport_node, .scroll_offset_y).?.dimension.value, 0.001);

    // Caller scrolls programmatically → the viewport follows (ensure-visible path).
    offset.set(-120);
    try testing.expectApproxEqAbs(@as(f32, -120.0), store.getLayout(sv.viewport_node, .scroll_offset_y).?.dimension.value, 0.001);

    // Wheel writes back into the caller's signal (clamped): from -120, wheel up
    // (+1 → +20 px) → -100.
    _ = router.route(.{ .name = "scroll", .id = "", .node_id = sv.viewport_node, .scroll_delta = 1.0 });
    try testing.expectApproxEqAbs(@as(f32, -100.0), offset.peek(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -100.0), store.getLayout(sv.viewport_node, .scroll_offset_y).?.dimension.value, 0.001);
}

test "ScrollView with short content has no scrollbar" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var stub = StubChild{};
    const sv = try mountScrollView(&env, .{
        .content = component.childOf(StubChild, &stub),
        .content_height = 100,
        .viewport_height = 600,
    });
    try testing.expect(sv.thumb_node == reg.NULL_NODE);
}

test "The scrollbar occupies its own channel; gutter .stable keeps it reserved" {
    const contentWidth = struct {
        /// Resolved width of the offset wrapper — the box the hosted content fills.
        fn get(env: *TestEnv, sv: *ScrollView, outer: reg.NodeId) f32 {
            var engine = @import("../layout/flexbox.zig").LayoutEngine.init(&env.registry, &env.store, null);
            engine.solve(outer, 0, 0, 400, 600);
            return env.registry.getNode(sv.wrapper_node).?.geometry.width;
        }
    }.get;

    // Scrolling: the track is a sibling, so the content stops short of it — a
    // full-width row's right edge is never hidden under the thumb.
    var e1 = TestEnv.init(testing.allocator);
    defer e1.deinit();
    e1.wire();
    var stub1 = StubChild{};
    const scrolling = try mountScrollView(&e1, .{
        .content = component.childOf(StubChild, &stub1),
        .content_height = 1000,
        .viewport_height = 600,
    });
    const w_scrolling = contentWidth(&e1, scrolling, 0);
    try testing.expectApproxEqAbs(@as(f32, 400 - SCROLLBAR_WIDTH), w_scrolling, 0.5);

    // Short content, gutter .auto (default): no channel, content gets the full width.
    var e2 = TestEnv.init(testing.allocator);
    defer e2.deinit();
    e2.wire();
    var stub2 = StubChild{};
    const short_auto = try mountScrollView(&e2, .{
        .content = component.childOf(StubChild, &stub2),
        .content_height = 100,
        .viewport_height = 600,
    });
    try testing.expectApproxEqAbs(@as(f32, 400), contentWidth(&e2, short_auto, 0), 0.5);

    // Same short content with .stable: the channel is held open, so the content box
    // is exactly as wide as it will be once rows start overflowing — no reflow jump.
    var e3 = TestEnv.init(testing.allocator);
    defer e3.deinit();
    e3.wire();
    var stub3 = StubChild{};
    const short_stable = try mountScrollView(&e3, .{
        .content = component.childOf(StubChild, &stub3),
        .content_height = 100,
        .viewport_height = 600,
        .gutter = .stable,
    });
    try testing.expectApproxEqAbs(w_scrolling, contentWidth(&e3, short_stable, 0), 0.5);
}

test "ScrollView thumb drag-follow via global move; handler removed on unmount" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = theme_mod.Theme.dark();
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    var stub = StubChild{};
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(ScrollView, .{
        .content = component.childOf(StubChild, &stub),
        .content_height = 1000,
        .viewport_height = 600,
    });
    b.close();
    try testing.expectEqual(@as(usize, 1), env.router.global_handlers.items.len);

    const anchor = env.registry.getNode(root).?.first_child;
    const sv: *ScrollView = @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));

    // Press the thumb (typed handler), then drag down 59.6 px of track space →
    // 100 px of content space: offset goes 0 → -100 (clamped ≥ -400).
    _ = env.router.route(.{ .name = "mouse_down", .id = "", .node_id = sv.thumb_node, .y = 10.0 });
    try testing.expect(sv.bar().?.dragging.peek());
    _ = env.router.route(.{ .name = "mouse_move", .id = "", .y = 10.0 + 59.6 });
    try testing.expectApproxEqAbs(@as(f32, -100.0), sv.scroll_offset.peek(), 0.01);
    _ = env.router.route(.{ .name = "mouse_up", .id = "" });
    try testing.expect(!sv.bar().?.dragging.peek());

    // Rebuild the root empty → the anchor is reconciled away → onUnmount removes
    // the global handler (and the instance is freed without leak).
    try b.rootAt(root);
    b.close();
    try testing.expectEqual(@as(usize, 0), env.router.global_handlers.items.len);
}

/// 1000px-tall content for the fill-slot test below.
const TallChild = struct {
    pub fn build(_: *TallChild, ctx: *BuildContext) !void {
        const n = try ctx.builder.openNodeKeyed(.box, null);
        try ctx.builder.height(n, 1000, .px);
        ctx.builder.close();
    }
    pub fn deinit(_: *TallChild) void {}
};

test "a fill ScrollView clamps against its solved height, not the 600px prop" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var tall = TallChild{};
    const sv = try mountScrollView(&env, .{
        .fill = true,
        .content = component.childOf(TallChild, &tall),
        .content_height = 1000,
    });
    // A definite 300x400 slot (the window root in an app).
    try env.store.setLayout(0, .width, .{ .dimension = .{ .value = 300, .unit = .px } });
    try env.store.setLayout(0, .height, .{ .dimension = .{ .value = 400, .unit = .px } });
    env.solve(0, 300, 400);
    // The visible area really is the 400px slot.
    try testing.expectApproxEqAbs(@as(f32, 400), env.geom(sv.viewport_node).height, 0.5);

    // Wheel far down: the last 600px must become reachable (1000 - 400).
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = env.router.route(.{ .name = "scroll", .id = "", .node_id = sv.viewport_node, .scroll_delta = -1.0 });
    }
    try testing.expectApproxEqAbs(@as(f32, -600.0), sv.scroll_offset.peek(), 0.001);
}

test "ScrollView: an explicit viewport_height without fill is honored (backward compatible)" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var tall = TallChild{};
    const sv = try mountScrollView(&env, .{
        .content = component.childOf(TallChild, &tall),
        .content_height = 1000,
        .viewport_height = 300,
    });
    env.solve(0, 300, 400);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = env.router.route(.{ .name = "scroll", .id = "", .node_id = sv.viewport_node, .scroll_delta = -1.0 });
    }
    try testing.expectApproxEqAbs(@as(f32, -700.0), sv.scroll_offset.peek(), 0.001);
}

test "ScrollView fill: a window resize re-clamps the offset and resizes the thumb with no wheel event" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var tall = TallChild{};
    const sv = try mountScrollView(&env, .{
        .fill = true,
        .content = component.childOf(TallChild, &tall),
        .content_height = 1000,
    });
    try env.store.setLayout(0, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
    try env.store.setLayout(0, .height, .{ .dimension = .{ .value = 100, .unit = .percent } });

    // 400px window: viewport and content both report on the first frame.
    _ = try env.frame(0, 300, 400);
    try testing.expectApproxEqAbs(@as(f32, 400), sv.viewport_h_sig.peek(), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1000), sv.content_h_sig.peek(), 0.5);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = env.router.route(.{ .name = "scroll", .id = "", .node_id = sv.viewport_node, .scroll_delta = -1.0 });
    }
    try testing.expectApproxEqAbs(@as(f32, -600), sv.scroll_offset.peek(), 0.01); // bottom
    _ = try env.frame(0, 300, 400);
    const thumb_400 = env.geom(sv.thumb_node).height;

    // Window grows to 800: max scroll is now 200 — the offset follows without a
    // wheel event (before on_resize it stayed at -600, past the end), and the
    // thumb grows because more of the content is visible.
    _ = try env.frame(0, 300, 800);
    try testing.expectApproxEqAbs(@as(f32, -200), sv.scroll_offset.peek(), 0.01);
    _ = try env.frame(0, 300, 800);
    try testing.expect(env.geom(sv.thumb_node).height > thumb_400 + 1);
}

test "ScrollView fill: the scrollbar appears and disappears as a resize flips whether content fits" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var tall = TallChild{}; // 1000px of content
    const sv = try mountScrollView(&env, .{
        .fill = true,
        .content = component.childOf(TallChild, &tall),
        .content_height = 1000,
    });
    try env.store.setLayout(0, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
    try env.store.setLayout(0, .height, .{ .dimension = .{ .value = 100, .unit = .percent } });
    const viewport = sv.viewport_node;
    const wrapper = sv.wrapper_node;

    // 400px tall: content overflows → bar shown, viewport loses the channel.
    _ = try env.frame(0, 400, 400);
    _ = try env.frame(0, 400, 400);
    try testing.expect(sv.track_node != reg.NULL_NODE);
    try testing.expect(env.isVisible(sv.thumb_node));
    try testing.expectApproxEqAbs(@as(f32, 400 - SCROLLBAR_WIDTH), env.geom(viewport).width, 0.5);

    // 1200px tall: everything fits → the bar goes away with no rebuild of the
    // content (same viewport + wrapper nodes) and the viewport takes full width.
    _ = try env.frame(0, 400, 1200);
    _ = try env.frame(0, 400, 1200);
    try testing.expect(sv.track_node == reg.NULL_NODE);
    try testing.expectEqual(viewport, sv.viewport_node);
    try testing.expectEqual(wrapper, sv.wrapper_node);
    try testing.expectApproxEqAbs(@as(f32, 400), env.geom(viewport).width, 0.5);

    // Back down: the bar comes back.
    _ = try env.frame(0, 400, 400);
    _ = try env.frame(0, 400, 400);
    try testing.expect(env.isVisible(sv.thumb_node));
    try testing.expectApproxEqAbs(@as(f32, 400 - SCROLLBAR_WIDTH), env.geom(viewport).width, 0.5);
}
