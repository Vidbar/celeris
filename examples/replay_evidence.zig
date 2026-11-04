//! Replay & evidence — a DevTools-style trace-playback pane, in two tabs:
//!   * "Replay" — play back a recorded session over a filmstrip timeline, with
//!     per-frame evidence and a repo link.
//!   * "Steps" — a numbered execution trace you step through manually, with a
//!     breakpoint gutter and a highlighted current step (absorbed from the old
//!     steps_breakpoints.zig — both examples were "trace/playback" UIs, so they
//!     live together now instead of as two near-duplicate example apps).
//!
//! Playback (Replay tab) is driven by one persistent worker thread that posts a
//! tick to the UI thread every ~140ms (`application.postTask`, the thread-safe
//! marshal shown in thread_test). All state logic runs on the UI thread and lives
//! in signals read by `build` (reactive root), so advancing a frame — whether by
//! the player, a filmstrip click, the transport buttons, or the Steps tab's
//! toolbar — repaints the relevant tab.
//!
//! Compiled in CI (`zig build examples`) and run with `zig build replay_evidence`.

const std = @import("std");
const builtin = @import("builtin");
const celeris = @import("celeris");
const fw = celeris.framework;

// Win32 Sleep (kernel32 is already linked). Only referenced on Windows, so the
// decl is pruned on other targets.
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

/// Cross-platform millisecond sleep (`std.Thread.sleep` was removed in Zig 0.16).
fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        Sleep(ms);
    } else {
        const ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}

const BuildContext = fw.component.BuildContext;

const Frame = struct {
    event: []const u8,
    r: u8,
    g: u8,
    b: u8,
    ts_ms: u32,
    log: []const u8,
    file: []const u8,
    line: u32,
};

/// A recorded interaction trace — the "evidence" the replay scrubs through.
const frames = [_]Frame{
    .{ .event = "mount", .r = 60, .g = 130, .b = 246, .ts_ms = 0, .log = "WindowChrome mounted — 40 nodes", .file = "window_chrome.zig", .line = 98 },
    .{ .event = "hover close", .r = 232, .g = 176, .b = 74, .ts_ms = 320, .log = "hover_close.set(true)", .file = "window_chrome.zig", .line = 201 },
    .{ .event = "click close", .r = 232, .g = 92, .b = 92, .ts_ms = 540, .log = "on_close → window.close()", .file = "window_chrome.zig", .line = 93 },
    .{ .event = "restyle radius", .r = 168, .g = 120, .b = 221, .ts_ms = 910, .log = "radius.set(22)", .file = "restyle_inspector.zig", .line = 46 },
    .{ .event = "swatch green", .r = 74, .g = 194, .b = 122, .ts_ms = 1180, .log = "color_idx.set(1)", .file = "restyle_inspector.zig", .line = 92 },
    .{ .event = "measure pass", .r = 86, .g = 182, .b = 194, .ts_ms = 1330, .log = "hug chip — 1 line, w=47", .file = "flexbox.zig", .line = 95 },
    .{ .event = "run to bp", .r = 209, .g = 154, .b = 102, .ts_ms = 1600, .log = "current.set(3)", .file = "steps_breakpoints.zig", .line = 95 },
    .{ .event = "present", .r = 60, .g = 130, .b = 246, .ts_ms = 1740, .log = "swapchain present — 8.1ms", .file = "wgpu_backend.zig", .line = 1325 },
};

const COMMIT = "d3ffc65";

/// One filmstrip cell — a tinted thumbnail. Lifted state: clicking scrubs the
/// caller's `frame` signal here and pauses playback.
const FrameThumb = struct {
    index: i64,
    frame_data: Frame,
    frame: *fw.signals.Signal(i64),
    playing: *fw.signals.Signal(bool),

    fn onPick(self: *FrameThumb, _: fw.events.Event) void {
        self.playing.set(false); // manual scrub stops the player
        self.frame.set(self.index);
    }

    pub fn build(self: *FrameThumb, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const is_cur = self.frame.peek() == self.index;

        const cell = try b.openNodeKeyed(.box, null);
        try b.width(cell, 54, .px);
        try b.height(cell, 34, .px);
        try b.radius(cell, 4);
        try b.background(cell, self.frame_data.r, self.frame_data.g, self.frame_data.b);
        // The current frame gets a bright ring; the rest a faint outline.
        try b.borderWidth(cell, if (is_cur) 2 else 1);
        if (is_cur) {
            try b.borderColor(cell, 255, 255, 255);
        } else {
            try b.borderColorAlpha(cell, 0, 0, 0, 0.35);
        }
        var idbuf: [16]u8 = undefined;
        const aid = std.fmt.bufPrint(&idbuf, "thumb{d}", .{self.index}) catch "thumb";
        try b.clickable(cell, aid);
        if (ctx.router) |r| try r.onNode(cell, .click, ctx.handler(self, onPick));
        b.close();
    }

    pub fn deinit(_: *FrameThumb) void {}
};

