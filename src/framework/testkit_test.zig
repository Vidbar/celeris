//! Proves testkit.zig's finders/interactions actually resolve through the real
//! widget/event pipeline, not a fiction of their own. Mounts a real `Button`
//! the same way `button.zig`'s own tests do, then drives it entirely through
//! `testkit.Query` instead of manual node-walking.
const std = @import("std");
const testing = std.testing;
const component = @import("component.zig");
const events = @import("events.zig");
const button = @import("button.zig");
const testkit = @import("testkit.zig");

test "testkit.Query finds a mounted Button by role and label, and clicks it for real" {
    var h = testkit.Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();

    var b = component.UIBuilder.init(&h.registry, &h.store);
    var ctx = component.BuildContext{ .builder = &b, .router = &h.router, .mounts = &h.mounts };
    _ = try b.openNodeKeyed(.box, null); // root

    const Sink = struct {
        var clicks: u32 = 0;
        fn onClick(_: ?*anyopaque, _: events.Event) void {
            clicks += 1;
        }
    };
    Sink.clicks = 0;

    try ctx.mountOwned(button.Button, .{
        .label = "Save",
        .on_click = events.Handler{ .ptr = null, .call = Sink.onClick },
    });
    b.close();

    var q = testkit.Query.init(&h);

    // Same node, found two different ways — role is the ARIA-style contract,
    // label is what a user (or a screen reader) actually sees.
    const by_role = q.byRole("button") orelse return error.ButtonNotFound;
    const by_label = q.byLabel("Save") orelse return error.ButtonNotFound;
    try testing.expectEqual(by_role, by_label);

    q.click(by_role);
    try testing.expectEqual(@as(u32, 1), Sink.clicks);
}

test "testkit.Query.expectVisible catches a hugged box that never got measured" {
    // Mirrors the exact TooltipHost/ToastHost class of bug test_support.zig's
    // Harness.solve() doc comment warns about: a node can have every prop set
    // and still be 0x0 on screen. expectVisible must fail for it.
    var h = testkit.Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();

    var b = component.UIBuilder.init(&h.registry, &h.store);
    const root = try b.openBox();
    b.close();

    // No solve() call: the node never gets measured, so its geometry stays
    // the zero-value default.
    var q = testkit.Query.init(&h);
    try testing.expectError(testkit.Query.AssertError.NodeNotVisible, q.expectVisible(root));
}

const signals = @import("../core/signals.zig");
const props = @import("../core/properties.zig");
const text_mod = @import("../render/text.zig");
const test_support = @import("test_support.zig");

test "text styles: builder writes, testkit reads back, decorations never relayout" {
    var h = testkit.Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();

    var b = component.UIBuilder.init(&h.registry, &h.store);
    const root = try b.openBox();
    const t = try b.addText("ls -la");
    try b.fontMono(t, true);
    try b.fontItalic(t, true);
    try b.fontBold(t, true);
    try b.textDecoration(t, .{ .underline = .wavy, .strikethrough = true });
    try b.decorationColor(t, 255, 0, 0);
    try b.textFaint(t, true);
    b.close();
    _ = root;

    var q = testkit.Query.init(&h);
    const s = q.textStyle(t);
    try testing.expectEqual(text_mod.FontRole.mono_bold_italic, s.role);
    try testing.expectEqual(text_mod.UnderlineStyle.wavy, s.decoration.underline);
    try testing.expect(s.decoration.strikethrough and !s.decoration.overline);
    try testing.expectEqual([4]f32{ 1, 0, 0, 1 }, s.decoration_color.?);
    try testing.expect(s.faint);

    // Turning italic off keeps family and weight.
    try b.fontItalic(t, false);
    try testing.expectEqual(text_mod.FontRole.mono_bold, q.textStyle(t).role);

    // Paint-only keys: render-dirty, never layout-dirty.
    inline for (.{
        .{ props.StyleKey.text_decoration, props.PropValue{ .number = (text_mod.TextDecoration{ .overline = true }).toNumber() } },
        .{ props.StyleKey.text_decoration_color, props.PropValue{ .color = .{ .r = 0, .g = 1, .b = 0, .a = 1 } } },
        .{ props.StyleKey.text_faint, props.PropValue{ .boolean = false } },
    }) |kv| {
        const n = h.registry.getNode(t).?;
        n.layout_dirty = false;
        n.render_dirty = false;
        try h.store.setStyle(t, kv[0], kv[1]);
        try testing.expect(n.render_dirty);
        try testing.expect(!n.layout_dirty);
    }
    // ...while the face is a shaping input and does relayout.
    const n = h.registry.getNode(t).?;
    n.layout_dirty = false;
    try b.fontItalic(t, true);
    try testing.expect(n.layout_dirty);
}

