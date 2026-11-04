const std = @import("std");
const reg = @import("registry.zig");
const props = @import("properties.zig");
const prop_parse = @import("prop_parse.zig");

// ── Easing Functions ──────────────────────────────────────────────────────────
//
// All easing functions: f(0) = 0, f(1) = 1.
// Input `t` is clamped to [0, 1] before calling.

pub const Easing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
    spring,

    pub fn apply(self: Easing, t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        return switch (self) {
            .linear => clamped,
            .ease_in => easeIn(clamped),
            .ease_out => easeOut(clamped),
            .ease_in_out => easeInOut(clamped),
            .spring => springEasing(clamped),
        };
    }
};

/// Quadratic ease-in: slow start, fast end.
fn easeIn(t: f32) f32 {
    return t * t;
}

/// Quadratic ease-out: fast start, slow end.
fn easeOut(t: f32) f32 {
    return 1.0 - (1.0 - t) * (1.0 - t);
}

/// Cubic ease-in-out: slow start, fast middle, slow end.
fn easeInOut(t: f32) f32 {
    if (t < 0.5) {
        return 2.0 * t * t;
    } else {
        const shifted = -2.0 * t + 2.0;
        return 1.0 - shifted * shifted / 2.0;
    }
}

/// Damped spring with slight overshoot. Feels organic for UI elements.
/// Approximation: 1 - cos(t * π * 2.5) * e^(-t * 6)
fn springEasing(t: f32) f32 {
    if (t >= 1.0) return 1.0;
    const decay = @exp(-t * 6.0);
    const oscillation = @cos(t * std.math.pi * 2.5);
    return 1.0 - oscillation * decay;
}

// ── Animation Target ──────────────────────────────────────────────────────────

pub const AnimTarget = union(enum) {
    layout: struct { node_id: reg.NodeId, key: props.LayoutKey },
    style: struct { node_id: reg.NodeId, key: props.StyleKey },

    pub fn nodeId(self: AnimTarget) reg.NodeId {
        return switch (self) {
            .layout => |l| l.node_id,
            .style => |s| s.node_id,
        };
    }

    pub fn eql(a: AnimTarget, b: AnimTarget) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) return false;
        return switch (a) {
            .layout => |la| la.node_id == b.layout.node_id and la.key == b.layout.key,
            .style => |sa| sa.node_id == b.style.node_id and sa.key == b.style.key,
        };
    }
};

// ── Animation ─────────────────────────────────────────────────────────────────

pub const Animation = struct {
    target: AnimTarget,
    from: f32,
    to: f32,
    duration_ms: f32,
    elapsed_ms: f32 = 0,
    easing: Easing = .ease_out,
    is_complete: bool = false,
    /// When set, the animation loops instead of completing: on reaching the end it
    /// wraps `elapsed_ms` back to the start (preserving overflow) and keeps running.
    /// Used for indeterminate/looping indicators (e.g. a traveling progress bar).
    repeat: bool = false,
    /// Unit the interpolated value is written in. `px` covers most animations, but a
    /// value that must track a resizable parent (a progress fill sweeping across its
    /// track) has to animate in `percent` — otherwise the widget would have to know
    /// its resolved pixel width at build time, before layout has run.
    unit: props.DimUnit = .px,

    /// Current interpolated value based on elapsed time and easing.
    pub fn currentValue(self: *const Animation) f32 {
        if (self.duration_ms <= 0) return self.to;
        const t = std.math.clamp(self.elapsed_ms / self.duration_ms, 0.0, 1.0);
        const eased = self.easing.apply(t);
        return self.from + (self.to - self.from) * eased;
    }
};

// ── AnimationEngine ───────────────────────────────────────────────────────────

