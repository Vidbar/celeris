//! Event routing for the component model.
//!
//! Widgets used to receive events through a vtable `handleEvent` plus a brittle
//! `std.mem.indexOf` substring scan of the JSON payload. Components instead
//! register a handler keyed by the action id they already attach to a node
//! (`clickable`/`hoverable`/`focusable` modifiers). The host callback forwards
//! every engine event to `EventRouter.dispatch`, which extracts the payload's
//! `id` and invokes the handlers registered for exactly that id.
//!
//! A handler typically just writes a Signal (hover/press/value); the existing
//! signal → PropertyStore binding then updates only what changed — no widget
//! re-render for a hover.

const std = @import("std");
const core_events = @import("../core/events.zig");

/// Milliseconds between "tick" events. THE single source of truth for the tick
/// cadence: `c_api.zig`'s event loop emits a tick every `TICK_MS` (its `should_tick`
/// check) and every widget that counts ticks must derive its counts from this, via
/// `ticksForMs`, rather than from an assumed frame rate.
///
/// A tick is deliberately coarse — it drives the caret blink and the hot-reload
/// poll, not animation. Per-frame motion belongs in `AnimationEngine`.
pub const TICK_MS: u32 = 500;

/// Re-exported so widgets (Menu, Dialog) can write `events.FocusOrigin` without
/// a second import of `core/events.zig` — see its doc-comment for the focus-visible
/// focus-visible design.
pub const FocusOrigin = core_events.FocusOrigin;

/// Tick count that covers at least `ms` of wall time (minimum 1, so a duration
/// shorter than one tick still gets a tick). Use this instead of hand-rolling
/// `ms * SOME_FPS / 1000`.
pub fn ticksForMs(ms: u32) u32 {
    return @max(1, (ms + TICK_MS - 1) / TICK_MS);
}

/// A routed UI event delivered to a handler. Fields are typed — handlers read
/// `x`/`y`/`key_code`/`scroll_delta`/`text` directly. Filled from a structured
/// `CelerisEvent` (`dispatchEvent`, the live path) or, in tests, by parsing a
/// `(name, json)` pair (`dispatch`).
pub const Event = struct {
    /// Engine event name: "click", "mouse_enter", "mouse_leave", "mouse_down",
    /// "mouse_up", "focus", "blur", "char_input", "scroll", ...
    name: []const u8,
    /// The action id the event targets (the modifier id on the node).
    id: []const u8,
    x: f32 = 0,
    y: f32 = 0,
    key_code: u32 = 0,
    scroll_delta: f32 = 0,
    /// char_input / IME composed text (UTF-8).
    text: []const u8 = "",
    /// Keyboard modifiers held during the event.
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    /// Registry id of the target node (0 = none/global). The live path fills this
    /// from `CelerisEvent.node_id`; it drives per-node handler routing.
    node_id: u32 = 0,
};

/// A per-node typed event handler. Replaces the string action-id + separate
/// `router.on(...)` wiring as the user-facing API: declarative props like
/// `.on_click = ctx.handler(self, onClick)` produce one of these and the builder
/// auto-registers it against the node's id. `ptr` is the payload (usually the
/// owning component `*Self`, or null for `void`).
pub const Handler = struct {
    ptr: ?*anyopaque,
    call: *const fn (?*anyopaque, Event) void,
};

/// The event kinds a node handler can be registered for. Mapped from engine event
/// names by `kindFromName`. `value_changed` is emitted by widgets internally (not
/// by the OS), so it has no name mapping.
pub const EventKind = enum {
    click,
    right_click,
    mouse_enter,
    mouse_leave,
    mouse_down,
    mouse_up,
    key_down,
    focus,
    blur,
    value_changed,
    drop,
    scroll,
    /// Horizontal scroll — `scroll_delta` carries the horizontal notches
    /// (positive = right); from a tilt wheel, touchpad, or Shift+wheel.
    scroll_h,
    char_input,
    text_composition,
    text_commit,
    double_click,
};

