//! Alt chords and programmatic focus, side by side — run with `zig build alt_focus`.
//!
//! Two focusable panes log every key_down they receive:
//!   * "Captures Alt" has `b.capturesAltKeys`: on Windows, Alt+B / Alt+F /
//!     Alt+Backspace / Alt+Left arrive here with `alt` set.
//!   * "Plain" does not: on Windows Alt chords go to the system instead (only F10
//!     arrives). On Linux both panes receive them.
//! Alt+F4 must still close the window from either pane, and Alt+Space must still
//! open the window menu.
//!
//! The capturing pane takes focus at startup with `ctx.requestFocus` (it is built
//! in that same pass, so the focus lands after the first layout). The two buttons
//! move focus with a stored `FocusRequester`.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;
const component = fw.component;

const LOG_LINES = 8;

const Pane = struct {
    title: []const u8,
    key: []const u8,
    captures_alt: bool,
    rev: fw.signals.Signal(u32),
    lines: [LOG_LINES][64]u8 = undefined,
    lens: [LOG_LINES]usize = @splat(0),
    count: usize = 0,
    node: component.NodeId = 0,
    focused: bool = false,

    fn log(self: *Pane, comptime fmt: []const u8, args: anytype) void {
        const slot = self.count % LOG_LINES;
        const s = std.fmt.bufPrint(&self.lines[slot], fmt, args) catch self.lines[slot][0..0];
        self.lens[slot] = s.len;
        self.count += 1;
        self.rev.set(self.rev.get() +% 1);
    }

    fn onKey(self: *Pane, ev: fw.events.Event) void {
        var name_buf: [16]u8 = undefined;
        const name: []const u8 = if (ev.key()) |k| (std.enums.tagName(fw.events.Key, k) orelse
            (std.fmt.bufPrint(&name_buf, "0x{x}", .{k.code()}) catch "?")) else "?";
        self.log("{s}{s}{s}{s}", .{
            if (ev.ctrl) "Ctrl+" else "",
            if (ev.alt) "Alt+" else "",
            if (ev.shift) "Shift+" else "",
            name,
        });
    }
    fn onFocus(self: *Pane, ev: fw.events.Event) void {
        _ = ev;
        self.focused = true;
        self.rev.set(self.rev.get() +% 1);
    }
    fn onBlur(self: *Pane, ev: fw.events.Event) void {
        _ = ev;
        self.focused = false;
        self.rev.set(self.rev.get() +% 1);
    }

    pub fn build(self: *Pane, ctx: *component.BuildContext) !void {
        const b = ctx.builder;
        _ = self.rev.get(); // re-run the reactive root on every logged key
        self.node = try ctx.boxNode(.{
            .key = self.key,
            .grow = 1,
            .height = component.pct(100),
            .direction = .column,
            .gap = 4,
            .padding = component.EdgeInsets{ .l = 12, .t = 12, .r = 12, .b = 12 },
            .border_width = 1,
            .radius = 6,
            .focusable = true,
            .on_key = ctx.handler(self, onKey),
            .on_focus = ctx.handler(self, onFocus),
            .on_blur = ctx.handler(self, onBlur),
        }, .{PaneBody{ .pane = self }});
        if (self.captures_alt) try b.capturesAltKeys(self.node);
    }
};

const PaneBody = struct {
    pane: *Pane,
    pub fn build(self: PaneBody, ctx: *component.BuildContext) !void {
        const p = self.pane;
        const b = ctx.builder;
        var head: [96]u8 = undefined;
        const h = try std.fmt.bufPrint(&head, "{s}{s}", .{ p.title, if (p.focused) "  (focused)" else "" });
        const t = try ctx.text(h);
        try b.fontSize(t, 16);
        try b.fontBold(t, true);
        if (p.count == 0) _ = try ctx.text("Press keys here.");
        // Newest last.
        const n = @min(p.count, LOG_LINES);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const slot = (p.count - n + i) % LOG_LINES;
            const line = try ctx.text(p.lines[slot][0..p.lens[slot]]);
            try b.fontMono(line, true);
        }
    }
};

const App = struct {
    alt: Pane,
    plain: Pane,
    focuser: component.FocusRequester = .{ .hooks = null },
    started: bool = false,

    fn focusAlt(self: *App, ev: fw.events.Event) void {
        _ = ev;
        _ = self.focuser.focus(self.alt.node);
    }
    fn focusPlain(self: *App, ev: fw.events.Event) void {
        _ = ev;
        _ = self.focuser.focus(self.plain.node);
    }

    pub fn build(self: *App, ctx: *component.BuildContext) !void {
        const b = ctx.builder;
        const col = try b.openBox();
        try b.flexColumn(col);
        try b.gap(col, 12);
        try b.padding(col, 16, 16, 16, 16);
        try b.width(col, 100, .percent);
        try b.height(col, 100, .percent);

        _ = try ctx.text("Try Alt+B, Alt+F, Alt+Backspace, Alt+Left in each pane. Alt+F4 / Alt+Space stay with the system.");

        const buttons = try b.openBox();
        try b.flexRow(buttons);
        try b.gap(buttons, 8);
        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "focus-alt", .label = "Focus \"Captures Alt\"", .on_click = ctx.handler(self, focusAlt) });
        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "focus-plain", .label = "Focus \"Plain\"", .on_click = ctx.handler(self, focusPlain) });
        b.close();

        const row = try b.openBox();
        try b.flexRow(row);
        try b.gap(row, 12);
        try b.width(row, 100, .percent);
        try b.flexGrow(row, 1);
        try ctx.mount(&self.alt);
        try ctx.mount(&self.plain);
        b.close();

        b.close();

        self.focuser = ctx.focusRequester();
        if (!self.started) {
            self.started = true;
            _ = ctx.requestFocus(self.alt.node); // built this pass → lands after layout
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = App{
        .alt = .{ .title = "Captures Alt", .key = "pane-alt", .captures_alt = true, .rev = fw.signals.Signal(u32).init(allocator, 0) },
        .plain = .{ .title = "Plain", .key = "pane-plain", .captures_alt = false, .rev = fw.signals.Signal(u32).init(allocator, 0) },
    };
    defer app.alt.rev.deinit();
    defer app.plain.rev.deinit();

    try fw.runApp(&app, &router, .{
        .title = "Alt chords and focus",
        .width = 820,
        .height = 420,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
