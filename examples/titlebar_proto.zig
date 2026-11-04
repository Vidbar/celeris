//! titlebar_proto — a custom window caption composed by the app.
//!
//! There is no native OS title bar (the window is borderless: WS_POPUP with
//! WM_NCCALCSIZE stripped), so the whole top strip is ours to draw. The framework
//! supplies only what an app cannot: `WindowChrome`'s draggable region and the
//! min/max/close controls. Everything visible in the caption here — the wordmark,
//! the pill, the 44px height, and the `MenuBar` — is this example's, passed
//! through `options.app_bar` as a content slot. Doubles as a bold/mono smoke test
//! for per-node font-select, and as the live demo for the embeddable-`MenuBar`
//! work: the bar sits to the right
//! of the wordmark, transparent, at the caption's own height, and its popups
//! open under the right button instead of at the window's top-left corner.
//!
//! Run: `zig build titlebar_proto`

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

// ── Demo menu state (module-level, like a real host's app state) ──────────────
// `Menu.on_select` only hands the callback the menu itself + the chosen
// action_id (framework.menu.Menu.on_select), not host context — a real host
// closes over its own state some other way (a global, a context struct
// threaded through main()); globals are the simplest thing that demonstrates
// the reactive checked/enabled wiring here.
var g_grid_checked: fw.signals.Signal(bool) = undefined;
var g_advanced_checked: fw.signals.Signal(bool) = undefined;
var g_rec_start_enabled: fw.signals.Signal(bool) = undefined;
var g_rec_stop_enabled: fw.signals.Signal(bool) = undefined;
var g_status: [128]u8 = undefined;
var g_status_len: usize = 0;

fn setStatus(s: []const u8) void {
    g_status_len = @min(s.len, g_status.len);
    @memcpy(g_status[0..g_status_len], s[0..g_status_len]);
}

fn onMenuSelect(_: *fw.menu.Menu, action_id: []const u8) void {
    if (std.mem.eql(u8, action_id, "view.grid")) {
        g_grid_checked.set(!g_grid_checked.get());
        setStatus(if (g_grid_checked.get()) "Grid on" else "Grid off");
    } else if (std.mem.eql(u8, action_id, "rec.advanced")) {
        g_advanced_checked.set(!g_advanced_checked.get());
        setStatus(if (g_advanced_checked.get()) "Advanced mode on" else "Advanced mode off");
    } else if (std.mem.eql(u8, action_id, "rec.start")) {
        g_rec_start_enabled.set(false);
        g_rec_stop_enabled.set(true);
        setStatus("Recording started");
    } else if (std.mem.eql(u8, action_id, "rec.stop")) {
        g_rec_start_enabled.set(true);
        g_rec_stop_enabled.set(false);
        setStatus("Recording stopped");
    } else if (std.mem.eql(u8, action_id, "proj.new")) {
        setStatus("New project");
    } else if (std.mem.eql(u8, action_id, "proj.save")) {
        setStatus("Project saved");
    } else if (std.mem.eql(u8, action_id, "proj.exit")) {
        setStatus("Exit (demo, does not close the app)");
    } else if (std.mem.eql(u8, action_id, "recent.a")) {
        setStatus("Opening demo_project.cel");
    } else if (std.mem.eql(u8, action_id, "recent.b")) {
        setStatus("Opening recording_2026.cel");
    } else if (std.mem.eql(u8, action_id, "run.exec")) {
        setStatus("Running");
    } else if (std.mem.eql(u8, action_id, "view.dark")) {
        setStatus("Dark mode (visual demo)");
    }
}

/// The caption's contents: a bold wordmark, a rounded pill, and — the point of
/// this example — a `MenuBar` to the right of them, transparent and at
/// the caption's own height, with each menu's popup opening under its own
/// button instead of at the window origin, and its buttons excluded
/// from the caption's drag region.
const Caption = struct {
    label: []const u8,
    badge: ?[]const u8 = null,

    menu_bar: *fw.menu.MenuBar,
    project_menu: *fw.menu.Menu,
    recent_menu: *fw.menu.Menu,
    recording_menu: *fw.menu.Menu,
    run_menu: *fw.menu.Menu,
    view_menu: *fw.menu.Menu,

    pub fn build(self: *Caption, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;

        const row = try b.openBox();
        try b.flexRow(row);
        try b.alignItems(row, .center);
        try b.gap(row, 10);
        try b.padding(row, 0, 0, 0, 14);

        const wm = try b.addText(self.label);
        try b.fontSize(wm, 15);
        try b.fontBold(wm, true);
        try b.flexShrink(wm, 0);
        try b.textColorOf(wm, t.text);

        if (self.badge) |text| {
            const pill = try b.openBox();
            try b.backgroundOf(pill, t.accent_container);
            try b.radius(pill, 10);
            try b.borderWidth(pill, 1);
            try b.borderColorOf(pill, t.accent.withAlpha(0.55));
            try b.flexRow(pill);
            try b.alignItems(pill, .center);
            try b.flexShrink(pill, 0);
            try b.padding(pill, 3, 9, 3, 9);
            const txt = try b.addText(text);
            try b.fontSize(txt, 11);
            try b.fontBold(txt, true);
            try b.textColorOf(txt, t.text_on_accent_container);
            b.close(); // pill
        }

        // Transparent, hugs its own content, matches the 44px caption —
        // none of the old width:100%/opaque-bar/fixed-32px defaults.
        self.menu_bar.height = 44;
        self.menu_bar.background = fw.theme.Color.transparent();
        self.menu_bar.hug = true;
        try self.menu_bar.build(ctx);

        b.close(); // row
    }

    pub fn deinit(_: *Caption) void {}
};