test "text styles: bindStyle drives every style after the build" {
    var h = testkit.Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();
    const a = testing.allocator;

    var b = component.UIBuilder.init(&h.registry, &h.store);
    _ = try b.openBox();
    const t = try b.addText("run");
    b.close();

    var role = signals.Signal(props.PropValue).init(a, .{ .number = 0 });
    defer role.deinit();
    var deco = signals.Signal(props.PropValue).init(a, .{ .number = 0 });
    defer deco.deinit();
    var deco_col = signals.Signal(props.PropValue).init(a, .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 1 } });
    defer deco_col.deinit();
    var faint = signals.Signal(props.PropValue).init(a, .{ .boolean = false });
    defer faint.deinit();

    var scope = signals.Scope.init(a);
    defer scope.deinit();
    try signals.bindStyle(&scope, &h.store, t, .font_role, &role);
    try signals.bindStyle(&scope, &h.store, t, .text_decoration, &deco);
    try signals.bindStyle(&scope, &h.store, t, .text_decoration_color, &deco_col);
    try signals.bindStyle(&scope, &h.store, t, .text_faint, &faint);

    // One SGR update: 1;2;3;4:3;9;53;58 — bold, faint, italic, curly, strike, overline, red line.
    role.set(.{ .number = @floatFromInt(text_mod.FontRole.bold_italic.bits()) });
    deco.set(.{ .number = (text_mod.TextDecoration{ .underline = .wavy, .strikethrough = true, .overline = true }).toNumber() });
    deco_col.set(.{ .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } });
    faint.set(.{ .boolean = true });

    const s = testkit.textStyle(&h.store, t);
    try testing.expect(s.role.isBold() and s.role.isItalic() and !s.role.isMono());
    try testing.expectEqual(text_mod.TextDecoration{ .underline = .wavy, .strikethrough = true, .overline = true }, s.decoration);
    try testing.expectEqual(@as(f32, 1), s.decoration_color.?[0]);
    try testing.expect(s.faint);

    // SGR 0: everything back off.
    role.set(.{ .number = 0 });
    deco.set(.{ .number = 0 });
    faint.set(.{ .boolean = false });
    const r = testkit.textStyle(&h.store, t);
    try testing.expectEqual(text_mod.FontRole.default, r.role);
    try testing.expect(r.decoration.isNone());
    try testing.expect(!r.faint);
}

test "text styles: measurement follows the italic face; lines never change it" {
    const a = testing.allocator;
    const primary = test_support.loadSystemFont(a) catch return error.SkipZigTest;
    defer a.free(primary);
    // Any second, differently-proportioned face stands in for an italic cut.
    const other = blk: {
        var threaded = std.Io.Threaded.init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();
        for ([_][]const u8{ "C:/Windows/Fonts/consola.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf" }) |p| {
            if (std.Io.Dir.cwd().readFileAlloc(io, p, a, .unlimited)) |d| break :blk d else |_| {}
        }
        return error.SkipZigTest;
    };
    defer a.free(other);
    var atlas = try text_mod.FontAtlas.init(a, primary, 16);
    defer atlas.deinit();

    const W = struct {
        fn of(at: *text_mod.FontAtlas, setup: *const fn (*component.UIBuilder, @import("../core/registry.zig").NodeId) anyerror!void) !f32 {
            var h = testkit.Harness.init(testing.allocator);
            defer h.deinit();
            h.wire();
            var b = component.UIBuilder.init(&h.registry, &h.store);
            const root = try b.openBox();
            try b.flexRow(root);
            const t = try b.addText("Hello world");
            try setup(&b, t);
            b.close();
            h.solveWith(at, root, 800, 200);
            return h.geom(t).width;
        }
    };
    const plain = try W.of(&atlas, struct {
        fn f(_: *component.UIBuilder, _: @import("../core/registry.zig").NodeId) anyerror!void {}
    }.f);
    const decorated = try W.of(&atlas, struct {
        fn f(b: *component.UIBuilder, t: @import("../core/registry.zig").NodeId) anyerror!void {
            try b.textDecoration(t, .{ .underline = .double, .strikethrough = true, .overline = true });
            try b.textFaint(t, true);
        }
    }.f);
    const italic = struct {
        fn f(b: *component.UIBuilder, t: @import("../core/registry.zig").NodeId) anyerror!void {
            try b.fontItalic(t, true);
        }
    }.f;
    // Synthetic italic: the upright face's advances — same width.
    const synthetic = try W.of(&atlas, italic);
    try atlas.addRoleFont(.italic, other);
    const real = try W.of(&atlas, italic);

    try testing.expectEqual(plain, decorated);
    try testing.expectEqual(plain, synthetic);
    try testing.expect(real != plain);
}
