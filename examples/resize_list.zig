//! Visual check for `on_resize` through `VirtualList(.fill = true)`.
//!
//! A 100 000-row list filling the whole window. The list never receives a
//! viewport height: it learns the real one from `on_resize` after the first
//! frame and again on every window resize.
//!
//! Drive it: drag the window's bottom edge down (and back up) without scrolling.
//! What to look for: rows fill the window the whole time — no empty band below the
//! last row until the next wheel event. Each time the materialized range changes,
//! stdout prints `[resize_list] rows <first>..<last> (<n> materialized)`.
//!
//! Run: `zig build resize_list`   Compiled in CI via `zig build examples`.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

const ROWS: usize = 100_000;
const ROW_H: f32 = 24;

const Row = struct { n: usize };
const VL = fw.virtual_list.VirtualList(Row);

const App = struct {
    rows: []Row,
    /// Range drawn by the current rebuild; printed when it changes.
    lo: usize = std.math.maxInt(usize),
    hi: usize = 0,
    drawn: usize = 0,
    last_lo: usize = std.math.maxInt(usize),
    last_hi: usize = 0,

    fn drawRow(self: *App, ctx: *fw.component.BuildContext, item: Row, idx: usize) anyerror!void {
        const b = ctx.builder;
        // The range effect draws the window in ascending order; a restart at a
        // lower index (or the first row) begins a new pass.
        if (idx < self.hi or self.drawn == 0) {
            self.report();
            self.lo = idx;
            self.drawn = 0;
        }
        self.hi = idx;
        self.drawn += 1;

        const wrap = try b.openBox();
        try b.padding(wrap, 4, 12, 4, 12);
        try b.height(wrap, ROW_H, .px);
        if (idx % 2 == 0) try b.background(wrap, 0x1c, 0x1c, 0x22);
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "row {d}", .{item.n}) catch "?";
        _ = try b.addText(s);
        b.close();
    }

    /// Prints the previous pass's range if it differs from the last one printed.
    fn report(self: *App) void {
        if (self.drawn == 0) return;
        if (self.lo == self.last_lo and self.hi == self.last_hi) return;
        std.debug.print("[resize_list] rows {d}..{d} ({d} materialized)\n", .{ self.lo, self.hi, self.drawn });
        self.last_lo = self.lo;
        self.last_hi = self.hi;
    }

    fn onTick(self: *App) void {
        // The last pass has no successor to trigger its report; flush it here.
        self.report();
    }

    pub fn build(self: *App, ctx: *fw.component.BuildContext) !void {
        if (ctx.router) |r| try r.onTick(0, self, onTick);
        try ctx.mountOwned(VL, .{
            .items = @as([]const Row, self.rows),
            .item_height = ROW_H,
            .viewport_height = 100, // deliberately wrong: only the frame-0 estimate
            .fill = true,
            .overdraw = 2,
            .render = VL.renderFn(*App, drawRow),
            .payload = self,
        });
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    const rows = try allocator.alloc(Row, ROWS);
    defer allocator.free(rows);
    for (rows, 0..) |*r, i| r.* = .{ .n = i };

    var app = App{ .rows = rows };
    try fw.runApp(&app, &router, .{
        .title = "Celeris — on_resize / VirtualList fill",
        .width = 600,
        .height = 400,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x2d, .g = 0x4f, .b = 0x8f }, .dark),
    });
}
