//! The canonical Celeris counter — the reference for the component model.
//!
//! What it shows, and nothing it doesn't need:
//!   * The root app is a plain struct with `build(self, *BuildContext)`. `runApp`
//!     mounts it reactively — no `triggerRebuild`, no `register`, no action-id strings.
//!   * State is a `Signal`. The count label is a `dynText` bound once to that signal;
//!     when the signal changes, the framework updates the text node in place — the
//!     tree is not rebuilt.
//!   * The button is framework-owned (`ctx.mountOwned`) with a typed `on_click`
//!     handler (`ctx.handler`) — no allocation, no `deinit`, no string wiring.
//!
//! This file is compiled in CI (`zig build examples`) and run with `zig build counter`,
//! and `zig build test` checks that docs/FRAMEWORK_API.md quotes it verbatim.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

const CounterApp = struct {
    /// The only state: a reactive integer. `dynText` below tracks it.
    count: fw.signals.Signal(i64),
    /// Owns the `dynText` binding effect for the app's lifetime.
    scope: fw.signals.Scope,

    /// Typed `on_click` handler: bump the signal. The bound label repaints itself;
    /// we never touch the UI tree here.
    fn onIncrement(self: *CounterApp, ev: fw.events.Event) void {
        _ = ev;
        self.count.set(self.count.get() + 1);
    }

    pub fn build(self: *CounterApp, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;

        const col = try b.openBox();
        try b.flexColumn(col);
        try b.alignItems(col, .center);
        try b.justifyContent(col, .center);
        try b.gap(col, 16);
        try b.width(col, 100, .percent);
        try b.height(col, 100, .percent);

        // Reactive label — bound once; updates in place when `count` changes.
        const label = try ctx.dynText(i64, &self.scope, &self.count, "Count: {d}");
        try b.fontSize(label, 32);

        // Framework-owned button with a typed handler. A row wrapper lets it hug.
        const wrap = try b.openBox();
        try b.flexRow(wrap);
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .key = "increment",
            .label = "Increment",
            .on_click = ctx.handler(self, onIncrement),
        });
        b.close(); // wrap

        b.close(); // col
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = CounterApp{
        .count = fw.signals.Signal(i64).init(allocator, 0),
        .scope = fw.signals.Scope.init(allocator),
    };
    defer app.count.deinit();
    defer app.scope.deinit();

    try fw.runApp(&app, &router, .{
        .title = "Celeris Counter",
        .width = 400,
        .height = 300,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
