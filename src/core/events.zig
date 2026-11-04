const std = @import("std");
const reg = @import("registry.zig");

/// Finds the deepest node (visually top-most in Z-Order)
/// that intersects the given coordinates (x, y).
pub fn hitTest(hit_list: []const @import("../render/renderer.zig").HitNode, registry: *const reg.UIRegistry, store: *const @import("properties.zig").PropertyStore, x: f32, y: f32) ?reg.NodeId {
    if (hit_list.len == 0) return null;

    // hit_list is pre-sorted from highest Z-Order to lowest
    for (hit_list) |hit_node| {
        const node_id = hit_node.id;
        if (node_id >= registry.nodes.items.len) continue;
        const node = &registry.nodes.items[node_id];

        // Skip nodes removed since the hit list was baked (a rebuild between
        // frames): their slot keeps its old geometry until reused.
        if (!node.alive) continue;

        // Skip nodes with invalid layout
        if (node.geometry.width <= 0 or node.geometry.height <= 0) continue;

        // Skip pointer_events: none
        if (store.modifierFlag(node_id, .pointer_events_none)) continue;

        // Strict bounding box check against actual geometry
        if (x >= node.geometry.x and x <= node.geometry.x + node.geometry.width and
            y >= node.geometry.y and y <= node.geometry.y + node.geometry.height)
        {
            // Verify it wasn't visually clipped away by a parent overflow_hidden
            const c = hit_node.clip_rect;
            if (x >= c.x and x <= c.x + c.w and y >= c.y and y <= c.y + c.h) {
                return node_id;
            }
        }
    }

    return null;
}

test "hitTest reverse Z-Order detection" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var store = @import("properties.zig").PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    const id1 = try registry.createNode(.box);
    const id2 = try registry.createNode(.box);
    const id3 = try registry.createNode(.box);

    // Box 1: Large background
    registry.nodes.items[id1].geometry = .{ .x = 0, .y = 0, .width = 500, .height = 500 };

    // Box 2: Middle floating box
    registry.nodes.items[id2].geometry = .{ .x = 100, .y = 100, .width = 200, .height = 200 };

    // Box 3: Small topmost button, overlapping Box 2
    registry.nodes.items[id3].geometry = .{ .x = 150, .y = 150, .width = 50, .height = 50 };

    const HitNode = @import("../render/renderer.zig").HitNode;
    const inf_clip = @import("../render/renderer.zig").ClipRect{ .x = -10000, .y = -10000, .w = 20000, .h = 20000 };
    var hit_list = [_]HitNode{
        .{ .id = id3, .z_index = 0, .draw_order = 0, .clip_rect = inf_clip },
        .{ .id = id2, .z_index = 0, .draw_order = 0, .clip_rect = inf_clip },
        .{ .id = id1, .z_index = 0, .draw_order = 0, .clip_rect = inf_clip },
    };

    // Point inside all three, should hit topmost (id3)
    try std.testing.expectEqual(id3, hitTest(&hit_list, &registry, &store, 175, 175));

    // Point inside id1 and id2, but outside id3
    try std.testing.expectEqual(id2, hitTest(&hit_list, &registry, &store, 120, 120));

    // Point only inside id1
    try std.testing.expectEqual(id1, hitTest(&hit_list, &registry, &store, 10, 10));

    // Point outside everything
    try std.testing.expectEqual(@as(?reg.NodeId, null), hitTest(&hit_list, &registry, &store, -10, -10));
}

pub const EventPhase = enum { capture, target, bubble };

