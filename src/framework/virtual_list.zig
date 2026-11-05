//! VirtualList — windowed list that materializes only the visible rows.
//!
//! v1 uses a **fixed item height** (covers ~90% of real lists). A list of 10 000
//! rows renders ~`ceil(viewport/item_height) + 2*overdraw` item nodes, not 10 000,
//! so shaping and the layout walk stay O(window) instead of O(count).
//!
//! Framework-owned via `ctx.mountOwned(VirtualList(Row), .{ .items = rows,
//! .item_height = 24, .viewport_height = 480, .render = VL.renderFn(*Self, drawRow),
//! .payload = self })`. The `render` callback fills each row wrapper (already sized
//! to `item_height`); `payload` is forwarded to it (Zig has no closures — same
//! pattern as `forEach`).
//!
//! Structure: a clipping viewport (owns the typed `on_scroll`) whose single child
//! `body` is a column of `[top spacer][visible rows keyed by ABSOLUTE index]
//! [bottom spacer]`. Spacer heights place row `i` at `i*item_height` inside `body`,
//! independent of the current window, so identity is stable; the viewport's
//! render-only `scroll_offset_y` then translates the whole body by `-scroll_top`.
//!
//! Two reads drive it, split coarse/fine so a small scroll costs a translation, not
//! a rebuild (mirrors ScrollView's self-scope effects — the build itself reads no
//! signals, so the mountOwned build-effect never subscribes cross-scope):
//!   • `start_sig` — a memoized `Computed(usize)` of the first materialized index.
//!     It only re-notifies when the window actually shifts (crossing an item
//!     boundary), so the range effect (which repopulates `body` via `rootAt`) fires
//!     once per boundary crossed — not per scrolled pixel.
//!   • `scroll_top` — the raw offset; the translation effect writes the viewport's
//!     `scroll_offset_y` on every scroll (render-only, no layout solve).
//!
//! Cost note: sub-item scrolling is render-only. Crossing an item boundary re-runs
//! the range effect, whose spacer-height writes mark `layout_dirty` — a bounded
//! O(window) reconcile, not the O(count) full solve virtualization exists to avoid.

