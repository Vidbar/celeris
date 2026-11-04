//! ProgressBar — determinate and indeterminate progress indicator.
//!
//! Framework-owned via `ctx.mountOwned(ProgressBar, .{ .initial_value = 0.4 })` (no
//! `init`/`register`/`deinit` in user code). The bar is a rounded track (`bg_input`)
//! holding an `accent` fill.
//!
//!   • **Determinate** (default): `value` (a `Signal(f32)` in 0..1, seeded from
//!     `initial_value`) drives the fill width via an effect. Update it through the
//!     returned instance's `value.set(...)`.
//!   • **Indeterminate** (`.indeterminate = true`): there are no transforms in the
//!     render, so instead of a spinner we use a **traveling bar** — a 30%-wide fill
//!     pushed along by an invisible leading spacer whose `width` sweeps 0→70% and
//!     loops (a percentage WIDTH, which the solver resolves; it ignores percentage
//!     margins, so animating `margin_left` never actually moved the bar), driven
//!     by the engine's
//!     `AnimationEngine` (`addRepeating`, per frame) via `builder.animator`.
//!     It used to run off the router's `onTick`, on the assumption that framework
//!     widgets had no handle to the animator; that channel is a coarse ~500ms
//!     heartbeat (`events.TICK_MS`), not a frame, so the bar lurched across in
//!     quarter-track jumps. Where no animator is injected (headless, test harness)
//!     it still degrades to the tick, registered against `root_id` so the handler is
//!     pruned automatically when the node is removed — no `onUnmount` needed.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");
const animation = @import("../core/animation.zig");

const BuildContext = component.BuildContext;

/// Fraction of the track the traveling fill occupies (indeterminate).
const TRAVEL_FILL_PCT: f32 = 30.0;
/// How far the fill's left edge sweeps (100% − fill width), in track %.
const TRAVEL_SPAN_PCT: f32 = 100.0 - TRAVEL_FILL_PCT;
/// One full sweep of the traveling fill, animator-driven (per frame).
const SWEEP_MS: f32 = 1200;
/// Phase advanced per tick in the TICK FALLBACK only (no animator: headless/tests).
/// A tick is the router's coarse ~500ms heartbeat, not a frame (`events.TICK_MS`),
/// so this is `TICK_MS / SWEEP_MS` — the same 1.2s sweep, sampled coarsely. It was
/// 0.02 under a "~50 frames" comment, which at the real cadence crawled the bar
/// across in 25 seconds.
const TRAVEL_STEP: f32 = @as(f32, @floatFromInt(events.TICK_MS)) / SWEEP_MS;

