//! Text styles a terminal's SGR sequences ask for — italic (real and synthetic),
//! every underline style, underline color, strikethrough, overline, faint — at
//! three sizes, proportional and mono, on a dark page. Run with
//! `zig build text_styles`.
//!
//! By eye: lines span exactly the glyphs of each run; underlines sit under the
//! baseline (descenders cross them), strikethroughs through the x-height, the
//! overline at the ascent; the wavy line is smooth; faint text is half as bright.
//! Synthetic italic (proportional rows, when the host has no italic cut) leans
//! about 14°.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;
const Deco = fw.text.TextDecoration;

const App = struct {
    fn run(b: *fw.builder.UIBuilder, s: []const u8, size: f32, mono: bool, f: struct {
        bold: bool = false,
        italic: bool = false,
        faint: bool = false,
        deco: Deco = .{},
        line_rgb: ?[3]u8 = null,
    }) !void {
        const t = try b.addText(s);
        try b.fontSize(t, size);
        try b.textColor(t, 0xE6, 0xE6, 0xE6);
        try b.fontMono(t, mono);
        try b.fontBold(t, f.bold);
        try b.fontItalic(t, f.italic);
        try b.textFaint(t, f.faint);
        try b.textDecoration(t, f.deco);
        if (f.line_rgb) |c| try b.decorationColor(t, c[0], c[1], c[2]);
    }

    fn row(b: *fw.builder.UIBuilder, size: f32, mono: bool) !void {
        const r = try b.openBox();
        try b.flexRow(r);
        try b.gap(r, 14);
        try b.alignItems(r, .center);
        try run(b, "plain", size, mono, .{});
        try run(b, "italic", size, mono, .{ .italic = true });
        try run(b, "bold italic", size, mono, .{ .bold = true, .italic = true });
        try run(b, "single gjpq", size, mono, .{ .deco = .{ .underline = .single } });
        try run(b, "double", size, mono, .{ .deco = .{ .underline = .double } });
        try run(b, "wavy error", size, mono, .{ .deco = .{ .underline = .wavy }, .line_rgb = .{ 0xF1, 0x4C, 0x4C } });
        try run(b, "dotted", size, mono, .{ .deco = .{ .underline = .dotted } });
        try run(b, "dashed", size, mono, .{ .deco = .{ .underline = .dashed } });
        try run(b, "strike", size, mono, .{ .deco = .{ .strikethrough = true } });
        try run(b, "overline", size, mono, .{ .deco = .{ .overline = true } });
        try run(b, "faint", size, mono, .{ .faint = true });
        try run(b, "faint bold", size, mono, .{ .faint = true, .bold = true });
        try run(b, "all", size, mono, .{ .italic = true, .deco = .{ .underline = .wavy, .strikethrough = true, .overline = true }, .line_rgb = .{ 0x4F, 0xC1, 0xFF } });
        b.close();
    }

    pub fn build(self: *App, ctx: *fw.component.BuildContext) !void {
        _ = self;
        const b = ctx.builder;
        const page = try b.openBox();
        try b.width(page, 100, .percent);
        try b.height(page, 100, .percent);
        try b.background(page, 0x1E, 0x1E, 0x1E);
        try b.flexColumn(page);
        try b.gap(page, 18);
        try b.padding(page, 24, 24, 24, 24);
        for ([_]f32{ 13, 16, 24 }) |size| {
            try row(b, size, false);
            try row(b, size, true);
        }
        b.close();
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();
    var app = App{};
    try fw.runApp(&app, &router, .{
        .title = "Celeris Text Styles",
        .width = 1500,
        .height = 520,
    });
}
