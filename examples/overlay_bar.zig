//! overlay_bar — a secondary window with its own component tree.
//!
//! The recording-HUD shape: a main window with state worth keeping (a scrolled
//! list, a counter), and a compact always-on-top bar that appears while a session
//! is "recording", floats over whatever the user is doing, and goes away again.
//!
//! What this example is really demonstrating is what does NOT happen: opening and
//! closing the bar never rebuilds the main window's tree. Scroll the list, bump the
//! counter, toggle the bar a few times — the list stays where you left it. The
//! alternative (returning a different root from the
//! app's `build`) unmounts everything and loses exactly that state.
//!
//! Also on show:
//!   • `hide_app_bar` + `ctx.dragRegion` — a caption-less bar the user can still
//!     move out of the way by dragging anywhere that isn't a button.
//!   • `window.hide()` / `window.show()` — the main window steps aside while the
//!     bar is up, with its tree intact.
//!   • Independent input: the bar's Stop button drives its own handlers.
//!
//! Run: `zig build overlay_bar`

const std = @import("std");
const builtin = @import("builtin");
const celeris = @import("celeris");
const fw = celeris.framework;

// Win32-only decl; the branch below is comptime-resolved, so it is pruned elsewhere.
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

/// Cross-platform millisecond sleep (`std.Thread.sleep` is posix-only in 0.16).
fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        Sleep(ms);
    } else {
        std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
    }
}

const BuildContext = fw.component.BuildContext;

/// The floating bar's contents. A plain component — it has no idea it is being
/// built into a different window than the rest of the app, which is the point.
const RecorderBar = struct {
    // Lifted state, the framework's convention: these signals belong to the app and
    // are only read here.
    steps: ?*fw.signals.Signal(u32) = null,
    recording: ?*fw.signals.Signal(bool) = null,

    allocator: std.mem.Allocator = undefined,
    scope: fw.signals.Scope = undefined,
    hover_stop: fw.signals.Signal(bool) = undefined,

    pub fn init(allocator: std.mem.Allocator) RecorderBar {
        return .{
            .allocator = allocator,
            .scope = fw.signals.Scope.init(allocator),
            .hover_stop = fw.signals.Signal(bool).init(allocator, false),
        };
    }

    /// Fired when the window this was built into closes. The scope below owns
    /// `dynText`'s binding, which points at a node in that window's registry — an
    /// effect still subscribed to `steps` and still writing into a store that is
    /// about to be freed. Dropping it here is the difference between reopening the
    /// bar and corrupting the heap.
    ///
    /// This is the contract for any caller-owned content (`childOf`) reused across
    /// windows: state that refers to *nodes* is per-mount and belongs here; state
    /// that is genuinely the app's (the step count, the recording flag) lives
    /// outside and is exactly what survives.
    pub fn onUnmount(self: *RecorderBar) void {
        self.scope.deinit();
        self.scope = fw.signals.Scope.init(self.allocator);
    }

    pub fn deinit(self: *RecorderBar) void {
        self.scope.deinit();
        self.hover_stop.deinit();
    }

    fn onStop(self: *RecorderBar, _: fw.events.Event) void {
        if (self.recording) |r| r.set(false);
    }

    pub fn build(self: *RecorderBar, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = ctx.theme();

        const bar = try b.openBox();
        try b.flexRow(bar);
        try b.alignItems(bar, .center);
        try b.gap(bar, 12);
        try b.width(bar, 100, .percent);
        try b.height(bar, 100, .percent);
        try b.padding(bar, 0, 14, 0, 14);
        try b.backgroundOf(bar, t.surface_low);

        // The whole bar is the grab handle — minus the button, which is built after
        // it and therefore wins the hit test. On a window with no caption this is
        // the only way the user can move it.
        try ctx.dragRegion(bar);

        // Recording dot.
        const dot = try b.openBox();
        try b.width(dot, 10, .px);
        try b.height(dot, 10, .px);
        try b.radius(dot, 5);
        try b.backgroundOf(dot, t.danger);
        try b.flexShrink(dot, 0);
        b.close();

        const label = try b.addText("Recording");
        try b.fontSize(label, 13);
        try b.fontBold(label, true);
        try b.textColorOf(label, t.text);
        try b.flexShrink(label, 0);

        // Live step counter, bound to the app's signal: the bar updates without
        // anything rebuilding either window.
        const count = try ctx.dynText(u32, &self.scope, self.steps.?, "{d} steps");
        try b.fontSize(count, 13);
        try b.fontMono(count, true);
        try b.textColorOf(count, t.text_secondary);

        const spacer = try b.openBox();
        try b.flexGrow(spacer, 1);
        b.close();

        // Stop button — its clicks reach this window's router only.
        const stop = try b.openBox();
        try b.flexRow(stop);
        try b.alignItems(stop, .center);
        try b.justifyContent(stop, .center);
        try b.padding(stop, 6, 14, 6, 14);
        try b.radius(stop, 6);
        try b.backgroundOf(stop, if (self.hover_stop.get()) t.danger else t.surface_high);
        try b.flexShrink(stop, 0);
        try b.clickable(stop, "overlay_stop");
        try b.hoverable(stop, "overlay_stop");
        if (ctx.router) |r| {
            try r.onNode(stop, .click, ctx.handler(self, onStop));
            const hh = ctx.signalSetter(&self.hover_stop);
            try r.onNode(stop, .mouse_enter, hh);
            try r.onNode(stop, .mouse_leave, hh);
        }
        const stop_txt = try b.addText("Stop");
        try b.fontSize(stop_txt, 13);
        try b.fontBold(stop_txt, true);
        try b.textColorOf(stop_txt, t.text);
        b.close(); // stop

        b.close(); // bar
    }
};