const std = @import("std");
const component = @import("component.zig");
const builder_mod = @import("builder.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;

/// Reconciliation keys for the two spacers. Sentinels far above any realistic item
/// count so they never collide with the per-row keys (the absolute row index).
const TOP_SPACER_KEY: u64 = std.math.maxInt(u64);
const BOTTOM_SPACER_KEY: u64 = std.math.maxInt(u64) - 1;

pub fn VirtualList(comptime Item: type) type {
    return struct {
        const Self = @This();

        /// Row renderer: `render(payload, ctx, item, absolute_index)`. Fills the row
        /// wrapper (already sized to `item_height`). Build with `renderFn`.
        pub const RenderFn = *const fn (?*anyopaque, *BuildContext, Item, usize) anyerror!void;

        // ── Props (from init_props; re-applied on rebuild) ──────────────────────
        /// The full backing data (caller-owned). VirtualList never materializes all
        /// of it — only the visible window.
        items: []const Item = &.{},
        item_height: f32 = 24,
        /// Fixed viewport height (px). With `fill` it is only the frame-0 estimate,
        /// used until the first solve reports the real height.
        viewport_height: f32 = 400,
        /// Size the viewport to 100% of the parent's height and track the real
        /// height via `on_resize`: growing the window materializes more rows
        /// without a scroll, shrinking it materializes fewer.
        fill: bool = false,
        /// Extra rows kept above/below the viewport so a fast scroll doesn't flash
        /// blank before the next range rebuild.
        overdraw: u32 = 4,
        render: RenderFn = undefined,
        payload: ?*anyopaque = null,
        /// Optional external revision signal (the lifted-data pattern used by
        /// TreeView/StatusBar): after mutating `items` in place, `.set(rev+1)` to
        /// re-materialize the visible window without a full parent rebuild.
        data_rev: ?*signals.Signal(u32) = null,

        // ── State (created in onMount / first build) ────────────────────────────
        scroll_top: signals.Signal(f32) = undefined,
        /// Solved viewport height from `on_resize` (`fill` only); 0 = not solved
        /// yet, use the `viewport_height` estimate.
        measured_h: signals.Signal(f32) = undefined,
        scope: signals.Scope = undefined,
        start_sig: *signals.Computed(usize) = undefined,
        /// Materialized row count, memoized from `measured_h`: the range effect
        /// re-runs only when a resize changes how many rows fit, not per pixel.
        win_sig: *signals.Computed(usize) = undefined,

        // ── Captured during build() ─────────────────────────────────────────────
        store: ?*props.PropertyStore = null,
        registry: ?*reg.UIRegistry = null,
        router: ?*events.EventRouter = null,
        mounts: ?*component.MountTable = null,
        measure: ?component.TextMeasure = null,
        theme: theme_mod.Theme = undefined,
        viewport_node: reg.NodeId = reg.NULL_NODE,
        body_node: reg.NodeId = reg.NULL_NODE,
        bound: bool = false,

        pub fn onMount(self: *Self, allocator: std.mem.Allocator) void {
            self.scroll_top = signals.Signal(f32).init(allocator, 0);
            self.measured_h = signals.Signal(f32).init(allocator, 0);
            self.scope = signals.Scope.init(allocator);
        }

        pub fn deinit(self: *Self) void {
            // Effects (range + translation) and the computeds' recompute effects are
            // torn down first, unsubscribing while the signals are still alive; then
            // the signals are freed.
            self.scope.deinit();
            self.measured_h.deinit();
            self.scroll_top.deinit();
        }

        // ── Range math ──────────────────────────────────────────────────────────

        /// The viewport height the window is sized for: the solved height once
        /// `on_resize` reported it (`fill`), else the `viewport_height` prop.
        fn viewportH(self: *const Self) f32 {
            const m = self.measured_h.peek();
            return if (self.fill and m > 0) m else self.viewport_height;
        }

        /// Number of rows materialized: the visible count plus overdraw both sides.
        fn windowLen(self: *const Self) usize {
            if (self.item_height <= 0) return 0;
            const vis: usize = @intFromFloat(@ceil(self.viewportH() / self.item_height));
            return vis + 2 * @as(usize, self.overdraw);
        }

        /// `win_sig`'s compute: subscribes to `measured_h`, memoized on the count.
        fn computeWindow(self: *Self) usize {
            _ = self.measured_h.get();
            return self.windowLen();
        }

        fn totalHeight(self: *const Self) f32 {
            return @as(f32, @floatFromInt(self.items.len)) * self.item_height;
        }

        /// First materialized index for the current scroll: `floor(top/h) - overdraw`,
        /// floored at 0. Memoized in `start_sig`, so it only changes when the window
        /// crosses an item boundary. Reads `scroll_top` reactively.
        fn computeStart(self: *Self) usize {
            if (self.item_height <= 0) return 0;
            const top = self.scroll_top.get();
            const first: i64 = @intFromFloat(@floor(top / self.item_height));
            const start = first - @as(i64, self.overdraw);
            return if (start < 0) 0 else @intCast(start);
        }

        // ── Scroll handling ───────────────────────────────────────────────────────

        fn onScroll(self: *Self, ev: events.Event) void {
            // Wheel down (delta < 0) scrolls content down → scroll_top increases.
            self.setScrollClamped(self.scroll_top.peek() - ev.scroll_delta * 20.0);
        }

        fn setScrollClamped(self: *Self, value: f32) void {
            var t = value;
            if (t < 0) t = 0;
            const max_t = @max(0.0, self.totalHeight() - self.viewportH());
            if (t > max_t) t = max_t;
            self.scroll_top.set(t);
        }

        fn onResize(self: *Self, ev: events.Event) void {
            self.measured_h.set(ev.height);
            // A taller viewport lowers the max scroll: re-clamp so a list scrolled
            // to the bottom doesn't leave a gap under its last row.
            self.setScrollClamped(self.scroll_top.peek());
        }

        // ── Effects ───────────────────────────────────────────────────────────────

        /// Coarse: repopulates `body` with the current window. Fires once per item
        /// boundary crossed (subscribed to `start_sig`) and on data-revision bumps.
        fn rebuildRange(self: *Self) void {
            const registry = self.registry orelse return;
            _ = self.start_sig.get(); // subscribe: window shifts
            _ = self.win_sig.get(); // subscribe: window grows/shrinks (resize)
            if (self.data_rev) |rv| _ = rv.get(); // subscribe: data changes
            if (self.body_node == reg.NULL_NODE) return;

            var b = builder_mod.UIBuilder.init(registry, self.store.?);
            b.theme = self.theme;
            b.measure = self.measure;
            b.rootAt(self.body_node) catch return;
            var ctx = BuildContext{ .builder = &b, .router = self.router, .mounts = self.mounts };
            self.populate(&b, &ctx) catch {};
            std.debug.assert(b.parent_stack.len == 1); // balance guard (only our rootAt frame)
            b.close();
            registry.markLayoutDirty(self.body_node);
        }

        fn populate(self: *Self, b: *builder_mod.UIBuilder, ctx: *BuildContext) !void {
            const count = self.items.len;
            const win = self.win_sig.peek(); // already subscribed in rebuildRange
            var start = self.start_sig.peek(); // already subscribed in rebuildRange
            var end = start + win;
            if (end > count) end = count;
            // Keep the window full at the bottom rather than shrinking it.
            if (end == count and count > win) start = count - win;
            if (start > count) start = count;
            const ih = self.item_height;

            // Top spacer: lifts row `start` to y = start*item_height inside body.
            const top = try b.openNodeKeyed(.box, TOP_SPACER_KEY);
            try b.width(top, 100, .percent);
            try b.height(top, @as(f32, @floatFromInt(start)) * ih, .px);
            b.close();

            // Visible rows, keyed by ABSOLUTE index so identity survives scrolling.
            var i = start;
            while (i < end) : (i += 1) {
                const row = try b.openNodeKeyed(.box, @as(u64, i));
                try b.width(row, 100, .percent);
                try b.height(row, ih, .px);
                try self.render(self.payload, ctx, self.items[i], i);
                b.close();
            }

            // Bottom spacer: reserves the remaining scroll extent.
            const bot = try b.openNodeKeyed(.box, BOTTOM_SPACER_KEY);
            try b.width(bot, 100, .percent);
            try b.height(bot, @as(f32, @floatFromInt(count - end)) * ih, .px);
            b.close();
        }

        /// Fine: translates the whole body by `-scroll_top` (render-only). Runs on
        /// every scroll; subscribed to `scroll_top`.
        fn updateTranslation(self: *Self) void {
            const store = self.store orelse return;
            if (self.viewport_node == reg.NULL_NODE) return;
            const top = self.scroll_top.get();
            store.setLayout(self.viewport_node, .scroll_offset_y, .{ .dimension = .{ .value = -top, .unit = .px } }) catch {};
        }

        // ── Build ───────────────────────────────────────────────────────────────

        pub fn build(self: *Self, ctx: *BuildContext) !void {
            const b = ctx.builder;
            self.store = b.store;
            self.registry = b.registry;
            self.router = ctx.router;
            self.mounts = ctx.mounts;
            self.measure = b.measure;
            self.theme = b.theme;

            // Viewport clips the overflow and owns the wheel (routed here by node id).
            // With `fill` the viewport takes its parent's height and reports the real
            // value through `on_resize` (first solve included).
            const viewport = if (self.fill) try ctx.boxNode(.{
                .width = component.pct(100),
                .height = component.pct(100),
                .direction = .column,
                .on_scroll = ctx.handler(self, onScroll),
                .on_resize = ctx.handler(self, onResize),
            }, .{
                Body{ .vl = self },
            }) else try ctx.boxNode(.{
                .width = component.pct(100),
                .height = self.viewport_height,
                .direction = .column,
                .on_scroll = ctx.handler(self, onScroll),
            }, .{
                Body{ .vl = self },
            });
            self.viewport_node = viewport;
            try b.overflowHidden(viewport);

            if (!self.bound) {
                // `body` exists now; the range effect's first run populates it.
                self.start_sig = try self.scope.createComputed(usize, self, computeStart);
                self.win_sig = try self.scope.createComputed(usize, self, computeWindow);
                _ = try self.scope.createEffect(self, rebuildRange);
                _ = try self.scope.createEffect(self, updateTranslation);
                self.bound = true;
            } else {
                // Parent-driven re-mount (e.g. props changed). Re-populate and
                // re-translate untracked so the build-effect never subscribes.
                const prev = signals.untrackedBegin();
                self.rebuildRange();
                self.updateTranslation();
                signals.untrackedEnd(prev);
            }
        }

        /// Viewport's single child: the scrollable body column the range effect fills.
        pub const Body = struct {
            vl: *Self,
            pub fn build(self: *Body, ctx: *BuildContext) !void {
                const body = try ctx.builder.openNodeKeyed(.box, null);
                self.vl.body_node = body;
                try ctx.builder.width(body, 100, .percent);
                try ctx.builder.store.setLayout(body, .flex_direction, .{ .keyword = .column });
                ctx.builder.close();
            }
            pub fn deinit(_: *Body) void {}
        };

        /// Erases a typed row renderer `fn (P, *BuildContext, Item, usize) !void`
        /// (P a pointer payload) into a `RenderFn`. Pair with `.payload = p`.
        pub fn renderFn(comptime P: type, comptime f: fn (P, *BuildContext, Item, usize) anyerror!void) RenderFn {
            const Wrap = struct {
                fn call(erased: ?*anyopaque, ctx: *BuildContext, item: Item, idx: usize) anyerror!void {
                    const typed: P = @ptrCast(@alignCast(erased.?));
                    return f(typed, ctx, item, idx);
                }
            };
            return Wrap.call;
        }
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const Row = struct { n: usize };

const Recorder = struct {
    count: usize = 0,
    fn draw(self: *Recorder, ctx: *BuildContext, item: Row, idx: usize) anyerror!void {
        _ = idx;
        _ = item;
        self.count += 1;
        // A trivial leaf so the row has some content (no measure needed).
        _ = try ctx.builder.addText("");
    }
};

const VL = VirtualList(Row);

const TestEnv = @import("test_support.zig").Harness;

fn mountVL(env: *TestEnv, init_props: anytype) !*VL {
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = theme_mod.Theme.dark();
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(VL, init_props);
    b.close();
    const anchor = env.registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));
}

/// Count of direct children of `parent`.
fn childCount(registry: *reg.UIRegistry, parent: reg.NodeId) usize {
    var c: usize = 0;
    var cur = registry.getNode(parent).?.first_child;
    while (cur != reg.NULL_NODE) : (cur = registry.getNode(cur).?.next_sibling) c += 1;
    return c;
}

/// The absolute-index-keyed row wrapper NodeIds under `body` (excludes spacers).
fn rowNodes(registry: *reg.UIRegistry, body: reg.NodeId, out: *std.array_list.Managed(reg.NodeId)) !void {
    var cur = registry.getNode(body).?.first_child;
    while (cur != reg.NULL_NODE) : (cur = registry.getNode(cur).?.next_sibling) {
        try out.append(cur); // includes the leading/trailing spacers
    }
}

test "VirtualList materializes only the window, not all 10k items" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var items: [10_000]Row = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .n = i };
    var rec = Recorder{};

    const vl = try mountVL(&env, .{
        .items = @as([]const Row, &items),
        .item_height = 20,
        .viewport_height = 400, // 20 rows visible
        .overdraw = 4,
        .render = VL.renderFn(*Recorder, Recorder.draw),
        .payload = &rec,
    });

    // window = ceil(400/20) + 2*4 = 28 rows + 2 spacers = 30 body children.
    try testing.expectEqual(@as(usize, 28), vl.windowLen());
    try testing.expectEqual(@as(usize, 30), childCount(&env.registry, vl.body_node));

    // Top spacer height 0 (start 0); bottom spacer reserves the rest.
    var cur = env.registry.getNode(vl.body_node).?.first_child;
    const top_spacer = cur;
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getLayout(top_spacer, .height).?.dimension.value, 0.001);
    // Last child = bottom spacer: (10000 - 28) * 20.
    var last = cur;
    while (env.registry.getNode(cur).?.next_sibling != reg.NULL_NODE) {
        cur = env.registry.getNode(cur).?.next_sibling;
        last = cur;
    }
    try testing.expectApproxEqAbs(@as(f32, (10_000 - 28) * 20), env.store.getLayout(last, .height).?.dimension.value, 0.5);
}

