//! Key/value property panel — the recipe for a DevTools-style inspector pane.
//!
//! Per the framework philosophy (no new widget until there are ≥2 real consumers),
//! a property panel is a **composition**, not a built-in widget: a small reusable
//! `KvRow` component plus a plain build-loop over the data. This example is the
//! executable reference the docs quote (see `FRAMEWORK_API.md` → "Recipes →
//! Key/value property panel"), so it can't silently drift from the real API.
//!
//! What it shows:
//!   * `KvRow` — a two-cell row (dimmed key with a fixed column basis, value that
//!     grows). Because every key cell shares the same basis, columns line up across
//!     rows without a table/grid.
//!   * A build-loop that stamps one `KvRow` per data pair — the "map over a slice"
//!     pattern, no widget needed.
//!   * A reactive value via `dynText` bound to a `Signal`: the button mutates the
//!     signal and only that row's value text repaints (no tree rebuild).
//!
//! Compiled in CI (`zig build examples`) and run with `zig build property_panel`.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

/// One key/value pair rendered as an aligned two-cell row. Reusable: the app
/// stamps a slice of these in a loop. To promote this to a real widget later (once
/// a second consumer needs it), move it to `src/framework/` with lifted props
/// (`values: []const Kv`, `data_rev`) following the same patterns as the other
/// widgets — see the docs' promotion criterion.
const KvRow = struct {
    key: []const u8,
    value: []const u8,

    pub fn build(self: *KvRow, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;

        // Material card: each pair is its own tile so the panel reflows into a
        // grid instead of a stacked list (width set by the caller's grid cell).
        const row = try b.openBox();
        try b.flexColumn(row);
        try b.width(row, 100, .percent);
        try b.padding(row, 8, 10, 8, 10);
        try b.gap(row, 2);
        try b.backgroundOf(row, t.surface_low);
        try b.borderColorOf(row, t.border_color);
        try b.borderWidth(row, 1);
        try b.radius(row, t.radius_base);

        // Accessibility: expose the pair as a "listitem" whose accessible name is
        // "key: value", so a UIA client / screen reader reads the row as one unit
        // (a bare box carries no role and wouldn't reach the a11y tree at all). The
        // "list" role is on the container the rows are stamped into (see build()).
        try b.role(row, "listitem");
        var name_buf: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}: {s}", .{ self.key, self.value }) catch self.key;
        try b.ariaLabel(row, name);

        // Key label, dimmed, above the value.
        const key = try b.addText(self.key);
        try b.fontSize(key, 11);
        try b.textColor(key, t.text_disabled.r, t.text_disabled.g, t.text_disabled.b);

        // Value: shrinks to fit the card instead of spilling past it (flex-shrink
        // defaults to 0 in this engine — Yoga-style — so min-width:0 is needed for
        // a long value to wrap inside its allocation).
        const val = try b.addText(self.value);
        try b.flexShrink(val, 1);
        try b.minWidth(val, 0, .px);
        try b.textColor(val, t.text.r, t.text.g, t.text.b);

        b.close(); // row
    }

    pub fn deinit(_: *KvRow) void {}
};

const PropertyPanelApp = struct {
    /// The reactive value shown in the "renders" row; the button bumps it.
    renders: fw.signals.Signal(i64),
    /// Owns the `dynText` binding effect for the app's lifetime.
    scope: fw.signals.Scope,

    /// Static inspector data. In a real DevTools pane these come from the selected
    /// element; here they're literals to keep the recipe self-contained.
    const static_rows = [_]KvRow{
        .{ .key = "id", .value = "n_42" },
        .{ .key = "type", .value = "Box" },
        .{ .key = "width", .value = "320px" },
        .{ .key = "flex-direction", .value = "row" },
        .{ .key = "visible", .value = "true" },
    };

    fn onBump(self: *PropertyPanelApp, ev: fw.events.Event) void {
        _ = ev;
        self.renders.set(self.renders.get() + 1);
    }

    pub fn build(self: *PropertyPanelApp, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;

        const col = try b.openBox();
        try b.flexColumn(col);
        try b.width(col, 100, .percent);
        try b.height(col, 100, .percent);
        try b.padding(col, 16, 16, 16, 16);
        try b.gap(col, 4);

        // Panel title.
        const title = try b.addText("Properties");
        try b.fontSize(title, 20);
        try b.textColor(title, t.text.r, t.text.g, t.text.b);

        // Accessibility: the rows live inside a "list" container so a UIA client
        // reads them as an enumerable list (each KvRow is a "listitem"); a screen
        // reader can then announce "N of M" as it moves through the pairs. Visually
        // it's a wrapping grid of cards — each cell a fixed width so the panel
        // reflows into 2-3 columns depending on how wide the window is.
        const list = try b.openBox();
        try b.flexRow(list);
        try b.flexWrap(list, true);
        try b.width(list, 100, .percent);
        try b.gap(list, 8);
        try b.role(list, "list");

        // The recipe: one KvRow per data pair, stamped in a loop, each in its own
        // fixed-width grid cell.
        var rows = static_rows;
        for (&rows) |*row| {
            const cell = try b.openBox();
            try b.width(cell, 140, .px);
            try row.build(ctx);
            b.close(); // cell
        }

        // A reactive card: same shape as KvRow's card, but the value is a dynText
        // bound to the signal — mutating the signal repaints only this text node.
        // It's a "listitem" too; its accessible name is the key ("renders"), and
        // the live value stays reachable as the card's child text node (a
        // "listitem" is named by the author, not its contents, so we don't fold
        // the changing value into the name where it would go stale).
        const live_cell = try b.openBox();
        try b.width(live_cell, 140, .px);
        const live = try b.openBox();
        try b.flexColumn(live);
        try b.width(live, 100, .percent);
        try b.padding(live, 8, 10, 8, 10);
        try b.gap(live, 2);
        try b.backgroundOf(live, t.surface_low);
        try b.borderColorOf(live, t.border_color);
        try b.borderWidth(live, 1);
        try b.radius(live, t.radius_base);
        try b.role(live, "listitem");
        try b.ariaLabel(live, "renders");
        const live_key = try b.addText("renders");
        try b.fontSize(live_key, 11);
        try b.textColor(live_key, t.text_disabled.r, t.text_disabled.g, t.text_disabled.b);
        const live_val = try ctx.dynText(i64, &self.scope, &self.renders, "{d}");
        try b.textColor(live_val, t.text.r, t.text.g, t.text.b);
        b.close(); // live
        b.close(); // live_cell

        b.close(); // list

        // Button to drive the reactive value (a row wrapper lets it hug).
        const wrap = try b.openBox();
        try b.flexRow(wrap);
        try b.marginTop(wrap, 12);
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .key = "bump",
            .label = "Re-render",
            .on_click = ctx.handler(self, onBump),
        });
        b.close(); // wrap

        b.close(); // col
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = PropertyPanelApp{
        .renders = fw.signals.Signal(i64).init(allocator, 0),
        .scope = fw.signals.Scope.init(allocator),
    };
    defer app.renders.deinit();
    defer app.scope.deinit();

    try fw.runApp(&app, &router, .{
        .title = "Celeris Property Panel",
        .width = 480,
        .height = 420,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
