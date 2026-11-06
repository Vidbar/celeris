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