// ── Steps tab (absorbed from steps_breakpoints.zig) ───────────────────────────

const Kind = enum { build, layout, paint };
const Step = struct { kind: Kind, desc: []const u8 };

const steps = [_]Step{
    .{ .kind = .build, .desc = "mount WindowChrome" },
    .{ .kind = .build, .desc = "addText(\"Celeris\") + fontBold" },
    .{ .kind = .build, .desc = "openNodeKeyed chip" },
    .{ .kind = .layout, .desc = "measure pass — hug chip" },
    .{ .kind = .layout, .desc = "place pass" },
    .{ .kind = .layout, .desc = "solve children extent" },
    .{ .kind = .paint, .desc = "upload glyph atlas" },
    .{ .kind = .paint, .desc = "present frame" },
};

fn kindColor(kind: Kind) struct { r: u8, g: u8, b: u8 } {
    return switch (kind) {
        .build => .{ .r = 168, .g = 120, .b = 221 }, // purple
        .layout => .{ .r = 209, .g = 154, .b = 102 }, // amber
        .paint => .{ .r = 86, .g = 182, .b = 194 }, // cyan
    };
}

fn kindLabel(kind: Kind) []const u8 {
    return switch (kind) {
        .build => "build",
        .layout => "layout",
        .paint => "paint",
    };
}

/// One trace row: breakpoint gutter · current caret · number · kind tag · desc.
/// Lifted state — clicking the gutter toggles the caller's `bp_bits` bit.
const StepRow = struct {
    index: i64,
    step: Step,
    current: *fw.signals.Signal(i64),
    bp_bits: *fw.signals.Signal(i64),

    fn bit(self: *StepRow) i64 {
        return @as(i64, 1) << @intCast(self.index);
    }
    fn onToggleBp(self: *StepRow, _: fw.events.Event) void {
        self.bp_bits.set(self.bp_bits.peek() ^ self.bit());
    }

    pub fn build(self: *StepRow, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;
        const is_cur = self.current.peek() == self.index;
        const has_bp = (self.bp_bits.peek() & self.bit()) != 0;

        const row = try b.openNodeKeyed(.box, null);
        try b.flexRow(row);
        try b.width(row, 100, .percent);
        try b.alignItems(row, .center);
        try b.padding(row, 5, 10, 5, 10);
        try b.gap(row, 8);
        if (is_cur) {
            try b.background(row, t.accent_container.r, t.accent_container.g, t.accent_container.b);
            try b.radius(row, 5);
        }

        // Breakpoint gutter: a clickable dot, solid red when set, hollow otherwise.
        const gutter = try b.openNodeKeyed(.box, null);
        try b.backgroundAlpha(gutter, 0, 0, 0, 0.0);
        try b.width(gutter, 18, .px);
        try b.alignItems(gutter, .center);
        try b.justifyContent(gutter, .center);
        const dot = try b.openNodeKeyed(.box, null);
        try b.width(dot, 12, .px);
        try b.height(dot, 12, .px);
        try b.radius(dot, 6);
        if (has_bp) {
            try b.background(dot, t.danger.r, t.danger.g, t.danger.b);
        } else {
            try b.backgroundAlpha(dot, 0, 0, 0, 0.0);
            try b.borderWidth(dot, 1);
            try b.borderColorAlpha(dot, t.text_secondary.r, t.text_secondary.g, t.text_secondary.b, 0.5);
        }
        var idbuf: [16]u8 = undefined;
        const aid = std.fmt.bufPrint(&idbuf, "bp{d}", .{self.index}) catch "bp";
        try b.clickable(dot, aid);
        if (ctx.router) |r| try r.onNode(dot, .click, ctx.handler(self, onToggleBp));
        b.close(); // dot
        b.close(); // gutter

        // Current-step caret.
        const caret = try b.addText(if (is_cur) "\u{25B6}" else " ");
        try b.fontSize(caret, 11);
        try b.width(caret, 10, .px);
        try b.textColor(caret, t.accent.r, t.accent.g, t.accent.b);

        // Step number — bold monospace, brightened on the current row.
        var numbuf: [8]u8 = undefined;
        const num = std.fmt.bufPrint(&numbuf, "{d}", .{self.index + 1}) catch "?";
        const num_txt = try b.addText(num);
        try b.fontSize(num_txt, 13);
        try b.fontMono(num_txt, true);
        try b.fontBold(num_txt, true);
        try b.width(num_txt, 16, .px);
        try b.textAlign(num_txt, .right);
        if (is_cur) {
            try b.textColor(num_txt, t.text.r, t.text.g, t.text.b);
        } else {
            try b.textColor(num_txt, t.text_disabled.r, t.text_disabled.g, t.text_disabled.b);
        }

        // Phase tag — monospace, colored by kind.
        const kc = kindColor(self.step.kind);
        const tag = try b.addText(kindLabel(self.step.kind));
        try b.fontSize(tag, 12);
        try b.fontMono(tag, true);
        try b.width(tag, 52, .px);
        try b.textColor(tag, kc.r, kc.g, kc.b);

        // Description — brightened on the current row.
        const desc = try b.addText(self.step.desc);
        try b.fontSize(desc, 13);
        try b.flexGrow(desc, 1);
        if (is_cur) {
            try b.textColor(desc, t.text.r, t.text.g, t.text.b);
        } else {
            try b.textColor(desc, t.text_secondary.r, t.text_secondary.g, t.text_secondary.b);
        }

        b.close(); // row
    }

    pub fn deinit(_: *StepRow) void {}
};

