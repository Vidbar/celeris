//! debugger_variables — a Visual Studio-style Variables view built from a
//! `ColumnHeader` and a `TreeView` with columns (Name | Value | Type).
//!
//! What it shows:
//!   • The header sits above the `ScrollView`, so it stays put while the rows
//!     scroll vertically; header and rows share the `scroll_x` signal, so they
//!     scroll together horizontally (Shift+wheel, or the bottom scrollbar).
//!   • Drag a separator in the header to resize a column (never below its
//!     `min_width`). The widths are app-owned signals; the release prints them.
//!   • Lazy branches: structs and arrays start with no children. Expanding one
//!     fires "expand" (controlled expansion); the app builds its children then
//!     and bumps `data_rev`. `items` holds 2 000 elements, so the tree is also
//!     virtualized through the scroll bridge.
//!   • Per-cell colors: numbers and pointers get their own Value color.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

const TreeNode = fw.tree_view.TreeNode;
const Cell = fw.tree_view.Cell;
const NodeList = std.array_list.Managed(TreeNode);

const VIEWPORT_H: f32 = 520;
const ITEMS: usize = 2000;

const number_color = fw.theme.Color{ .r = 0xb5, .g = 0xce, .b = 0xa8 };
const pointer_color = fw.theme.Color{ .r = 0x9c, .g = 0xdc, .b = 0xfe };

/// What a lazy branch expands into.
const Kind = enum { frame, point, items, item };

