const std = @import("std");
const events = @import("events.zig");
const c_api = @import("../c_api.zig");
const UIBuilder = @import("builder.zig").UIBuilder;

/// High-level Window abstraction that wraps the Celeris engine C-API.
/// This is the primary entry point for Zig framework users.
pub const Window = struct {
    allocator: std.mem.Allocator,
    engine_id: i32,
    router: events.EventRouter,

    pub fn init(allocator: std.mem.Allocator, config: *const c_api.CelerisWindowConfig) !*Window {
        const engine_id = c_api.celeris_create_window(config);
        if (engine_id < 0) {
            return error.EngineCreationFailed;
        }

        const self = try allocator.create(Window);
        self.* = .{
            .allocator = allocator,
            .engine_id = engine_id,
            .router = events.EventRouter.init(allocator),
        };

        // Track window before wiring the callback so the trampoline can find it.
        const slot: usize = @intCast(engine_id - 1);
        if (slot >= g_windows.len) {
            allocator.destroy(self);
            c_api.celeris_deinit(engine_id);
            return error.TooManyWindows;
        }
        g_windows[slot] = self;

        // Wire up the engine events to our router. `celeris_register_event_callback`
        // is per-engine, but the callback signature carries no engine_id — so we
        // register a distinct trampoline per engine slot, each with its slot index
        // baked in at comptime, and route only to that slot's window.
        c_api.celeris_register_event_callback(self.engine_id, event_trampolines[slot]);

        return self;
    }

    pub fn deinit(self: *Window) void {
        self.router.deinit();
        c_api.celeris_deinit(self.engine_id);
        const slot: usize = @intCast(self.engine_id - 1);
        if (slot < g_windows.len and g_windows[slot] == self) g_windows[slot] = null;
        self.allocator.destroy(self);
    }

    pub fn startLoop(self: *Window) i32 {
        _ = self;
        return c_api.celeris_start_loop();
    }

    pub fn rebuildUI(self: *Window, build_fn: *const fn (*UIBuilder) anyerror!void) !void {
        try c_api.rebuildUI(self.engine_id, build_fn);
    }

    // OS Window Controls
    pub fn startDrag(self: *Window) void {
        c_api.celeris_window_start_drag(self.engine_id);
    }

    pub fn close(self: *Window) void {
        c_api.celeris_window_close(self.engine_id);
    }

    pub fn minimize(self: *Window) void {
        c_api.celeris_window_minimize(self.engine_id);
    }

    pub fn maximize(self: *Window) void {
        c_api.celeris_window_maximize(self.engine_id);
    }

    pub fn isMaximized(self: *Window) bool {
        return c_api.celeris_window_is_maximized(self.engine_id) != 0;
    }
};

// Per-engine window tracking, indexed by (engine_id - 1). The engine assigns
// contiguous ids starting at 1, so this doubles as the trampoline slot index.
const MAX_WINDOWS = 16;
var g_windows: [MAX_WINDOWS]?*Window = [_]?*Window{null} ** MAX_WINDOWS;

const core_events = @import("../core/events.zig");
const CelerisEvent = core_events.CelerisEvent;

/// One C-ABI trampoline per engine slot, generated at comptime. Each closes over
/// its own `slot` so the shared callback signature (which carries no engine_id)
/// still routes the event to exactly the window that owns that engine.
const event_trampolines: [MAX_WINDOWS]core_events.StructuredEventCallback = blk: {
    var arr: [MAX_WINDOWS]core_events.StructuredEventCallback = undefined;
    for (0..MAX_WINDOWS) |i| {
        arr[i] = struct {
            const slot = i;
            fn callback(ev: *const CelerisEvent) callconv(.c) void {
                if (g_windows[slot]) |w| {
                    _ = w.router.dispatchEvent(ev);
                }
            }
        }.callback;
    }
    break :blk arr;
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Per-engine trampoline routes only to the owning window's router" {
    const a = std.testing.allocator;

    // Two headless windows sharing the global tracking table, in slots 0 and 1.
    var w1 = Window{ .allocator = a, .engine_id = 1, .router = events.EventRouter.init(a) };
    var w2 = Window{ .allocator = a, .engine_id = 2, .router = events.EventRouter.init(a) };
    defer w1.router.deinit();
    defer w2.router.deinit();

    g_windows[0] = &w1;
    g_windows[1] = &w2;
    defer {
        g_windows[0] = null;
        g_windows[1] = null;
    }

    const Sink = struct {
        var w1_hits: u32 = 0;
        var w2_hits: u32 = 0;
        fn onW1(_: ?*anyopaque, _: events.Event) void {
            w1_hits += 1;
        }
        fn onW2(_: ?*anyopaque, _: events.Event) void {
            w2_hits += 1;
        }
    };
    Sink.w1_hits = 0;
    Sink.w2_hits = 0;

    // Each router listens for a click on node 5.
    try w1.router.onNode(5, .click, .{ .ptr = null, .call = Sink.onW1 });
    try w2.router.onNode(5, .click, .{ .ptr = null, .call = Sink.onW2 });

    var ev = CelerisEvent{
        .event_type = @intFromEnum(core_events.EventType.click),
        .node_id = 5,
        .action_id = "n5",
        .x = 0,
        .y = 0,
        .key_code = 0,
        .scroll_delta = 0,
        .text = "",
        .modifiers = 0,
    };

    // The trampoline for engine 2 (slot 1) must reach only w2's router.
    event_trampolines[1](&ev);
    try std.testing.expectEqual(@as(u32, 0), Sink.w1_hits);
    try std.testing.expectEqual(@as(u32, 1), Sink.w2_hits);

    // And engine 1 (slot 0) only w1's router.
    event_trampolines[0](&ev);
    try std.testing.expectEqual(@as(u32, 1), Sink.w1_hits);
    try std.testing.expectEqual(@as(u32, 1), Sink.w2_hits);
}