const StepsTab = struct {
    current: fw.signals.Signal(i64),
    bp_bits: fw.signals.Signal(i64),
    rows: [steps.len]StepRow = undefined,

    fn onBack(self: *StepsTab, _: fw.events.Event) void {
        self.current.set(@max(0, self.current.peek() - 1));
    }
    fn onStep(self: *StepsTab, _: fw.events.Event) void {
        self.current.set(@min(@as(i64, steps.len - 1), self.current.peek() + 1));
    }
    /// Run to the next breakpoint after the current step (or the last step).
    fn onRun(self: *StepsTab, _: fw.events.Event) void {
        const bits = self.bp_bits.peek();
        var i = self.current.peek() + 1;
        while (i < steps.len) : (i += 1) {
            if ((bits & (@as(i64, 1) << @intCast(i))) != 0) {
                self.current.set(i);
                return;
            }
        }
        self.current.set(@as(i64, steps.len - 1));
    }
    fn onReset(self: *StepsTab, _: fw.events.Event) void {
        self.current.set(0);
    }

    pub fn init(allocator: std.mem.Allocator) StepsTab {
        return .{
            .current = fw.signals.Signal(i64).init(allocator, 0),
            // Preset breakpoints on step 4 (measure) and step 7 (upload atlas).
            .bp_bits = fw.signals.Signal(i64).init(allocator, (@as(i64, 1) << 3) | (@as(i64, 1) << 6)),
        };
    }

    pub fn deinit(self: *StepsTab) void {
        self.current.deinit();
        self.bp_bits.deinit();
    }

    pub fn build(self: *StepsTab, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;
        _ = self.current.get(); // subscribe: re-run the build on any step change
        _ = self.bp_bits.get();

        const col = try b.openBox();
        try b.flexColumn(col);
        try b.width(col, 100, .percent);
        try b.height(col, 100, .percent);
        try b.padding(col, 16, 16, 16, 16);
        try b.gap(col, 10);
        try b.background(col, t.bg_surface.r, t.bg_surface.g, t.bg_surface.b);

        // Header + toolbar.
        const head = try b.openBox();
        try b.flexRow(head);
        try b.width(head, 100, .percent);
        try b.alignItems(head, .center);
        try b.gap(head, 8);
        const title = try b.addText("Execution");
        try b.fontSize(title, 15);
        try b.fontBold(title, true);
        try b.flexGrow(title, 1);
        try b.textColor(title, t.text.r, t.text.g, t.text.b);
        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "back", .label = "\u{25C0} Back", .on_click = ctx.handler(self, onBack) });
        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "step", .label = "Step \u{25B6}", .on_click = ctx.handler(self, onStep) });
        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "run", .label = "Run to bp", .on_click = ctx.handler(self, onRun) });
        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "reset", .label = "Reset", .on_click = ctx.handler(self, onReset) });
        b.close(); // head

        // The trace: one StepRow per step.
        const list = try b.openBox();
        try b.flexColumn(list);
        try b.width(list, 100, .percent);
        try b.flexGrow(list, 1);
        try b.gap(list, 2);
        for (&self.rows, 0..) |*r, i| {
            r.* = .{ .index = @intCast(i), .step = steps[i], .current = &self.current, .bp_bits = &self.bp_bits };
            try r.build(ctx);
        }
        b.close(); // list

        b.close(); // col
    }
};

