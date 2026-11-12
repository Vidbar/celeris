const std = @import("std");
const celeris = @import("celeris");

const fw = celeris.framework;
const theme_mod = fw.theme;
const TreeNode = fw.tree_view.TreeNode;

// std.Thread.sleep was removed in Zig 0.16 (sleeping needs an Io). Only the single
// gated streaming worker uses this, so a lazily-initialized Io is safe here.
var g_io_threaded: ?std.Io.Threaded = null;
fn exampleIo() std.Io {
    if (g_io_threaded == null) g_io_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    return g_io_threaded.?.io();
}
fn sleepMs(ms: i64) void {
    std.Io.sleep(exampleIo(), std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

/// Text "streamed" one token at a time from a worker thread, to demo thread-safe
/// repaint (postTask + the new cross-thread wake). Mimics an agent emitting tokens.
const STREAM_MSG =
    "Scanned the workspace. Found Zig sources under src/ and examples/. " ++
    "The render loop lives in c_api.zig; platform backends in src/platform/. " ++
    "Folder picker and cross-thread repaint are wired and working.";

// Caps that keep the directory walk (run on the UI thread inside the pick callback)
// snappy on large folders — virtualization is what would lift these for real.
const MAX_DEPTH = 3;
const MAX_ENTRIES_PER_DIR = 200;

// ── Sidebar: EXPLORER header + file tree ──────────────────────────────────────
const LeftPaneWidget = struct {
    app: *DashboardApp,

    pub fn build(self: *LeftPaneWidget, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const root = try b.openBox();
        try b.flexRow(root);
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);

        // Activity bar
        const act = try b.openBox();
        try b.width(act, 48, .px);
        try b.height(act, 100, .percent);
        try b.background(act, 40, 40, 40);
        b.close();

        // Sidebar (header + tree)
        const sidebar = try b.openBox();
        try b.flexGrow(sidebar, 1);
        try b.height(sidebar, 100, .percent);
        try b.flexColumn(sidebar);
        try b.background(sidebar, 37, 37, 38);

        // EXPLORER header
        const header = try b.openBox();
        try b.width(header, 100, .percent);
        try b.height(header, 32, .px);
        try b.flexRow(header);
        try b.alignItems(header, .center);
        try b.padding(header, 0, 12, 0, 12);
        try b.background(header, 45, 45, 48);
        const label = self.app.folderName();
        const htxt = try b.addText(label);
        try b.fontSize(htxt, 11);
        try b.textColor(htxt, 180, 180, 185);
        b.close();

        // Framework-owned TreeView reading the app-owned data:
        // repopulating is "mutate tree_roots, bump tree_rev".
        try ctx.mountOwned(fw.tree_view.TreeView, .{
            .fill = true,
            .roots = &self.app.tree_roots,
            .data_rev = &self.app.tree_rev,
        });
        b.close(); // sidebar

        b.close(); // root
    }

    pub fn deinit(_: *LeftPaneWidget) void {}
};

// ── Right pane: mounts the (framework-owned) Tabs. SplitPane hosts a Child, so this
// thin wrapper is what `ctx.mountOwned`s the Tabs with the app's items + active signal.
/// Initial editor text (applied once to the framework-owned TextArea in onMount).
const EDITOR_WELCOME = "// Welcome to Celeris.\n" ++
    "// Pick a folder with \"Add Folder\" to populate the tree,\n" ++
    "// then \"Run Agent\" to stream a response into the Agent tab.\n\n" ++
    "pub fn main() void {\n" ++
    "    std.debug.print(\"Hello Multiline World!\", .{});\n" ++
    "}\n";

/// ScrollView content: mounts the framework-owned TextArea — the app no
/// longer allocates/registers/frees the editor; `initial_text` seeds the buffer.
const EditorContent = struct {
    pub fn build(_: *EditorContent, ctx: *fw.component.BuildContext) !void {
        try ctx.mountOwned(fw.text_area.TextArea, .{
            .fill = true,
            .key = "main_editor",
            .initial_text = EDITOR_WELCOME,
        });
    }
    pub fn deinit(_: *EditorContent) void {}
};

/// Editor tab content: mounts the framework-owned ScrollView whose `content` is
/// the EditorContent wrapper above (a stable Child the pane owns).
const EditorPane = struct {
    content: EditorContent = .{},
    pub fn build(self: *EditorPane, ctx: *fw.component.BuildContext) !void {
        try ctx.mountOwned(fw.scroll_view.ScrollView, .{
            .fill = true,
            .content = fw.component.childOf(EditorContent, &self.content),
        });
    }
    pub fn deinit(_: *EditorPane) void {}
};

const RightPane = struct {
    app: *DashboardApp,
    pub fn build(self: *RightPane, ctx: *fw.component.BuildContext) !void {
        try ctx.mountOwned(fw.tabs.Tabs, .{
            .fill = true,
            .items = &self.app.tab_items,
            .active = &self.app.active_tab,
        });
    }
    pub fn deinit(_: *RightPane) void {}
};

// ── Agent chat panel: where the streamed "response" lands (tests #2) ──────────
const AgentChatPanel = struct {
    // Value-owned by DashboardApp (no init/create): the pointers are wired to the
    // app's stream state in DashboardApp.init.
    visible: *usize = undefined, // atomic-read count of visible STREAM_MSG chars
    streaming: *bool = undefined, // atomic-read running flag

    pub fn build(self: *AgentChatPanel, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const n = @atomicLoad(usize, self.visible, .acquire);
        const running = @atomicLoad(bool, self.streaming, .acquire);

        const root = try b.openBox();
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);
        try b.flexColumn(root);
        try b.padding(root, 24, 28, 24, 28);
        try b.background(root, 30, 30, 32);

        // Header: avatar dot + name
        const head = try b.openBox();
        try b.flexRow(head);
        try b.alignItems(head, .center);
        try b.marginBottom(head, 14);
        const dot = try b.openBox();
        try b.width(dot, 10, .px);
        try b.height(dot, 10, .px);
        try b.radius(dot, 5);
        try b.marginRight(dot, 10);
        try b.background(dot, 60, 160, 90);
        b.close();
        const name = try b.addText("Agent");
        try b.fontSize(name, 16);
        try b.textColor(name, 235, 235, 235);
        b.close(); // head

        // Status line (animated spinner while streaming, driven by repaints)
        const frames = "|/-\\";
        var status_buf: [48]u8 = undefined;
        // Advance ~1 frame per 6 tokens (≈10 fps at 18 ms/token) so the spinner
        // reads as a steady spin rather than a blur.
        const status_txt: []const u8 = if (running)
            std.fmt.bufPrint(&status_buf, "{c}  working…", .{frames[(n / 6) % 4]}) catch "working…"
        else if (n > 0)
            "done"
        else
            "idle — press Run Agent";
        const st = try b.addText(status_txt);
        try b.fontSize(st, 12);
        try b.textColor(st, if (running) 90 else 130, if (running) 170 else 130, if (running) 250 else 130);
        try b.marginBottom(st, 16);

        // Message bubble
        const bubble = try b.openBox();
        try b.width(bubble, 100, .percent);
        try b.flexColumn(bubble);
        try b.padding(bubble, 14, 16, 14, 16);
        try b.radius(bubble, 8);
        try b.background(bubble, 42, 42, 46);
        const body = if (n > 0) STREAM_MSG[0..n] else "The agent's streamed response will appear here.";
        const msg = try b.addText(body);
        try b.fontSize(msg, 14);
        try b.textColor(msg, if (n > 0) 220 else 120, if (n > 0) 220 else 120, if (n > 0) 225 else 120);
        b.close(); // bubble

        b.close(); // root
    }

    pub fn deinit(_: *AgentChatPanel) void {}
};