test "VirtualList scroll reuses in-range rows and shifts the window" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var items: [10_000]Row = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .n = i };
    var rec = Recorder{};

    const vl = try mountVL(&env, .{
        .items = @as([]const Row, &items),
        .item_height = 20,
        .viewport_height = 400,
        .overdraw = 4,
        .render = VL.renderFn(*Recorder, Recorder.draw),
        .payload = &rec,
    });

    // Snapshot the NodeIds of rows currently in range (keyed by absolute index).
    var before = std.array_list.Managed(reg.NodeId).init(testing.allocator);
    defer before.deinit();
    try rowNodes(&env.registry, vl.body_node, &before);
    // A row that will still be in range after scrolling 5 items: absolute index 10.
    // before[] holds [top_spacer, rows 0..27, bottom_spacer]; row 10 is before[11].
    const row10_before = before.items[11];

    // Scroll down 5 items (100 px). start = floor(100/20) - 4 = 1.
    env.registry.global_layout_dirty = false;
    env.registry.global_render_dirty = false;
    _ = env.router.route(.{ .name = "scroll", .id = "", .node_id = vl.viewport_node, .scroll_delta = -5.0 });

    try testing.expectApproxEqAbs(@as(f32, 100.0), vl.scroll_top.peek(), 0.001);
    try testing.expectEqual(@as(usize, 1), vl.start_sig.peek());
    // Translation applied (render-only).
    try testing.expectApproxEqAbs(@as(f32, -100.0), env.store.getLayout(vl.viewport_node, .scroll_offset_y).?.dimension.value, 0.001);

    // Window shifted: still 28 rows + 2 spacers.
    try testing.expectEqual(@as(usize, 30), childCount(&env.registry, vl.body_node));
    // Row 10 is still in range (window now 1..28), and kept its NodeId.
    var after = std.array_list.Managed(reg.NodeId).init(testing.allocator);
    defer after.deinit();
    try rowNodes(&env.registry, vl.body_node, &after);
    // Window start is 1 now: [top_spacer, rows 1..28, bottom_spacer]; row 10 = after[10].
    try testing.expectEqual(row10_before, after.items[10]);
    // Top spacer now reserves 1 row.
    try testing.expectApproxEqAbs(@as(f32, 20.0), env.store.getLayout(after.items[0], .height).?.dimension.value, 0.001);
}

