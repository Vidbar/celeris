//! ColumnHeader — a row of column titles with draggable separators.
//!
//! The header is its own widget (Qt's `QHeaderView`, an ImGui table's header
//! row): it draws the titles and resizes the columns, and the views that show
//! columnar data (`TreeView.columns`) read the same column widths. Nothing is
//! owned by the header:
//!
//!   • **Widths are lifted state.** Every `Column` carries a caller-owned
//!     `*Signal(f32)`. A separator drag writes it live; the header and every
//!     view sharing the `Column` slice re-apply the width render-only (no row
//!     rebuild). The app keeps the widths across sessions by keeping the signals.
//!   • **Horizontal scroll is shared.** Pass the same `scroll_x` signal given to
//!     the `ScrollView.offset_x` that hosts the view; the header translates its
//!     titles by it, so header and rows stay aligned while the body scrolls. The
//!     header sits *outside* that ScrollView, which is what keeps it fixed when
//!     the rows scroll vertically.
//!
//! Each column is `width` px wide; the last `GRIP_W` px of it are the resize
//! grip (the resize cursor, a 1 px separator line at the right edge). A column
//! with `stretch` also takes the space left over to the right edge of the view
//! (never less than `width`); give it to the last column for the usual look.
//! `on_column_resize` fires once per drag, on release, when the width changed.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

/// Width (px) of the drag grip at each column's right edge.
pub const GRIP_W: f32 = 6;

/// One column of a columnar view. The slice of columns is caller-owned and is
/// shared by the `ColumnHeader` and the view (e.g. `TreeView.columns`).
pub const Column = struct {
    /// Header title.
    title: []const u8,
    /// Caller-owned width in px (two-way): its initial value is the initial
    /// width; a separator drag writes it, and the caller may write it too (e.g.
    /// to restore saved widths). Values under `min_width` are drawn at `min_width`.
    width: *signals.Signal(f32),
    /// A drag never makes the column narrower than this.
    min_width: f32 = 24,
    /// Also take the space left over to the right edge of the view.
    stretch: bool = false,

    /// The width the column is drawn at (non-reactive read).
    pub fn widthNow(self: Column) f32 {
        return @max(self.min_width, self.width.peek());
    }
    /// The width the column is drawn at, subscribing the running effect.
    pub fn widthTracked(self: Column) f32 {
        return @max(self.min_width, self.width.get());
    }
};

/// Sum of the drawn column widths (non-reactive).
pub fn totalWidth(columns: []const Column) f32 {
    var t: f32 = 0;
    for (columns) |c| t += c.widthNow();
    return t;
}

/// The width a drag to `pointer_x` gives a column, for a drag that started at
/// `start_x` with the column `start_w` wide: follows the pointer, clamped to
/// `min_width`.
pub fn dragWidth(start_w: f32, start_x: f32, pointer_x: f32, min_width: f32) f32 {
    return @max(min_width, start_w + (pointer_x - start_x));
}

fn colorValue(c: theme_mod.Color) props.PropValue {
    return props.PropValue.rgbA(c.r, c.g, c.b, @as(f32, @floatFromInt(c.a)) / 255.0);
}

