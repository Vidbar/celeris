//! Restyle inspector — a DevTools-style restyle pane: an editable list of a
//! selected element's style properties that restyle a live preview as you change
//! them (the Chrome DevTools "Styles" pane, in miniature).
//!
//! How the live edit works: the app owns one Signal per editable property and
//! *reads* them in `build` (reactive root), so mutating any property re-runs
//! the build and the preview box repaints with the new style. The controls are two
//! small lifted-state widgets that mutate the app's signals:
//!   * `Stepper` — a labelled −/＋ numeric row bound to a `*Signal(f32)`.
//!   * `Swatch`  — a color chip bound to a shared `*Signal(i64)` selection index.
//! Neither owns state; the app does. This is the lifted-state convention the other
//! widgets follow (caller-owned `*Signal(T)` props).
//!
//! Compiled in CI (`zig build examples`) and run with `zig build restyle_inspector`.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

const BuildContext = fw.component.BuildContext;

/// The background palette the swatches pick from (name shown in the inspector).
const Swatchable = struct { name: []const u8, r: u8, g: u8, b: u8 };
const palette = [_]Swatchable{
    .{ .name = "blue", .r = 60, .g = 130, .b = 246 },
    .{ .name = "green", .r = 74, .g = 194, .b = 122 },
    .{ .name = "amber", .r = 232, .g = 176, .b = 74 },
    .{ .name = "red", .r = 232, .g = 92, .b = 92 },
    .{ .name = "purple", .r = 168, .g = 120, .b = 221 },
};

/// A labelled numeric row with −/＋ steppers, bound to a caller-owned signal.
/// Lifted state: the app owns `value`; the stepper only mutates it.
const Stepper = struct {
    label: []const u8,
    value: *fw.signals.Signal(f32),
    step: f32 = 1,
    min: f32 = 0,
    max: f32 = 200,

    fn onDec(self: *Stepper, _: fw.events.Event) void {
        self.value.set(std.math.clamp(self.value.peek() - self.step, self.min, self.max));
    }
    fn onInc(self: *Stepper, _: fw.events.Event) void {
        self.value.set(std.math.clamp(self.value.peek() + self.step, self.min, self.max));
    }

    pub fn build(self: *Stepper, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;

        const row = try b.openBox();
        try b.flexRow(row);
        try b.width(row, 100, .percent);
        try b.alignItems(row, .center);
        try b.gap(row, 8);

        // Property name (mono, like a CSS property), fixed column.
        const name = try b.addText(self.label);
        try b.fontSize(name, 13);
        try b.fontMono(name, true);
        try b.width(name, 46, .percent);
        try b.textColor(name, t.text_secondary.r, t.text_secondary.g, t.text_secondary.b);

        // Current value (mono), right up against the steppers.
        var buf: [16]u8 = undefined;
        const val = std.fmt.bufPrint(&buf, "{d:.0}px", .{self.value.peek()}) catch "?";
        const val_txt = try b.addText(val);
        try b.fontSize(val_txt, 13);
        try b.fontMono(val_txt, true);
        try b.flexGrow(val_txt, 1);
        try b.textColor(val_txt, t.text.r, t.text.g, t.text.b);

        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "dec", .label = "−", .on_click = ctx.handler(self, onDec) });
        try ctx.mountOwned(fw.button.Button, .{ .hug = true, .key = "inc", .label = "+", .on_click = ctx.handler(self, onInc) });

        b.close(); // row
    }

    pub fn deinit(_: *Stepper) void {}
};

/// A color chip bound to a shared selection index. Lifted state: clicking sets the
/// app's `selected` signal to this swatch's `index`; the selected one shows a ring.
const Swatch = struct {
    index: i64,
    color: Swatchable,
    selected: *fw.signals.Signal(i64),

    fn onPick(self: *Swatch, _: fw.events.Event) void {
        self.selected.set(self.index);
    }

    pub fn build(self: *Swatch, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const is_sel = self.selected.peek() == self.index;

        const chip = try b.openNodeKeyed(.box, null);
        try b.width(chip, 26, .px);
        try b.height(chip, 26, .px);
        try b.radius(chip, 6);
        try b.background(chip, self.color.r, self.color.g, self.color.b);
        // Selected swatch gets a light ring; others a subtle dark outline.
        try b.borderWidth(chip, if (is_sel) 2 else 1);
        if (is_sel) {
            try b.borderColor(chip, 255, 255, 255);
        } else {
            try b.borderColorAlpha(chip, 0, 0, 0, 0.35);
        }
        var idbuf: [24]u8 = undefined;
        const aid = std.fmt.bufPrint(&idbuf, "swatch{d}", .{self.index}) catch "swatch";
        try b.clickable(chip, aid);
        if (ctx.router) |r| try r.onNode(chip, .click, ctx.handler(self, onPick));
        b.close();
    }

    pub fn deinit(_: *Swatch) void {}
};

