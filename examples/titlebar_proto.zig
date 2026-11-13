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

// ── Demo state ──────────────────────────────────────────────────────────────
// Lives in `Demo` (the app instance), not in globals: every menu's `on_select`
// is an `events.Handler` whose payload is `*Demo`, so the selection reaches the
// host's own state directly — the same way a host would route ids into its own
// command registry.
const Demo = struct {
    const titles_start = 3; // "Celeris", the startup title
    grid_checked: fw.signals.Signal(bool),
    advanced_checked: fw.signals.Signal(bool),
    rec_start_enabled: fw.signals.Signal(bool),
    rec_stop_enabled: fw.signals.Signal(bool),
    status: [128]u8 = undefined,
    status_len: usize = 0,
    status_id: fw.component.NodeId = 0,
    title_idx: usize = titles_start,

    fn init(allocator: std.mem.Allocator) Demo {
        var d: Demo = .{
            .grid_checked = fw.signals.Signal(bool).init(allocator, false),
            .advanced_checked = fw.signals.Signal(bool).init(allocator, false),
            .rec_start_enabled = fw.signals.Signal(bool).init(allocator, true),
            .rec_stop_enabled = fw.signals.Signal(bool).init(allocator, false),
        };
        d.setStatus("Ready");
        return d;
    }

    fn deinit(self: *Demo) void {
        self.grid_checked.deinit();
        self.advanced_checked.deinit();
        self.rec_start_enabled.deinit();
        self.rec_stop_enabled.deinit();
    }

    fn setStatus(self: *Demo, s: []const u8) void {
        self.status_len = @min(s.len, self.status.len);
        @memcpy(self.status[0..self.status_len], s[0..self.status_len]);
    }

    fn onMenuSelect(self: *Demo, ev: fw.events.Event) void {
        const id = ev.id; // the chosen item's action_id
        if (std.mem.eql(u8, id, "view.grid")) {
            self.grid_checked.set(!self.grid_checked.get());
            self.setStatus(if (self.grid_checked.get()) "Grid on" else "Grid off");
        } else if (std.mem.eql(u8, id, "rec.advanced")) {
            self.advanced_checked.set(!self.advanced_checked.get());
            self.setStatus(if (self.advanced_checked.get()) "Advanced mode on" else "Advanced mode off");
        } else if (std.mem.eql(u8, id, "rec.start")) {
            self.rec_start_enabled.set(false);
            self.rec_stop_enabled.set(true);
            self.setStatus("Recording started");
        } else if (std.mem.eql(u8, id, "rec.stop")) {
            self.rec_start_enabled.set(true);
            self.rec_stop_enabled.set(false);
            self.setStatus("Recording stopped");
        } else if (std.mem.eql(u8, id, "proj.new")) {
            self.setStatus("New project");
        } else if (std.mem.eql(u8, id, "proj.rename")) {
            // Manual check for `fw.window.setTitle`: watch the taskbar / Alt+Tab
            // entry. The titles include non-ASCII text on purpose (UTF-16 on
            // Win32, UTF-8 through libdecor on Wayland).
            const titles = [_][]const u8{ "demo_project - Celeris", "Diseño ñandú - Celeris", "日本語 \u{1F4C1} - Celeris", "Celeris" };
            self.title_idx = (self.title_idx + 1) % titles.len;
            fw.window.setTitle(titles[self.title_idx]);
            self.setStatus("Window retitled (check the taskbar)");
        } else if (std.mem.eql(u8, id, "proj.save")) {
            self.setStatus("Project saved");
        } else if (std.mem.eql(u8, id, "proj.exit")) {
            self.setStatus("Exit (demo, does not close the app)");
        } else if (std.mem.eql(u8, id, "recent.a")) {
            self.setStatus("Opening demo_project.cel");
        } else if (std.mem.eql(u8, id, "recent.b")) {
            self.setStatus("Opening recording_2026.cel");
        } else if (std.mem.eql(u8, id, "run.exec")) {
            self.setStatus("Running");
        } else if (std.mem.eql(u8, id, "view.dark")) {
            self.setStatus("Dark mode (visual demo)");
        }
    }

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

        const status = try b.addText(self.status[0..self.status_len]);
        self.status_id = status;
        try b.fontSize(status, 13);
        try b.textColor(status, t.text_secondary.r, t.text_secondary.g, t.text_secondary.b);

        b.close(); // col
    }
};

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

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = Demo.init(allocator);
    defer app.deinit();
    const on_select = fw.events.makeHandler(&app, Demo.onMenuSelect);

    // ── Menus ───────────────────────────────────────────────────────────────
    const project_menu = try fw.menu.Menu.init(allocator, "project_menu");
    defer project_menu.deinit();
    project_menu.on_select = on_select;
    try project_menu.addItemEx(.{ .label = "New", .action_id = "proj.new", .shortcut = "Ctrl+N" });

    const recent_menu = try fw.menu.Menu.init(allocator, "recent_menu");
    defer recent_menu.deinit();
    try recent_menu.addItem("demo_project.cel", "recent.a");
    try recent_menu.addItem("recording_2026.cel", "recent.b");
    try project_menu.addSubmenu("Recent", recent_menu);

    try project_menu.addItemEx(.{ .label = "Save", .action_id = "proj.save", .shortcut = "Ctrl+S" });
    try project_menu.addItem("Rename window", "proj.rename");
    try project_menu.addSeparator();
    try project_menu.addItemEx(.{ .label = "Exit", .action_id = "proj.exit", .shortcut = "Ctrl+Q" });

    const recording_menu = try fw.menu.Menu.init(allocator, "recording_menu");
    defer recording_menu.deinit();
    recording_menu.on_select = on_select;
    try recording_menu.addItemEx(.{ .label = "Start recording", .action_id = "rec.start", .enabled_signal = &app.rec_start_enabled });
    try recording_menu.addItemEx(.{ .label = "Stop recording", .action_id = "rec.stop", .enabled_signal = &app.rec_stop_enabled });
    try recording_menu.addSeparator();
    try recording_menu.addItemEx(.{ .label = "Advanced mode", .action_id = "rec.advanced", .checked_signal = &app.advanced_checked });

    const run_menu = try fw.menu.Menu.init(allocator, "run_menu");
    defer run_menu.deinit();
    run_menu.on_select = on_select;
    try run_menu.addItemEx(.{ .label = "Run", .action_id = "run.exec", .shortcut = "F5" });

    const view_menu = try fw.menu.Menu.init(allocator, "view_menu");
    defer view_menu.deinit();
    view_menu.on_select = on_select;
    try view_menu.addItemEx(.{ .label = "Grid", .action_id = "view.grid", .checked_signal = &app.grid_checked });
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