const ReplayApp = struct {
    frame: fw.signals.Signal(i64),
    playing: fw.signals.Signal(bool),
    thumbs: [frames.len]FrameThumb = undefined,

    /// Posted from the worker thread every tick; advances one frame while playing
    /// and stops at the end. Runs on the UI thread, so touching signals is safe.
    fn onTick(self: *ReplayApp) void {
        if (!self.playing.peek()) return;
        const cur = self.frame.peek();
        if (cur < frames.len - 1) {
            self.frame.set(cur + 1);
        } else {
            self.playing.set(false); // reached the end
        }
    }

    fn onPlayPause(self: *ReplayApp, _: fw.events.Event) void {
        if (self.playing.peek()) {
            self.playing.set(false);
        } else {
            if (self.frame.peek() >= frames.len - 1) self.frame.set(0); // replay from start
            self.playing.set(true);
        }
    }
    fn onRestart(self: *ReplayApp, _: fw.events.Event) void {
        self.playing.set(false);
        self.frame.set(0);
    }
    fn onStepBack(self: *ReplayApp, _: fw.events.Event) void {
        self.playing.set(false);
        self.frame.set(@max(0, self.frame.peek() - 1));
    }

    pub fn build(self: *ReplayApp, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;
        const fi: usize = @intCast(std.math.clamp(self.frame.get(), 0, frames.len - 1));
        const is_playing = self.playing.get();
        const f = frames[fi];

        const col = try b.openBox();
        try b.flexColumn(col);
        try b.width(col, 100, .percent);
        try b.height(col, 100, .percent);
        try b.padding(col, 16, 16, 16, 16);
        try b.gap(col, 12);
        try b.background(col, t.bg_surface.r, t.bg_surface.g, t.bg_surface.b);

        // ── Transport bar ───────────────────────────────────────────────────
        const bar = try b.openBox();
        try b.flexRow(bar);
        try b.width(bar, 100, .percent);
        try b.alignItems(bar, .center);
        try b.gap(bar, 8);
        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "pp", .label = if (is_playing) "Pause" else "Play", .on_click = ctx.handler(self, onPlayPause) });
        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "back", .label = "\u{25C0}", .on_click = ctx.handler(self, onStepBack) });
        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "restart", .label = "Restart", .on_click = ctx.handler(self, onRestart) });

        var cbuf: [24]u8 = undefined;
        const counter = std.fmt.bufPrint(&cbuf, "frame {d} / {d}", .{ fi + 1, frames.len }) catch "";
        const ctxt = try b.addText(counter);
        try b.fontSize(ctxt, 13);
        try b.fontMono(ctxt, true);
        try b.flexGrow(ctxt, 1);
        try b.textAlign(ctxt, .right);
        try b.textColor(ctxt, t.text_secondary.r, t.text_secondary.g, t.text_secondary.b);
        b.close(); // bar

        // ── Filmstrip timeline (the scrubber) ───────────────────────────────
        const strip = try b.openBox();
        try b.flexRow(strip);
        try b.width(strip, 100, .percent);
        try b.gap(strip, 6);
        for (&self.thumbs, 0..) |*th, i| {
            th.* = .{ .index = @intCast(i), .frame_data = frames[i], .frame = &self.frame, .playing = &self.playing };
            try th.build(ctx);
        }
        b.close(); // strip

        // ── Evidence area ───────────────────────────────────────────────────
        const area = try b.openBox();
        try b.flexRow(area);
        try b.width(area, 100, .percent);
        try b.flexGrow(area, 1);
        try b.gap(area, 12);

        // Left: the "captured frame" preview (a tinted stand-in for a screenshot).
        const preview = try b.openBox();
        try b.flexColumn(preview);
        try b.flexGrow(preview, 1);
        try b.height(preview, 100, .percent);
        try b.alignItems(preview, .center);
        try b.justifyContent(preview, .center);
        try b.radius(preview, 8);
        try b.background(preview, f.r, f.g, f.b);
        const pv_label = try b.addText(f.event);
        try b.fontSize(pv_label, 20);
        try b.fontBold(pv_label, true);
        try b.textColor(pv_label, 255, 255, 255);
        b.close(); // preview

        // Right: the evidence card — event, timestamp, log, repo link.
        const card = try b.openBox();
        try b.flexColumn(card);
        try b.width(card, 250, .px);
        try b.height(card, 100, .percent);
        try b.gap(card, 10);
        try b.padding(card, 14, 14, 14, 14);
        try b.radius(card, 8);
        try b.background(card, t.bg_input.r, t.bg_input.g, t.bg_input.b);
        try b.borderWidth(card, 1);
        try b.borderColor(card, t.border_color.r, t.border_color.g, t.border_color.b);

        const ev_head = try b.addText("Evidence");
        try b.fontSize(ev_head, 14);
        try b.fontBold(ev_head, true);
        try b.textColor(ev_head, t.text.r, t.text.g, t.text.b);

        var tsbuf: [24]u8 = undefined;
        const ts = std.fmt.bufPrint(&tsbuf, "t = {d}ms", .{f.ts_ms}) catch "";
        const ts_txt = try b.addText(ts);
        try b.fontSize(ts_txt, 12);
        try b.fontMono(ts_txt, true);
        try b.textColor(ts_txt, t.text_secondary.r, t.text_secondary.g, t.text_secondary.b);

        // Console log line, monospace on a slightly inset surface.
        const logrow = try b.openBox();
        try b.width(logrow, 100, .percent);
        try b.padding(logrow, 6, 8, 6, 8);
        try b.radius(logrow, 5);
        try b.background(logrow, 30, 33, 39);
        const log_txt = try b.addText(f.log);
        try b.fontSize(log_txt, 12);
        try b.fontMono(log_txt, true);
        try b.textColor(log_txt, 152, 195, 121); // green, like console output
        b.close(); // logrow

        // Repo link: file:line @ commit — the "repo" leg of the pane.
        var repobuf: [64]u8 = undefined;
        const repo = std.fmt.bufPrint(&repobuf, "{s}:{d} @ {s}", .{ f.file, f.line, COMMIT }) catch "";
        const repo_txt = try b.addText(repo);
        try b.fontSize(repo_txt, 12);
        try b.fontMono(repo_txt, true);
        try b.textColor(repo_txt, t.accent.r, t.accent.g, t.accent.b);

        b.close(); // card
        b.close(); // area

        b.close(); // col
    }

    pub fn deinit(_: *ReplayApp) void {}
};

