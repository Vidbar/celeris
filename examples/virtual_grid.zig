//! Visual check for `VirtualGrid`.
//!
//! A 100 000 × 40 grid over a pull source with per-column widths, a **frozen
//! header row** built outside the grid and kept column-aligned via a shared
//! `col_scroll` signal, plus a lifted selection the keyboard drives.
//!
//! Drive it: click the grid, then arrow / Tab / PageDown / Ctrl+End around;
//! wheel scrolls vertically, Shift+wheel horizontally.
//! What to look for: no blank flashes beyond overdraw scrolling diagonally under
//! continuous input; the header stays aligned with the body; no layout hitch on
//! a boundary crossing. (In-cell editing + column resize compose on top and are
//! not the grid's to own.)
//!
//! Run: `zig build virtual_grid`   Compiled in CI via `zig build examples`.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;
const reg = celeris.internal.registry;
const props = celeris.internal.properties;

const ROWS: usize = 100_000;
const COLS: usize = 40;
const ROW_H: f32 = 26;

const VG = fw.VirtualGrid(Cell);
const Cell = struct { row: usize, col: usize };

fn colWidth(_: ?*anyopaque, col: usize) f32 {
    if (col == 0) return 160;
    return if (col % 2 == 0) 90 else 130;
}

const Grid = struct {
    selected: fw.signals.Signal(fw.CellRange) = undefined,
    /// Shared with the grid (`col_scroll` prop) AND read by the header effect.
    col_scroll: fw.signals.Signal(f32) = undefined,
    row_scroll: fw.signals.Signal(f32) = undefined,
    scope: fw.signals.Scope = undefined,
    header_strip: reg.NodeId = reg.NULL_NODE,
    store: ?*props.PropertyStore = null,

    fn cellAt(_: ?*anyopaque, row: usize, col: usize) Cell {
        return .{ .row = row, .col = col };
    }

    fn drawCell(self: *Grid, ctx: *fw.component.BuildContext, cell: Cell, row: usize, col: usize) anyerror!void {
        const b = ctx.builder;
        const sel = self.selected.peek().focus;
        const wrap = try b.openBox();
        try b.padding(wrap, 4, 8, 4, 8);
        try b.height(wrap, ROW_H, .px);
        if (sel.row == row and sel.col == col) {
            try b.background(wrap, 0x2d, 0x4f, 0x8f);
        } else if (row % 2 == 0) {
            try b.background(wrap, 0x1c, 0x1c, 0x22);
        }
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}:{d}", .{ cell.row, cell.col }) catch "?";
        const t = try b.addText(s);
        try b.fontSize(t, 12);
        b.close();
    }

    /// Frozen-header composition: translate the header strip by `-col_scroll`,
    /// exactly what the grid does to each body row's strip.
    fn syncHeader(self: *Grid) void {
        const store = self.store orelse return;
        if (self.header_strip == reg.NULL_NODE) return;
        store.setLayout(self.header_strip, .scroll_offset_x, .{ .dimension = .{ .value = -self.col_scroll.get(), .unit = .px } }) catch {};
    }

    pub fn build(self: *Grid, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        self.store = b.store;

        const root = try b.openBox();
        try b.flexColumn(root);
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);
        try b.background(root, 0x12, 0x12, 0x16);

        // ── Frozen header ────────────────────────────────────────────────────
        const header_vp = try b.openBox();
        try b.width(header_vp, 100, .percent);
        try b.height(header_vp, ROW_H, .px);
        try b.overflowHidden(header_vp);
        const strip = try b.openBox();
        try b.flexRow(strip);
        try b.height(strip, ROW_H, .px);
        self.header_strip = strip;
        var col: usize = 0;
        while (col < COLS) : (col += 1) {
            const hc = try b.openBox();
            try b.width(hc, colWidth(null, col), .px);
            try b.height(hc, ROW_H, .px);
            try b.padding(hc, 4, 8, 4, 8);
            try b.background(hc, 0x24, 0x24, 0x2c);
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "col {d}", .{col}) catch "col";
            const t = try b.addText(s);
            try b.fontSize(t, 12);
            b.close();
        }
        b.close(); // strip
        b.close(); // header_vp

        _ = try self.scope.createEffect(self, syncHeader);

        // ── The grid ────────────────────────────────────────────────────────
        try ctx.mountOwned(VG, .{
            .row_count = ROWS,
            .col_count = COLS,
            .cell_at = &cellAt,
            .col_width_at = &colWidth,
            .render = VG.cellFn(*Grid, drawCell),
            .payload = self,
            .row_height = ROW_H,
            .viewport_width = 980,
            .viewport_height = 560,
            .overdraw = 6,
            .selected = &self.selected,
            .col_scroll = &self.col_scroll,
            .row_scroll = &self.row_scroll,
        });

        b.close(); // root
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = Grid{
        .selected = fw.signals.Signal(fw.CellRange).init(allocator, .{}),
        .col_scroll = fw.signals.Signal(f32).init(allocator, 0),
        .row_scroll = fw.signals.Signal(f32).init(allocator, 0),
        .scope = fw.signals.Scope.init(allocator),
    };
    defer app.selected.deinit();
    defer app.col_scroll.deinit();
    defer app.row_scroll.deinit();
    defer app.scope.deinit();

    try fw.runApp(&app, &router, .{
        .title = "Celeris — VirtualGrid demo",
        .width = 1000,
        .height = 660,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x2d, .g = 0x4f, .b = 0x8f }, .dark),
    });
}
