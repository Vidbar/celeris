//! Selector with actions — the recipe in docs/FRAMEWORK_API.md, runnable.
//!
//! A 26 px toolbar with two pickers side by side:
//!   * A run-configuration selector built from a box (the trigger) + a `Menu`
//!     with a header, radio items bound to `config`, a separator and the
//!     "Edit Configurations..." command row. Choosing a radio changes the
//!     selection; the command row runs its own action and leaves it alone.
//!   * A plain `Dropdown` (value picker only) sized for the same toolbar, with
//!     its selection lifted into `mode`.
//! "Reload" swaps the configuration list, the case where the host must drive
//! the selection after its options change.
//!
//! Run: zig build selector_actions

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

const CONFIGS_A = [_][]const u8{ "App", "Unit tests", "Benchmarks" };
const CONFIGS_B = [_][]const u8{ "Server", "Client" };
const MODES = [_][]const u8{ "Debug", "ReleaseSafe", "ReleaseFast" };

const TOOLBAR_H: f32 = 26;

const App = struct {
    allocator: std.mem.Allocator,
    // Signals first: widget effects that observe them unsubscribe before they free.
    config: fw.signals.Signal(usize),
    mode: fw.signals.Signal(usize),
    /// Bumped by Reload: `build` reads it, so the menu rows are rebuilt.
    layout_rev: fw.signals.Signal(u32),
    scope: fw.signals.Scope,
    configs: []const []const u8 = &CONFIGS_A,
    menu: *fw.menu.Menu,

    // Captured during build().
    store: ?@FieldType(fw.component.UIBuilder, "store") = null,
    picker_btn: fw.component.NodeId = 0,
    picker_label: fw.component.NodeId = 0,
    bound: bool = false,

    fn init(allocator: std.mem.Allocator) !*App {
        const self = try allocator.create(App);
        self.* = .{
            .allocator = allocator,
            .config = fw.signals.Signal(usize).init(allocator, 0),
            .mode = fw.signals.Signal(usize).init(allocator, 0),
            .layout_rev = fw.signals.Signal(u32).init(allocator, 0),
            .scope = fw.signals.Scope.init(allocator),
            .menu = try fw.menu.Menu.init(allocator, "run_configs"),
        };
        try self.fillMenu();
        self.menu.on_select = fw.events.makeHandler(self, onMenuSelect);
        return self;
    }

    fn deinit(self: *App) void {
        self.scope.deinit();
        self.menu.deinit();
        self.mode.deinit();
        self.layout_rev.deinit();
        self.config.deinit();
        self.allocator.destroy(self);
    }

    fn fillMenu(self: *App) !void {
        self.menu.clearItems();
        try self.menu.addHeader("Configurations");
        for (self.configs, 0..) |name, i| try self.menu.addRadio(name, "", &self.config, i);
        try self.menu.addSeparator();
        try self.menu.addItem("Edit Configurations...", "edit_configs");
    }

    fn onPicker(self: *App, _: fw.events.Event) void {
        self.menu.popupBelow(self.picker_btn, 2, .pointer);
    }

    fn onMenuSelect(self: *App, ev: fw.events.Event) void {
        if (std.mem.eql(u8, ev.id, "edit_configs")) {
            std.debug.print("[selector] Edit Configurations... (selection stays {s})\n", .{self.configs[self.config.peek()]});
        } else {
            std.debug.print("[selector] config -> {s}\n", .{self.configs[self.config.peek()]});
        }
    }

    fn onModeChange(self: *App, ev: fw.events.Event) void {
        std.debug.print("[selector] mode -> {s} (index {?d})\n", .{ MODES[self.mode.peek()], ev.item_id });
    }

    /// Swaps the option list. The host owns the selection, so it resets it to
    /// a valid index itself, then rebuilds the menu rows (`clearItems` contract).
    fn onReload(self: *App, _: fw.events.Event) void {
        self.configs = if (self.configs.ptr == &CONFIGS_A) &CONFIGS_B else &CONFIGS_A;
        self.fillMenu() catch return;
        self.config.set(0);
        self.layout_rev.set(self.layout_rev.peek() +% 1);
    }

    /// Keeps the trigger label on `configs[config]`, live (no rebuild).
    fn refreshLabel(self: *App) void {
        const store = self.store orelse return;
        const i = self.config.get();
        _ = self.layout_rev.get();
        if (self.picker_label == 0 or i >= self.configs.len) return;
        if (store.stringAllocator().dupe(u8, self.configs[i])) |s| store.setTextContent(self.picker_label, s) else |_| {}
    }

    pub fn build(self: *App, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;
        self.store = b.store;
        _ = self.layout_rev.get(); // rebuild the menu rows after a reload

        const root = try b.openBox();
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);
        try b.flexColumn(root);

        // Toolbar.
        const bar = try b.openBox();
        try b.width(bar, 100, .percent);
        try b.height(bar, TOOLBAR_H + 8, .px);
        try b.flexRow(bar);
        try b.alignItems(bar, .center);
        try b.gap(bar, 8);
        try b.padding(bar, 4, 8, 4, 8);
        try b.backgroundOf(bar, t.surface_high);

        // Selector with actions: a focusable box + the Menu below it.
        self.picker_btn = try ctx.boxNode(.{
            .height = TOOLBAR_H,
            .padding = fw.component.EdgeInsets.symmetric(8, 0),
            .direction = .row,
            .@"align" = .center,
            .gap = 6,
            .border_width = 1,
            .radius = 4,
            .focusable = true,
            .on_click = ctx.handler(self, onPicker),
        }, .{
            PickerLabel{ .app = self },
            fw.component.Text{ .content = "v", .size = 10, .color = fw.component.rgb(t.text.r, t.text.g, t.text.b) },
        });
        try b.role(self.picker_btn, "button");
        try b.ariaLabel(self.picker_btn, "Run configuration");
        try b.borderColorAlpha(self.picker_btn, 80, 80, 80, 255);

        // Plain value picker, sized for the same toolbar.
        try ctx.mountOwned(fw.dropdown.Dropdown, .{
            .options = &MODES,
            .selected = &self.mode,
            .on_change = ctx.handler(self, onModeChange),
            .width = null,
            .height = TOOLBAR_H,
            .font_size = 12,
            .aria_label = "Build mode",
        });

        try ctx.mountOwned(fw.button.Button, .{ .label = "Reload configs", .on_click = ctx.handler(self, onReload) });
        b.close(); // bar

        // Last child of the root: full-window overlay.
        try self.menu.build(ctx);
        b.close(); // root

        try fw.component.bindVisuals(self, &self.scope, &self.bound, refreshLabel);
    }
};

const PickerLabel = struct {
    app: *App,
    pub fn build(self: *PickerLabel, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;
        const app = self.app;
        app.picker_label = try b.addText(app.configs[@min(app.config.peek(), app.configs.len - 1)]);
        try b.fontSize(app.picker_label, 12);
        try b.textColor(app.picker_label, t.text.r, t.text.g, t.text.b);
    }
    pub fn deinit(_: *PickerLabel) void {}
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();
    const app = try App.init(allocator);
    defer app.deinit();

    try fw.runApp(app, &router, .{
        .title = "Celeris Selector with actions",
        .width = 640,
        .height = 360,
        .theme = fw.theme.Theme.dark(),
    });
}
