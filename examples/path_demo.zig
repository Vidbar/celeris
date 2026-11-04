//! Visual check for `NodeType.path` rendering.
//!
//! Draws five shapes that exercise every path feature — a straight
//! diagonal, a single cubic, an elbow (two lines), a ~15-segment flattened
//! "connection" bézier, and a closed triangle — each at three scales, plus one
//! translucent stroke to eyeball the (known) opaque-only limitation.
//!
//! What to look for: no beading at
//! joints on the opaque bézier, clean round caps, the connection reads as one
//! stroke, and no z-order inversion against the rectangular "node" cards.
//!
//! Run: `zig build path_demo`   Compiled in CI via `zig build examples`.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;
const PV = fw.PathVertex;

/// Scales the on-curve + control coords of a vertex list by `k` (about the
/// origin). Comptime so each demo row is a plain literal array.
fn scaled(comptime verts: []const PV, comptime k: f32) [verts.len]PV {
    var out: [verts.len]PV = undefined;
    for (verts, 0..) |v, i| {
        out[i] = .{
            .x = v.x * k,
            .y = v.y * k,
            .c1x = v.c1x * k,
            .c1y = v.c1y * k,
            .c2x = v.c2x * k,
            .c2y = v.c2y * k,
            .move = v.move,
            .close = v.close,
        };
    }
    return out;
}

const diagonal = [_]PV{ .{ .x = 0, .y = 40 }, .{ .x = 120, .y = 0 } };

const cubic = [_]PV{
    .{ .x = 0, .y = 40 },
    .{ .x = 120, .y = 40, .c1x = 30, .c1y = -30, .c2x = 90, .c2y = 90 },
};

const elbow = [_]PV{
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 40 },
    .{ .x = 120, .y = 40 },
};

// A node-graph connection: S-curve between two ports.
const connection = [_]PV{
    .{ .x = 0, .y = 10 },
    .{ .x = 160, .y = 60, .c1x = 80, .c1y = 10, .c2x = 80, .c2y = 60 },
};

const triangle = [_]PV{
    .{ .x = 0, .y = 50 },
    .{ .x = 50, .y = 0 },
    .{ .x = 100, .y = 50, .close = 1 },
};

const Row = struct { name: []const u8, verts: []const PV, y: f32 };

const rows = [_]Row{
    .{ .name = "diagonal", .verts = &diagonal, .y = 40 },
    .{ .name = "cubic", .verts = &cubic, .y = 140 },
    .{ .name = "elbow", .verts = &elbow, .y = 240 },
    .{ .name = "connection", .verts = &connection, .y = 340 },
    .{ .name = "closed triangle", .verts = &triangle, .y = 440 },
};

const PathDemo = struct {
    pub fn build(_: *PathDemo, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;

        const canvas = try b.openBox();
        try b.width(canvas, 100, .percent);
        try b.height(canvas, 100, .percent);
        try b.background(canvas, 0x14, 0x14, 0x18);

        inline for (rows) |row| {
            inline for (.{ 1.0, 1.6, 2.4 }, 0..) |k, col| {
                const s = comptime scaled(row.verts, k);
                const id = try b.path(&s);
                try b.positionAbsolute(id, 40 + @as(f32, @floatFromInt(col)) * 300, row.y);
                try b.borderColor(id, 0x6c, 0xa8, 0xff);
                try b.borderWidth(id, 3);
            }
        }

        // Translucent stroke (opaque-only limitation is visible here as beading
        // at the joints — expected in v1).
        const t = comptime scaled(&connection, 2.0);
        const tid = try b.path(&t);
        try b.positionAbsolute(tid, 40, 540);
        try b.borderColorAlpha(tid, 0xff, 0x8c, 0x42, 0.4);
        try b.borderWidth(tid, 8);

        b.close(); // canvas
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = PathDemo{};
    try fw.runApp(&app, &router, .{
        .title = "Celeris — NodeType.path demo",
        .width = 1000,
        .height = 640,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x6c, .g = 0xa8, .b = 0xff }, .dark),
    });
}