/// Maps an engine event name to the `EventKind` used for node-handler lookup, or
/// null for names that don't target a node handler (tick, mouse_move…). Text
/// events (char_input / text_composition / text_commit) target the focused node;
/// double_click targets the hit node — the engine emits node_id for all of them.
pub fn kindFromName(name: []const u8) ?EventKind {
    const map = .{
        .{ "click", EventKind.click },
        .{ "right_mouse_down", EventKind.right_click },
        .{ "mouse_enter", EventKind.mouse_enter },
        .{ "mouse_leave", EventKind.mouse_leave },
        .{ "mouse_down", EventKind.mouse_down },
        .{ "mouse_up", EventKind.mouse_up },
        .{ "key_down", EventKind.key_down },
        .{ "focus", EventKind.focus },
        .{ "blur", EventKind.blur },
        .{ "drop", EventKind.drop },
        .{ "scroll", EventKind.scroll },
        .{ "scroll_h", EventKind.scroll_h },
        .{ "char_input", EventKind.char_input },
        .{ "text_composition", EventKind.text_composition },
        .{ "text_commit", EventKind.text_commit },
        .{ "double_click", EventKind.double_click },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, name, m[0])) return m[1];
    }
    return null;
}

/// Extracts the string value of the top-level `"id"` field from a payload like
/// `{"id":"save_btn","x":1.0}`. Returns null if absent. Note: the engine emits
/// ids drawn from a restricted charset (no quotes), so a plain scan is exact.
pub fn extractId(payload: []const u8) ?[]const u8 {
    const key = "\"id\":\"";
    const start = std.mem.indexOf(u8, payload, key) orelse return null;
    const vstart = start + key.len;
    const vend = std.mem.indexOfScalarPos(u8, payload, vstart, '"') orelse return null;
    return payload[vstart..vend];
}

/// Extracts a JSON number field like `"key_code":65` from a flat payload.
pub fn extractF32(payload: []const u8, comptime field: []const u8) ?f32 {
    const key = "\"" ++ field ++ "\":";
    const start = std.mem.indexOf(u8, payload, key) orelse return null;
    var i = start + key.len;
    const begin = i;
    while (i < payload.len) : (i += 1) {
        const c = payload[i];
        if (c == ',' or c == '}') break;
    }
    return std.fmt.parseFloat(f32, std.mem.trim(u8, payload[begin..i], " ")) catch null;
}

// ── Accelerators ─────────────────────────────────────────────────────────
//
// Maps keyboard chords (Ctrl/Shift/Alt + key) directly to a `Handler`. Installed
// on the router via `setAccelerators`, the table is consulted on every
// `key_down` BEFORE focus routing: a match calls the handler (synthesizing a
// "click" Event, the same shape a menu item emits) and consumes the event — the
// focused node never sees it. Mnemonics (Alt+letter menu opening) are out of
// scope. (Moved here from menu.zig, which re-exports these names.)

pub const Accelerator = struct {
    key_code: u32,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    handler: Handler,
};

pub const Accelerators = struct {
    list: std.array_list.Managed(Accelerator),

    pub fn init(allocator: std.mem.Allocator) Accelerators {
        return .{ .list = std.array_list.Managed(Accelerator).init(allocator) };
    }
    pub fn deinit(self: *Accelerators) void {
        self.list.deinit();
    }
    pub fn add(self: *Accelerators, acc: Accelerator) !void {
        try self.list.append(acc);
    }
    /// Returns the handler bound to this chord, or null. First match wins.
    pub fn match(self: *Accelerators, key_code: u32, ctrl: bool, shift: bool, alt: bool) ?Handler {
        for (self.list.items) |a| {
            if (a.key_code == key_code and a.ctrl == ctrl and a.shift == shift and a.alt == alt) {
                return a.handler;
            }
        }
        return null;
    }
};

