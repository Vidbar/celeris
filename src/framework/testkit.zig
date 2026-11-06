//! Finder + interaction helpers for widget tests, layered on top of
//! `test_support.Harness`. Every operation here resolves through the exact same
//! primitives production code uses — `core/accessibility.zig`'s role/name/
//! visibility logic and `EventRouter.route` — so a passing assertion here is
//! never a fiction the real engine doesn't share. Nothing in this file is a
//! parallel "test mode" path: no widget or core module imports it, and no
//! production code branches on its presence (mirrors the reasoning in
//! `test_support.zig`'s own header comment).
//!
//! Modeled after Compose's `ComposeTestRule` finder API, adapted to the fact
//! that Zig tests run in-process with zero language boundary: there is no need
//! to round-trip through a serialized semantics tree (the JSON the C API hands
//! external hosts) when the test binary can just read the registry/store
//! directly, the same way `core/accessibility.zig` does internally.
const std = @import("std");
const reg = @import("../core/registry.zig");
const props = @import("../core/properties.zig");
const a11y = @import("../core/accessibility.zig");
const events = @import("events.zig");
const test_support = @import("test_support.zig");

pub const Harness = test_support.Harness;

/// Finds nodes and drives real events against a `Harness`. Construct with a
/// pointer to an already-`wire()`d harness; the query borrows it, it owns
/// nothing itself.
pub const Query = struct {
    h: *Harness,

    pub fn init(h: *Harness) Query {
        return .{ .h = h };
    }

    /// First live node whose `.clickable` or `.focusable` action id equals
    /// `id` — the same id production dispatch and UIA's `ActionChannel`
    /// target by (see `withNodeSimple`'s callers and `b.clickable(...)` at
    /// build time). This is the primary finder for interactive elements.
    pub fn byTestId(self: Query, id: []const u8) ?reg.NodeId {
        for (self.h.registry.nodes.items) |node| {
            if (!node.alive) continue;
            if (matchesModifierId(self.h, node.id, .clickable, id)) return node.id;
            if (matchesModifierId(self.h, node.id, .focusable, id)) return node.id;
        }
        return null;
    }

    /// First live control element whose ARIA-style role (as `core/accessibility.zig`
    /// computes it — real modifier reads, decorative-node demotion, and all)
    /// equals `role` (e.g. "button", "checkbox", "textbox").
    pub fn byRole(self: Query, role: []const u8) ?reg.NodeId {
        for (self.h.registry.nodes.items) |node| {
            if (!node.alive) continue;
            if (!a11y.isControlElement(&self.h.registry, &self.h.store, node.id)) continue;
            if (std.mem.eql(u8, a11y.accessibleRole(&self.h.store, node.id, node.node_type), role)) return node.id;
        }
        return null;
    }

    /// First live node whose accessible name (label, or own text content —
    /// same resolution `core/accessibility.zig` uses for UIA/AT-SPI) equals
    /// `name`.
    pub fn byLabel(self: Query, name: []const u8) ?reg.NodeId {
        for (self.h.registry.nodes.items) |node| {
            if (!node.alive) continue;
            if (std.mem.eql(u8, a11y.accessibleName(&self.h.registry, &self.h.store, node.id), name)) return node.id;
        }
        return null;
    }

    /// Routes a real "click" at `node_id` — the same `Event` shape the engine
    /// builds after hit-testing a real pointer click, targeted by `node_id`
    /// exactly like a UIA `InvokeProvider.Invoke` thunk does.
    pub fn click(self: Query, node_id: reg.NodeId) void {
        _ = self.h.router.route(.{ .name = "click", .id = "", .node_id = node_id });
    }

    /// Routes a real "key_down" at `node_id` (already-focused element).
    pub fn keyDown(self: Query, node_id: reg.NodeId, key_code: u32) void {
        _ = self.h.router.route(.{ .name = "key_down", .id = "", .node_id = node_id, .key_code = key_code });
    }

    /// Routes a real "char_input" commit at `node_id`.
    pub fn typeText(self: Query, node_id: reg.NodeId, text: []const u8) void {
        _ = self.h.router.route(.{ .name = "char_input", .id = "", .node_id = node_id, .text = text });
    }

    /// Routes "focus" at `node_id`.
    pub fn focus(self: Query, node_id: reg.NodeId) void {
        _ = self.h.router.route(.{ .name = "focus", .id = "", .node_id = node_id });
    }

    pub const PointerError = error{NodeNotSolved};

    /// Routes a pointer event (`mouse_down`, `mouse_up`, `click`, `double_click`)
    /// at `node_id`, placed at node-local (`lx`, `ly`). The window coordinates
    /// the handler receives in `ev.x/y` come from the node's resolved rect via
    /// the public `LayoutReader` — call `h.solve(...)` first — so a widget that
    /// converts back in its handler sees exactly what production gives it.
    pub fn pointerAt(self: Query, name: []const u8, node_id: reg.NodeId, lx: f32, ly: f32) PointerError!void {
        const r = self.h.reader().rect(node_id) orelse return PointerError.NodeNotSolved;
        _ = self.h.router.route(.{ .name = name, .id = "", .node_id = node_id, .x = r.x + lx, .y = r.y + ly });
    }

    /// `pointerAt("mouse_down", ...)`.
    pub fn mouseDownAt(self: Query, node_id: reg.NodeId, lx: f32, ly: f32) PointerError!void {
        return self.pointerAt("mouse_down", node_id, lx, ly);
    }

    /// Routes a global (untargeted) pointer event — what `router.onGlobal`
    /// handlers see during a drag — at a point given relative to `ref_node`.
    /// `lx`/`ly` may be negative or past the node's size (pointer left it).
    pub fn globalPointerAt(self: Query, name: []const u8, ref_node: reg.NodeId, lx: f32, ly: f32) PointerError!void {
        const r = self.h.reader().rect(ref_node) orelse return PointerError.NodeNotSolved;
        _ = self.h.router.route(.{ .name = name, .id = "", .node_id = 0, .x = r.x + lx, .y = r.y + ly });
    }

    pub const AssertError = error{NodeNotVisible};

    /// Fails unless `node_id` resolved to a non-zero box after `h.solve(...)`
    /// — see `Harness.isVisible`'s doc comment for why this, and not a store
    /// read, is the right claim to test.
    pub fn expectVisible(self: Query, node_id: reg.NodeId) AssertError!void {
        if (!self.h.isVisible(node_id)) return AssertError.NodeNotVisible;
    }
};