const App = struct {
    arena: std.mem.Allocator,
    roots: NodeList,
    kinds: std.AutoHashMap(usize, Kind),
    next_id: usize = 1,
    rev: fw.signals.Signal(u32),
    scroll_y: fw.signals.Signal(f32),
    scroll_x: fw.signals.Signal(f32),
    content_w: fw.signals.Signal(f32),
    widths: [3]fw.signals.Signal(f32),
    columns: [3]fw.Column = undefined,
    tree_host: TreeHost = undefined,

    fn init(self: *App, arena: std.mem.Allocator, gpa: std.mem.Allocator) !void {
        self.* = .{
            .arena = arena,
            .roots = NodeList.init(arena),
            .kinds = std.AutoHashMap(usize, Kind).init(arena),
            .rev = fw.signals.Signal(u32).init(gpa, 0),
            .scroll_y = fw.signals.Signal(f32).init(gpa, 0),
            .scroll_x = fw.signals.Signal(f32).init(gpa, 0),
            .content_w = fw.signals.Signal(f32).init(gpa, 0),
            .widths = .{
                fw.signals.Signal(f32).init(gpa, 220),
                fw.signals.Signal(f32).init(gpa, 260),
                fw.signals.Signal(f32).init(gpa, 160),
            },
        };
        self.columns = .{
            .{ .title = "Name", .width = &self.widths[0], .min_width = 80 },
            .{ .title = "Value", .width = &self.widths[1], .min_width = 60 },
            .{ .title = "Type", .width = &self.widths[2], .min_width = 50, .stretch = true },
        };
        self.tree_host = .{ .app = self };
        try self.roots.append(try self.branch("frame", "{...}", "main.Frame", .frame));
        try self.roots.append(try self.leafNode("argc", "3", "i32", number_color));
        try self.roots.append(try self.leafNode("argv", "0x7ff6a2c01040", "[*][*:0]u8", pointer_color));
        try self.roots.append(try self.branch("items", "len = 2000", "[]main.Item", .items));
    }

    fn deinit(self: *App) void {
        for (&self.widths) |*w| w.deinit();
        self.content_w.deinit();
        self.scroll_x.deinit();
        self.scroll_y.deinit();
        self.rev.deinit();
    }

    fn cells(self: *App, value: []const u8, ty: []const u8, color: ?fw.theme.Color) ![]const Cell {
        const out = try self.arena.alloc(Cell, 2);
        out[0] = .{ .text = value, .color = color };
        out[1] = .{ .text = ty };
        return out;
    }

    fn leafNode(self: *App, name: []const u8, value: []const u8, ty: []const u8, color: ?fw.theme.Color) !TreeNode {
        const id = self.next_id;
        self.next_id += 1;
        return .{ .id = id, .name = name, .node_type = .leaf, .cells = try self.cells(value, ty, color), .children = NodeList.init(self.arena) };
    }

    /// A branch with no children yet: it still shows a caret, and its children
    /// are built the first time it is expanded.
    fn branch(self: *App, name: []const u8, value: []const u8, ty: []const u8, kind: Kind) !TreeNode {
        const id = self.next_id;
        self.next_id += 1;
        try self.kinds.put(id, kind);
        return .{ .id = id, .name = name, .node_type = .branch, .cells = try self.cells(value, ty, null), .children = NodeList.init(self.arena) };
    }

    fn load(self: *App, node: *TreeNode) !void {
        const kind = self.kinds.get(node.id) orelse return;
        const a = self.arena;
        switch (kind) {
            .frame => {
                try node.children.append(try self.leafNode("pc", "0x00007ff6a2b91f3c", "usize", pointer_color));
                try node.children.append(try self.branch("origin", "{ x = 12, y = -4 }", "main.Point", .point));
                try node.children.append(try self.leafNode("name", "\"render_loop\"", "[]const u8", null));
                try node.children.append(try self.leafNode("depth", "7", "u32", number_color));
            },
            .point => {
                try node.children.append(try self.leafNode("x", "12", "i32", number_color));
                try node.children.append(try self.leafNode("y", "-4", "i32", number_color));
            },
            .items => {
                for (0..ITEMS) |i| {
                    const name = try std.fmt.allocPrint(a, "[{d}]", .{i});
                    const value = try std.fmt.allocPrint(a, "{{ id = {d}, weight = {d}.{d} }}", .{ i, i % 97, i % 10 });
                    try node.children.append(try self.branch(name, value, "main.Item", .item));
                }
            },
            .item => {
                try node.children.append(try self.leafNode("id", try std.fmt.allocPrint(a, "{d}", .{node.id}), "u64", number_color));
                try node.children.append(try self.leafNode("weight", "0.5", "f32", number_color));
                try node.children.append(try self.leafNode("next", "null", "?*main.Item", pointer_color));
            },
        }
    }

    fn onExpand(self: *App, ev: fw.events.Event) void {
        const id = ev.item_id orelse return;
        const node = fw.tree_view.TreeView.findNode(&self.roots, id) orelse return;
        const expand = std.mem.eql(u8, ev.name, "expand");
        if (expand and node.children.items.len == 0) {
            self.load(node) catch return;
            // Nothing to show after all: drop the caret.
            if (node.children.items.len == 0) node.node_type = .leaf;
        }
        node.expanded = expand and node.node_type == .branch;
        self.rev.set(self.rev.peek() + 1);
    }

    fn onColumnResize(self: *App, ev: fw.events.Event) void {
        std.debug.print("[variables] column {d} resized: Name={d:.0} Value={d:.0} Type={d:.0}\n", .{
            ev.item_id orelse 0, self.widths[0].peek(), self.widths[1].peek(), self.widths[2].peek(),
        });
    }

    pub fn build(self: *App, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const root = try b.openBox();
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);
        try b.flexColumn(root);

        try ctx.mountOwned(fw.ColumnHeader, .{
            .columns = &self.columns,
            .scroll_x = &self.scroll_x,
            .font_size = 13,
            .on_column_resize = ctx.handler(self, onColumnResize),
        });

        const body = try b.openBox();
        try b.width(body, 100, .percent);
        try b.flexGrow(body, 1);
        try b.flexBasis(body, 0, .px);
        try b.minHeight(body, 0, .px);
        try ctx.mountOwned(fw.scroll_view.ScrollView, .{
            .fill = true,
            .viewport_height = VIEWPORT_H,
            .content_height = 4 * 22,
            .offset = &self.scroll_y,
            .offset_x = &self.scroll_x,
            .content_width = &self.content_w,
            .content = fw.component.childOf(TreeHost, &self.tree_host),
        });
        b.close(); // body
        b.close(); // root
    }
};

/// Mounts the TreeView as the ScrollView's content (TreeView needs `onMount`).
const TreeHost = struct {
    app: *App,

    pub fn build(self: *TreeHost, ctx: *fw.component.BuildContext) !void {
        const app = self.app;
        try ctx.mountOwned(fw.tree_view.TreeView, .{
            .roots = &app.roots,
            .data_rev = &app.rev,
            .controlled_expansion = true,
            .toggle_on_row_click = false,
            .on_expand = ctx.handler(app, App.onExpand),
            .on_collapse = ctx.handler(app, App.onExpand),
            .columns = &app.columns,
            .content_width = &app.content_w,
            .scroll_offset = &app.scroll_y,
            .viewport_height = VIEWPORT_H,
            .font_size = 13,
        });
    }
    pub fn deinit(_: *TreeHost) void {}
};

pub fn main() !void {
    const gpa = std.heap.c_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var router = fw.events.EventRouter.init(gpa);
    defer router.deinit();

    var app: App = undefined;
    try app.init(arena_state.allocator(), gpa);
    defer app.deinit();

    try fw.runApp(&app, &router, .{
        .title = "Celeris Variables",
        .width = 720,
        .height = 560,
        .theme = fw.theme.Theme.dark(),
    });
}