/// Caller-owned option list for the theme dropdown (must outlive the widget).
const THEME_OPTIONS = [_][]const u8{ "Dark Theme", "Light Theme", "System Theme" };
const RADIO_OPTIONS = [_][]const u8{ "Small", "Medium", "Large" };

/// Caller-owned backing data for the VirtualList demo (must outlive the widget).
const VRow = struct { n: usize };
var g_vlist_items: [500]VRow = blk: {
    var items: [500]VRow = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .n = i };
    break :blk items;
};
const VL = fw.virtual_list.VirtualList(VRow);

fn drawVRow(_: *ComponentsTab, ctx: *fw.component.BuildContext, item: VRow, idx: usize) anyerror!void {
    _ = idx;
    const b = ctx.builder;
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Virtual row {d}", .{item.n}) catch "row";
    const t = try b.addText(label);
    try b.fontSize(t, 12);
    try b.textColor(t, 200, 200, 205);
}

/// Two tiny leaf components for the Grid/Stack layout-helper demo below.
const GridCell = struct {
    label: []const u8,
    pub fn build(self: *GridCell, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const box = try b.openBox();
        try b.padding(box, 8, 8, 8, 8);
        try b.background(box, 50, 50, 55);
        try b.radius(box, 4);
        const t = try b.addText(self.label);
        try b.fontSize(t, 12);
        try b.textColor(t, 210, 210, 215);
        b.close();
    }
    pub fn deinit(_: *GridCell) void {}
};

