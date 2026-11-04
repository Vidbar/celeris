//! Vector path geometry for `NodeType.path`.
//!
//! A path is a flat, comparable array of `PathVertex` — `move` / line / `cubic`
//! / `close` — which the C-ABI passes as `[*]const f32 + len` and the
//! reconciler diffs as plain bytes. This module owns the two derived things the
//! rest of the engine needs from it: the flattened line-segment list the
//! renderer strokes (`flatten`), and the bounding box layout uses for intrinsic
//! sizing (`bounds`). Nothing here allocates a GPU resource or mentions a
//! backend; it is pure geometry over `std`.

const std = @import("std");

/// One vertex of a path. `extern` and all-`f32` on purpose: the whole array is
/// one contiguous `f32` blob across the C-ABI, and two paths compare byte-for-
/// byte. Stride is `stride_f32` floats.
///
/// Segment kind is implicit in the control points of the vertex the segment
/// *arrives at*:
///   * `c1 == previous on-curve point` AND `c2 == (x, y)`  → straight line
///     (the degenerate cubic for a line — a builder's `lineTo` writes this).
///   * all four control coordinates zero                   → also a straight
///     line (tolerated so a hand-rolled zero-filled vertex still works).
///   * otherwise                                           → cubic Bézier with
///     control points `c1`, `c2`.
pub const PathVertex = extern struct {
    x: f32,
    y: f32,
    c1x: f32 = 0,
    c1y: f32 = 0,
    c2x: f32 = 0,
    c2y: f32 = 0,
    /// `!= 0` → start a new subpath here (pen up, then move). The first vertex
    /// of a path is an implicit move regardless.
    move: f32 = 0,
    /// `!= 0` → after this vertex, close the current subpath with a straight
    /// segment back to its move point.
    close: f32 = 0,
};

/// Floats per `PathVertex`. `celeris_node_set_path`'s float `count` must be a
/// multiple of this.
pub const stride_f32: usize = @divExact(@sizeOf(PathVertex), @sizeOf(f32));

comptime {
    std.debug.assert(stride_f32 == 8);
}

/// A flattened straight segment in path-local coordinates. Style (color, width,
/// opacity, z, clip) is attached by the renderer's bake, not here.
pub const PathSegment = struct {
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
};

pub const Bounds = struct {
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,

    pub fn width(self: Bounds) f32 {
        return self.max_x - self.min_x;
    }
    pub fn height(self: Bounds) f32 {
        return self.max_y - self.min_y;
    }
};

/// Default flatten tolerance in *path* pixels (paths are unscaled today, so this
/// is also screen pixels). ~0.3px chord deviation is below one device pixel at
/// the scales a node editor typically uses.
pub const default_tolerance: f32 = 0.3;

const max_subdiv_depth: usize = 16;

const SegList = std.array_list.Managed(PathSegment);

fn approxEq(ax: f32, ay: f32, bx: f32, by: f32) bool {
    return @abs(ax - bx) < 0.01 and @abs(ay - by) < 0.01;
}

fn isLineSegment(v: PathVertex, from_x: f32, from_y: f32) bool {
    if (v.c1x == 0 and v.c1y == 0 and v.c2x == 0 and v.c2y == 0) return true;
    return approxEq(v.c1x, v.c1y, from_x, from_y) and approxEq(v.c2x, v.c2y, v.x, v.y);
}

/// Squared distance from point `p` to the infinite line through `a`,`b`. Used
/// only for the flatness test, so the degenerate `a == b` case (returns the
/// squared distance to the shared point) is fine.
fn distSqToLine(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const len_sq = dx * dx + dy * dy;
    if (len_sq < 1e-9) {
        const ex = px - ax;
        const ey = py - ay;
        return ex * ex + ey * ey;
    }
    const cross = (px - ax) * dy - (py - ay) * dx;
    return (cross * cross) / len_sq;
}

