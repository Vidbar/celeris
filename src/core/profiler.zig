//! Zone profiler with Chrome Trace Event (JSON) export.
//!
//! Why this exists: the frame profiler baked into `c_api`/`wgpu_backend` reports
//! aggregate per-phase numbers for the *last* frame. This module records every
//! timed region as an individual event with a thread id and a precise begin/dur,
//! then serializes the lot to the Chrome Trace format. Drop the resulting `.json`
//! into <https://ui.perfetto.dev> (or `chrome://tracing`) and you get the same
//! flame chart / timeline you'd get from a browser performance snapshot: the hot
//! path, per-zone time, call counts, and nesting — for whatever we instrument.
//!
//! Two gates, so it costs nothing unless you ask for it:
//!   1. Comptime: `enabled` comes from the `-Dprofiling` build option. When the
//!      build wasn't compiled with profiling, every `zone()`/`end()` folds to a
//!      no-op and the recording machinery is dead-code-eliminated. Release builds
//!      pay zero.
//!   2. Runtime: even in a profiling build, zones do nothing until the host calls
//!      `enable()` (wired to the `CELERIS_TRACE` env var in `c_api`). So a
//!      profiling build still runs at full speed for normal use.
//!
//! Usage in a hot path:
//!     const prof = @import("../core/profiler.zig");
//!     const z = prof.zone(@src()); defer z.end();          // labelled by fn name
//!     const z2 = prof.zoneNamed("layout.solve"); defer z2.end(); // custom label
//!
//! Threading: each thread owns a buffer (no lock on the hot path); buffers are
//! registered into a global list under a mutex only the first time a thread emits.

const std = @import("std");
const build_options = @import("build_options");

/// Compile-time master switch. False ⇒ the whole profiler is inert and elided.
pub const enabled = build_options.profiling;

// ── Internal state ─────────────────────────────────────────────────────────────
// All profiler storage uses the page allocator so it never touches the engine's
// allocators (and so a leak here can't be confused with an engine leak).
const Event = struct {
    name: []const u8, // points at a comptime string; never freed
    start_ns: i64,
    dur_ns: i64,
};

const ThreadBuffer = struct {
    tid: u64,
    events: std.ArrayListUnmanaged(Event) = .empty,
};

var g_active: bool = false;
var g_io: ?std.Io = null;
var g_mutex: std.atomic.Mutex = .unlocked;
var g_buffers: std.ArrayListUnmanaged(*ThreadBuffer) = .empty;

threadlocal var tl_buf: ?*ThreadBuffer = null;

fn lockMutex() void {
    while (!g_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn nowNs() i64 {
    const io = g_io orelse return 0;
    const ts = std.Io.Clock.now(.awake, io);
    return @intCast(ts.nanoseconds);
}

fn threadBuffer() *ThreadBuffer {
    if (tl_buf) |b| return b;
    const alloc = std.heap.page_allocator;
    const b = alloc.create(ThreadBuffer) catch unreachable;
    b.* = .{ .tid = std.Thread.getCurrentId() };
    lockMutex();
    defer g_mutex.unlock();
    g_buffers.append(alloc, b) catch unreachable;
    tl_buf = b;
    return b;
}

fn record(name: []const u8, start_ns: i64, dur_ns: i64) void {
    const b = threadBuffer();
    b.events.append(std.heap.page_allocator, .{
        .name = name,
        .start_ns = start_ns,
        .dur_ns = dur_ns,
    }) catch {}; // dropping a sample is preferable to crashing the app
}

// ── Public API ───────────────────────────────────────────────────────────────

/// A scoped timing region. Call `end()` (via `defer`) to record it.
pub const Zone = struct {
    name: []const u8 = "",
    start_ns: i64 = 0,

    pub inline fn end(self: Zone) void {
        if (comptime !enabled) return;
        if (!g_active) return;
        record(self.name, self.start_ns, nowNs() - self.start_ns);
    }
};

/// Open a zone labelled by the calling function name. `defer z.end();`.
pub inline fn zone(comptime src: std.builtin.SourceLocation) Zone {
    if (comptime !enabled) return .{};
    if (!g_active) return .{};
    return .{ .name = src.fn_name, .start_ns = nowNs() };
}

/// Open a zone with an explicit label (for distinguishing sub-phases of one fn).
pub inline fn zoneNamed(comptime name: []const u8) Zone {
    if (comptime !enabled) return .{};
    if (!g_active) return .{};
    return .{ .name = name, .start_ns = nowNs() };
}

/// Turn profiling on at runtime. `io` is reused for clock reads and the flush.
/// No-op in a non-profiling build.
pub fn enable(io: std.Io) void {
    if (comptime !enabled) return;
    g_io = io;
    g_active = true;
}

/// True if a profiling build has been switched on by the host.
pub fn isActive() bool {
    if (comptime !enabled) return false;
    return g_active;
}

/// Serialize every recorded event to the Chrome Trace Event JSON format and
/// write it to `path`. Timestamps are rebased so the trace starts near t=0.
/// No-op (returns without writing) in a non-profiling build or if never enabled.
pub fn flush(path: []const u8) !void {
    if (comptime !enabled) return;
    const io = g_io orelse return;

    lockMutex();
    defer g_mutex.unlock();

    // Rebase to the earliest start so Perfetto's timeline begins at ~0.
    var base_ns: i64 = std.math.maxInt(i64);
    var total: usize = 0;
    for (g_buffers.items) |b| {
        total += b.events.items.len;
        for (b.events.items) |e| {
            if (e.start_ns < base_ns) base_ns = e.start_ns;
        }
    }
    if (total == 0) {
        std.debug.print("[Celeris] profiler: nothing recorded yet (is recording armed? interact to produce frames, then dump again)\n", .{});
        return;
    }

    const alloc = std.heap.page_allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    try out.appendSlice(alloc, "{\"traceEvents\":[\n");
    var first = true;
    for (g_buffers.items) |b| {
        for (b.events.items) |e| {
            if (!first) try out.appendSlice(alloc, ",\n");
            first = false;
            // ts/dur in microseconds (float keeps sub-µs precision). Zone names
            // are our own fn names / literals, so they need no JSON escaping.
            const ts_us = @as(f64, @floatFromInt(e.start_ns - base_ns)) / 1000.0;
            const dur_us = @as(f64, @floatFromInt(e.dur_ns)) / 1000.0;
            const line = try std.fmt.allocPrint(
                alloc,
                "{{\"name\":\"{s}\",\"cat\":\"celeris\",\"ph\":\"X\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"dur\":{d:.3}}}",
                .{ e.name, b.tid, ts_us, dur_us },
            );
            defer alloc.free(line);
            try out.appendSlice(alloc, line);
        }
    }
    try out.appendSlice(alloc, "\n]}\n");

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    std.debug.print("[Celeris] profiler: wrote {d} events to {s}\n", .{ total, path });
}

test "zone records and flush emits valid chrome trace json" {
    // Only meaningful in a -Dprofiling build; inert otherwise (run with
    // `zig build test -Dprofiling`).
    if (comptime !enabled) return;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    enable(io);

    {
        const z = zoneNamed("test.zone");
        defer z.end();
        var acc: u64 = 0;
        for (0..1000) |i| acc +%= i; // a little work so dur > 0
        std.mem.doNotOptimizeAway(acc);
    }

    const path = "celeris_prof_selftest.json";
    try flush(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(data);

    try std.testing.expect(std.mem.indexOf(u8, data, "traceEvents") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "test.zone") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"ph\":\"X\"") != null);
}