fn matchesModifierId(h: *Harness, node_id: reg.NodeId, key: props.ModifierKey, id: []const u8) bool {
    const modifier = h.store.getModifier(node_id, key) orelse return false;
    return switch (modifier) {
        .string => |s| std.mem.eql(u8, s, id),
        else => false,
    };
}

// ── Text measurement stub ─────────────────────────────────────────────────────

const builder_mod = @import("builder.zig");

/// A deterministic, role-aware `TextMeasure` for testing text widgets without a
/// window or fonts. Install it with `b.measure = fw.testkit.measureStub();`.
///
/// Metrics (per codepoint, so UTF-8 text measures by character, not by byte):
/// - `.default` → `default_advance` (10px), `.bold` → `bold_advance` (11px),
///   `.mono` / `.mono_bold` → `mono_advance` (12px);
/// - plus `letter_spacing` per codepoint, as the renderer applies tracking;
/// - in `.default` and `.bold`, the pair "AV" kerns by `kern_av` (−3px), so a
///   widget that sums single-character widths instead of measuring prefixes
///   drifts here the way it would against a real font.
/// The advances don't scale with `font_size`; tests compare columns and x, not size.
pub const MeasureStub = struct {
    pub const default_advance: f32 = 10;
    pub const bold_advance: f32 = 11;
    pub const mono_advance: f32 = 12;
    pub const kern_av: f32 = -3;

    var ctx_byte: u8 = 0;

    pub fn width(ctx: *anyopaque, text: []const u8, font_size: f32) f32 {
        return styled(ctx, text, font_size, .{});
    }

    pub fn styled(_: *anyopaque, text: []const u8, _: f32, style: builder_mod.TextMeasure.MeasureStyle) f32 {
        const adv: f32 = switch (style.role) {
            .default => default_advance,
            .bold => bold_advance,
            .mono, .mono_bold => mono_advance,
        };
        const kerns = style.role == .default or style.role == .bold;
        var w: f32 = 0;
        var prev: u21 = 0;
        var i: usize = 0;
        while (i < text.len) {
            // Lenient stepping: an invalid lead byte counts as one character.
            const n = @min(std.unicode.utf8ByteSequenceLength(text[i]) catch 1, text.len - i);
            const cp: u21 = std.unicode.utf8Decode(text[i .. i + n]) catch 0xFFFD;
            i += n;
            if (kerns and prev == 'A' and cp == 'V') w += kern_av;
            w += adv + style.letter_spacing;
            prev = cp;
        }
        return w;
    }
};

/// The `TextMeasure` handle for `MeasureStub`. Width with `width` / `widthStyled`
/// / `widthRole`; vertical geometry falls back to the default proportions.
pub fn measureStub() builder_mod.TextMeasure {
    return .{
        .ctx = @ptrCast(&MeasureStub.ctx_byte),
        .measureFn = MeasureStub.width,
        .measureStyledFn = MeasureStub.styled,
    };
}

test "measureStub tells roles apart, kerns AV, counts codepoints and tracking" {
    const m = measureStub();
    try std.testing.expectEqual(@as(f32, 30), m.width("abc", 16));
    try std.testing.expectEqual(@as(f32, 36), m.widthRole("abc", 16, .mono));
    try std.testing.expectEqual(@as(f32, 33), m.widthRole("abc", 16, .bold));
    // The un-styled width is the default role.
    try std.testing.expectEqual(m.width("abc", 16), m.widthRole("abc", 16, .default));
    // Kerning makes the prefix narrower than the sum of its characters.
    try std.testing.expectEqual(@as(f32, 17), m.width("AV", 16));
    try std.testing.expectEqual(@as(f32, 24), m.widthRole("AV", 16, .mono));
    // "é" (2 bytes) and "日" (3 bytes) are one character each.
    try std.testing.expectEqual(@as(f32, 20), m.width("é日", 16));
    try std.testing.expectEqual(@as(f32, 3 * 14), m.widthStyled("abc", 16, .{ .role = .mono, .letter_spacing = 2 }));
    // Invalid UTF-8 does not trap.
    try std.testing.expectEqual(@as(f32, 10), m.width("\xff", 16));
}