fn flattenCubic(
    p0x: f32,
    p0y: f32,
    p1x: f32,
    p1y: f32,
    p2x: f32,
    p2y: f32,
    p3x: f32,
    p3y: f32,
    tol_sq: f32,
    depth: usize,
    out: *SegList,
) !void {
    if (depth >= max_subdiv_depth or
        (distSqToLine(p1x, p1y, p0x, p0y, p3x, p3y) <= tol_sq and
            distSqToLine(p2x, p2y, p0x, p0y, p3x, p3y) <= tol_sq))
    {
        try out.append(.{ .ax = p0x, .ay = p0y, .bx = p3x, .by = p3y });
        return;
    }
    // de Casteljau split at t = 0.5
    const p01x = (p0x + p1x) * 0.5;
    const p01y = (p0y + p1y) * 0.5;
    const p12x = (p1x + p2x) * 0.5;
    const p12y = (p1y + p2y) * 0.5;
    const p23x = (p2x + p3x) * 0.5;
    const p23y = (p2y + p3y) * 0.5;
    const p012x = (p01x + p12x) * 0.5;
    const p012y = (p01y + p12y) * 0.5;
    const p123x = (p12x + p23x) * 0.5;
    const p123y = (p12y + p23y) * 0.5;
    const mx = (p012x + p123x) * 0.5;
    const my = (p012y + p123y) * 0.5;
    try flattenCubic(p0x, p0y, p01x, p01y, p012x, p012y, mx, my, tol_sq, depth + 1, out);
    try flattenCubic(mx, my, p123x, p123y, p23x, p23y, p3x, p3y, tol_sq, depth + 1, out);
}

/// Flattens `verts` to straight segments, allocated from `gpa` (caller owns the
/// returned slice — bake hands it a frame arena). Lines pass through as one
/// segment; cubics are adaptively subdivided to `tolerance` px (`<= 0` → the
/// default). An empty or single-vertex path yields an empty slice.
pub fn flatten(verts: []const PathVertex, tolerance: f32, gpa: std.mem.Allocator) ![]PathSegment {
    var out = SegList.init(gpa);
    errdefer out.deinit();
    if (verts.len < 2) return out.toOwnedSlice();

    const tol = if (tolerance > 0) tolerance else default_tolerance;
    const tol_sq = tol * tol;

    var cur_x: f32 = verts[0].x;
    var cur_y: f32 = verts[0].y;
    var sub_x: f32 = verts[0].x;
    var sub_y: f32 = verts[0].y;

    for (verts[1..]) |v| {
        if (v.move != 0) {
            cur_x = v.x;
            cur_y = v.y;
            sub_x = v.x;
            sub_y = v.y;
            continue;
        }
        if (isLineSegment(v, cur_x, cur_y)) {
            try out.append(.{ .ax = cur_x, .ay = cur_y, .bx = v.x, .by = v.y });
        } else {
            try flattenCubic(cur_x, cur_y, v.c1x, v.c1y, v.c2x, v.c2y, v.x, v.y, tol_sq, 0, &out);
        }
        cur_x = v.x;
        cur_y = v.y;
        if (v.close != 0) {
            if (!approxEq(cur_x, cur_y, sub_x, sub_y)) {
                try out.append(.{ .ax = cur_x, .ay = cur_y, .bx = sub_x, .by = sub_y });
            }
            cur_x = sub_x;
            cur_y = sub_y;
        }
    }
    return out.toOwnedSlice();
}

/// Axis-aligned bounds of the path — the union of every on-curve point and, for
/// cubic segments, their control points (conservative: a Bézier stays inside its
/// control hull). Used for intrinsic layout sizing. Empty path → all-zero.
pub fn bounds(verts: []const PathVertex) Bounds {
    if (verts.len == 0) return .{};
    var b = Bounds{
        .min_x = verts[0].x,
        .min_y = verts[0].y,
        .max_x = verts[0].x,
        .max_y = verts[0].y,
    };
    var cur_x: f32 = verts[0].x;
    var cur_y: f32 = verts[0].y;
    for (verts, 0..) |v, i| {
        expand(&b, v.x, v.y);
        if (i > 0 and v.move == 0 and !isLineSegment(v, cur_x, cur_y)) {
            expand(&b, v.c1x, v.c1y);
            expand(&b, v.c2x, v.c2y);
        }
        cur_x = v.x;
        cur_y = v.y;
    }
    return b;
}