pub const EventRouter = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayListUnmanaged(Entry) = .empty,
    tick_handlers: std.ArrayListUnmanaged(TickEntry) = .empty,
    global_handlers: std.ArrayListUnmanaged(GlobalEntry) = .empty,
    /// Per-node typed handlers, keyed by (node id, kind). Rewritten in place
    /// on rebuild (no duplicates) and pruned when a node is removed via the registry
    /// node-removed hook.
    node_handlers: std.ArrayListUnmanaged(NodeEntry) = .empty,
    /// Accelerator table consulted on key_down before focus routing.
    /// Borrowed — the host owns it and must outlive the router (or unset it).
    accelerators: ?*Accelerators = null,
    /// Observers invoked on every routed event regardless of target node/id — a
    /// side channel that never consumes the event, so normal routing always
    /// proceeds after (the tooltip host's hover/press/scroll dwell tracking, an
    /// app-level focus counter). Keyed by owner node like the other broadcast
    /// channels below — see `NodeEntry`'s doc comment for the shared contract.
    observers: std.ArrayListUnmanaged(GlobalEntry) = .empty,

    /// Registration is replace-in-place per `(node, kind)` — a rebuild re-applies
    /// the same props, so it overwrites rather than duplicates — and pruned when
    /// `node` is removed via the registry's node-removed hook (`nodeRemovedListener`
    /// → `removeNodeHandlers`). `TickEntry`/`GlobalEntry` share this exact contract,
    /// keyed by `owner` instead of `(node, kind)` (they broadcast to every
    /// registered owner rather than picking one by kind).
    const NodeEntry = struct {
        node: u32,
        kind: EventKind,
        h: Handler,
    };

    const Entry = struct {
        /// Borrowed action id — must outlive the router (action ids are normally
        /// string literals or owned by the component being routed).
        id: []const u8,
        ctx: *anyopaque,
        call: *const fn (*anyopaque, Event) void,
    };

    /// A handler for id-less events (currently "tick"), e.g. caret blink. `owner`
    /// is the registering component's own node id: like `NodeEntry`, registration
    /// replaces in place per owner (idempotent across rebuilds) and is pruned
    /// automatically when `owner` is removed — see `removeNodeHandlers`.
    const TickEntry = struct {
        owner: u32,
        ctx: *anyopaque,
        call: *const fn (*anyopaque) void,
    };

    /// A handler for id-less pointer events that aren't "tick" — chiefly the
    /// engine's global "mouse_move"/"mouse_up", which carry no target id (so they
    /// can't be id-routed). Used for drag-follow (e.g. a SplitPane sash) and,
    /// doubling as `observers`' entry type, for the observer channel above. The
    /// handler switches on `ev.name`. Same owner-keyed contract as `TickEntry`.
    const GlobalEntry = struct {
        owner: u32,
        ctx: *anyopaque,
        call: *const fn (*anyopaque, Event) void,
    };

    pub fn init(allocator: std.mem.Allocator) EventRouter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EventRouter) void {
        self.handlers.deinit(self.allocator);
        self.tick_handlers.deinit(self.allocator);
        self.global_handlers.deinit(self.allocator);
        self.node_handlers.deinit(self.allocator);
        self.observers.deinit(self.allocator);
    }

    /// Drops all registrations (e.g. before a full rebuild re-registers them).
    pub fn clear(self: *EventRouter) void {
        self.handlers.clearRetainingCapacity();
        self.tick_handlers.clearRetainingCapacity();
        self.global_handlers.clearRetainingCapacity();
        self.node_handlers.clearRetainingCapacity();
        self.observers.clearRetainingCapacity();
    }

    /// Registers (or replaces, for the same `ctx`) an observer that sees every
    /// routed event regardless of target node/id (the tooltip host, an app-level
    /// focus counter). `owner` is the registering component's own node id — call
    /// unconditionally from `build()` every time, not just on first mount; see
    /// `onNode`'s doc comment for why replace-in-place makes that safe.
    pub fn onObserver(self: *EventRouter, owner: u32, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) void) !void {
        try registerOwned(GlobalEntry, self.allocator, &self.observers, owner, ctx, ObserverWrap(@TypeOf(ctx), handler).call);
    }
    fn ObserverWrap(comptime Ctx: type, comptime handler: anytype) type {
        return struct {
            fn call(erased: *anyopaque, ev: Event) void {
                handler(@as(Ctx, @ptrCast(@alignCast(erased))), ev);
            }
        };
    }

    /// Registers (or replaces) the handler for `(node, kind)`. Replacing in place is
    /// what keeps the table from growing across rebuilds — a build re-applies the
    /// same props, so the same (node, kind) pair is overwritten, not duplicated.
    pub fn onNode(self: *EventRouter, node: u32, kind: EventKind, h: Handler) !void {
        for (self.node_handlers.items) |*e| {
            if (e.node == node and e.kind == kind) {
                e.h = h;
                return;
            }
        }
        try self.node_handlers.append(self.allocator, .{ .node = node, .kind = kind, .h = h });
    }

    /// Drops every handler owned by `node`, across every owner-keyed channel:
    /// `node_handlers`, `tick_handlers`, `global_handlers`, and `observers`. Wired
    /// to the registry's node-removed hook so a reconciled-away node — whether it
    /// was a plain clickable/hoverable target or a widget's caret-blink/drag-follow/
    /// observer registration — leaves nothing dangling, with no per-widget
    /// `onUnmount` bookkeeping required.
    pub fn removeNodeHandlers(self: *EventRouter, node: u32) void {
        var i: usize = 0;
        while (i < self.node_handlers.items.len) {
            if (self.node_handlers.items[i].node == node) {
                _ = self.node_handlers.swapRemove(i);
            } else {
                i += 1;
            }
        }
        i = 0;
        while (i < self.tick_handlers.items.len) {
            if (self.tick_handlers.items[i].owner == node) {
                _ = self.tick_handlers.swapRemove(i);
            } else {
                i += 1;
            }
        }
        i = 0;
        while (i < self.global_handlers.items.len) {
            if (self.global_handlers.items[i].owner == node) {
                _ = self.global_handlers.swapRemove(i);
            } else {
                i += 1;
            }
        }
        i = 0;
        while (i < self.observers.items.len) {
            if (self.observers.items[i].owner == node) {
                _ = self.observers.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Erased entry point for `UIRegistry.addNodeRemovedListener` — `ctx` is the
    /// `*EventRouter`.
    pub fn nodeRemovedListener(ctx: ?*anyopaque, id: u32) void {
        const self: *EventRouter = @ptrCast(@alignCast(ctx.?));
        self.removeNodeHandlers(id);
    }

    /// Installs (or, with null, removes) the accelerator table consulted on every
    /// key_down before focus routing. Borrowed; the host owns the table.
    pub fn setAccelerators(self: *EventRouter, acc: ?*Accelerators) void {
        self.accelerators = acc;
    }

    /// Registers (or replaces, for the same `owner`) a handler for id-less pointer
    /// events (mouse_move / mouse_up with no target id), delivered with the event
    /// name so the handler can switch. `owner` is the registering component's own
    /// node id — call unconditionally from `build()` every time; see `onNode`.
    pub fn onGlobal(self: *EventRouter, owner: u32, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) void) !void {
        try registerOwned(GlobalEntry, self.allocator, &self.global_handlers, owner, ctx, ObserverWrap(@TypeOf(ctx), handler).call);
    }

    /// Registers (or replaces, for the same `owner`) a handler for the periodic
    /// "tick" event (no id in payload). `owner` is the registering component's own
    /// node id — call unconditionally from `build()` every time; see `onNode`.
    ///
    /// IMPORTANT: a tick is a coarse ~`TICK_MS` (500ms) heartbeat, NOT a per-frame
    /// event — it exists for the caret blink and the hot-reload poll. Never derive a
    /// tick count from a frame rate: convert real durations with `TICK_MS` (see
    /// `ticksForMs`). Assuming 60fps here silently multiplied three widgets' timings
    /// by ~30x (a 4s toast lasted 2 minutes; a 500ms tooltip dwell took 15s).
    /// Anything needing smooth per-frame motion belongs in `AnimationEngine`, not here.
    pub fn onTick(self: *EventRouter, owner: u32, ctx: anytype, comptime handler: fn (@TypeOf(ctx)) void) !void {
        const Ctx = @TypeOf(ctx);
        const Wrap = struct {
            fn call(erased: *anyopaque) void {
                handler(@as(Ctx, @ptrCast(@alignCast(erased))));
            }
        };
        try registerOwned(TickEntry, self.allocator, &self.tick_handlers, owner, ctx, Wrap.call);
    }

    /// Shared replace-in-place registration for the owner-keyed broadcast channels
    /// (`TickEntry`/`GlobalEntry`, both `{ owner, ctx, call }`): overwrites the
    /// existing entry for `owner` if there is one, else appends. Keeps a rebuild's
    /// unconditional re-registration from growing these lists — the same
    /// invariant `onNode` keeps for `(node, kind)`.
    fn registerOwned(comptime Entry_: type, allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(Entry_), owner: u32, ctx: anytype, call: anytype) !void {
        for (list.items) |*e| {
            if (e.owner == owner) {
                e.ctx = ctx;
                e.call = call;
                return;
            }
        }
        try list.append(allocator, .{ .owner = owner, .ctx = ctx, .call = call });
    }

    /// Registers `handler` to receive events targeting `id`. `ctx` is passed back
    /// verbatim on each call.
    pub fn on(
        self: *EventRouter,
        id: []const u8,
        ctx: anytype,
        comptime handler: fn (@TypeOf(ctx), Event) void,
    ) !void {
        const Ctx = @TypeOf(ctx);
        const Wrap = struct {
            fn call(erased: *anyopaque, ev: Event) void {
                const typed: Ctx = @ptrCast(@alignCast(erased));
                handler(typed, ev);
            }
        };
        try self.handlers.append(self.allocator, .{
            .id = id,
            .ctx = ctx,
            .call = Wrap.call,
        });
    }

    /// Routes a fully-formed Event. tick → tick handlers; a matched accelerator →
    /// its handler directly; id-less (mouse_move / mouse_up) → global handlers;
    /// otherwise every exact-id handler. Observers see everything in between (see
    /// `onObserver`). Returns the number of handlers invoked.
    pub fn route(self: *EventRouter, ev: Event) usize {
        if (std.mem.eql(u8, ev.name, "tick")) {
            // Snapshot first: tick handlers are (re)registered from widget build()
            // (caret blink, toast timers, ...), so a handler that triggers a
            // rebuild can mutate/reallocate `tick_handlers` mid-loop — same UAF
            // class as the node-handler channel below.
            var matches = std.array_list.Managed(TickEntry).init(self.allocator);
            defer matches.deinit();
            for (self.tick_handlers.items) |h| matches.append(h) catch {};
            for (matches.items) |h| h.call(h.ctx);
            return matches.items.len;
        }
        // Accelerators: a matching chord calls the bound handler directly
        // (synthesizing a "click" Event, the shape a menu item emits) and
        // consumes the key_down — the focused node's handlers never run. Checked
        // before ALL routing (including the global channel) so it also works for
        // focus-less key_downs (node_id 0). A single handler call, not a list
        // iteration, so there's nothing to snapshot here.
        if (self.accelerators) |acc| {
            if (std.mem.eql(u8, ev.name, "key_down")) {
                if (acc.match(ev.key_code, ev.ctrl, ev.shift, ev.alt)) |h| {
                    h.call(h.ptr, .{ .name = "click", .id = "" });
                    return 1;
                }
            }
        }
        // Observers: see every event that reaches this point, as a side channel —
        // never consumes the event, so normal routing always proceeds below.
        // Snapshot first: like every other broadcast channel here, a handler can
        // trigger a rebuild that mutates `observers` mid-loop.
        if (self.observers.items.len > 0) {
            var matches = std.array_list.Managed(GlobalEntry).init(self.allocator);
            defer matches.deinit();
            for (self.observers.items) |h| matches.append(h) catch {};
            for (matches.items) |h| h.call(h.ctx, ev);
        }
        // A genuinely target-less event (mouse_move / mouse_up with no node) goes to
        // the global handlers. Node-targeted events carry node_id != 0, so this only
        // fires for the drag-follow style globals.
        if (ev.id.len == 0 and ev.node_id == 0) {
            // Same snapshot rationale: onGlobal is also registered from widget
            // build() (drag-follow sashes/thumbs), so this list can be mutated
            // mid-dispatch by a handler-triggered rebuild.
            var matches = std.array_list.Managed(GlobalEntry).init(self.allocator);
            defer matches.deinit();
            for (self.global_handlers.items) |h| matches.append(h) catch {};
            for (matches.items) |h| h.call(h.ctx, ev);
            return matches.items.len;
        }
        var invoked: usize = 0;
        // Per-node typed handlers: the primary channel. Keyed by the target
        // node id (from CelerisEvent.node_id), independent of the action-id string.
        //
        // Snapshot the matches before calling any of them: a handler commonly does
        // `someSignal.set(...)`, and effects run synchronously inside `Signal.set`
        // (core/signals.zig), so the tree can be rebuilt mid-dispatch. A rebuild
        // calls `router.clear()` then re-`onNode()`s every handler; if the new view
        // registers more handlers than `node_handlers`' retained capacity, `append`
        // reallocates the backing array out from under this `for` loop's `.items`
        // slice — a use-after-free once the list is large enough to trigger the
        // realloc (e.g. a long list view). Copying the matched `Handler`s (stable
        // {ptr, fn} pairs) into a scratch buffer first means the loop below no
        // longer touches `self.node_handlers` at all.
        if (ev.node_id != 0) {
            if (kindFromName(ev.name)) |kind| {
                var matches = std.array_list.Managed(Handler).init(self.allocator);
                defer matches.deinit();
                for (self.node_handlers.items) |h| {
                    if (h.node == ev.node_id and h.kind == kind) matches.append(h.h) catch {};
                }
                for (matches.items) |h| {
                    h.call(h.ptr, ev);
                    invoked += 1;
                }
            }
        }
        // String-id channel: exact-id interop registrations via `on(id, ...)`.
        // No framework widget uses this anymore (the last node-scoped consumer,
        // TreeList, migrated to `onNode`) — it's `router.on`'s own public surface
        // for low-level Zig hosts driving raw action-id boxes. Same
        // snapshot-before-call rationale as above: a handler can just as easily
        // drive a navigation that rebuilds `handlers` mid-loop.
        {
            var matches = std.array_list.Managed(Entry).init(self.allocator);
            defer matches.deinit();
            for (self.handlers.items) |h| {
                if (std.mem.eql(u8, h.id, ev.id)) matches.append(h) catch {};
            }
            for (matches.items) |h| {
                h.call(h.ctx, ev);
                invoked += 1;
            }
        }
        return invoked;
    }

    /// Routes a structured C-ABI event (the live path) — no JSON parsing.
    pub fn dispatchEvent(self: *EventRouter, ev: *const core_events.CelerisEvent) usize {
        const et: core_events.EventType = @enumFromInt(ev.event_type);
        return self.route(.{
            .name = et.name(),
            .id = std.mem.span(ev.action_id),
            .x = ev.x,
            .y = ev.y,
            .key_code = ev.key_code,
            .scroll_delta = ev.scroll_delta,
            .text = std.mem.span(ev.text),
            .ctrl = (ev.modifiers & core_events.MOD_CTRL) != 0,
            .shift = (ev.modifiers & core_events.MOD_SHIFT) != 0,
            .alt = (ev.modifiers & core_events.MOD_ALT) != 0,
            .node_id = ev.node_id,
        });
    }

    /// Test/authoring helper: routes a `(name, json)` pair by parsing typed fields
    /// out of the payload. The live engine path uses `dispatchEvent`; this exists
    /// for the concise JSON-literal call sites in the widget tests.
    pub fn dispatch(self: *EventRouter, name: []const u8, payload: []const u8) usize {
        return self.route(.{
            .name = name,
            .id = extractId(payload) orelse "",
            .x = extractF32(payload, "x") orelse 0,
            .y = extractF32(payload, "y") orelse 0,
            .key_code = if (extractF32(payload, "key_code")) |k| @intFromFloat(k) else 0,
            .scroll_delta = extractF32(payload, "delta") orelse 0,
            .node_id = if (extractF32(payload, "node_id")) |n| @intFromFloat(n) else 0,
        });
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "extractId pulls the id value" {
    try std.testing.expectEqualStrings("save_btn", extractId("{\"id\":\"save_btn\",\"x\":1.0}").?);
    try std.testing.expectEqualStrings("a", extractId("{\"id\":\"a\"}").?);
    try std.testing.expectEqual(@as(?[]const u8, null), extractId("{\"x\":1.0}"));
    try std.testing.expectEqual(@as(?[]const u8, null), extractId("garbage"));
}

test "EventRouter dispatches to matching id only" {
    const a = std.testing.allocator;
    var router = EventRouter.init(a);
    defer router.deinit();

    const Sink = struct {
        var btn_events: u32 = 0;
        var other_events: u32 = 0;
        var last_name_buf: [32]u8 = undefined;
        var last_name_len: usize = 0;
        which: u8,
        fn onBtn(self: *@This(), ev: Event) void {
            _ = self;
            btn_events += 1;
            std.mem.copyForwards(u8, &last_name_buf, ev.name);
            last_name_len = ev.name.len;
        }
        fn onOther(self: *@This(), ev: Event) void {
            _ = self;
            _ = ev;
            other_events += 1;
        }
    };
    Sink.btn_events = 0;
    Sink.other_events = 0;
    var s1 = Sink{ .which = 1 };
    var s2 = Sink{ .which = 2 };

    try router.on("btn", &s1, Sink.onBtn);
    try router.on("other", &s2, Sink.onOther);

    // Event for "btn" → only btn handler fires.
    try std.testing.expectEqual(@as(usize, 1), router.dispatch("click", "{\"id\":\"btn\",\"x\":2.0}"));
    try std.testing.expectEqual(@as(u32, 1), Sink.btn_events);
    try std.testing.expectEqual(@as(u32, 0), Sink.other_events);
    try std.testing.expectEqualStrings("click", Sink.last_name_buf[0..Sink.last_name_len]);

    // Unknown id → nobody fires.
    try std.testing.expectEqual(@as(usize, 0), router.dispatch("click", "{\"id\":\"ghost\"}"));

    // clear() removes registrations.
    router.clear();
    try std.testing.expectEqual(@as(usize, 0), router.dispatch("click", "{\"id\":\"btn\"}"));
}

test "EventRouter — onNode routes by (node,kind), replaces in place, prunes on remove" {
    const a = std.testing.allocator;
    var router = EventRouter.init(a);
    defer router.deinit();

    const Sink = struct {
        var clicks: u32 = 0;
        var enters: u32 = 0;
        fn onClick(_: ?*anyopaque, _: Event) void {
            clicks += 1;
        }
        fn onEnter(_: ?*anyopaque, _: Event) void {
            enters += 1;
        }
    };
    Sink.clicks = 0;
    Sink.enters = 0;

    try router.onNode(5, .click, .{ .ptr = null, .call = Sink.onClick });
    try router.onNode(5, .mouse_enter, .{ .ptr = null, .call = Sink.onEnter });
    try std.testing.expectEqual(@as(usize, 2), router.node_handlers.items.len);

    // Re-registering the same (node,kind) replaces, not appends.
    try router.onNode(5, .click, .{ .ptr = null, .call = Sink.onClick });
    try std.testing.expectEqual(@as(usize, 2), router.node_handlers.items.len);

    // A click on node 5 hits only the click handler; the kind must match.
    _ = router.route(.{ .name = "click", .id = "n5", .node_id = 5 });
    try std.testing.expectEqual(@as(u32, 1), Sink.clicks);
    try std.testing.expectEqual(@as(u32, 0), Sink.enters);

    // Removing the node drops every handler bound to it.
    router.removeNodeHandlers(5);
    try std.testing.expectEqual(@as(usize, 0), router.node_handlers.items.len);
    _ = router.route(.{ .name = "click", .id = "n5", .node_id = 5 });
    try std.testing.expectEqual(@as(u32, 1), Sink.clicks); // unchanged
}

test "EventRouter: scroll_h routes by node with the horizontal delta" {
    const a = std.testing.allocator;
    var router = EventRouter.init(a);
    defer router.deinit();

    const Sink = struct {
        var dx: f32 = 0;
        var vertical: u32 = 0;
        fn onScrollH(_: ?*anyopaque, ev: Event) void {
            dx = ev.scroll_delta;
        }
        fn onScroll(_: ?*anyopaque, _: Event) void {
            vertical += 1;
        }
    };
    Sink.dx = 0;
    Sink.vertical = 0;

    try router.onNode(7, .scroll_h, .{ .ptr = null, .call = Sink.onScrollH });
    try router.onNode(7, .scroll, .{ .ptr = null, .call = Sink.onScroll });

    // Horizontal hits only the scroll_h handler, carrying the notches.
    _ = router.route(.{ .name = "scroll_h", .id = "n7", .node_id = 7, .scroll_delta = 3.0 });
    try std.testing.expectEqual(@as(f32, 3.0), Sink.dx);
    try std.testing.expectEqual(@as(u32, 0), Sink.vertical);

    // Vertical stays on its own kind.
    _ = router.route(.{ .name = "scroll", .id = "n7", .node_id = 7, .scroll_delta = -1.0 });
    try std.testing.expectEqual(@as(u32, 1), Sink.vertical);
    try std.testing.expectEqual(@as(f32, 3.0), Sink.dx); // unchanged
}

test "EventRouter: a matched accelerator fires the action and consumes the key_down" {
    const a = std.testing.allocator;
    var router = EventRouter.init(a);
    defer router.deinit();

    const Sink = struct {
        var saves: u32 = 0;
        var node_keys: u32 = 0;
        var last_name_buf: [16]u8 = undefined;
        var last_name_len: usize = 0;
        fn onSave(erased: ?*anyopaque, ev: Event) void {
            _ = erased;
            saves += 1;
            std.mem.copyForwards(u8, &last_name_buf, ev.name);
            last_name_len = ev.name.len;
        }
        fn onNodeKey(_: ?*anyopaque, _: Event) void {
            node_keys += 1;
        }
    };
    Sink.saves = 0;
    Sink.node_keys = 0;

    var accels = Accelerators.init(a);
    defer accels.deinit();
    try accels.add(.{ .key_code = 'S', .ctrl = true, .handler = .{ .ptr = null, .call = Sink.onSave } });
    router.setAccelerators(&accels);

    // Node 7 plays the focused widget: it has its own key_down handler.
    try router.onNode(7, .key_down, .{ .ptr = null, .call = Sink.onNodeKey });

    // Ctrl+S → the accelerator fires its handler (as a click) and the focused
    // node does NOT receive the key_down.
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = 7, .key_code = 'S', .ctrl = true });
    try std.testing.expectEqual(@as(u32, 1), Sink.saves);
    try std.testing.expectEqual(@as(u32, 0), Sink.node_keys);
    try std.testing.expectEqualStrings("click", Sink.last_name_buf[0..Sink.last_name_len]);

    // A non-matching chord passes through to the focused node as usual.
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = 7, .key_code = 'S' });
    try std.testing.expectEqual(@as(u32, 1), Sink.saves);
    try std.testing.expectEqual(@as(u32, 1), Sink.node_keys);

    // Unsetting the table restores plain routing for the chord too.
    router.setAccelerators(null);
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = 7, .key_code = 'S', .ctrl = true });
    try std.testing.expectEqual(@as(u32, 1), Sink.saves);
    try std.testing.expectEqual(@as(u32, 2), Sink.node_keys);
}