const Demo = struct {
    status_id: fw.component.NodeId = 0,

    pub fn build(self: *Demo, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;

        const col = try b.openBox();
        try b.flexColumn(col);
        try b.alignItems(col, .center);
        try b.justifyContent(col, .center);
        try b.gap(col, 12);
        try b.width(col, 100, .percent);
        try b.height(col, 100, .percent);

        const h = try b.addText("44px custom title bar");
        try b.fontSize(h, 24);
        try b.fontBold(h, true);
        try b.textColor(h, t.text.r, t.text.g, t.text.b);

        const sub = try b.addText("app-composed caption . drag . window controls . embedded MenuBar");
        try b.fontSize(sub, 14);
        try b.textColor(sub, t.text_secondary.r, t.text_secondary.g, t.text_secondary.b);

        // Monospace line — exercises the mono role end to end.
        const mono = try b.addText("options.app_bar = childOf(Caption, &caption)");
        try b.fontSize(mono, 14);
        try b.fontMono(mono, true);
        try b.textColor(mono, t.accent.r, t.accent.g, t.accent.b);

        const status = try b.addText(g_status[0..g_status_len]);
        self.status_id = status;
        try b.fontSize(status, 13);
        try b.textColor(status, t.text_secondary.r, t.text_secondary.g, t.text_secondary.b);

        b.close(); // col
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    g_grid_checked = fw.signals.Signal(bool).init(allocator, false);
    defer g_grid_checked.deinit();
    g_advanced_checked = fw.signals.Signal(bool).init(allocator, false);
    defer g_advanced_checked.deinit();
    g_rec_start_enabled = fw.signals.Signal(bool).init(allocator, true);
    defer g_rec_start_enabled.deinit();
    g_rec_stop_enabled = fw.signals.Signal(bool).init(allocator, false);
    defer g_rec_stop_enabled.deinit();
    setStatus("Ready");

    // ── Menus ───────────────────────────────────────────────────────────────
    const project_menu = try fw.menu.Menu.init(allocator, "project_menu");
    defer project_menu.deinit();
    project_menu.on_select = onMenuSelect;
    try project_menu.addItemEx(.{ .label = "New", .action_id = "proj.new", .shortcut = "Ctrl+N" });

    const recent_menu = try fw.menu.Menu.init(allocator, "recent_menu");
    defer recent_menu.deinit();
    recent_menu.on_select = onMenuSelect;
    try recent_menu.addItem("demo_project.cel", "recent.a");
    try recent_menu.addItem("recording_2026.cel", "recent.b");
    try project_menu.addSubmenu("Recent", recent_menu);

    try project_menu.addItemEx(.{ .label = "Save", .action_id = "proj.save", .shortcut = "Ctrl+S" });
    try project_menu.addSeparator();
    try project_menu.addItemEx(.{ .label = "Exit", .action_id = "proj.exit", .shortcut = "Ctrl+Q" });

    const recording_menu = try fw.menu.Menu.init(allocator, "recording_menu");
    defer recording_menu.deinit();
    recording_menu.on_select = onMenuSelect;
    try recording_menu.addItemEx(.{ .label = "Start recording", .action_id = "rec.start", .enabled_signal = &g_rec_start_enabled });
    try recording_menu.addItemEx(.{ .label = "Stop recording", .action_id = "rec.stop", .enabled_signal = &g_rec_stop_enabled });
    try recording_menu.addSeparator();
    try recording_menu.addItemEx(.{ .label = "Advanced mode", .action_id = "rec.advanced", .checked_signal = &g_advanced_checked });

    const run_menu = try fw.menu.Menu.init(allocator, "run_menu");
    defer run_menu.deinit();
    run_menu.on_select = onMenuSelect;
    try run_menu.addItemEx(.{ .label = "Run", .action_id = "run.exec", .shortcut = "F5" });

    const view_menu = try fw.menu.Menu.init(allocator, "view_menu");
    defer view_menu.deinit();
    view_menu.on_select = onMenuSelect;
    try view_menu.addItemEx(.{ .label = "Grid", .action_id = "view.grid", .checked_signal = &g_grid_checked });
    try view_menu.addItemEx(.{ .label = "Dark mode", .action_id = "view.dark" });
    // Long label on purpose: exercises the content-measured panel width
    // (the fixed 200px PANEL_W would clip or crowd this).
    try view_menu.addItemEx(.{ .label = "Sync real-time collaboration", .action_id = "view.sync" });

    const menu_bar = try fw.menu.MenuBar.init(allocator, "app_menu_bar");
    defer menu_bar.deinit();
    try menu_bar.addMenu("Project", project_menu);
    try menu_bar.addMenu("Recording", recording_menu);
    try menu_bar.addMenu("Run", run_menu);
    try menu_bar.addMenu("View", view_menu);

    var app = Demo{};
    // Caller-owned: the slot must outlive runApp.
    var caption = Caption{
        .label = "Celeris",
        .badge = "DevTools",
        .menu_bar = menu_bar,
        .project_menu = project_menu,
        .recent_menu = recent_menu,
        .recording_menu = recording_menu,
        .run_menu = run_menu,
        .view_menu = view_menu,
    };

    try fw.runApp(&app, &router, .{
        .title = "Celeris",
        .width = 900,
        .height = 560,
        .app_bar = fw.component.childOf(Caption, &caption),
        .app_bar_height = 44,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