const BAR_W: u32 = 460;
const BAR_H: u32 = 56;

const App = struct {
    allocator: std.mem.Allocator,
    recording: fw.signals.Signal(bool) = undefined,
    steps: fw.signals.Signal(u32) = undefined,
    /// State that must survive the bar opening and closing — the whole point.
    counter: fw.signals.Signal(u32) = undefined,
    bar: RecorderBar = undefined,
    hover_start: fw.signals.Signal(bool) = undefined,
    scope: fw.signals.Scope = undefined,

    /// The main window's saved rect, so `Stop` puts it back exactly where it was
    ///. No PID sweep, no HWND, no rect lost if the app dies meanwhile — the
    /// window is still there the whole time, just hidden.
    saved: ?fw.Rect = null,

    fn init(allocator: std.mem.Allocator) App {
        return .{
            .allocator = allocator,
            .recording = fw.signals.Signal(bool).init(allocator, false),
            .steps = fw.signals.Signal(u32).init(allocator, 0),
            .counter = fw.signals.Signal(u32).init(allocator, 0),
            .hover_start = fw.signals.Signal(bool).init(allocator, false),
            .bar = RecorderBar.init(allocator),
            .scope = fw.signals.Scope.init(allocator),
        };
    }

    fn deinit(self: *App) void {
        self.scope.deinit();
        self.bar.deinit();
        self.hover_start.deinit();
        self.counter.deinit();
        self.steps.deinit();
        self.recording.deinit();
    }

    fn onStart(self: *App, _: fw.events.Event) void {
        self.saved = fw.window.bounds();
        self.steps.set(0);
        self.recording.set(true);
        // The main window steps aside — hidden, not torn down.
        fw.window.hide();
    }

    /// Fired by the counter button, to prove the main window's state is untouched
    /// by the bar coming and going.
    fn onBump(self: *App, _: fw.events.Event) void {
        self.counter.set(self.counter.peek() + 1);
    }

    /// Ticked from the capture thread (via `postTask`, so it runs on the UI
    /// thread), standing in for real capture work.
    fn onTick(self: *App) void {
        if (!self.recording.peek()) {
            // Recording just ended (the bar's Stop button wrote the signal): bring
            // the main window back where it was.
            if (self.saved) |r| {
                fw.window.setBounds(r.x, r.y, r.w, r.h);
                self.saved = null;
                fw.window.show();
            }
            return;
        }
        self.steps.set(self.steps.peek() + 1);
    }

    pub fn build(self: *App, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = ctx.theme();

        // The bar's window follows `recording` (declarative form). Opening and
        // closing it does not touch anything below.
        try ctx.mountOwned(fw.OverlayWindow, .{
            .open = &self.recording,
            .options = fw.WindowOptions{
                .content = fw.component.childOf(RecorderBar, &self.bar),
                .title = "Recording",
                .width = BAR_W,
                .height = BAR_H,
                .placement = .{ .anchored = .{ .at = .top_right, .margin = 16 } },
                .always_on_top = true,
                .resizable = false,
                // No caption at all: the full 56px belong to the content.
                .hide_app_bar = true,
                .window_corners = .round_small,
                .window_outline = t.border_color,
            },
        });

        const col = try b.openBox();
        try b.flexColumn(col);
        try b.alignItems(col, .center);
        try b.justifyContent(col, .center);
        try b.gap(col, 16);
        try b.width(col, 100, .percent);
        try b.height(col, 100, .percent);

        const h = try b.addText("Overlay window demo");
        try b.fontSize(h, 24);
        try b.fontBold(h, true);
        try b.textColorOf(h, t.text);

        const sub = try b.addText("Start recording: this window hides, a 460x56 bar floats on top.");
        try b.fontSize(sub, 14);
        try b.textColorOf(sub, t.text_secondary);

        // The state that proves the point: bump it, toggle the bar, come back — the
        // count is still here, because this tree was never unmounted.
        const count = try ctx.dynText(u32, &self.scope, &self.counter, "main-window state: {d}");
        try b.fontSize(count, 14);
        try b.fontMono(count, true);
        try b.textColorOf(count, t.accent);

        const row = try b.openBox();
        try b.flexRow(row);
        try b.gap(row, 10);

        try self.button(ctx, "Bump state", "bump", onBump, null);
        try self.button(ctx, "Start recording", "start", onStart, &self.hover_start);

        b.close(); // row
        b.close(); // col
    }

    fn button(
        self: *App,
        ctx: *BuildContext,
        label: []const u8,
        id: []const u8,
        comptime on_click: anytype,
        hover: ?*fw.signals.Signal(bool),
    ) !void {
        const b = ctx.builder;
        const t = b.theme;
        const btn = try b.openBox();
        try b.flexRow(btn);
        try b.alignItems(btn, .center);
        try b.padding(btn, 8, 16, 8, 16);
        try b.radius(btn, 6);
        const hot = if (hover) |hv| hv.get() else false;
        try b.backgroundOf(btn, if (hot) t.accent else t.surface_high);
        try b.clickable(btn, id);
        try b.hoverable(btn, id);
        if (ctx.router) |r| {
            try r.onNode(btn, .click, ctx.handler(self, on_click));
            if (hover) |hv| {
                const hh = ctx.signalSetter(hv);
                try r.onNode(btn, .mouse_enter, hh);
                try r.onNode(btn, .mouse_leave, hh);
            }
        }
        const txt = try b.addText(label);
        try b.fontSize(txt, 13);
        try b.fontBold(txt, true);
        try b.textColorOf(txt, t.text);
        b.close();
    }
};

/// Persistent capture driver: posts a tick to the UI thread on a fixed cadence.
/// The tick decides whether to advance, so this loop touches no signals itself.
fn captureLoop(app: *App) void {
    while (true) {
        sleepMs(250);
        fw.application.postTask(App.onTick, app);
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = App.init(allocator);
    defer app.deinit();
    app.bar.steps = &app.steps;
    app.bar.recording = &app.recording;

    // One daemon-style capture thread for the app's lifetime (process exit reaps it).
    _ = std.Thread.spawn(.{}, captureLoop, .{&app}) catch {};

    try fw.runApp(&app, &router, .{
        .title = "Celeris — overlay window",
        .width = 820,
        .height = 520,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