test "EventRouter — multiple handlers for the same id all fire" {
    const a = std.testing.allocator;
    var router = EventRouter.init(a);
    defer router.deinit();

    const Counter = struct {
        var n: u32 = 0;
        fn on(self: *@This(), ev: Event) void {
            _ = self;
            _ = ev;
            n += 1;
        }
    };
    Counter.n = 0;
    var c = Counter{};
    try router.on("x", &c, Counter.on);
    try router.on("x", &c, Counter.on);
    try std.testing.expectEqual(@as(usize, 2), router.dispatch("click", "{\"id\":\"x\"}"));
    try std.testing.expectEqual(@as(u32, 2), Counter.n);
}

test "EventRouter — route() survives a handler that clears+regrows node_handlers past its capacity" {
    const a = std.testing.allocator;
    var router = EventRouter.init(a);
    defer router.deinit();

    const Noop = struct {
        fn call(_: ?*anyopaque, _: Event) void {}
    };
    const Rebuilder = struct {
        var fired: u32 = 0;
        fn onClick(erased: ?*anyopaque, _: Event) void {
            const self: *EventRouter = @ptrCast(@alignCast(erased.?));
            fired += 1;
            // Simulate the navigation-inside-dispatch scenario: a handler triggers
            // a full rebuild that clears and re-registers node_handlers with more
            // entries than the retained capacity, forcing `append` to reallocate
            // the backing array while `route()`'s outer loop is still iterating it.
            self.clear();
            var i: u32 = 0;
            while (i < 500) : (i += 1) {
                self.onNode(1000 + i, .click, .{ .ptr = null, .call = Noop.call }) catch unreachable;
            }
        }
    };
    Rebuilder.fired = 0;

    try router.onNode(5, .click, .{ .ptr = @ptrCast(&router), .call = Rebuilder.onClick });

    const invoked = router.route(.{ .name = "click", .id = "n5", .node_id = 5 });
    try std.testing.expectEqual(@as(usize, 1), invoked);
    try std.testing.expectEqual(@as(u32, 1), Rebuilder.fired);
    try std.testing.expectEqual(@as(usize, 500), router.node_handlers.items.len);
}