const StackBadge = struct {
    pub fn build(_: *StackBadge, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const t = try b.addText("overlay");
        try b.fontSize(t, 10);
        try b.textColor(t, 255, 255, 255);
    }
    pub fn deinit(_: *StackBadge) void {}
};

const ComponentsTab = struct {
    // Needed to reach the app-owned Dialog signal + Menu/status-bar state, which
    // must outlive this per-tab widget.
    app: *DashboardApp,
    grid_a: GridCell = .{ .label = "A" },
    grid_b: GridCell = .{ .label = "B" },
    grid_c: GridCell = .{ .label = "C" },
    stack_badge: StackBadge = .{},

    fn onShowToast(_: *ComponentsTab, _: fw.events.Event) void {
        fw.toast.show("Saved successfully", .success, 3000);
    }

    fn onOpenDialog(self: *ComponentsTab, _: fw.events.Event) void {
        self.app.dialog_open.set(true);
    }

    fn onOpenMenu(self: *ComponentsTab, _: fw.events.Event) void {
        self.app.ctx_menu.popup(220, 260, .pointer); // opened from a click handler
    }

    pub fn build(self: *ComponentsTab, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;

        const root = try b.openBox();
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);
        try b.padding(root, 20, 20, 20, 20);
        try b.flexColumn(root);
        // Stretch children on the cross axis so mountOwned anchors fill the
        // column width — full-width widgets (Slider) then size correctly.
        try b.alignItems(root, .stretch);
        try b.background(root, 30, 30, 32);

        const title = try b.addText("UI Components");
        try b.fontSize(title, 24);
        try b.textColor(title, 255, 255, 255);
        try b.marginBottom(title, 20);

        // Primary button: framework-owned Button with a background override.
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .key = "btn_submit",
            .label = "Submit Form",
            .background = theme_mod.Color{ .r = 0, .g = 120, .b = 215 },
        });
        const spacer2 = try b.openBox();
        try b.height(spacer2, 10, .px);
        b.close();

        // Glyph-only buttons: the `tooltip` prop shown at hover-dwell, reusing
        // the same text as `aria_label` — one source of truth for the button's name,
        // spoken and shown. Mirrors an activity-bar row of icon-only controls.
        const glyph_row = try b.openBox();
        try b.flexRow(glyph_row);
        try ctx.mountOwned(fw.button.Button, .{
            .key = "glyph_explorer",
            .hug = true,
            .label = "E",
            .aria_label = "Explorer",
            .tooltip = "Explorer",
            .background = theme_mod.Color{ .r = 60, .g = 60, .b = 63 },
        });
        const glyph_spacer1 = try b.openBox();
        try b.width(glyph_spacer1, 8, .px);
        b.close();
        try ctx.mountOwned(fw.button.Button, .{
            .key = "glyph_search",
            .hug = true,
            .label = "S",
            .aria_label = "Search",
            .tooltip = "Search",
            .background = theme_mod.Color{ .r = 60, .g = 60, .b = 63 },
        });
        const glyph_spacer2 = try b.openBox();
        try b.width(glyph_spacer2, 8, .px);
        b.close();
        try ctx.mountOwned(fw.button.Button, .{
            .key = "glyph_settings",
            .hug = true,
            .label = "G",
            .aria_label = "Settings",
            .tooltip = "Settings",
            .background = theme_mod.Color{ .r = 60, .g = 60, .b = 63 },
        });
        b.close();
        const spacer2b = try b.openBox();
        try b.height(spacer2b, 10, .px);
        b.close();

        // IconButton is framework-owned now: mounted, not held as a field.
        try ctx.mountOwned(fw.icon_button.IconButton, .{ .icon = fw.icons.settings_gear });
        const spacer3 = try b.openBox();
        try b.height(spacer3, 10, .px);
        b.close();

        try ctx.mountOwned(fw.checkbox.Checkbox, .{ .label = "Enable Feature", .initial_checked = true });
        const spacer4 = try b.openBox();
        try b.height(spacer4, 10, .px);
        b.close();

        try ctx.mountOwned(fw.radio.Radio, .{ .label = "Select This", .initial_checked = false });
        const spacer5 = try b.openBox();
        try b.height(spacer5, 10, .px);
        b.close();

        try ctx.mountOwned(fw.slider.Slider, .{ .initial_value = 0.7 });
        const spacer6 = try b.openBox();
        try b.height(spacer6, 10, .px);
        b.close();

        const dd_wrap = try b.openBox();
        try b.width(dd_wrap, 100, .percent);
        try ctx.builder.hoverable(dd_wrap, "dd_wrap_tip");
        const dd_tip = try b.store.stringAllocator().dupe(u8, "Pick a color theme");
        try b.store.setModifier(dd_wrap, .tooltip, .{ .string = dd_tip });
        try ctx.mountOwned(fw.dropdown.Dropdown, .{ .options = &THEME_OPTIONS });
        b.close();
        const spacer7 = try b.openBox();
        try b.height(spacer7, 10, .px);
        b.close();

        try ctx.mountOwned(fw.radio_group.RadioGroup, .{ .options = &RADIO_OPTIONS });
        const spacer8 = try b.openBox();
        try b.height(spacer8, 10, .px);
        b.close();

        try ctx.mountOwned(fw.progress.ProgressBar, .{ .initial_value = 0.45 });
        const spacer9 = try b.openBox();
        try b.height(spacer9, 10, .px);
        b.close();

        try ctx.mountOwned(fw.status_bar.StatusBar, .{
            .items = @constCast(&[_]fw.status_bar.StatusItem{
                .{ .value = "Connected", .kind = .ok },
                .{ .value = "3 warnings", .kind = .warn },
            }),
        });
        const spacer10 = try b.openBox();
        try b.height(spacer10, 10, .px);
        b.close();

        // Toast / Dialog / context-Menu triggers (row of buttons).
        const trigger_row = try b.openBox();
        try b.flexRow(trigger_row);
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .key = "btn_toast",
            .label = "Show Toast",
            .on_click = ctx.handler(self, onShowToast),
        });
        const trig_spacer1 = try b.openBox();
        try b.width(trig_spacer1, 8, .px);
        b.close();
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .key = "btn_dialog",
            .label = "Open Dialog",
            .on_click = ctx.handler(self, onOpenDialog),
        });
        const trig_spacer2 = try b.openBox();
        try b.width(trig_spacer2, 8, .px);
        b.close();
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .key = "btn_menu",
            .label = "Open Menu",
            .on_click = ctx.handler(self, onOpenMenu),
        });
        b.close(); // trigger_row

        // The Dialog itself: closed (zero-size, inert) until `dialog_open` is set.
        try ctx.mountOwned(fw.dialog.Dialog, .{
            .open = &self.app.dialog_open,
            .title = "Example Dialog",
            .content = fw.component.childOf(DialogBody, &self.app.dialog_body),
        });

        // Context menu: a plain (non-mountOwned) component the app owns and pops
        // up on demand — same shape the codebase's own Menu tests use.
        try self.app.ctx_menu.build(ctx);

        const spacer11 = try b.openBox();
        try b.height(spacer11, 10, .px);
        b.close();

        // Grid layout helper (2 columns) + Stack overlay helper.
        try fw.grid.grid(ctx, 2, .{ &self.grid_a, &self.grid_b, &self.grid_c });
        const spacer12 = try b.openBox();
        try b.height(spacer12, 10, .px);
        b.close();
        try fw.stack.stack(ctx, .{ &self.grid_a, &self.stack_badge });
        const spacer13 = try b.openBox();
        try b.height(spacer13, 120, .px);
        b.close();

        // Virtualized list: only the visible window is materialized (see tree_bench.zig
        // for a dedicated perf harness; this is just a functional demo).
        try ctx.mountOwned(VL, .{
            .items = &g_vlist_items,
            .item_height = 22,
            .viewport_height = 132,
            .render = VL.renderFn(*ComponentsTab, drawVRow),
            .payload = self,
        });

        b.close();
    }

    pub fn deinit(_: *ComponentsTab) void {}
};