// ── Node-local pointer coordinates through the public API ─────────────────────

const component = @import("component.zig");

/// Stand-in for a third-party widget: it uses only `fw.component` (no registry,
/// no store) to turn pointer events into coordinates local to its own node.
const LocalProbe = struct {
    reader: ?component.LayoutReader = null,
    target: reg.NodeId = 0,
    down: ?component.MeasuredRect.Point = null,
    drag: ?component.MeasuredRect.Point = null,

    fn onDown(self: *LocalProbe, ev: events.Event) void {
        self.down = self.reader.?.toLocal(ev.node_id, ev.x, ev.y);
    }
    fn onGlobal(self: *LocalProbe, ev: events.Event) void {
        if (!std.mem.eql(u8, ev.name, "mouse_move")) return;
        self.drag = self.reader.?.toLocal(self.target, ev.x, ev.y);
    }

    /// Outer row (padding l=20,t=15) → 30px sibling → 100×40 target.
    fn build(self: *LocalProbe, ctx: *component.BuildContext, outer: *reg.NodeId) !void {
        self.reader = ctx.layoutReader();
        outer.* = try ctx.boxNode(.{
            .width = component.px(400),
            .height = component.px(200),
            .direction = .row,
            .padding = component.EdgeInsets{ .l = 20, .t = 15 },
            .@"align" = .start,
        }, .{});
        try ctx.builder.rootAt(outer.*);
        try ctx.box(.{ .width = component.px(30), .height = component.px(10) }, .{});
        self.target = try ctx.boxNode(.{
            .width = component.px(100),
            .height = component.px(40),
            .on_mouse_down = ctx.handler(self, onDown),
        }, .{});
        ctx.builder.close();
        if (ctx.router) |r| try r.onGlobal(self.target, self, onGlobal);
    }
};

test "LayoutReader: local coords on an offset node, scrolled ancestor, drag out of bounds" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    h.wire();
    var b = builder_mod.UIBuilder.init(&h.registry, &h.store);
    var ctx = component.BuildContext.initWithRouter(&b, &h.router);

    var probe = LocalProbe{};
    var outer: reg.NodeId = 0;
    // Not solved yet: no rect, and the testkit refuses to invent coordinates.
    try probe.build(&ctx, &outer);
    try std.testing.expect(ctx.measuredRect(probe.target) == null);
    const q = Query.init(&h);
    try std.testing.expectError(Query.PointerError.NodeNotSolved, q.mouseDownAt(probe.target, 0, 0));

    h.solve(outer, 400, 200);
    const r = ctx.measuredRect(probe.target).?;
    // Offset by the parent's padding (20) and the sibling (30) — window space.
    try std.testing.expectEqual(@as(f32, 50), r.x);
    try std.testing.expectEqual(@as(f32, 15), r.y);
    try std.testing.expectEqual(@as(f32, 100), r.w);
    try std.testing.expectEqual(@as(f32, 40), r.h);
    try std.testing.expectEqual(ctx.measuredSize(probe.target).?.w, r.w);

    // Left edge is local 0, whatever the offset.
    try q.mouseDownAt(probe.target, 0, 0);
    try std.testing.expectEqual(@as(f32, 0), probe.down.?.x);
    try std.testing.expectEqual(@as(f32, 0), probe.down.?.y);
    try q.mouseDownAt(probe.target, 37, 12);
    try std.testing.expectEqual(@as(f32, 37), probe.down.?.x);
    try std.testing.expectEqual(@as(f32, 12), probe.down.?.y);
    // The raw window coords are untouched.
    try std.testing.expect(r.contains(50 + 37, 15 + 12));

    // Drag leaves the node: locals go negative / past the size, unclamped.
    try q.globalPointerAt("mouse_move", probe.target, -25, 60);
    try std.testing.expectEqual(@as(f32, -25), probe.drag.?.x);
    try std.testing.expectEqual(@as(f32, 60), probe.drag.?.y);
    try q.globalPointerAt("mouse_move", probe.target, 130, -5);
    try std.testing.expectEqual(@as(f32, 130), probe.drag.?.x);
    try std.testing.expectEqual(@as(f32, -5), probe.drag.?.y);

    // A scrolled ancestor moves the painted rect; the reader follows it, so a
    // click at the node's painted left edge is still local 0.
    try b.scrollOffsetY(outer, -10);
    const rs = ctx.measuredRect(probe.target).?;
    try std.testing.expectEqual(@as(f32, 5), rs.y);
    _ = h.router.route(.{ .name = "mouse_down", .id = "", .node_id = probe.target, .x = 50, .y = 5 });
    try std.testing.expectEqual(@as(f32, 0), probe.down.?.x);
    try std.testing.expectEqual(@as(f32, 0), probe.down.?.y);
}