const RestyleApp = struct {
    radius: fw.signals.Signal(f32),
    border_w: fw.signals.Signal(f32),
    padding: fw.signals.Signal(f32),
    color_idx: fw.signals.Signal(i64),

    // Reusable rows, re-created each build with fresh pointers into our signals.
    steppers: [3]Stepper = undefined,
    swatches: [palette.len]Swatch = undefined,

    pub fn build(self: *RestyleApp, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;

        // Read the signals here (reactive root): any edit re-runs build → the
        // preview below repaints with the new style.
        const radius = self.radius.get();
        const border_w = self.border_w.get();
        const pad = self.padding.get();
        const ci: usize = @intCast(std.math.clamp(self.color_idx.get(), 0, palette.len - 1));
        const col = palette[ci];

        const root = try b.openBox();
        try b.flexRow(root);
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);

        // ── Left: live preview stage ────────────────────────────────────────
        const stage = try b.openBox();
        try b.flexColumn(stage);
        try b.flexGrow(stage, 1);
        try b.height(stage, 100, .percent);
        try b.alignItems(stage, .center);
        try b.justifyContent(stage, .center);
        try b.background(stage, t.bg_base.r, t.bg_base.g, t.bg_base.b);

        const preview = try b.openBox();
        try b.width(preview, 220, .px);
        try b.height(preview, 130, .px);
        try b.alignItems(preview, .center);
        try b.justifyContent(preview, .center);
        try b.background(preview, col.r, col.g, col.b);
        try b.radius(preview, radius);
        try b.borderWidth(preview, border_w);
        try b.borderColor(preview, 255, 255, 255);
        try b.padding(preview, pad, pad, pad, pad);
        const plabel = try b.addText("Preview");
        try b.fontSize(plabel, 16);
        try b.fontBold(plabel, true);
        try b.textColor(plabel, 255, 255, 255);
        b.close(); // preview
        b.close(); // stage

        // ── Right: the inspector panel — a grid of Material cards, one per
        // property group, so the "Styles" pane reads as a set of cards rather
        // than a single stacked list. ─────────────────────────────────────────
        const panel = try b.openBox();
        try b.flexColumn(panel);
        try b.width(panel, 260, .px);
        try b.height(panel, 100, .percent);
        try b.padding(panel, 16, 16, 16, 16);
        try b.gap(panel, 12);
        try b.background(panel, t.bg_surface.r, t.bg_surface.g, t.bg_surface.b);

        const heading = try b.addText("Styles");
        try b.fontSize(heading, 15);
        try b.fontBold(heading, true);
        try b.textColor(heading, t.text.r, t.text.g, t.text.b);

        // Card: dimensions (the three numeric stepper rows).
        const dims_card = try b.openBox();
        try b.flexColumn(dims_card);
        try b.width(dims_card, 100, .percent);
        try b.gap(dims_card, 8);
        try b.padding(dims_card, 12, 12, 12, 12);
        try b.backgroundOf(dims_card, t.surface_low);
        try b.borderColorOf(dims_card, t.border_color);
        try b.borderWidth(dims_card, 1);
        try b.radius(dims_card, t.radius_base * 2);

        self.steppers[0] = .{ .label = "radius", .value = &self.radius, .step = 2, .max = 65 };
        self.steppers[1] = .{ .label = "border", .value = &self.border_w, .step = 1, .max = 16 };
        self.steppers[2] = .{ .label = "padding", .value = &self.padding, .step = 2, .max = 48 };
        for (&self.steppers) |*s| try s.build(ctx);

        b.close(); // dims_card

        // Card: background swatches.
        const bg_card = try b.openBox();
        try b.flexColumn(bg_card);
        try b.width(bg_card, 100, .percent);
        try b.gap(bg_card, 8);
        try b.padding(bg_card, 12, 12, 12, 12);
        try b.backgroundOf(bg_card, t.surface_low);
        try b.borderColorOf(bg_card, t.border_color);
        try b.borderWidth(bg_card, 1);
        try b.radius(bg_card, t.radius_base * 2);

        const bg_label = try b.addText("background");
        try b.fontSize(bg_label, 13);
        try b.fontMono(bg_label, true);
        try b.textColor(bg_label, t.text_secondary.r, t.text_secondary.g, t.text_secondary.b);

        const swrow = try b.openBox();
        try b.flexRow(swrow);
        try b.flexWrap(swrow, true);
        try b.gap(swrow, 8);
        for (&self.swatches, 0..) |*s, i| {
            s.* = .{ .index = @intCast(i), .color = palette[i], .selected = &self.color_idx };
            try s.build(ctx);
        }
        b.close(); // swrow

        b.close(); // bg_card

        b.close(); // panel
        b.close(); // root
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = RestyleApp{
        .radius = fw.signals.Signal(f32).init(allocator, 12),
        .border_w = fw.signals.Signal(f32).init(allocator, 2),
        .padding = fw.signals.Signal(f32).init(allocator, 8),
        .color_idx = fw.signals.Signal(i64).init(allocator, 0),
    };
    defer app.radius.deinit();
    defer app.border_w.deinit();
    defer app.padding.deinit();
    defer app.color_idx.deinit();

    try fw.runApp(&app, &router, .{
        .title = "Celeris — Restyle Inspector",
        .width = 720,
        .height = 460,
        .app_bar_style = .custom,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
