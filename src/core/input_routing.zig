//! Pointer routing — the hit-test → target → bubble part of input handling,
//! shared by the engine (`c_api.handleOSInput`) and the test harness
//! (`framework/testkit.zig`'s window-coordinate helpers).
//!
//! Given the frame's hit list (z-sorted by the renderer's bake), it resolves
//! which node a pointer action lands on — so a higher-`zIndex` overlay blocks
//! the nodes beneath it — and emits the same events, in the same order, through
//! an `EventSink`. It owns only the pointer state routing needs (hovered node,
//! pressed nodes). Everything that is not routing stays with the engine: focus,
//! cursor, owner-modal blocking, DPI scale, double-click timing, IME.
//!
//! There is one copy of this logic. A test that clicks through it exercises the
//! code a user's click does.
const std = @import("std");
const reg = @import("registry.zig");
const props = @import("properties.zig");
const events = @import("events.zig");
const HitNode = @import("../render/renderer.zig").HitNode;

pub const MAX_PRESSED = 32;

/// Pointer state that persists between events. Embedded in the engine (and in
/// the test harness); the removal hook must call `Router.nodeRemoved`.
pub const PointerState = struct {
    /// Nearest `.hoverable` ancestor-or-self of what is under the pointer.
    hovered: ?reg.NodeId = null,
    /// Clickable nodes on the hit path of the current press (target first) —
    /// the ones that got `mouse_down` and must get the matching `mouse_up`.
    pressed: [MAX_PRESSED]reg.NodeId = undefined,
    pressed_len: usize = 0,
    /// `hover_within` hoverables whose subtree holds the hit, outermost first.
    within: [MAX_PRESSED]reg.NodeId = undefined,
    within_len: usize = 0,
};

