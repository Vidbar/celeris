//! A VS Code-style file explorer: the TreeView features an IDE side bar needs.
//!
//!   * A full-width section header `Button` with its label at the start
//!     (`.justify = .start`).
//!   * One-line rows that clip in a narrow pane, explorer metrics (13 px text,
//!     8 px indent) and per-node icon colors.
//!   * Single-click "preview" vs double-click "activate" (`activate_on_click`).
//!   * A context menu on right click / Shift+F10 / the menu key, opened with
//!     `Menu.popupWindow` at the position the tree reports.
//!
//! Every tree event is printed to stdout, so the behavior can be checked from a
//! terminal (or a UI Automation script) while clicking around.
//! Run with `zig build explorer`.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;
const TreeNode = fw.tree_view.TreeNode;

const folder_color = fw.theme.Color{ .r = 220, .g = 180, .b = 90 };
const zig_color = fw.theme.Color{ .r = 247, .g = 164, .b = 29 };

const ExplorerApp = struct {
    allocator: std.mem.Allocator,
    roots: std.array_list.Managed(TreeNode),
    menu: *fw.menu.Menu,
    section_open: bool = true,

    fn file(self: *ExplorerApp, id: usize, name: []const u8, color: ?fw.theme.Color) TreeNode {
        return .{ .id = id, .name = name, .node_type = .leaf, .icon = "\u{25A0}", .icon_color = color, .children = std.array_list.Managed(TreeNode).init(self.allocator) };
    }
    fn folder(self: *ExplorerApp, id: usize, name: []const u8) TreeNode {
        return .{ .id = id, .name = name, .node_type = .branch, .expanded = true, .icon = "\u{25A0}", .icon_color = folder_color, .children = std.array_list.Managed(TreeNode).init(self.allocator) };
    }

    fn init(allocator: std.mem.Allocator) !*ExplorerApp {
        const self = try allocator.create(ExplorerApp);
        self.* = .{
            .allocator = allocator,
            .roots = std.array_list.Managed(TreeNode).init(allocator),
            .menu = try fw.menu.Menu.init(allocator, "explorer_ctx_menu"),
        };
        try self.menu.addItem("Open to the Side", "open_side");
        try self.menu.addItem("Rename", "rename");
        try self.menu.addSeparator();
        try self.menu.addItem("Delete", "delete");
        self.menu.on_select = fw.events.makeHandler(self, onMenuSelect);

        var src = self.folder(1, "src");
        try src.children.append(self.file(2, "main.zig", zig_color));
        try src.children.append(self.file(3, "a_file_with_a_very_long_name_that_never_fits_in_the_pane.zig", zig_color));
        var docs = self.folder(4, "docs");
        try docs.children.append(self.file(5, "README.md", null));
        try src.children.append(docs);
        try self.roots.append(src);
        try self.roots.append(self.file(6, "build.zig", zig_color));
        return self;
    }

    fn freeNode(node: *TreeNode) void {
        for (node.children.items) |*c| freeNode(c);
        node.children.deinit();
    }

    fn deinit(self: *ExplorerApp) void {
        for (self.roots.items) |*n| freeNode(n);
        self.roots.deinit();
        self.menu.deinit();
        self.allocator.destroy(self);
    }

    fn onTreeEvent(self: *ExplorerApp, ev: fw.events.Event) void {
        if (ev.item_id) |id| {
            std.debug.print("[explorer] {s} id={d} x={d:.0} y={d:.0}\n", .{ ev.name, id, ev.x, ev.y });
        } else {
            std.debug.print("[explorer] {s} id=none x={d:.0} y={d:.0}\n", .{ ev.name, ev.x, ev.y });
        }
        if (std.mem.eql(u8, ev.name, "context_menu")) self.menu.popupWindow(ev.x, ev.y, .pointer);
    }

    fn onMenuSelect(_: *ExplorerApp, ev: fw.events.Event) void {
        std.debug.print("[explorer] menu {s}\n", .{ev.id});
    }

    fn onHeader(_: *ExplorerApp, _: fw.events.Event) void {
        std.debug.print("[explorer] header click\n", .{});
    }

    pub fn build(self: *ExplorerApp, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const root = try b.openBox();
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);
        try b.flexRow(root);

        // The side bar: a narrow fixed column, as a user would drag it.
        const side = try b.openBox();
        try b.width(side, 180, .px);
        try b.height(side, 100, .percent);
        try b.flexColumn(side);

        try ctx.mountOwned(fw.button.Button, .{
            .key = "section",
            .label = "\u{02C5} EXPLORER",
            .justify = .start,
            .radius = 0,
            .padding = fw.component.EdgeInsets{ .l = 4, .t = 2, .b = 2 },
            .on_click = ctx.handler(self, onHeader),
        });

        const tree_box = try b.openBox();
        try b.width(tree_box, 100, .percent);
        try b.flexGrow(tree_box, 1);
        try ctx.mountOwned(fw.tree_view.TreeView, .{
            .fill = true,
            .roots = &self.roots,
            .font_size = 13,
            .indent = 8,
            .row_padding = fw.component.EdgeInsets{ .t = 1, .b = 1, .l = 4, .r = 8 },
            .activate_on_click = true,
            .on_activate = ctx.handler(self, onTreeEvent),
            .on_expand = ctx.handler(self, onTreeEvent),
            .on_collapse = ctx.handler(self, onTreeEvent),
            .on_context_menu = ctx.handler(self, onTreeEvent),
        });
        b.close(); // tree_box
        b.close(); // side

        // The editor area.
        const editor = try b.openBox();
        try b.flexGrow(editor, 1);
        try b.height(editor, 100, .percent);
        b.close();

        try self.menu.build(ctx);
        b.close(); // root
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();
    const app = try ExplorerApp.init(allocator);
    defer app.deinit();

    try fw.runApp(app, &router, .{
        .title = "Celeris Explorer",
        .width = 640,
        .height = 400,
        .theme = fw.theme.Theme.dark(),
    });
}
