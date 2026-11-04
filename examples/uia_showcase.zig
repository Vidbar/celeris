//! UIA showcase — a minimal app to validate the Windows UI Automation action
//! patterns (Invoke / Toggle / Value / ExpandCollapse / SelectionItem) and
//! accessible Name/ControlType with a real UIA client (Inspect.exe, NVDA, or any
//! UIA automation tool).
//!
//! Every interactive widget also bumps a shared "Events" counter through its
//! normal handler, so a UIA Invoke()/SetValue()/Toggle() that drives the *real*
//! input path is observable: the counter advances exactly as if a user acted.
//!
//! Run: `zig build uia_showcase`.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

const OPTIONS = [_][]const u8{ "Fast", "Balanced", "Thorough" };

const ShowcaseApp = struct {
    /// Bumped by every widget's real handler. If a UIA action drives the true
    /// input path, this advances — proving the pattern isn't a parallel shortcut.
    events: fw.signals.Signal(i64),
    /// Bumped every time the engine processes a focus change. Focus moves through
    /// one funnel (`moveFocus`), which is exactly where the UIA focus-changed event
    /// is raised — so this label advancing is visible proof the funnel ran, whatever
    /// the origin (Tab, click, or a UIA client's SetFocus).
    focus_events: fw.signals.Signal(i64),
    scope: fw.signals.Scope,

    fn bump(self: *ShowcaseApp, _: fw.events.Event) void {
        self.events.set(self.events.get() + 1);
    }

    /// The observer channel sees every routed event regardless of node/id; we count
    /// only the focus ones. Blur shares the same funnel but we key on focus to keep
    /// it clear.
    fn onFocus(self: *ShowcaseApp, ev: fw.events.Event) void {
        if (std.mem.eql(u8, ev.name, "focus")) {
            self.focus_events.set(self.focus_events.get() + 1);
        }
    }

    /// Opens a Material-styled card: elevated surface, rounded corners, a
    /// hairline outline and a heading — the container every demo lives in so the
    /// showcase reads as a grid of cards rather than a stacked list. Caller must
    /// `b.close()` once after mounting the card's content.
    fn openCard(ctx: *fw.component.BuildContext, title: []const u8) !fw.builder.NodeId {
        const b = ctx.builder;
        const t = b.theme;

        const card = try b.openBox();
        try b.width(card, 240, .px);
        try b.flexColumn(card);
        try b.gap(card, 10);
        try b.padding(card, 16, 16, 16, 16);
        try b.backgroundOf(card, t.surface_low);
        try b.borderColorOf(card, t.border_color);
        try b.borderWidth(card, 1);
        try b.radius(card, t.radius_base * 2);

        const heading = try b.addText(title);
        try b.fontSize(heading, 13);
        try b.textColor(heading, t.text_secondary.r, t.text_secondary.g, t.text_secondary.b);

        return card;
    }

    pub fn build(self: *ShowcaseApp, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;

        const col = try b.openBox();
        try b.flexColumn(col);
        try b.gap(col, 16);
        try b.padding(col, 20, 20, 20, 20);
        try b.width(col, 100, .percent);
        try b.height(col, 100, .percent);
        try b.backgroundOf(col, t.bg_base);

        // Header: live proof the real handler ran (via click OR via UIA Invoke),
        // and that the focus funnel (moveFocus → UIA focus-changed) ran.
        const header = try b.openBox();
        try b.flexRow(header);
        try b.gap(header, 24);
        const counter = try ctx.dynText(i64, &self.scope, &self.events, "Events: {d}");
        try b.fontSize(counter, 16);
        try b.textColor(counter, t.text.r, t.text.g, t.text.b);

        if (ctx.router) |r| try r.onObserver(col, self, onFocus);
        const focus_counter = try ctx.dynText(i64, &self.scope, &self.focus_events, "Focus events: {d}");
        try b.fontSize(focus_counter, 16);
        try b.textColor(focus_counter, t.text.r, t.text.g, t.text.b);
        b.close(); // header

        // Widget gallery: one card per pattern, reflowing into a 3-column grid.
        const grid = try b.openBox();
        try b.flexRow(grid);
        try b.flexWrap(grid, true);
        try b.gap(grid, 16);
        try b.width(grid, 100, .percent);

        // 1) Button → InvokePattern.
        _ = try openCard(ctx, "Button (InvokePattern)");
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .label = "Create…",
            .on_click = ctx.handler(self, bump),
        });
        b.close(); // card

        // 2) Checkbox → TogglePattern.
        _ = try openCard(ctx, "Checkbox (TogglePattern)");
        try ctx.mountOwned(fw.checkbox.Checkbox, .{
            .label = "Open on startup",
            .on_change = ctx.handler(self, bump),
        });
        b.close(); // card

        // 3) TextInput → ValuePattern.
        _ = try openCard(ctx, "Input (ValuePattern)");
        try ctx.mountOwned(fw.text_input.TextInput, .{
            .placeholder = "Project name",
            .on_change = ctx.handler(self, bump),
        });
        b.close(); // card

        // 4) Dropdown → ExpandCollapsePattern (combobox).
        _ = try openCard(ctx, "Dropdown (ExpandCollapsePattern)");
        try ctx.mountOwned(fw.dropdown.Dropdown, .{
            .options = &OPTIONS,
            .aria_label = "Render mode",
            .on_change = ctx.handler(self, bump),
        });
        b.close(); // card

        // 5) RadioGroup → SelectionItemPattern per row.
        _ = try openCard(ctx, "Radios (SelectionItemPattern)");
        try ctx.mountOwned(fw.radio_group.RadioGroup, .{
            .options = &OPTIONS,
            .on_change = ctx.handler(self, bump),
        });
        b.close(); // card

        b.close(); // grid
        b.close(); // col
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = ShowcaseApp{
        .events = fw.signals.Signal(i64).init(allocator, 0),
        .focus_events = fw.signals.Signal(i64).init(allocator, 0),
        .scope = fw.signals.Scope.init(allocator),
    };
    defer app.events.deinit();
    defer app.focus_events.deinit();
    defer app.scope.deinit();

    try fw.runApp(&app, &router, .{
        .title = "Celeris UIA Showcase",
        .width = 820,
        .height = 520,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