/// Why a focus move happened — the input distinguishes CSS's `:focus-visible`
/// (and Flutter's `FocusHighlightMode`) from earlier engines like Qt's
/// per-event `FocusReason`: a single funnel (`moveFocus`) computes one global
/// `FocusHighlightMode` from this, rather than every widget deciding on its
/// own whether to paint a ring. Passed by every one of `moveFocus`'s callers
/// (mouse click, Tab, focus-scope push/pop, UIA `SetFocus`, programmatic
/// text-value changes).
pub const FocusOrigin = enum {
    /// A mouse/pointer click resolved this focus target. Switches the engine
    /// to `.pointer` highlight mode — the ring does not paint.
    pointer,
    /// Tab/Shift+Tab or in-widget arrow-key navigation. Switches to `.keyboard`
    /// — the ring paints. Also used for a focus scope opened by a keyboard
    /// action (e.g. an accelerator), so the ring is visible right away.
    keyboard,
    /// A host/UIA-external call set the value directly (`ValuePattern.SetValue`
    /// driving `setNodeTextViaInput`, say) — not a user interaction. Treated
    /// like `.keyboard` (assume "keyboard-like" intent), matching the CSS
    /// `:focus-visible` default for `element.focus()` from script.
    programmatic,
    /// An external UI Automation client (a screen reader) requested focus via
    /// `IRawElementProviderFragment::SetFocus`. Treated like `.keyboard` — an
    /// assistive-tech user needs the ring, regardless of what drove focus here
    /// a moment ago.
    uia_external,
    /// Restoring focus after a focus-scope pop (a menu/dialog closing) is not
    /// a new navigation — it must NOT recompute the highlight mode, just put
    /// focus back where it was under whatever mode was already active.
    restore,
    /// The focused node was removed from the tree (e.g. a virtualized row
    /// scrolled out). Focus goes to `null`; like `.restore`, this is not a
    /// navigation and must not recompute the highlight mode.
    removed,
};

/// Whether the engine currently shows the focus ring — a single global flag
/// (not per-node), recomputed by `moveFocus` from each call's `FocusOrigin`.
/// Mirrors Flutter's `FocusManager.highlightMode`; deliberately NOT modeled
/// as Qt's per-event `FocusReason` consulted independently by every widget —
/// with one funnel already routing every focus move, a single computed mode
/// is one source of truth instead of N widgets re-deriving the same answer.
pub const FocusHighlightMode = enum { pointer, keyboard };

/// The engine's event vocabulary, typed. Emission goes through one helper that
/// maps each to its wire name (and, later, a structured C-ABI event), so the
/// ~13 scattered `cb(name, json)` sites stop hand-rolling strings. `name()` is
/// the exact legacy string the host callback / EventRouter already match on.
/// `text_composition` is reserved for IME composed text (designed in now, not
/// yet emitted).
pub const EventType = enum(c_int) {
    mouse_move,
    mouse_down,
    mouse_up,
    right_mouse_down,
    right_mouse_up,
    mouse_enter,
    mouse_leave,
    global_mouse_down,
    click,
    focus,
    blur,
    key_down,
    key_up,
    char_input,
    scroll,
    tick,
    /// IME preedit update — `text` carries the in-progress composition string
    /// (UTF-8); an empty string ends/cancels the composition.
    text_composition,
    /// IME commit — `text` carries the finalized string (UTF-8) to insert.
    text_commit,
    /// File/text drag-and-drop dropped on a node — `text` carries the payload
    /// (a newline-separated URI/path list, or plain text).
    drop,
    /// Double/triple click, detected by timing in `c_api`. `key_code` carries
    /// the consecutive-click count (2 = double, 3 = triple), so a handler can
    /// escalate word→line selection. Appended last to keep the C-ABI enum stable.
    double_click,
    /// Horizontal scroll — `scroll_delta` carries the horizontal notches
    /// (positive = right). Emitted from a horizontal wheel/tilt or Shift+wheel.
    /// Appended last to keep the C-ABI enum stable.
    scroll_h,

    pub fn name(self: EventType) [:0]const u8 {
        return switch (self) {
            .mouse_move => "mouse_move",
            .mouse_down => "mouse_down",
            .mouse_up => "mouse_up",
            .right_mouse_down => "right_mouse_down",
            .right_mouse_up => "right_mouse_up",
            .mouse_enter => "mouse_enter",
            .mouse_leave => "mouse_leave",
            .global_mouse_down => "global_mouse_down",
            .click => "click",
            .focus => "focus",
            .blur => "blur",
            .key_down => "key_down",
            .key_up => "key_up",
            .char_input => "char_input",
            .scroll => "scroll",
            .tick => "tick",
            .text_composition => "text_composition",
            .text_commit => "text_commit",
            .drop => "drop",
            .double_click => "double_click",
            .scroll_h => "scroll_h",
        };
    }
};