test "VirtualList sub-item scroll is render-only (no window rebuild)" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var items: [1000]Row = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .n = i };
    var rec = Recorder{};

    const vl = try mountVL(&env, .{
        .items = @as([]const Row, &items),
        .item_height = 20,
        .viewport_height = 400,
        .overdraw = 4,
        .render = VL.renderFn(*Recorder, Recorder.draw),
        .payload = &rec,
    });

    const draws_after_mount = rec.count;
    env.registry.global_layout_dirty = false;

    // Scroll 8 px — less than one item; start stays 0, so no window rebuild.
    _ = env.router.route(.{ .name = "scroll", .id = "", .node_id = vl.viewport_node, .scroll_delta = -0.4 });
    try testing.expectApproxEqAbs(@as(f32, 8.0), vl.scroll_top.peek(), 0.001);
    try testing.expectEqual(@as(usize, 0), vl.start_sig.peek());
    // No new rows drawn (range effect did not fire), only a render-only translation.
    try testing.expectEqual(draws_after_mount, rec.count);
    try testing.expect(!env.registry.global_layout_dirty);
    try testing.expectApproxEqAbs(@as(f32, -8.0), env.store.getLayout(vl.viewport_node, .scroll_offset_y).?.dimension.value, 0.001);
}

test "VirtualList data_rev bump re-materializes the visible window" {
    // The external `rev` signal must outlive the widget: on teardown, `env.deinit`
    // destroys the VL scope effect that subscribed to `rev` (it must unsubscribe
    // while `rev` is still alive). Declaring `rev`/`backing` first makes their
    // defers run AFTER env.deinit — mirroring an app where data outlives the list.
    var backing = std.array_list.Managed(Row).init(testing.allocator);
    defer backing.deinit();
    try backing.appendNTimes(.{ .n = 0 }, 50);
    var rev = signals.Signal(u32).init(testing.allocator, 0);
    defer rev.deinit();
    var rec = Recorder{};

    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    const vl = try mountVL(&env, .{
        .items = @as([]const Row, backing.items),
        .item_height = 20,
        .viewport_height = 400,
        .overdraw = 4,
        .render = VL.renderFn(*Recorder, Recorder.draw),
        .payload = &rec,
        .data_rev = &rev,
    });
    // 28-row window capped at 50 items → 28 rows materialized.
    try testing.expectEqual(@as(usize, 30), childCount(&env.registry, vl.body_node));

    // Shrink the data to 5 rows in place, then bump the revision.
    backing.shrinkRetainingCapacity(5);
    vl.items = backing.items;
    rev.set(1);

    // Only 5 rows now + 2 spacers.
    try testing.expectEqual(@as(usize, 7), childCount(&env.registry, vl.body_node));
}