pub const ProgressBar = struct {
    // Props (from init_props; re-applied on rebuild).
    initial_value: f32 = 0,
    indeterminate: bool = false,

    // State (auto-created in onMount; preserved across rebuilds).
    value: signals.Signal(f32) = undefined,
    scope: signals.Scope = undefined,
    phase: f32 = 0, // indeterminate sweep position, 0..1

    // Captured during build().
    store: ?*props.PropertyStore = null,
    router: ?*events.EventRouter = null,
    root_id: reg.NodeId = reg.NULL_NODE,
    fill_id: reg.NodeId = reg.NULL_NODE,
    /// Indeterminate only: transparent box before the fill; its animated width
    /// is the fill's offset along the track.
    spacer_id: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,

    pub fn onMount(self: *ProgressBar, allocator: std.mem.Allocator) void {
        self.value = signals.Signal(f32).init(allocator, self.initial_value);
        self.scope = signals.Scope.init(allocator);
    }

    pub fn deinit(self: *ProgressBar) void {
        self.scope.deinit();
        self.value.deinit();
    }

    pub fn build(self: *ProgressBar, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;
        self.theme = t;
        self.store = b.store;
        self.router = ctx.router;

        // Root = track.
        self.root_id = try ctx.boxNode(.{
            .width = component.pct(100),
            .height = 6,
            .radius = 3,
            .role = "progressbar",
        }, .{
            Body{ .pb = self },
        });
        try b.backgroundAlpha(self.root_id, t.bg_input.r, t.bg_input.g, t.bg_input.b, 255);
        try b.overflowHidden(self.root_id); // clip the traveling fill at the edges
        try b.flexRow(self.root_id); // spacer then fill, side by side

        if (self.indeterminate) {
            // Prefer the per-frame animator: the sweep is motion, and the router's
            // tick is a coarse ~500ms heartbeat (`events.TICK_MS`), which produced a
            // bar that visibly jumped a quarter of the track twice a second. Register
            // once per fill node — `add` rewinds `elapsed_ms`, so re-registering on
            // every rebuild would pin the loop to its first frame forever.
            const target = animation.AnimTarget{ .layout = .{ .node_id = self.spacer_id, .key = .width } };
            if (b.animator) |anim| {
                if (!anim.has(target)) {
                    try anim.addRepeating(target, 0, TRAVEL_SPAN_PCT, SWEEP_MS, .linear, .percent);
                }
            } else if (ctx.router) |r| {
                // No animator (headless / a test harness): fall back to the tick so the
                // bar still advances, just coarsely.
                try r.onTick(self.root_id, self, onTick);
            }
        } else if (!self.bound) {
            _ = try self.scope.createEffect(self, updateFill);
        } else {
            const prev = signals.untrackedBegin();
            self.updateFill();
            signals.untrackedEnd(prev);
        }
        self.bound = true;
    }

    /// Determinate: fill width follows `value` (0..1 → 0..100%).
    fn updateFill(self: *ProgressBar) void {
        const store = self.store orelse return;
        if (self.fill_id == reg.NULL_NODE) return;
        const pct = std.math.clamp(self.value.get(), 0, 1) * 100.0;
        store.setLayout(self.fill_id, .width, .{ .dimension = .{ .value = pct, .unit = .percent } }) catch {};
    }

    /// Indeterminate: advance the sweep phase and move the fixed-width fill.
    fn onTick(self: *ProgressBar) void {
        const store = self.store orelse return;
        if (self.spacer_id == reg.NULL_NODE) return;
        self.phase += TRAVEL_STEP;
        if (self.phase >= 1.0) self.phase -= 1.0;
        const left = self.phase * TRAVEL_SPAN_PCT;
        store.setLayout(self.spacer_id, .width, .{ .dimension = .{ .value = left, .unit = .percent } }) catch {};
    }
};

/// The fill: full-height accent bar. Determinate starts at width 0 (the effect sets
/// it); indeterminate is a fixed 30% traveling block.
const Body = struct {
    pb: *ProgressBar,
    pub fn build(self: *Body, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const pb = self.pb;
        const t = pb.theme;

        if (pb.indeterminate) {
            const spacer = try b.openNodeKeyed(.box, null);
            pb.spacer_id = spacer;
            try b.width(spacer, 0, .percent);
            try b.height(spacer, 100, .percent);
            try b.flexShrink(spacer, 0);
            b.close();
        }
        const fill = try b.openNodeKeyed(.box, null);
        pb.fill_id = fill;
        try b.flexShrink(fill, 0);
        try b.width(fill, if (pb.indeterminate) TRAVEL_FILL_PCT else 0, .percent);
        try b.height(fill, 100, .percent);
        try b.radius(fill, 3);
        try b.backgroundAlpha(fill, t.accent.r, t.accent.g, t.accent.b, 255);
        b.close();
    }
    pub fn deinit(_: *Body) void {}
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const dark = theme_mod.Theme.dark();
const TestEnv = @import("test_support.zig").Harness;

fn mountProgress(env: *TestEnv, init_props: anytype) !*ProgressBar {
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(ProgressBar, init_props);
    b.close();
    const anchor = env.registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));
}

test "ProgressBar determinate: fill width follows value" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    const pb = try mountProgress(&env, .{ .initial_value = 0.5 });
    try testing.expectApproxEqAbs(@as(f32, 50.0), env.store.getLayout(pb.fill_id, .width).?.dimension.value, 0.001);

    pb.value.set(0.8);
    try testing.expectApproxEqAbs(@as(f32, 80.0), env.store.getLayout(pb.fill_id, .width).?.dimension.value, 0.001);

    // Out-of-range clamps.
    pb.value.set(2.0);
    try testing.expectApproxEqAbs(@as(f32, 100.0), env.store.getLayout(pb.fill_id, .width).?.dimension.value, 0.001);
}