/// Structured C-ABI event — the engine's only event channel.
/// Hosts/bindings route on typed fields instead of parsing JSON. `action_id`/`text`
/// are always NUL-terminated ("" when absent). `node_id` is the registry id (0 =
/// none / global event).
pub const CelerisEvent = extern struct {
    event_type: c_int,
    node_id: u32,
    action_id: [*:0]const u8,
    x: f32,
    y: f32,
    key_code: u32,
    scroll_delta: f32,
    /// char_input codepoint / IME composed text, UTF-8.
    text: [*:0]const u8,
    /// Keyboard modifier bitmask: bit0 = Shift, bit1 = Ctrl, bit2 = Alt.
    modifiers: u32,
};

pub const MOD_SHIFT: u32 = 1 << 0;
pub const MOD_CTRL: u32 = 1 << 1;
pub const MOD_ALT: u32 = 1 << 2;

comptime {
    // Lock the CelerisEvent layout to what include/celeris.h and the C# binding
    // marshal on 64-bit desktop (LP64 / Win64). A field reorder or resize trips the
    // build here instead of silently corrupting host-side decoding. Keep the mirror
    // `_Static_assert` in include/celeris.h in sync.
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(CelerisEvent) == 48);
        std.debug.assert(@offsetOf(CelerisEvent, "event_type") == 0);
        std.debug.assert(@offsetOf(CelerisEvent, "node_id") == 4);
        std.debug.assert(@offsetOf(CelerisEvent, "action_id") == 8);
        std.debug.assert(@offsetOf(CelerisEvent, "x") == 16);
        std.debug.assert(@offsetOf(CelerisEvent, "y") == 20);
        std.debug.assert(@offsetOf(CelerisEvent, "key_code") == 24);
        std.debug.assert(@offsetOf(CelerisEvent, "scroll_delta") == 28);
        std.debug.assert(@offsetOf(CelerisEvent, "text") == 32);
        std.debug.assert(@offsetOf(CelerisEvent, "modifiers") == 40);
    }
}

pub const StructuredEventCallback = *const fn (event: *const CelerisEvent) callconv(.c) void;

pub const EventContext = struct {
    registry: *reg.UIRegistry,
    store: *const @import("properties.zig").PropertyStore,
    propagation_stopped: *bool,
    event_callback: ?StructuredEventCallback = null,
    allocator: std.mem.Allocator,
    /// MOD_* bitmask copied onto every dispatched event (Shift/Ctrl/Alt held
    /// during the pointer action).
    modifiers: u32 = 0,
};

