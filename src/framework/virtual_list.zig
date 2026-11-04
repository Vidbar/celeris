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
        viewport_height: f32 = 400,
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
        scope: signals.Scope = undefined,
        start_sig: *signals.Computed(usize) = undefined,

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
            self.scope = signals.Scope.init(allocator);
        }

        pub fn deinit(self: *Self) void {
            // Effects (range + translation) and the computed's recompute effect are
            // torn down first, unsubscribing while scroll_top is still alive; then
            // the signal is freed.
            self.scope.deinit();
            self.scroll_top.deinit();
        }

        // ── Range math ──────────────────────────────────────────────────────────

        /// Number of rows materialized: the visible count plus overdraw both sides.
        fn windowLen(self: *const Self) usize {
            if (self.item_height <= 0) return 0;
            const vis: usize = @intFromFloat(@ceil(self.viewport_height / self.item_height));
            return vis + 2 * @as(usize, self.overdraw);
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
            const max_t = @max(0.0, self.totalHeight() - self.viewport_height);
            if (t > max_t) t = max_t;
            self.scroll_top.set(t);
        }

        // ── Effects ───────────────────────────────────────────────────────────────

        /// Coarse: repopulates `body` with the current window. Fires once per item
        /// boundary crossed (subscribed to `start_sig`) and on data-revision bumps.
        fn rebuildRange(self: *Self) void {
            const registry = self.registry orelse return;
            _ = self.start_sig.get(); // subscribe: window shifts
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
            const win = self.windowLen();
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
            const viewport = try ctx.boxNode(.{
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
