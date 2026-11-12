//! Manual check: a resizable window with `.round` corners and a `window_outline`
//! must show ONE continuous 1px edge of the outline color on all four sides —
//! no white (unpainted non-client) column between the DWM border and the
//! content on the left, right or bottom.
//!
//! Run with `zig build window_edge`, then sample the left/right/bottom edges
//! (`scripts/sample_window_edge.ps1`) or zoom in on them by eye: no pixel in the
//! outermost 3px may be white.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

const App = struct {
    pub fn build(self: *App, ctx: *fw.component.BuildContext) !void {
        _ = self;
        const b = ctx.builder;
        const col = try b.openBox();
        try b.flexColumn(col);
        try b.alignItems(col, .center);
        try b.justifyContent(col, .center);
        try b.width(col, 100, .percent);
        try b.height(col, 100, .percent);
        const t = try b.addText("Edges: one 1px #2B2B2B line, no white");
        try b.fontSize(t, 16);
        b.close();
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();
    var app = App{};
    try fw.runApp(&app, &router, .{
        .title = "Celeris Window Edge",
        .width = 600,
        .height = 400,
        .window_corners = .round,
        .window_outline = .{ .r = 0x2B, .g = 0x2B, .b = 0x2B, .a = 255 },
    });
}