/// Persistent playback driver: posts a tick to the UI thread on a fixed cadence.
/// The tick decides whether to advance (only while playing), so this loop needs no
/// access to app state and never touches signals directly.
fn playbackLoop(app: *ReplayApp) void {
    while (true) {
        sleepMs(140);
        fw.application.postTask(ReplayApp.onTick, app);
    }
}

/// Root: hosts the two trace-playback tabs (framework-owned Tabs).
const TraceApp = struct {
    replay: ReplayApp,
    steps: StepsTab,
    tab_items: [2]fw.tabs.TabItem,
    active_tab: fw.signals.Signal(usize),

    pub fn build(self: *TraceApp, ctx: *BuildContext) !void {
        try ctx.mountOwned(fw.tabs.Tabs, .{
            .fill = true,
            .items = &self.tab_items,
            .active = &self.active_tab,
        });
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = TraceApp{
        .replay = .{
            .frame = fw.signals.Signal(i64).init(allocator, 0),
            .playing = fw.signals.Signal(bool).init(allocator, false),
        },
        .steps = StepsTab.init(allocator),
        .tab_items = undefined,
        .active_tab = fw.signals.Signal(usize).init(allocator, 0),
    };
    defer app.replay.frame.deinit();
    defer app.replay.playing.deinit();
    defer app.steps.deinit();
    defer app.active_tab.deinit();
    app.tab_items = .{
        .{ .title = "Replay", .child = fw.component.childOf(ReplayApp, &app.replay) },
        .{ .title = "Steps", .child = fw.component.childOf(StepsTab, &app.steps) },
    };

    // One daemon-style playback thread for the app's lifetime (process exit reaps it).
    _ = std.Thread.spawn(.{}, playbackLoop, .{&app.replay}) catch {};

    try fw.runApp(&app, &router, .{
        .title = "Celeris — Replay & Evidence",
        .width = 720,
        .height = 460,
        .app_bar_style = .custom,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
