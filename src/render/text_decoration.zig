//! Geometry of text decoration lines — underline (single / double / wavy /
//! dotted / dashed), strikethrough, overline — as quads the glyph pipeline draws
//! with the atlas line sprite (`text.LINE_SPRITE`). Pure and GPU-free, so tests
//! can check where every line lands.
//!
//! Everything here is in PHYSICAL px. Straight lines are snapped to whole pixels
//! with an integer thickness of at least 1px, so they are crisp at any scale;
//! only the wavy underline is antialiased (1px coverage ramps on both sides).
//! Placement and thickness come from the face's `post` / `OS/2` tables
//! (`text.DecorationMetrics`). Nothing here affects measurement or layout.

const std = @import("std");
const text = @import("text.zig");

/// One quad: edge A (a0→a1) and edge B (b0→b1), each with the sprite `v` it
/// samples. A solid band has `va == vb == v_solid`; an antialiasing ramp goes
/// `v_edge` (inside) → `v_clear` (outside).
pub const Quad = struct {
    a0: [2]f32,
    a1: [2]f32,
    b0: [2]f32,
    b1: [2]f32,
    va: f32,
    vb: f32,
};

/// CSS paint order: underline and overline go under the glyphs, the
/// strikethrough over them.
pub const Layer = enum { below_text, above_text };

pub const Spec = struct {
    /// Horizontal extent of the line's glyphs.
    x0: f32,
    x1: f32,
    /// Snapped baseline.
    baseline: f32,
    /// Font size.
    size: f32,
    metrics: text.DecorationMetrics,
    /// Ascent / em of the face — where the overline sits.
    ascent_ratio: f32,
    deco: text.TextDecoration,
};

fn thick(ratio: f32, size: f32) f32 {
    return @max(1.0, @round(ratio * size));
}

fn hband(out: *std.array_list.Managed(Quad), x0: f32, x1: f32, top: f32, t: f32) !void {
    if (x1 <= x0) return;
    const v = text.LINE_SPRITE.v_solid;
    try out.append(.{ .a0 = .{ x0, top }, .a1 = .{ x1, top }, .b0 = .{ x0, top + t }, .b1 = .{ x1, top + t }, .va = v, .vb = v });
}

/// Repeating dashes of length `on` every `on + off`, clipped to [x0, x1].
fn dashes(out: *std.array_list.Managed(Quad), x0: f32, x1: f32, top: f32, t: f32, on: f32, off: f32) !void {
    var x = x0;
    while (x < x1) : (x += on + off) try hband(out, x, @min(x + on, x1), top, t);
}

