//! Rounded clipping: `overflowHidden` + `radius` clips the whole subtree to the
//! rounded padding box — backgrounds, text, images and paths — and nested clips
//! intersect.
//!
//! Run with `zig build rounded_clip`. `scripts/sample_rounded_clip.ps1` samples the
//! corner pixels and fails if a child paints outside its rounded parent. By eye:
//! every card's corners show the dark page background (card 2: its white border),
//! never the child's color.
//!
//!   1. radius 24 + overflowHidden, a red child filling it, yellow text in the corner
//!   2. the same with a 4px white border: the child clips to the border's inner edge
//!   3. radius 24 around a square overflowHidden box around a blue child: the
//!      outer rounding still clips the grandchild (nested clips intersect)

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

/// Page background (#202020) — what a clipped corner must show.
const PAGE = .{ 0x20, 0x20, 0x20 };

const App = struct {
    fn card(b: *fw.builder.UIBuilder, left: f32, top: f32) !fw.builder.NodeId {
        const c = try b.openBox();
        try b.positionAbsolute(c, left, top);
        try b.width(c, 240, .px);
        try b.height(c, 160, .px);
        try b.radius(c, 24);
        try b.overflowHidden(c);
        try b.background(c, 0x30, 0x30, 0x30);
        return c;
    }

    fn fill(b: *fw.builder.UIBuilder, r: u8, g: u8, bl: u8) !void {
        const f = try b.openBox();
        try b.width(f, 100, .percent);
        try b.height(f, 100, .percent);
        try b.background(f, r, g, bl);
        b.close();
    }

    pub fn build(self: *App, ctx: *fw.component.BuildContext) !void {
        _ = self;
        const b = ctx.builder;
        const page = try b.openBox();
        try b.width(page, 100, .percent);
        try b.height(page, 100, .percent);
        try b.background(page, PAGE[0], PAGE[1], PAGE[2]);

        // 1. Plain rounded clip, with text crossing the corner.
        _ = try card(b, 40, 40);
        try fill(b, 0xE0, 0x3C, 0x3C);
        const t = try b.addText("WWWW");
        try b.positionAbsolute(t, -6, -10);
        try b.fontSize(t, 40);
        try b.textColor(t, 0xFF, 0xD7, 0x00);
        b.close();

        // 2. Bordered: children clip to the inner edge of the 4px border.
        const c2 = try card(b, 320, 40);
        try b.borderWidth(c2, 4);
        try b.borderColor(c2, 0xFF, 0xFF, 0xFF);
        try fill(b, 0x3C, 0xC0, 0x5A);
        b.close();

        // 3. Nested: rounded card > square overflowHidden box > blue child.
        _ = try card(b, 40, 240);
        const inner = try b.openBox();
        try b.width(inner, 100, .percent);
        try b.height(inner, 100, .percent);
        try b.overflowHidden(inner);
        try fill(b, 0x3C, 0x78, 0xE0);
        b.close();
        b.close();

        b.close(); // page
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();
    var app = App{};
    try fw.runApp(&app, &router, .{
        .title = "Celeris Rounded Clip",
        .width = 620,
        .height = 460,
    });
}