test "VirtualList mount/unmount ×64 without leaks" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var items: [200]Row = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .n = i };
    var rec = Recorder{};

    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = theme_mod.Theme.dark();
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    b.close();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        // Mount.
        try b.rootAt(root);
        try ctx.mountOwned(VL, .{
            .items = @as([]const Row, &items),
            .item_height = 20,
            .viewport_height = 400,
            .render = VL.renderFn(*Recorder, Recorder.draw),
            .payload = &rec,
        });
        b.close();
        // Unmount: rebuild the root empty → the anchor is reconciled away.
        try b.rootAt(root);
        b.close();
    }
    // testing.allocator asserts no leaks at env.deinit().
}

fn mountVLIn(env: *TestEnv, init_props: anytype) !struct { vl: *VL, root: reg.NodeId } {
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = theme_mod.Theme.dark();
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try b.width(root, 100, .percent);
    try b.height(root, 100, .percent);
    try ctx.mountOwned(VL, init_props);
    b.close();
    const anchor = env.registry.getNode(root).?.first_child;
    return .{ .vl = @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr)), .root = root };
}

/// The row wrapper keyed by absolute index `idx`, or null if not materialized.
fn rowAt(env: *TestEnv, vl: *VL, idx: usize) ?reg.NodeId {
    var nodes = std.array_list.Managed(reg.NodeId).init(testing.allocator);
    defer nodes.deinit();
    rowNodes(&env.registry, vl.body_node, &nodes) catch return null;
    // [top spacer, rows start.., bottom spacer]
    const start = vl.start_sig.peek();
    if (idx < start or idx - start + 1 >= nodes.items.len - 1) return null;
    return nodes.items[idx - start + 1];
}