pub const AnimationEngine = struct {
    animations: std.array_list.Managed(Animation),

    pub fn init(allocator: std.mem.Allocator) AnimationEngine {
        return .{
            .animations = std.array_list.Managed(Animation).init(allocator),
        };
    }

    pub fn deinit(self: *AnimationEngine) void {
        self.animations.deinit();
    }

    /// Add a new animation. If one already exists for the same target, replace it.
    /// This prevents duplicate animations on the same property (e.g. rapid scroll).
    pub fn add(
        self: *AnimationEngine,
        target: AnimTarget,
        from: f32,
        to: f32,
        duration_ms: f32,
        easing: Easing,
    ) !void {
        // Check for existing animation on the same target — replace it
        for (self.animations.items) |*anim| {
            if (AnimTarget.eql(anim.target, target)) {
                anim.from = from;
                anim.to = to;
                anim.duration_ms = duration_ms;
                anim.elapsed_ms = 0;
                anim.easing = easing;
                anim.is_complete = false;
                return;
            }
        }
        // No existing animation for this target — create new
        try self.animations.append(.{
            .target = target,
            .from = from,
            .to = to,
            .duration_ms = duration_ms,
            .easing = easing,
        });
    }

    /// Like `add`, but the animation loops forever (see `Animation.repeat`) instead
    /// of completing — for indeterminate indicators. Replaces any animation on the
    /// same target.
    pub fn addRepeating(
        self: *AnimationEngine,
        target: AnimTarget,
        from: f32,
        to: f32,
        duration_ms: f32,
        easing: Easing,
        unit: props.DimUnit,
    ) !void {
        try self.add(target, from, to, duration_ms, easing);
        for (self.animations.items) |*anim| {
            if (AnimTarget.eql(anim.target, target)) {
                anim.repeat = true;
                anim.unit = unit;
                return;
            }
        }
    }

    /// Whether a (still-running) animation is already registered for `target`. Lets a
    /// widget register a looping animation once per mount instead of on every rebuild
    /// — `add` resets `elapsed_ms`, so re-registering each build would restart the
    /// loop forever and freeze it at its first frame.
    pub fn has(self: *const AnimationEngine, target: AnimTarget) bool {
        for (self.animations.items) |*anim| {
            if (AnimTarget.eql(anim.target, target) and !anim.is_complete) return true;
        }
        return false;
    }

    /// Advance all animations by `delta_ms` and write interpolated values to the store.
    /// Returns `true` if any animation was active this frame (caller should re-layout).
    pub fn tick(self: *AnimationEngine, delta_ms: f32, store: *props.PropertyStore) bool {
        if (self.animations.items.len == 0) return false;

        var had_active: bool = false;

        for (self.animations.items) |*anim| {
            if (anim.is_complete) continue;

            had_active = true;
            anim.elapsed_ms += delta_ms;

            if (anim.elapsed_ms >= anim.duration_ms) {
                if (anim.repeat and anim.duration_ms > 0) {
                    // Loop: wrap the overflow back to the start and keep running.
                    anim.elapsed_ms -= anim.duration_ms;
                    if (anim.elapsed_ms >= anim.duration_ms) anim.elapsed_ms = 0; // huge delta guard
                } else {
                    anim.elapsed_ms = anim.duration_ms;
                    anim.is_complete = true;
                }
            }

            const value = anim.currentValue();

            // Write the interpolated value into the PropertyStore
            switch (anim.target) {
                // Each key is written in the shape its reader expects (prop_parse's
                // kind table): opacity, z_index, flex_grow … as numbers, lengths as
                // dimensions. Writing every non-opacity key as a dimension crashed the
                // renderer on number-typed keys and was ignored by the solver.
                .layout => |l| {
                    store.setLayout(l.node_id, l.key, prop_parse.animatedValue(prop_parse.layoutKind(l.key), value, anim.unit)) catch {};
                },
                .style => |s| {
                    store.setStyle(s.node_id, s.key, prop_parse.animatedValue(prop_parse.styleKind(s.key), value, .px)) catch {};
                },
            }
        }

        // Remove completed animations (swap-remove for O(1) per removal)
        var i: usize = 0;
        while (i < self.animations.items.len) {
            if (self.animations.items[i].is_complete) {
                _ = self.animations.swapRemove(i);
                // Don't increment — check the element that was swapped in
            } else {
                i += 1;
            }
        }

        return had_active;
    }

    /// Cancel all animations targeting a specific node.
    pub fn cancelNode(self: *AnimationEngine, node_id: reg.NodeId) void {
        var i: usize = 0;
        while (i < self.animations.items.len) {
            if (self.animations.items[i].target.nodeId() == node_id) {
                _ = self.animations.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Cancel all running animations.
    pub fn clear(self: *AnimationEngine) void {
        self.animations.clearRetainingCapacity();
    }

    /// Returns true if any animation is currently running.
    pub fn isActive(self: *const AnimationEngine) bool {
        return self.animations.items.len > 0;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Easing — boundary values" {
    // All easing functions should produce 0 at t=0 and 1 at t=1
    const easings = [_]Easing{ .linear, .ease_in, .ease_out, .ease_in_out, .spring };
    for (easings) |e| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), e.apply(0.0), 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), e.apply(1.0), 0.01);
    }
}

test "Easing — clamping" {
    // Negative and >1 inputs should be clamped
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Easing.linear.apply(-5.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Easing.linear.apply(99.0), 0.001);
}