/// A straight segment p→q of width `t`, antialiased across its width: a solid
/// core plus a 1px ramp straddling each edge (exact coverage integrates to `t`).
fn stroke(out: *std.array_list.Managed(Quad), p: [2]f32, q: [2]f32, t: f32) !void {
    const dx = q[0] - p[0];
    const dy = q[1] - p[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    const n = [2]f32{ -dy / len, dx / len };
    const S = text.LINE_SPRITE;
    const half = t / 2.0;
    const at = struct {
        fn f(pt: [2]f32, nn: [2]f32, d: f32) [2]f32 {
            return .{ pt[0] + nn[0] * d, pt[1] + nn[1] * d };
        }
    }.f;
    const inner = half - 0.5;
    if (inner > 0) {
        try out.append(.{ .a0 = at(p, n, -inner), .a1 = at(q, n, -inner), .b0 = at(p, n, inner), .b1 = at(q, n, inner), .va = S.v_solid, .vb = S.v_solid });
    }
    const in_edge = @max(inner, 0);
    // Outer ramps on both sides: inside edge full coverage → outside edge none.
    try out.append(.{ .a0 = at(p, n, in_edge), .a1 = at(q, n, in_edge), .b0 = at(p, n, half + 0.5), .b1 = at(q, n, half + 0.5), .va = S.v_edge, .vb = S.v_clear });
    try out.append(.{ .a0 = at(p, n, -in_edge), .a1 = at(q, n, -in_edge), .b0 = at(p, n, -(half + 0.5)), .b1 = at(q, n, -(half + 0.5)), .va = S.v_edge, .vb = S.v_clear });
}

/// Top edge of the underline: from the face's metrics, at least 1px below the baseline.
pub fn underlineTop(spec: Spec) f32 {
    return @max(spec.baseline + 1.0, @round(spec.baseline + spec.metrics.underline_top * spec.size));
}

pub fn underlineThickness(spec: Spec) f32 {
    return thick(spec.metrics.underline_thickness, spec.size);
}

pub fn strikeTop(spec: Spec) f32 {
    return @round(spec.baseline - spec.metrics.strike_top * spec.size);
}

pub fn overlineTop(spec: Spec) f32 {
    return @round(spec.baseline - spec.ascent_ratio * spec.size);
}

/// Wave amplitude (half the peak-to-trough height) and wavelength of a wavy
/// underline at `size`, in px.
pub fn waveShape(size: f32, t: f32) struct { amp: f32, wavelength: f32 } {
    const amp = @max(t, @round(size * 0.06));
    return .{ .amp = amp, .wavelength = amp * 6.0 };
}

/// Appends the quads of `spec.deco` that paint in `layer`.
pub fn emit(spec: Spec, layer: Layer, out: *std.array_list.Managed(Quad)) !void {
    if (spec.x1 <= spec.x0) return;
    const d = spec.deco;
    switch (layer) {
        .above_text => if (d.strikethrough) {
            try hband(out, spec.x0, spec.x1, strikeTop(spec), thick(spec.metrics.strike_thickness, spec.size));
        },
        .below_text => {
            const t = underlineThickness(spec);
            if (d.overline) try hband(out, spec.x0, spec.x1, overlineTop(spec), t);
            const top = underlineTop(spec);
            switch (d.underline) {
                .none => {},
                .single => try hband(out, spec.x0, spec.x1, top, t),
                .double => {
                    try hband(out, spec.x0, spec.x1, top, t);
                    try hband(out, spec.x0, spec.x1, top + 2 * t, t);
                },
                .dotted => try dashes(out, spec.x0, spec.x1, top, t, t, t),
                .dashed => try dashes(out, spec.x0, spec.x1, top, t, @max(3 * t, 3), @max(2 * t, 2)),
                .wavy => {
                    const w = waveShape(spec.size, t);
                    // The wave's crest sits on the underline's top edge.
                    const cy = top + w.amp;
                    const steps_per_wave: f32 = 8;
                    const dx = w.wavelength / steps_per_wave;
                    var x = spec.x0;
                    var prev = [2]f32{ x, cy };
                    while (x < spec.x1) {
                        x = @min(x + dx, spec.x1);
                        const ph = (x - spec.x0) / w.wavelength * 2.0 * std.math.pi;
                        const cur = [2]f32{ x, cy + w.amp * @sin(ph) };
                        try stroke(out, prev, cur, t);
                        prev = cur;
                    }
                },
            }
        },
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testSpec(deco: text.TextDecoration) Spec {
    return .{
        .x0 = 10,
        .x1 = 110,
        .baseline = 50,
        .size = 20,
        .metrics = .{ .underline_top = 0.1, .underline_thickness = 0.05, .strike_top = 0.3, .strike_thickness = 0.05 },
        .ascent_ratio = 0.9,
        .deco = deco,
    };
}

fn bounds(qs: []const Quad) [4]f32 {
    var b = [4]f32{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (qs) |q| for ([_][2]f32{ q.a0, q.a1, q.b0, q.b1 }) |p| {
        b[0] = @min(b[0], p[0]);
        b[1] = @min(b[1], p[1]);
        b[2] = @max(b[2], p[0]);
        b[3] = @max(b[3], p[1]);
    };
    return b;
}

test "no decoration emits nothing in either layer" {
    var out = std.array_list.Managed(Quad).init(testing.allocator);
    defer out.deinit();
    try emit(testSpec(.{}), .below_text, &out);
    try emit(testSpec(.{}), .above_text, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "single underline spans the glyphs below the baseline at the font's metrics" {
    var out = std.array_list.Managed(Quad).init(testing.allocator);
    defer out.deinit();
    try emit(testSpec(.{ .underline = .single }), .below_text, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const b = bounds(out.items);
    try testing.expectEqual([4]f32{ 10, 52, 110, 53 }, b); // top = 50 + 0.1×20, t = 1
    // Underlines never paint over the glyphs.
    out.clearRetainingCapacity();
    try emit(testSpec(.{ .underline = .single }), .above_text, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "double underline: two bands one thickness apart" {
    var out = std.array_list.Managed(Quad).init(testing.allocator);
    defer out.deinit();
    try emit(testSpec(.{ .underline = .double }), .below_text, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(f32, 52), out.items[0].a0[1]);
    try testing.expectEqual(@as(f32, 54), out.items[1].a0[1]);
}

test "dotted and dashed stay within the glyph span and leave gaps" {
    var out = std.array_list.Managed(Quad).init(testing.allocator);
    defer out.deinit();
    try emit(testSpec(.{ .underline = .dotted }), .below_text, &out);
    try testing.expectEqual(@as(usize, 50), out.items.len); // 1px on, 1px off over 100px
    try testing.expect(bounds(out.items)[2] <= 110);
    out.clearRetainingCapacity();
    try emit(testSpec(.{ .underline = .dashed }), .below_text, &out);
    try testing.expectEqual(@as(usize, 20), out.items.len); // 3 on, 2 off
    var covered: f32 = 0;
    for (out.items) |q| covered += q.a1[0] - q.a0[0];
    try testing.expectEqual(@as(f32, 60), covered);
}

test "wavy underline oscillates under the baseline across the whole span" {
    var out = std.array_list.Managed(Quad).init(testing.allocator);
    defer out.deinit();
    try emit(testSpec(.{ .underline = .wavy }), .below_text, &out);
    try testing.expect(out.items.len > 10);
    const b = bounds(out.items);
    const w = waveShape(20, 1);
    try testing.expect(b[1] >= 50); // never above the baseline
    try testing.expect(b[3] - b[1] >= 2 * w.amp); // peak-to-trough
    try testing.expectApproxEqAbs(@as(f32, 10), b[0], 1.0);
    try testing.expectApproxEqAbs(@as(f32, 110), b[2], 1.0);
    // Antialiased: some quads ramp to clear coverage.
    var ramps: usize = 0;
    for (out.items) |q| {
        if (q.vb == text.LINE_SPRITE.v_clear) ramps += 1;
    }
    try testing.expect(ramps > 0);
}

test "strikethrough paints over the glyphs; overline under them at the ascent" {
    var out = std.array_list.Managed(Quad).init(testing.allocator);
    defer out.deinit();
    try emit(testSpec(.{ .strikethrough = true, .overline = true }), .above_text, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(f32, 44), out.items[0].a0[1]); // 50 − 0.3×20
    out.clearRetainingCapacity();
    try emit(testSpec(.{ .strikethrough = true, .overline = true }), .below_text, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(f32, 32), out.items[0].a0[1]); // 50 − 0.9×20
}

test "lines are at least one pixel thick at tiny sizes" {
    var s = testSpec(.{ .underline = .single, .strikethrough = true });
    s.size = 6;
    try testing.expectEqual(@as(f32, 1), underlineThickness(s));
    try testing.expect(underlineTop(s) >= s.baseline + 1);
}