/// Simple body content mounted inside the Dialog demo above.
const DialogBody = struct {
    pub fn build(_: *DialogBody, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const t = try b.addText("This is a modal dialog. Press Escape or click outside to dismiss.");
        try b.fontSize(t, 13);
        try b.textColor(t, 210, 210, 215);
    }
    pub fn deinit(_: *DialogBody) void {}
};

const DashboardApp = struct {
    allocator: std.mem.Allocator,
    router: fw.events.EventRouter,
    /// App-owned tree data + revision: the framework-owned TreeView
    /// reads these; repopulating is "mutate tree_roots, bump tree_rev".
    tree_roots: std.array_list.Managed(TreeNode),
    tree_rev: fw.signals.Signal(u32),
    editor_pane: EditorPane,
    agent_panel: AgentChatPanel,

    left_pane: LeftPaneWidget,
    right_pane: RightPane,
    components_tab: ComponentsTab,
    /// Dialog demo state (caller-owned control signal + body content).
    dialog_open: fw.signals.Signal(bool),
    /// Side-bar collapsed state, lifted out of the SplitPane: a drag past its
    /// threshold writes it, and the "Side Bar" toolbar button toggles it.
    sidebar_collapsed: fw.signals.Signal(bool),
    dialog_body: DialogBody,
    /// Context-menu demo: a plain, app-owned Menu (not mountOwned — same pattern
    /// the framework's own Menu tests use), popped up from a button handler.
    ctx_menu: *fw.menu.Menu,
    /// Tab items + the active-tab signal, owned by the app so it can switch tabs
    /// (Run Agent → Agent tab) by writing the signal — Tabs is framework-owned.
    tab_items: [3]fw.tabs.TabItem,
    active_tab: fw.signals.Signal(usize),

    // ── Folder picker (#1) + cross-thread repaint (#2) test state ──
    /// Absolute path of the picked folder (UTF-8). 0 len = none.
    picked_path_buf: [1024]u8 = undefined,
    picked_path_len: usize = 0,
    /// Owns the dynamic tree node name strings; reset on each repopulation.
    tree_arena: std.heap.ArenaAllocator,
    tree_id_counter: usize = 1,
    tree_item_count: usize = 0,
    /// Visible chars of STREAM_MSG; written by the worker, read in build (atomic).
    stream_visible: usize = 0,
    streaming: bool = false,
    picking: bool = false,
    /// Repaint trigger: the reactive root reads this, and the streaming/picker
    /// callbacks bump it (on the UI thread) instead of calling `triggerRebuild`.
    rev: fw.signals.Signal(u32) = undefined,

    pub fn init(allocator: std.mem.Allocator) !*DashboardApp {
        const self = try allocator.create(DashboardApp);

        self.allocator = allocator;
        self.router = fw.events.EventRouter.init(allocator);
        self.tree_roots = std.array_list.Managed(TreeNode).init(allocator);
        self.tree_rev = fw.signals.Signal(u32).init(allocator, 0);
        self.tree_arena = std.heap.ArenaAllocator.init(allocator);
        self.tree_id_counter = 1;
        self.tree_item_count = 0;
        self.picked_path_len = 0;
        self.stream_visible = 0;
        self.streaming = false;
        self.picking = false;
        self.rev = fw.signals.Signal(u32).init(allocator, 0);

        self.editor_pane = .{};

        self.agent_panel = .{ .visible = &self.stream_visible, .streaming = &self.streaming };

        self.left_pane = .{ .app = self };
        self.dialog_open = fw.signals.Signal(bool).init(allocator, false);
        self.sidebar_collapsed = fw.signals.Signal(bool).init(allocator, false);
        self.dialog_body = .{};
        self.ctx_menu = try fw.menu.Menu.init(allocator, "components_ctx_menu");
        try self.ctx_menu.addItem("Cut", "cut");
        try self.ctx_menu.addItem("Copy", "copy");
        try self.ctx_menu.addSeparator();
        try self.ctx_menu.addItemEx(.{ .label = "Paste", .action_id = "paste", .enabled = false });
        self.components_tab = .{ .app = self };

        // Tabs is framework-owned now: the app holds the items + active signal,
        // and RightPane mounts the Tabs with them. "Run Agent" switches tabs by writing
        // active_tab — no Tabs pointer needed.
        self.active_tab = fw.signals.Signal(usize).init(allocator, 0);
        self.tab_items = .{
            .{ .title = "Agent", .child = fw.component.childOf(AgentChatPanel, &self.agent_panel) },
            .{ .title = "Editor", .child = fw.component.childOf(EditorPane, &self.editor_pane) },
            .{ .title = "Components", .child = fw.component.childOf(ComponentsTab, &self.components_tab) },
        };
        self.right_pane = .{ .app = self };

        // SplitPane + Tabs are framework-owned now: mounted in build().

        // Placeholder tree until a folder is picked. The TreeView is framework-owned
        // (mounted by LeftPaneWidget) — no register/action-id wiring.
        try self.seedPlaceholderTree();

        // Toolbar button handlers are typed `on_click` props on the mounted
        // Buttons — no router.on / action-id strings.

        return self;
    }

    /// "Side Bar" (typed on_click): collapses / reopens the tree pane by writing
    /// the SplitPane's lifted `collapsed` signal — no widget pointer needed.
    fn onToggleSidebar(self: *DashboardApp, ev: fw.events.Event) void {
        _ = ev;
        self.sidebar_collapsed.set(!self.sidebar_collapsed.peek());
    }

    /// "Add Folder" (typed on_click): picks a folder off the UI thread.
    fn onAddFolder(self: *DashboardApp, ev: fw.events.Event) void {
        _ = ev;
        if (@atomicLoad(bool, &self.picking, .acquire)) return;
        @atomicStore(bool, &self.picking, true, .release);
        _ = std.Thread.spawn(.{}, folderPickWorker, .{self}) catch {
            @atomicStore(bool, &self.picking, false, .release);
        };
    }

    /// "Run Agent" (typed on_click): switches to the Agent tab and streams.
    fn onRunAgent(self: *DashboardApp, ev: fw.events.Event) void {
        _ = ev;
        if (@atomicLoad(bool, &self.streaming, .acquire)) return;
        @atomicStore(bool, &self.streaming, true, .release);
        self.active_tab.set(0); // show the Agent tab (Tabs reacts to the signal)
        _ = std.Thread.spawn(.{}, streamWorker, .{self}) catch {
            @atomicStore(bool, &self.streaming, false, .release);
        };
    }

    /// A small built-in tree shown before any folder is picked.
    fn seedPlaceholderTree(self: *DashboardApp) !void {
        var root = TreeNode{
            .id = self.nextTreeId(),
            .name = "no folder — click \"Add Folder\"",
            .node_type = .branch,
            .expanded = true,
            .children = std.array_list.Managed(TreeNode).init(self.allocator),
        };
        try root.children.append(.{
            .id = self.nextTreeId(),
            .name = "examples",
            .node_type = .leaf,
            .children = std.array_list.Managed(TreeNode).init(self.allocator),
        });
        try root.children.append(.{
            .id = self.nextTreeId(),
            .name = "src",
            .node_type = .leaf,
            .children = std.array_list.Managed(TreeNode).init(self.allocator),
        });
        try self.tree_roots.append(root);
    }

    fn nextTreeId(self: *DashboardApp) usize {
        const id = self.tree_id_counter;
        self.tree_id_counter += 1;
        return id;
    }

    /// Recursively lists `dir_path` (absolute) into TreeNodes (names owned by tree_arena).
    fn listDir(self: *DashboardApp, dir_path: []const u8, depth: usize) std.array_list.Managed(TreeNode) {
        var list = std.array_list.Managed(TreeNode).init(self.allocator);
        const a = self.tree_arena.allocator();
        const io = exampleIo();
        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return list;
        defer dir.close(io);
        var it = dir.iterate();
        var count: usize = 0;
        while (count < MAX_ENTRIES_PER_DIR) {
            const entry = (it.next(io) catch break) orelse break;
            count += 1;
            self.tree_item_count += 1;
            const name = a.dupe(u8, entry.name) catch continue;
            const is_dir = entry.kind == .directory;
            var node = TreeNode{
                .id = self.nextTreeId(),
                .name = name,
                .node_type = if (is_dir) .branch else .leaf,
                .expanded = false,
                .children = std.array_list.Managed(TreeNode).init(self.allocator),
            };
            if (is_dir and depth + 1 < MAX_DEPTH) {
                const child_path = std.fs.path.join(a, &.{ dir_path, entry.name }) catch dir_path;
                node.children = self.listDir(child_path, depth + 1);
            }
            list.append(node) catch {};
        }
        return list;
    }

    fn deinitTreeNode(node: *TreeNode) void {
        for (node.children.items) |*child| deinitTreeNode(child);
        node.children.deinit();
    }

    /// Frees the current tree contents (node lists; names live in tree_arena).
    /// The widget resets its stale selection/hover when tree_rev bumps.
    fn clearTree(self: *DashboardApp) void {
        for (self.tree_roots.items) |*n| deinitTreeNode(n);
        self.tree_roots.clearRetainingCapacity();
    }

    /// Rebuilds the tree from the picked folder (called on the UI thread).
    fn populateFromFolder(self: *DashboardApp, path: []const u8) void {
        self.clearTree();
        _ = self.tree_arena.reset(.retain_capacity);
        self.tree_id_counter = 1;
        self.tree_item_count = 0;
        const a = self.tree_arena.allocator();

        var children = self.listDir(path, 0);
        const base = std.fs.path.basename(path);
        const root_name = a.dupe(u8, if (base.len > 0) base else path) catch "folder";
        const root = TreeNode{
            .id = self.nextTreeId(),
            .name = root_name,
            .node_type = .branch,
            .expanded = true,
            .children = children,
        };
        self.tree_roots.append(root) catch {
            deinitTreeNode(@constCast(&root));
            children = undefined;
            return;
        };
        // Structural data swap → the TreeView's build re-runs in isolation.
        self.tree_rev.set(self.tree_rev.peek() +% 1);
    }

    /// Basename of the picked folder for the EXPLORER header (uppercased-ish label).
    fn folderName(self: *DashboardApp) []const u8 {
        if (self.picked_path_len == 0) return "EXPLORER";
        const p = self.picked_path_buf[0..self.picked_path_len];
        const base = std.fs.path.basename(p);
        return if (base.len > 0) base else p;
    }

    /// Bump the repaint signal from the UI thread → the reactive root re-runs
    /// (replaces triggerRebuild). Called from postTask callbacks, so the signal
    /// drain runs on the UI thread — safe.
    fn requestRepaint(self: *DashboardApp) void {
        self.rev.set(self.rev.peek() +% 1);
    }

    pub fn deinit(self: *DashboardApp) void {
        self.ctx_menu.deinit();
        self.dialog_open.deinit();
        self.sidebar_collapsed.deinit();
        self.rev.deinit();
        self.router.deinit();
        for (self.tree_roots.items) |*n| deinitTreeNode(n);
        self.tree_roots.deinit();
        self.tree_rev.deinit();
        self.tree_arena.deinit();
        self.active_tab.deinit();
        self.allocator.destroy(self);
    }

    pub fn build(self: *DashboardApp, ctx: *fw.component.BuildContext) !void {
        // Reactive root: runApp mounts us via mountReactiveFill, so `ctx`
        // carries the MountTable + router. Widgets built below (Tabs → ComponentsTab)
        // need them for `mountOwned`; the old `BuildContext.init(b)` dropped both.
        const b = ctx.builder;
        _ = self.rev.get(); // subscribe the reactive root to the repaint signal
        b.theme = theme_mod.Theme{
            .bg_base = .{ .r = 30, .g = 30, .b = 30 },
            .bg_surface = .{ .r = 60, .g = 60, .b = 63 },
            .bg_surface_hover = .{ .r = 70, .g = 75, .b = 90 },
            .bg_input = .{ .r = 37, .g = 37, .b = 38 },
            .scrollbar_track = .{ .r = 25, .g = 25, .b = 28 },
            .scrollbar_thumb = .{ .r = 100, .g = 100, .b = 110 },
            .accent = .{ .r = 0, .g = 120, .b = 215 },
            .text = .{ .r = 220, .g = 220, .b = 220 },
            .border_color = .{ .r = 90, .g = 90, .b = 95 },
            .border_width = 1.0,
            .radius_base = 4.0,
        };

        const root = try b.openBox();
        try b.background(root, 30, 30, 30);
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);
        try b.flexColumn(root);

        // ── Toolbar: left-aligned buttons, search constrained on the right ──
        const toolbar = try b.openBox();
        try b.height(toolbar, 44, .px);
        try b.width(toolbar, 100, .percent);
        try b.flexRow(toolbar);
        try b.background(toolbar, 45, 45, 45);
        try b.alignItems(toolbar, .center);
        try b.padding(toolbar, 0, 10, 0, 10);

        // Toolbar buttons: framework-owned Buttons with a background override and
        // typed on_click handlers — the wrappers only add the 8px spacing.
        const tb_add = try b.openBox();
        try b.flexRow(tb_add); // row wrapper: children hug width (see mountOwned .hug)
        try b.marginRight(tb_add, 8);
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .key = "add_folder",
            .label = "Add Folder",
            .background = theme_mod.Color{ .r = 0, .g = 120, .b = 215 },
            .on_click = ctx.handler(self, onAddFolder),
        });
        b.close();
        const tb_run = try b.openBox();
        try b.flexRow(tb_run);
        try b.marginRight(tb_run, 8);
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .key = "run_agent",
            .label = "Run Agent",
            .background = theme_mod.Color{ .r = 60, .g = 160, .b = 90 },
            .on_click = ctx.handler(self, onRunAgent),
        });
        b.close();
        const tb_side = try b.openBox();
        try b.flexRow(tb_side);
        try b.marginRight(tb_side, 8);
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .key = "toggle_sidebar",
            .label = "Side Bar",
            .background = theme_mod.Color{ .r = 60, .g = 60, .b = 63 },
            .on_click = ctx.handler(self, onToggleSidebar),
        });
        b.close();

        // Flexible spacer pushes the search box to the right edge.
        const spacer = try b.openBox();
        try b.flexGrow(spacer, 1);
        b.close();

        // Search bar: framework-owned TextInput — the wrapper only constrains
        // the width; `.stretch` makes the mount anchor fill it.
        const search_wrap = try b.openBox();
        try b.width(search_wrap, 260, .px);
        try b.alignItems(search_wrap, .stretch);
        try ctx.mountOwned(fw.text_input.TextInput, .{ .key = "search_bar" });
        b.close();

        b.close(); // toolbar

        // ── Body: split pane (tree | tabs) ──
        const body = try b.openBox();
        try b.flexGrow(body, 1);
        try b.width(body, 100, .percent);
        try b.flexRow(body);
        try ctx.mountOwned(fw.split_pane.SplitPane, .{
            .fill = true,
            .left_child = fw.component.childOf(LeftPaneWidget, &self.left_pane),
            .right_child = fw.component.childOf(RightPane, &self.right_pane),
            .orientation = .horizontal,
            // VS Code-style side bar: stops at 180px, snaps shut when dragged past
            // 90px, reopens at 180px; the toolbar toggles the same signal.
            .left = .{ .min = 180, .collapsible = true, .collapsed = &self.sidebar_collapsed },
            .right = .{ .min = 240 },
        });
        b.close(); // body

        // ── Status bar ──
        const status = try b.openBox();
        try b.height(status, 24, .px);
        try b.width(status, 100, .percent);
        try b.background(status, 0, 122, 204);
        try b.flexRow(status);
        try b.alignItems(status, .center);
        try b.padding(status, 0, 10, 0, 10);

        const folder_label = if (self.picked_path_len > 0)
            self.picked_path_buf[0..self.picked_path_len]
        else
            "No folder selected";
        const fl = try b.addText(folder_label);
        try b.textColor(fl, 255, 255, 255);
        try b.fontSize(fl, 12);

        const sp2 = try b.openBox();
        try b.flexGrow(sp2, 1);
        b.close();

        if (self.tree_item_count > 0) {
            var cbuf: [32]u8 = undefined;
            const ct = std.fmt.bufPrint(&cbuf, "{d} items", .{self.tree_item_count}) catch "";
            const cn = try b.addText(ct);
            try b.textColor(cn, 255, 255, 255);
            try b.fontSize(cn, 12);
        }

        b.close(); // status

        b.close(); // root
    }
};