test "VirtualList fill: growing the window materializes the rows that now fit, no scroll needed" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var items: [10_000]Row = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .n = i };
    var rec = Recorder{};

    const m = try mountVLIn(&env, .{
        .items = @as([]const Row, &items),
        .item_height = 20,
        .viewport_height = 100, // deliberately wrong estimate: 5 rows
        .fill = true,
        .overdraw = 2,
        .render = VL.renderFn(*Recorder, Recorder.draw),
        .payload = &rec,
    });
    // Frame 0 builds from the estimate.
    try testing.expectEqual(@as(usize, 5 + 4), m.vl.windowLen());

    // First frame at 800×400: the solve reports 400px → 20 visible rows.
    _ = try env.frame(m.root, 800, 400);
    try testing.expectEqual(@as(usize, 20 + 4), m.vl.windowLen());
    _ = try env.frame(m.root, 800, 400); // apply the rebuilt window
    try testing.expect(env.isVisible(rowAt(&env, m.vl, 19).?));
    try testing.expect(rowAt(&env, m.vl, 30) == null);

    // Window grows to 900: row 44 (y = 880) is now on screen and must exist —
    // this is the "empty band until the next scroll" the client hit.
    _ = try env.frame(m.root, 800, 900);
    _ = try env.frame(m.root, 800, 900);
    try testing.expectEqual(@as(usize, 45 + 4), m.vl.windowLen());
    const row44 = rowAt(&env, m.vl, 44).?;
    try testing.expect(env.isVisible(row44));
    try testing.expectApproxEqAbs(@as(f32, 880), env.geom(row44).y, 0.5);

    // Shrinking materializes fewer rows again.
    _ = try env.frame(m.root, 800, 200);
    _ = try env.frame(m.root, 800, 200);
    try testing.expectEqual(@as(usize, 10 + 4), m.vl.windowLen());
}

test "VirtualList fill: a resize re-clamps a list scrolled to the bottom" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var items: [100]Row = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .n = i };
    var rec = Recorder{};
    const m = try mountVLIn(&env, .{
        .items = @as([]const Row, &items),
        .item_height = 20,
        .fill = true,
        .render = VL.renderFn(*Recorder, Recorder.draw),
        .payload = &rec,
    });
    _ = try env.frame(m.root, 800, 400);
    m.vl.setScrollClamped(1e9); // bottom: 2000 - 400
    try testing.expectApproxEqAbs(@as(f32, 1600), m.vl.scroll_top.peek(), 0.01);
    _ = try env.frame(m.root, 800, 1000);
    try testing.expectApproxEqAbs(@as(f32, 1000), m.vl.scroll_top.peek(), 0.01);
}