test "Easing — ease_out is faster initially than ease_in" {
    const mid = 0.5;
    const ease_in_mid = Easing.ease_in.apply(mid);
    const ease_out_mid = Easing.ease_out.apply(mid);
    // ease_out should be further along at t=0.5 than ease_in
    try std.testing.expect(ease_out_mid > ease_in_mid);
}

test "Animation — currentValue interpolates correctly" {
    var anim = Animation{
        .target = .{ .layout = .{ .node_id = 0, .key = .margin_top } },
        .from = 0.0,
        .to = 100.0,
        .duration_ms = 200.0,
        .elapsed_ms = 100.0,
        .easing = .linear,
    };
    // At t=0.5 with linear easing, value should be 50
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), anim.currentValue(), 0.01);

    // At completion
    anim.elapsed_ms = 200.0;
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), anim.currentValue(), 0.01);
}

test "Animation — zero duration jumps to target" {
    const anim = Animation{
        .target = .{ .layout = .{ .node_id = 0, .key = .width } },
        .from = 10.0,
        .to = 50.0,
        .duration_ms = 0,
        .easing = .ease_out,
    };
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), anim.currentValue(), 0.01);
}

test "AnimationEngine — add, tick, and complete" {
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(0);

    var engine = AnimationEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.add(
        .{ .layout = .{ .node_id = 0, .key = .margin_top } },
        0.0,
        100.0,
        200.0,
        .linear,
    );
    try std.testing.expect(engine.isActive());

    // Tick halfway
    _ = engine.tick(100.0, &store);
    const mid_val = store.getLayout(0, .margin_top).?.dimension.value;
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), mid_val, 0.5);

    // Tick to completion
    _ = engine.tick(100.0, &store);
    const final_val = store.getLayout(0, .margin_top).?.dimension.value;
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), final_val, 0.01);

    // Animation should be removed after completion
    try std.testing.expect(!engine.isActive());
}

test "AnimationEngine — replace existing animation on same target" {
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(0);

    var engine = AnimationEngine.init(std.testing.allocator);
    defer engine.deinit();

    // First animation
    try engine.add(
        .{ .layout = .{ .node_id = 0, .key = .margin_top } },
        0.0,
        100.0,
        500.0,
        .linear,
    );
    try std.testing.expectEqual(@as(usize, 1), engine.animations.items.len);

    // Replace with new animation on same target
    try engine.add(
        .{ .layout = .{ .node_id = 0, .key = .margin_top } },
        50.0,
        200.0,
        300.0,
        .ease_out,
    );
    // Should still be 1 animation, not 2
    try std.testing.expectEqual(@as(usize, 1), engine.animations.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), engine.animations.items[0].from, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), engine.animations.items[0].to, 0.01);
}

test "AnimationEngine — repeating animation loops instead of completing" {
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(0);

    var engine = AnimationEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Traveling bar: margin_left 0 → 70, looping over 300 ms.
    try engine.addRepeating(.{ .layout = .{ .node_id = 0, .key = .margin_left } }, 0.0, 70.0, 300.0, .linear, .percent);

    // Tick past the full duration + a bit: the animation must still be alive and
    // the value must have wrapped back near the start (elapsed 360 → 60 → 20% of 70).
    _ = engine.tick(360.0, &store);
    try std.testing.expect(engine.isActive());
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), store.getLayout(0, .margin_left).?.dimension.value, 0.5);

    // Another full loop keeps it alive.
    _ = engine.tick(300.0, &store);
    try std.testing.expect(engine.isActive());
}

test "AnimationEngine — cancelNode removes only targeted node" {
    var engine = AnimationEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.add(.{ .layout = .{ .node_id = 0, .key = .margin_top } }, 0, 10, 100, .linear);
    try engine.add(.{ .layout = .{ .node_id = 1, .key = .margin_top } }, 0, 20, 100, .linear);
    try engine.add(.{ .layout = .{ .node_id = 0, .key = .width } }, 0, 30, 100, .linear);
    try std.testing.expectEqual(@as(usize, 3), engine.animations.items.len);

    engine.cancelNode(0);
    try std.testing.expectEqual(@as(usize, 1), engine.animations.items.len);
    try std.testing.expectEqual(@as(reg.NodeId, 1), engine.animations.items[0].target.nodeId());
}

test "AnimationEngine — clear removes all" {
    var engine = AnimationEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.add(.{ .layout = .{ .node_id = 0, .key = .width } }, 0, 10, 100, .linear);
    try engine.add(.{ .layout = .{ .node_id = 1, .key = .height } }, 0, 20, 100, .linear);
    try std.testing.expect(engine.isActive());

    engine.clear();
    try std.testing.expect(!engine.isActive());
}