/// One input event's view of the world. Cheap to build per event.
pub const Router = struct {
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    hit_list: []const HitNode,
    sink: events.EventSink,
    state: *PointerState,
    propagation_stopped: *bool,
    allocator: std.mem.Allocator,
    /// MOD_* bitmask for every event this input produces.
    mods: u32 = 0,

    pub fn hitTest(self: Router, x: f32, y: f32) ?reg.NodeId {
        return events.hitTest(self.hit_list, self.registry, self.store, x, y);
    }

    /// Builds and emits one structured event. Strings live in stack buffers for
    /// the duration of the sink call only.
    pub fn emit(
        self: Router,
        event_type: events.EventType,
        node_id: reg.NodeId,
        action_id: []const u8,
        x: f32,
        y: f32,
        key_code: u32,
        scroll_delta: f32,
        text: []const u8,
        modifiers: u32,
    ) void {
        var idbuf: [128]u8 = undefined;
        var txtbuf: [256]u8 = undefined; // room for IME preedit/commit strings
        const ev = events.CelerisEvent{
            .event_type = @intFromEnum(event_type),
            .node_id = if (node_id == reg.NULL_NODE) 0 else node_id,
            .action_id = events.toCString(&idbuf, action_id),
            .x = x,
            .y = y,
            .key_code = key_code,
            .scroll_delta = scroll_delta,
            .text = events.toCString(&txtbuf, text),
            .modifiers = modifiers,
        };
        self.sink.emit(&ev);
    }

    fn eventCtx(self: Router, key_code: u32) events.EventContext {
        return .{
            .registry = self.registry,
            .store = self.store,
            .propagation_stopped = self.propagation_stopped,
            .sink = self.sink,
            .allocator = self.allocator,
            .modifiers = self.mods,
            .key_code = key_code,
        };
    }

    /// Hit-tests (x,y) and, on a hit, dispatches `event_type` capture→bubble via
    /// the given modifier keys. Returns the hit (null: nothing under the pointer).
    pub fn dispatchAt(
        self: Router,
        x: f32,
        y: f32,
        event_type: events.EventType,
        modifier_capture: props.ModifierKey,
        modifier_bubble: props.ModifierKey,
        key_code: u32,
    ) ?reg.NodeId {
        const hit_id = self.hitTest(x, y) orelse return null;
        events.dispatchEvent(self.eventCtx(key_code), hit_id, event_type, modifier_capture, modifier_bubble, x, y) catch {};
        return hit_id;
    }

    fn hoverableId(self: Router, id: reg.NodeId) []const u8 {
        const val = self.store.getModifier(id, .hoverable) orelse return "";
        return switch (val) {
            .string => |s| s,
            else => "unknown",
        };
    }

    /// Moves the hover to the nearest `.hoverable` ancestor-or-self of
    /// `top_hit`, emitting mouse_leave to the old node and mouse_enter to the
    /// new one. The single hover funnel: pointer motion and the post-rebuild
    /// recheck share it.
    pub fn updateHover(self: Router, top_hit: ?reg.NodeId, x: f32, y: f32) void {
        // One walk up from the hit: the nearest plain hoverable (exclusive
        // hover) and every `hover_within` hoverable (subtree hover).
        var hit_hoverable: ?reg.NodeId = null;
        var within: [MAX_PRESSED]reg.NodeId = undefined;
        var within_len: usize = 0;
        if (top_hit) |hit_id| {
            var current_id: reg.NodeId = hit_id;
            while (current_id != reg.NULL_NODE) {
                if (self.store.getModifier(current_id, .hoverable)) |_| {
                    if (self.store.modifierFlag(current_id, .hover_within)) {
                        if (within_len < MAX_PRESSED) {
                            within[within_len] = current_id;
                            within_len += 1;
                        }
                    } else if (hit_hoverable == null) {
                        hit_hoverable = current_id;
                    }
                }
                const node = self.registry.getNode(current_id) orelse break;
                current_id = node.parent;
            }
        }
        std.mem.reverse(reg.NodeId, within[0..within_len]); // outermost first

        // All leaves before any enter (innermost first), so a node that moves
        // between the two sets — its `hover_within` flag toggled while hovered
        // — gets leave→enter and ends up entered, never the reverse.
        const changed = self.state.hovered != hit_hoverable;
        if (changed) {
            if (self.state.hovered) |old_hover| {
                if (self.store.getModifier(old_hover, .hoverable) != null)
                    self.emit(.mouse_leave, old_hover, self.hoverableId(old_hover), x, y, 0, 0, "", self.mods);
            }
            self.state.hovered = null;
        }
        self.setWithin(within[0..within_len], x, y);
        if (!changed) return;
        self.state.hovered = hit_hoverable;
        if (self.state.hovered) |new_hover| {
            if (self.store.getModifier(new_hover, .hoverable) != null)
                self.emit(.mouse_enter, new_hover, self.hoverableId(new_hover), x, y, 0, 0, "", self.mods);
        }
    }

    /// Replaces the `hover_within` set: mouse_leave to the nodes that left it
    /// (innermost first), then mouse_enter to the ones that joined (outermost
    /// first) — the DOM's enter/leave order.
    fn setWithin(self: Router, new: []const reg.NodeId, x: f32, y: f32) void {
        var old: [MAX_PRESSED]reg.NodeId = undefined;
        const old_len = self.state.within_len;
        @memcpy(old[0..old_len], self.state.within[0..old_len]);
        @memcpy(self.state.within[0..new.len], new);
        self.state.within_len = new.len;
        var i = old_len;
        while (i > 0) {
            i -= 1;
            const id = old[i];
            if (std.mem.indexOfScalar(reg.NodeId, new, id) != null) continue;
            if (self.registry.getNode(id) == null) continue;
            self.emit(.mouse_leave, id, self.hoverableId(id), x, y, 0, 0, "", self.mods);
        }
        for (new) |id| {
            if (std.mem.indexOfScalar(reg.NodeId, old[0..old_len], id) != null) continue;
            self.emit(.mouse_enter, id, self.hoverableId(id), x, y, 0, 0, "", self.mods);
        }
    }

    /// Pointer motion: the global `mouse_move` (drag-follow handlers), then the
    /// hover update. Returns the top hit (the engine resolves the cursor from it).
    pub fn mouseMove(self: Router, x: f32, y: f32) ?reg.NodeId {
        self.emit(.mouse_move, reg.NULL_NODE, "", x, y, 0, 0, "", self.mods);
        const top_hit = self.hitTest(x, y);
        self.updateHover(top_hit, x, y);
        return top_hit;
    }

    /// The pointer left the window: the hovered node's `mouse_leave` (if any),
    /// then the target-less `pointer_left_window`. `x`/`y` are the last known
    /// in-window position.
    pub fn pointerLeftWindow(self: Router, x: f32, y: f32) void {
        self.setWithin(&.{}, x, y);
        if (self.state.hovered) |old_hover| {
            if (self.store.getModifier(old_hover, .hoverable) != null)
                self.emit(.mouse_leave, old_hover, self.hoverableId(old_hover), x, y, 0, 0, "", self.mods);
            self.state.hovered = null;
        }
        self.emit(.pointer_left_window, reg.NULL_NODE, "", x, y, 0, 0, "", self.mods);
    }

    /// Records the clickable nodes on the hit path of a mouse_down.
    fn capturePressed(self: Router, x: f32, y: f32) void {
        self.state.pressed_len = 0;
        var cur = self.hitTest(x, y) orelse return;
        while (cur != reg.NULL_NODE and self.state.pressed_len < MAX_PRESSED) {
            if (self.store.getModifier(cur, .clickable) != null or self.store.getModifier(cur, .clickable_capture) != null) {
                self.state.pressed[self.state.pressed_len] = cur;
                self.state.pressed_len += 1;
            }
            const node = self.registry.getNode(cur) orelse break;
            cur = node.parent;
        }
    }

    /// Left press: the global `global_mouse_down`, press capture, then
    /// `mouse_down` capture→bubble at the hit. Returns the hit; focus and
    /// double-click stay with the caller.
    pub fn mouseDown(self: Router, x: f32, y: f32) ?reg.NodeId {
        self.emit(.global_mouse_down, reg.NULL_NODE, "", x, y, 0, 0, "", self.mods);
        self.capturePressed(x, y);
        return self.dispatchAt(x, y, .mouse_down, .clickable_capture, .clickable, 0);
    }

    fn pressedActionId(self: Router, id: reg.NodeId) []const u8 {
        const m = self.store.getModifier(id, .clickable) orelse return "";
        return if (m == .string) m.string else "";
    }

    /// Delivers `mouse_up` to every node that took the current press, target
    /// first, then clears the capture.
    fn releaseAllPressed(self: Router, x: f32, y: f32) void {
        // Snapshot: a mouse_up handler may rebuild, and the removal hook edits
        // `pressed` while we iterate.
        var ids: [MAX_PRESSED]reg.NodeId = undefined;
        const n = self.state.pressed_len;
        @memcpy(ids[0..n], self.state.pressed[0..n]);
        self.state.pressed_len = 0;
        for (ids[0..n]) |id| {
            if (self.registry.getNode(id) == null) continue;
            self.emit(.mouse_up, id, self.pressedActionId(id), x, y, 0, 0, "", self.mods);
        }
    }

    /// Left release: the global `mouse_up`, then a node-targeted `mouse_up` to
    /// the nodes that took the press (DOM order: mouseup before click), then the
    /// `click` at the node under the pointer carrying `click_count` in key_code.
    pub fn mouseUp(self: Router, x: f32, y: f32, click_count: u32) void {
        self.emit(.mouse_up, reg.NULL_NODE, "", x, y, 0, 0, "", self.mods);
        self.releaseAllPressed(x, y);
        _ = self.dispatchAt(x, y, .click, .clickable_capture, .clickable, @max(click_count, 1));
    }

    /// Wheel: `scroll` (and/or `scroll_h`) to the nearest `.scrollable`
    /// ancestor-or-self of the hit. `dy`/`dx` are already-resolved axes.
    pub fn wheel(self: Router, x: f32, y: f32, dy: f32, dx: f32) void {
        var current_id: reg.NodeId = self.hitTest(x, y) orelse return;
        while (current_id != reg.NULL_NODE) {
            if (self.store.getModifier(current_id, .scrollable)) |mod| {
                const id_str = if (mod == .string) mod.string else "";
                if (dy != 0) self.emit(.scroll, current_id, id_str, x, y, 0, dy, "", self.mods);
                // Horizontal goes out as its own event type, positive = right.
                if (dx != 0) self.emit(.scroll_h, current_id, id_str, x, y, 0, dx, "", self.mods);
                return;
            }
            const node = self.registry.getNode(current_id) orelse return;
            current_id = node.parent;
        }
    }

    /// Removal hook: a removed node is no longer hovered (it gets its
    /// mouse_leave now) and, if it took the current press, gets its mouse_up now
    /// — so press/hover state it drives can't outlive it. `x`/`y` are the last
    /// known pointer position. Returns true if the hover was cleared (the
    /// engine then re-evaluates hover after the next bake).
    pub fn nodeRemoved(self: Router, id: reg.NodeId, x: f32, y: f32) bool {
        var hover_cleared = false;
        if (self.state.hovered == id) {
            self.state.hovered = null;
            hover_cleared = true;
            self.emit(.mouse_leave, id, "", x, y, 0, 0, "", 0);
        }
        const wl = self.state.within_len;
        if (std.mem.indexOfScalar(reg.NodeId, self.state.within[0..wl], id)) |w| {
            std.mem.copyForwards(reg.NodeId, self.state.within[w .. wl - 1], self.state.within[w + 1 .. wl]);
            self.state.within_len = wl - 1;
            hover_cleared = true;
            self.emit(.mouse_leave, id, "", x, y, 0, 0, "", 0);
        }
        var i: usize = 0;
        while (i < self.state.pressed_len) : (i += 1) {
            if (self.state.pressed[i] != id) continue;
            self.state.pressed_len -= 1;
            self.state.pressed[i] = self.state.pressed[self.state.pressed_len];
            self.emit(.mouse_up, id, "", x, y, 0, 0, "", 0);
            break;
        }
        return hover_cleared;
    }
};