pub const ColumnHeader = struct {
    // Props.
    /// Caller-owned columns (see `Column`). The header reads titles and widths.
    columns: []const Column = &.{},
    /// Shared horizontal scroll offset (px, `<= 0`), the same signal passed as
    /// `ScrollView.offset_x`. Omit when the view never scrolls horizontally.
    scroll_x: ?*signals.Signal(f32) = null,
    /// Header height in px.
    height: f32 = 24,
    /// Space before each title. Matches `TreeView.row_padding.l` by default, so a
    /// title starts where the column's content starts.
    padding_x: f32 = 10,
    /// Title text style. Null = engine default text.
    text_style: ?theme_mod.TextStyle = null,
    /// Overrides only the size of `text_style` (or of the default text).
    font_size: ?f32 = null,
    /// Header colors (`header_bg`, `header_text`, `header_separator`); unset
    /// fields come from `theme.list`, then the base theme tokens.
    colors: theme_mod.ListColors = .{},
    /// Fired (event name "column_resize", column index in `ev.item_id`) on the
    /// release that ends a separator drag, when the width changed. The new width
    /// is already in that column's `width` signal.
    on_column_resize: ?events.Handler = null,

    // State.
    scope: signals.Scope = undefined,
    bound: bool = false,
    /// Column index being dragged, if any.
    drag_col: ?usize = null,
    drag_start_x: f32 = 0,
    drag_start_w: f32 = 0,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    root_id: reg.NodeId = reg.NULL_NODE,
    strip_id: reg.NodeId = reg.NULL_NODE,
    /// One cell box per column, in order.
    cells: std.array_list.Managed(reg.NodeId) = undefined,
    /// One grip box per column, in order (maps a press back to its column).
    grips: std.array_list.Managed(reg.NodeId) = undefined,

    pub fn onMount(self: *ColumnHeader, allocator: std.mem.Allocator) void {
        self.scope = signals.Scope.init(allocator);
        self.cells = std.array_list.Managed(reg.NodeId).init(allocator);
        self.grips = std.array_list.Managed(reg.NodeId).init(allocator);
    }

    pub fn deinit(self: *ColumnHeader) void {
        self.scope.deinit();
        self.cells.deinit();
        self.grips.deinit();
    }

    fn textStyle(self: *const ColumnHeader) ?theme_mod.TextStyle {
        var st = self.text_style orelse (if (self.font_size != null) theme_mod.TextStyle{ .size = 0 } else return null);
        if (self.font_size) |s| st.size = s;
        if (st.size <= 0) return null;
        return st;
    }

    pub fn build(self: *ColumnHeader, ctx: *component.BuildContext) !void {
        const b = ctx.builder;
        self.store = b.store;
        self.cells.clearRetainingCapacity();
        self.grips.clearRetainingCapacity();
        const pal = b.theme.listColors(self.colors);

        const root = try b.openNodeKeyed(.box, null);
        self.root_id = root;
        try b.width(root, 100, .percent);
        try b.height(root, self.height, .px);
        try b.flexShrink(root, 0);
        try b.flexRow(root);
        try b.overflowHidden(root);
        try b.store.setStyle(root, .background, colorValue(pal.header_bg));
        try b.role(root, "group");

        // The strip carries the horizontal translation (`scroll_offset_x` on the
        // root shifts it) and is at least as wide as the columns.
        const strip = try b.openNodeKeyed(.box, null);
        self.strip_id = strip;
        try b.width(strip, 100, .percent);
        try b.minWidth(strip, totalWidth(self.columns), .px);
        try b.flexShrink(strip, 0);
        try b.height(strip, 100, .percent);
        try b.flexRow(strip);

        for (self.columns, 0..) |col, i| {
            const cell = try b.openNodeKeyed(.box, @as(u64, i));
            try self.cells.append(cell);
            try b.width(cell, col.widthNow(), .px);
            try b.minWidth(cell, col.widthNow(), .px);
            try b.flexShrink(cell, 0);
            if (col.stretch) try b.flexGrow(cell, 1);
            try b.height(cell, 100, .percent);
            try b.flexRow(cell);
            try b.alignItems(cell, .center);
            try b.overflowHidden(cell);
            try b.ariaLabel(cell, col.title);

            const title = try b.addText(col.title);
            try b.flexGrow(title, 1);
            try b.flexShrink(title, 1);
            try b.minWidth(title, 0, .px);
            try b.noWrap(title);
            try b.marginLeft(title, self.padding_x);
            try b.pointerEventsNone(title);
            if (self.textStyle()) |st| {
                try b.fontSize(title, st.size);
                if (st.line_height) |lh| try b.lineHeight(title, lh);
            }
            try b.store.setStyle(title, .color, colorValue(pal.header_text));

            // Grip: the press target with the resize cursor; the 1 px line sits
            // at the column's right edge.
            const grip = try ctx.boxNode(.{
                .on_mouse_down = ctx.handler(self, onGripDown),
            }, .{});
            try self.grips.append(grip);
            try b.width(grip, GRIP_W, .px);
            try b.height(grip, 100, .percent);
            try b.flexShrink(grip, 0);
            try b.cursor(grip, "resize_ew");
            try b.role(grip, "resizer_h");
            // The separator is the grip's 1 px right border (border-box: the grip
            // stays GRIP_W wide, so the line lands exactly on the column edge).
            try b.borderRight(grip, 1);
            try b.store.setStyle(grip, .border_color, colorValue(pal.header_separator));

            b.close(); // cell
        }

        b.close(); // strip
        b.close(); // root

        if (ctx.router) |r| try r.onGlobal(root, self, onGlobal);
        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn onGripDown(self: *ColumnHeader, ev: events.Event) void {
        for (self.grips.items, 0..) |g, i| {
            if (g != ev.node_id) continue;
            if (i >= self.columns.len) return;
            self.drag_col = i;
            self.drag_start_x = ev.x;
            self.drag_start_w = self.columns[i].widthNow();
            return;
        }
    }

    fn onGlobal(self: *ColumnHeader, ev: events.Event) void {
        const i = self.drag_col orelse return;
        if (i >= self.columns.len) {
            self.drag_col = null;
            return;
        }
        const col = self.columns[i];
        if (std.mem.eql(u8, ev.name, "mouse_move")) {
            const w = dragWidth(self.drag_start_w, self.drag_start_x, ev.x, col.min_width);
            if (w != col.width.peek()) col.width.set(w);
        } else if (std.mem.eql(u8, ev.name, "mouse_up")) {
            self.drag_col = null;
            if (col.widthNow() != self.drag_start_w) {
                if (self.on_column_resize) |h| h.call(h.ptr, .{ .name = "column_resize", .id = "", .item_id = i });
            }
        }
    }

    /// Render-only: re-applies the widths and the horizontal scroll. Subscribes
    /// to every column's width signal and to `scroll_x`.
    pub fn updateVisuals(self: *ColumnHeader) void {
        const store = self.store orelse return;
        if (self.root_id == reg.NULL_NODE) return;
        var total: f32 = 0;
        for (self.columns, 0..) |col, i| {
            const w = col.widthTracked();
            total += w;
            if (i >= self.cells.items.len) continue;
            const cell = self.cells.items[i];
            store.setLayout(cell, .width, .{ .dimension = .{ .value = w, .unit = .px } }) catch {};
            store.setLayout(cell, .min_width, .{ .dimension = .{ .value = w, .unit = .px } }) catch {};
        }
        store.setLayout(self.strip_id, .min_width, .{ .dimension = .{ .value = total, .unit = .px } }) catch {};
        const sx: f32 = if (self.scroll_x) |s| s.get() else 0;
        store.setLayout(self.root_id, .scroll_offset_x, .{ .dimension = .{ .value = sx, .unit = .px } }) catch {};
        if (store.registry) |r| r.markLayoutDirty(self.root_id);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Harness = @import("test_support.zig").Harness;

test "dragWidth follows the pointer and clamps to min_width" {
    try testing.expectEqual(@as(f32, 130), dragWidth(100, 50, 80, 24));
    try testing.expectEqual(@as(f32, 24), dragWidth(100, 50, -200, 24));
}

fn mountHeader(env: *Harness, init_props: anytype) !*ColumnHeader {
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = theme_mod.Theme.dark();
    var ctx = component.BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try b.width(root, 100, .percent);
    try b.height(root, 100, .percent);
    try b.flexColumn(root);
    try ctx.mountOwned(ColumnHeader, init_props);
    b.close();
    const anchor = env.registry.getNode(root).?.first_child;
    return @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));
}

const ResizeSink = struct {
    count: usize = 0,
    col: ?usize = null,
    fn on(p: ?*anyopaque, ev: events.Event) void {
        const s: *ResizeSink = @ptrCast(@alignCast(p.?));
        s.count += 1;
        s.col = ev.item_id;
    }
};

test "ColumnHeader: titles laid out at the column widths; a drag resizes live, clamps, fires once on release" {
    const a = testing.allocator;
    var env = Harness.init(a);
    defer env.deinit();
    env.wire();

    var w0 = signals.Signal(f32).init(a, 120);
    defer w0.deinit();
    var w1 = signals.Signal(f32).init(a, 80);
    defer w1.deinit();
    var w2 = signals.Signal(f32).init(a, 60);
    defer w2.deinit();
    const cols = [_]Column{
        .{ .title = "Name", .width = &w0, .min_width = 40 },
        .{ .title = "Value", .width = &w1 },
        .{ .title = "Type", .width = &w2, .stretch = true },
    };
    var sink = ResizeSink{};
    const h = try mountHeader(&env, .{
        .columns = &cols,
        .on_column_resize = events.Handler{ .ptr = &sink, .call = ResizeSink.on },
    });

    env.solve(0, 400, 200);
    try testing.expectApproxEqAbs(@as(f32, 120), env.geom(h.cells.items[0]).width, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 120), env.geom(h.cells.items[1]).x, 0.5);
    // The stretch column takes what is left of the 400 px view.
    try testing.expectApproxEqAbs(@as(f32, 400 - 200), env.geom(h.cells.items[2]).width, 0.5);

    // Press the first grip and drag 30 px right: the width follows live.
    const g = env.geom(h.grips.items[0]);
    env.route(.{ .name = "mouse_down", .id = "", .node_id = h.grips.items[0], .x = g.x + 2, .y = g.y + 2 });
    env.route(.{ .name = "mouse_move", .id = "", .x = g.x + 32, .y = g.y + 2 });
    try testing.expectEqual(@as(f32, 150), w0.peek());
    env.solve(0, 400, 200);
    try testing.expectApproxEqAbs(@as(f32, 150), env.geom(h.cells.items[0]).width, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 150), env.geom(h.cells.items[1]).x, 0.5);
    try testing.expectEqual(@as(usize, 0), sink.count); // not while dragging

    // Far to the left: clamped to min_width.
    env.route(.{ .name = "mouse_move", .id = "", .x = g.x - 500, .y = g.y + 2 });
    try testing.expectEqual(@as(f32, 40), w0.peek());
    env.route(.{ .name = "mouse_up", .id = "", .x = g.x - 500, .y = g.y + 2 });
    try testing.expectEqual(@as(usize, 1), sink.count);
    try testing.expectEqual(@as(?usize, 0), sink.col);

    // After release, moves no longer resize.
    env.route(.{ .name = "mouse_move", .id = "", .x = g.x + 100, .y = g.y + 2 });
    try testing.expectEqual(@as(f32, 40), w0.peek());
}

test "ColumnHeader: scroll_x translates the titles" {
    const a = testing.allocator;
    var env = Harness.init(a);
    defer env.deinit();
    env.wire();

    var w0 = signals.Signal(f32).init(a, 300);
    defer w0.deinit();
    var w1 = signals.Signal(f32).init(a, 300);
    defer w1.deinit();
    var sx = signals.Signal(f32).init(a, 0);
    defer sx.deinit();
    const cols = [_]Column{ .{ .title = "A", .width = &w0 }, .{ .title = "B", .width = &w1 } };
    const h = try mountHeader(&env, .{ .columns = &cols, .scroll_x = &sx });

    env.solve(0, 400, 200);
    const x0 = env.geom(h.cells.items[1]).x;
    sx.set(-100);
    env.solve(0, 400, 200);
    try testing.expectApproxEqAbs(x0 - 100, env.geom(h.cells.items[1]).x, 0.5);
}