// ── #1 Folder picker: runs off the UI thread so the native dialog never blocks
// the render loop; the result is marshalled back with postTask. ──
const PickResult = struct {
    app: *DashboardApp,
    path: [*:0]const u8, // engine-owned; freed in applyPick on the UI thread
};

fn applyPick(r: *PickResult) void {
    const p = std.mem.span(r.path);
    const n = @min(p.len, r.app.picked_path_buf.len);
    @memcpy(r.app.picked_path_buf[0..n], p[0..n]);
    r.app.picked_path_len = n;
    // Walk the folder on the UI thread (mutates the retained tree safely).
    r.app.populateFromFolder(r.app.picked_path_buf[0..n]);
    @atomicStore(bool, &r.app.picking, false, .release);
    fw.dialogs.freeString(r.path, null);
    const app = r.app;
    std.heap.c_allocator.destroy(r);
    app.requestRepaint();
}

fn folderPickWorker(self: *DashboardApp) void {
    const p = fw.dialogs.pickFolder(.{ .title = "Select a folder for the agent" }) orelse {
        @atomicStore(bool, &self.picking, false, .release);
        fw.application.requestRedraw();
        return;
    };
    const r = std.heap.c_allocator.create(PickResult) catch {
        fw.dialogs.freeString(p, null);
        @atomicStore(bool, &self.picking, false, .release);
        return;
    };
    r.* = .{ .app = self, .path = p };
    fw.application.postTask(applyPick, r);
}

// ── #2 Cross-thread repaint: a worker emits STREAM_MSG one char at a time. Each
// step posts a task that rebuilds — postTask now wakes the idle loop, so updates
// land within the frame instead of waiting out the idle timeout. ──
fn streamTick(self: *DashboardApp) void {
    self.requestRepaint();
}

fn streamWorker(self: *DashboardApp) void {
    @atomicStore(usize, &self.stream_visible, 0, .release);
    var n: usize = 0;
    while (n < STREAM_MSG.len) {
        n += 1;
        @atomicStore(usize, &self.stream_visible, n, .release);
        fw.application.postTask(streamTick, self);
        sleepMs(18);
    }
    @atomicStore(bool, &self.streaming, false, .release);
    fw.application.postTask(streamTick, self);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var app = try DashboardApp.init(allocator);
    defer app.deinit();

    try fw.runApp(app, &app.router, .{
        .title = "Celeris Dashboard",
        .width = 1200,
        .height = 800,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