fn expand(b: *Bounds, x: f32, y: f32) void {
    b.min_x = @min(b.min_x, x);
    b.min_y = @min(b.min_y, y);
    b.max_x = @max(b.max_x, x);
    b.max_y = @max(b.max_y, y);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "flatten: a straight line is one segment, endpoints preserved" {
    const verts = [_]PathVertex{
        .{ .x = 10, .y = 10 },
        .{ .x = 90, .y = 40 }, // zero control points → line
    };
    const segs = try flatten(&verts, 0, testing.allocator);
    defer testing.allocator.free(segs);

    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqual(@as(f32, 10), segs[0].ax);
    try testing.expectEqual(@as(f32, 90), segs[0].bx);
    try testing.expectEqual(@as(f32, 40), segs[0].by);
}

test "flatten: degenerate-cubic line encoding is also one segment" {
    const verts = [_]PathVertex{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0, .c1x = 0, .c1y = 0, .c2x = 100, .c2y = 0 },
    };
    const segs = try flatten(&verts, 0, testing.allocator);
    defer testing.allocator.free(segs);
    try testing.expectEqual(@as(usize, 1), segs.len);
}

test "flatten: a cubic subdivides, stays within tolerance, and is chain-connected" {
    // A symmetric arch from (0,0) to (100,0), control points pulling up.
    const verts = [_]PathVertex{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0, .c1x = 25, .c1y = 60, .c2x = 75, .c2y = 60 },
    };
    const segs = try flatten(&verts, 0.25, testing.allocator);
    defer testing.allocator.free(segs);

    try testing.expect(segs.len > 4); // actually curved → many segments
    // Chain: each segment starts where the previous ended.
    try testing.expectEqual(@as(f32, 0), segs[0].ax);
    for (segs[1..], 0..) |s, i| {
        try testing.expectApproxEqAbs(segs[i].bx, s.ax, 0.001);
        try testing.expectApproxEqAbs(segs[i].by, s.ay, 0.001);
    }
    const last = segs[segs.len - 1];
    try testing.expectApproxEqAbs(@as(f32, 100), last.bx, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), last.by, 0.001);

    // The analytic curve peaks at t=0.5, y = 0.75 * 60 = 45. Some flattened
    // vertex must land near there (tolerance is on the chord, not the value).
    var peak: f32 = 0;
    for (segs) |s| peak = @max(peak, s.ay);
    try testing.expectApproxEqAbs(@as(f32, 45), peak, 1.0);
}

test "flatten: move starts a new subpath (no connecting segment), close returns to start" {
    const verts = [_]PathVertex{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10, .close = 1 }, // closes back to (0,0)
        .{ .x = 50, .y = 50, .move = 1 }, // new subpath — no segment from (0,0)
        .{ .x = 60, .y = 50 },
    };
    const segs = try flatten(&verts, 0, testing.allocator);
    defer testing.allocator.free(segs);

    // (0,0)->(10,0), (10,0)->(10,10), close (10,10)->(0,0), then (50,50)->(60,50)
    try testing.expectEqual(@as(usize, 4), segs.len);
    try testing.expectEqual(@as(f32, 0), segs[2].bx); // close segment lands on subpath start
    try testing.expectEqual(@as(f32, 0), segs[2].by);
    try testing.expectEqual(@as(f32, 50), segs[3].ax); // new subpath, not chained
}

test "flatten: fewer than two vertices produces nothing" {
    const a = try flatten(&[_]PathVertex{}, 0, testing.allocator);
    defer testing.allocator.free(a);
    const b = try flatten(&[_]PathVertex{.{ .x = 1, .y = 2 }}, 0, testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 0), a.len);
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "bounds: unions on-curve points and cubic control points" {
    const verts = [_]PathVertex{
        .{ .x = 10, .y = 10 },
        .{ .x = 20, .y = 10 }, // line — controls ignored
        .{ .x = 30, .y = 10, .c1x = 25, .c1y = -40, .c2x = 35, .c2y = 80 }, // cubic
    };
    const b = bounds(&verts);
    try testing.expectEqual(@as(f32, 10), b.min_x);
    try testing.expectEqual(@as(f32, -40), b.min_y);
    try testing.expectEqual(@as(f32, 35), b.max_x);
    try testing.expectEqual(@as(f32, 80), b.max_y);
}