test "ProgressBar indeterminate: prefers the per-frame animator over the tick channel" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var anim = animation.AnimationEngine.init(testing.allocator);
    defer anim.deinit();

    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    b.animator = &anim;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(ProgressBar, .{ .indeterminate = true });
    b.close();
    const anchor = env.registry.getNode(0).?.first_child;
    const pb: *ProgressBar = @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));

    // With an animator present the coarse tick channel is left alone entirely.
    try testing.expectEqual(@as(usize, 0), env.router.tick_handlers.items.len);
    const target = animation.AnimTarget{ .layout = .{ .node_id = pb.spacer_id, .key = .width } };
    try testing.expect(anim.has(target));

    // Frame-rate motion: a 16ms frame moves the fill a small fraction of the sweep,
    // not the quarter-track lurch the 500ms tick produced.
    _ = anim.tick(16.0, &env.store);
    const after_frame = env.store.getLayout(pb.spacer_id, .width).?.dimension;
    try testing.expect(after_frame.value > 0);
    try testing.expect(after_frame.value < TRAVEL_SPAN_PCT / 10.0);
    // And it must be a PERCENT so the sweep tracks a resized track (the animator
    // wrote px unconditionally before `Animation.unit` existed).
    try testing.expectEqual(props.DimUnit.percent, after_frame.unit);

    // A rebuild must not rewind the loop: `add` resets elapsed_ms, so re-registering
    // every build would freeze the bar at frame one.
    const mid = env.store.getLayout(pb.spacer_id, .width).?.dimension.value;
    try b.rootAt(0);
    try ctx.mountOwned(ProgressBar, .{ .indeterminate = true });
    b.close();
    _ = anim.tick(16.0, &env.store);
    try testing.expect(env.store.getLayout(pb.spacer_id, .width).?.dimension.value > mid);
}

test "ProgressBar indeterminate: falls back to the tick channel with no animator" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    const pb = try mountProgress(&env, .{ .indeterminate = true });
    // Fixed 30% wide fill; a tick handler is registered.
    try testing.expectApproxEqAbs(@as(f32, 30.0), env.store.getLayout(pb.fill_id, .width).?.dimension.value, 0.001);
    try testing.expectEqual(@as(usize, 1), env.router.tick_handlers.items.len);

    // One tick widens the leading spacer by TRAVEL_STEP * TRAVEL_SPAN_PCT.
    _ = env.router.route(.{ .name = "tick", .id = "" });
    try testing.expectApproxEqAbs(TRAVEL_STEP * TRAVEL_SPAN_PCT, env.store.getLayout(pb.spacer_id, .width).?.dimension.value, 0.001);

    // Sweep past the end (>50 ticks) → phase wraps, still valid (< span).
    var i: usize = 0;
    while (i < 60) : (i += 1) _ = env.router.route(.{ .name = "tick", .id = "" });
    const left = env.store.getLayout(pb.spacer_id, .width).?.dimension.value;
    try testing.expect(left >= 0 and left <= TRAVEL_SPAN_PCT);
    try testing.expect(pb.phase < 1.0);
}

test "ProgressBar removes its tick handler on unmount" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(ProgressBar, .{ .indeterminate = true });
    b.close();
    try testing.expectEqual(@as(usize, 1), env.router.tick_handlers.items.len);

    // Reconcile the bar away → onUnmount removes the tick handler.
    try b.rootAt(root);
    b.close();
    try testing.expectEqual(@as(usize, 0), env.router.tick_handlers.items.len);
}

// Regression: the sweep animated `margin_left` in %, which the solver ignores
// (margins are px-only), so on screen the fill never left the start of the track.
// The behaviour that matters is the fill's GEOMETRY, so solve a real layout.
test "ProgressBar indeterminate: the fill actually moves along the track after layout" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    const pb = try mountProgress(&env, .{ .indeterminate = true });
    const flexbox = @import("../layout/flexbox.zig");
    var engine = flexbox.LayoutEngine.init(&env.registry, &env.store, null);
    engine.solve(0, 0, 0, 200, 20);
    const x0 = env.registry.getNode(pb.fill_id).?.geometry.x;

    var i: usize = 0;
    while (i < 1) : (i += 1) _ = env.router.route(.{ .name = "tick", .id = "" });
    env.registry.markLayoutDirty(pb.spacer_id);
    engine.solve(0, 0, 0, 200, 20);
    const x1 = env.registry.getNode(pb.fill_id).?.geometry.x;
    // 200px track; one tick moves the spacer TRAVEL_STEP * 70% of the track.
    try testing.expectApproxEqAbs(x0 + TRAVEL_STEP * TRAVEL_SPAN_PCT / 100.0 * 200.0, x1, 0.5);
    // And it stays a 30% block.
    try testing.expectApproxEqAbs(@as(f32, 60), env.registry.getNode(pb.fill_id).?.geometry.width, 0.5);
}