/// Copies `s` into `buf` as a NUL-terminated string for the C ABI (truncating to
/// fit). Returns a sentinel-terminated pointer valid until `buf` is reused.
///
/// Truncation never splits a UTF-8 codepoint. `emitEvent` runs this over every
/// `.text` payload crossing the structured C-ABI callback — IME preedit/commit,
/// paste, drop, `celeris_dispatch_set_text` — with a 256-byte buffer, so several
/// emoji or a run of accented/CJK text (each codepoint 2-4 bytes) reaches it
/// past capacity routinely, not just under adversarial input. A raw byte cut
/// used to hand the host a NUL-terminated string with a lone continuation byte
/// dangling at the end: not a memory-safety bug here (the buffer itself stays
/// in bounds), but invalid UTF-8 handed across an ABI boundary to callers that
/// reasonably assume `.text` is well-formed — a binding decoding it with a
/// strict UTF-8 walker has undefined behavior of its own to deal with.
pub fn toCString(buf: []u8, s: []const u8) [*:0]const u8 {
    if (buf.len == 0) return ""; // no room even for the terminator
    var n = @min(s.len, buf.len - 1);
    // If the cut lands mid-codepoint (on a `10xxxxxx` continuation byte), back
    // up to its start. Only applies when `s` was actually truncated (n < s.len
    // — otherwise `s[n]` is one past the slice); bounded by `n` itself, so this
    // terminates even if `s` is already malformed UTF-8 (it only needs *a*
    // safe byte boundary, not a full decode).
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    std.mem.copyForwards(u8, buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

/// Dispatches an event through the 3 DOM phases: Capture -> Target -> Bubble
pub fn dispatchEvent(
    ctx: EventContext,
    target_id: reg.NodeId,
    event_type: EventType,
    modifier_capture: @import("properties.zig").ModifierKey,
    modifier_bubble: @import("properties.zig").ModifierKey,
    x: f32,
    y: f32,
) !void {
    var path = std.array_list.Managed(reg.NodeId).init(ctx.allocator);
    defer path.deinit();

    // 1. Build the path from target up to root
    var current: reg.NodeId = target_id;
    while (current != reg.NULL_NODE) {
        try path.append(current);
        const node = ctx.registry.getNode(current) orelse break;
        current = node.parent;
    }

    ctx.propagation_stopped.* = false;

    // 2. Capture Phase (root down to target)
    var i: usize = path.items.len;
    while (i > 0) {
        i -= 1;
        const node_id = path.items[i];
        if (ctx.store.getModifier(node_id, modifier_capture)) |val| {
            fireCallback(ctx, event_type, node_id, val, x, y);
        }
        if (ctx.propagation_stopped.*) return;
    }

    // 3. Target Phase & 4. Bubble Phase (target up to root)
    // In our simplified model, we can treat Target as just the first step of Bubble.
    // A `.no_drag` modifier (embeddable MenuBar) stops the bubble from
    // reaching ancestors past it — e.g. a caption's drag-region handler must not
    // fire for a click on a menu-bar button nested inside it. The node carrying
    // `.no_drag` (and anything closer to target) still bubbles normally; only
    // ancestors beyond it are skipped.
    var bubble_limit: usize = path.items.len;
    for (path.items, 0..) |node_id, path_idx| {
        if (ctx.store.modifierFlag(node_id, .no_drag)) {
            bubble_limit = path_idx + 1;
            break;
        }
    }

    for (path.items[0..bubble_limit]) |node_id| {
        if (ctx.store.getModifier(node_id, modifier_bubble)) |val| {
            fireCallback(ctx, event_type, node_id, val, x, y);
        }
        if (ctx.propagation_stopped.*) return;
    }
}

fn fireCallback(
    ctx: EventContext,
    event_type: EventType,
    node_id: reg.NodeId,
    val: @import("properties.zig").PropValue,
    x: f32,
    y: f32,
) void {
    const id_str = switch (val) {
        .string => |s| s,
        else => "unknown",
    };
    if (ctx.event_callback) |cb| {
        var idbuf: [128]u8 = undefined;
        const ev = CelerisEvent{
            .event_type = @intFromEnum(event_type),
            .node_id = node_id,
            .action_id = toCString(&idbuf, id_str),
            .x = x,
            .y = y,
            .key_code = 0,
            .scroll_delta = 0,
            .text = "",
            .modifiers = ctx.modifiers,
        };
        cb(&ev);
    }
}

var test_fired: std.array_list.Managed([]const u8) = undefined;

fn testStructCb(ev: *const CelerisEvent) callconv(.c) void {
    const action = std.mem.span(ev.action_id);
    const dup = std.testing.allocator.dupe(u8, action) catch return;
    test_fired.append(dup) catch return;
}

test "dispatchEvent capture and bubble (structured)" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var store = @import("properties.zig").PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    test_fired = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer {
        for (test_fired.items) |str| std.testing.allocator.free(str);
        test_fired.deinit();
    }

    const id_root = try registry.createNode(.box);
    const id_child = try registry.createNode(.box);
    registry.appendChild(id_root, id_child);

    // Sync store size
    try store.props.appendNTimes(.{}, registry.nodes.items.len);

    // root listens to capture, child listens to bubble
    try store.setModifier(id_root, .clickable_capture, .{ .string = try store.stringAllocator().dupe(u8, "root_capture") });
    try store.setModifier(id_child, .clickable, .{ .string = try store.stringAllocator().dupe(u8, "child_bubble") });
    // root also listens to bubble
    try store.setModifier(id_root, .clickable, .{ .string = try store.stringAllocator().dupe(u8, "root_bubble") });

    var stopped = false;
    const ctx = EventContext{
        .registry = &registry,
        .store = &store,
        .propagation_stopped = &stopped,
        .event_callback = testStructCb,
        .allocator = std.testing.allocator,
    };

    try dispatchEvent(ctx, id_child, .click, .clickable_capture, .clickable, 0, 0);

    try std.testing.expectEqual(@as(usize, 3), test_fired.items.len);
    try std.testing.expectEqualStrings("root_capture", test_fired.items[0]); // capture, root→target
    try std.testing.expectEqualStrings("child_bubble", test_fired.items[1]); // bubble, target→root
    try std.testing.expectEqualStrings("root_bubble", test_fired.items[2]);
}

test "BUG: toCString truncation must not split a UTF-8 codepoint" {
    // Found while auditing emitEvent's fixed 256-byte text buffer: a run of
    // multi-byte codepoints (emoji, CJK, accents) that crosses the buffer
    // boundary used to get cut mid-sequence, handing hosts across the C-ABI
    // callback a NUL-terminated string with a dangling continuation byte —
    // not valid UTF-8, despite every input codepoint being well-formed.
    var buf: [5]u8 = undefined;

    // "aé" = 'a' (1 byte) + U+00E9 (2 bytes) = 3 bytes total, fits.
    {
        const r = toCString(&buf, "a\u{00E9}");
        try std.testing.expectEqualStrings("a\u{00E9}", std.mem.span(r));
    }

    // buf holds 4 content bytes + NUL. "aaaé" is 5 bytes (a,a,a,+2-byte é) —
    // a raw byte cut at 4 lands mid-é; must back up and drop the whole é.
    {
        const r = toCString(&buf, "aaa\u{00E9}");
        const got = std.mem.span(r);
        try std.testing.expect(std.unicode.utf8ValidateSlice(got));
        try std.testing.expectEqualStrings("aaa", got);
    }

    // 4-byte emoji alone, buffer can't fit it at all (needs 4 + NUL, have 5 —
    // actually fits exactly here) — use a smaller buffer to force the cut.
    {
        var small: [3]u8 = undefined; // 2 content bytes + NUL
        const r = toCString(&small, "\u{1F600}"); // F0 9F 98 80, all one codepoint
        const got = std.mem.span(r);
        try std.testing.expect(std.unicode.utf8ValidateSlice(got));
        try std.testing.expectEqualStrings("", got); // no byte of it is a valid prefix alone
    }

    // Already-truncated (not well-formed to begin with) input must not make
    // the backward scan run off the front of the buffer.
    {
        var small: [2]u8 = undefined;
        const r = toCString(&small, "\x80\x80\x80"); // all continuation bytes, no lead byte
        try std.testing.expectEqualStrings("", std.mem.span(r));
    }

    // No truncation needed: exact fit and under-capacity both pass through
    // untouched (regression guard for the n < s.len bounds check).
    {
        var exact: [4]u8 = undefined;
        try std.testing.expectEqualStrings("abc", std.mem.span(toCString(&exact, "abc")));
    }
}
