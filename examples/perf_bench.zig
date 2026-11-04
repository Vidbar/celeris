//! perf_bench — headless build+layout throughput bench (no GPU, no window).
//!
//! Rebuilds a wide UI tree through the exact path a real app uses on every
//! reactive update — `rebuildUI` = builder pass + text shaping +
//! `LayoutEngine.solve` — and reports per-iteration cost at several tree sizes.
//! Unlike `tree_bench` (which needs a window and a human scrolling), this runs
//! unattended, so it is the one to use in CI or for a quick A/B.
//!
//!   zig build perf_bench -Doptimize=ReleaseFast
//!
//! Note it measures the FULL-rebuild worst case: no virtualization, every row
//! materialized. Real scroll/hover frames are far cheaper (see tree_bench).
//!
//! Built with -Dprofiling, it also prints a per-phase breakdown (build /
//! layout.solve / bake) at each size, using the zones rebuildUI now carries
//! (src/c_api.zig) — added specifically to attribute perf_bench's superlinear
//! us/node growth (1.38 -> 2.33 us/node from 1.2k to 20k nodes, first measured
//! without any phase breakdown) to a phase instead of guessing:
//!
//!   zig build perf_bench -Doptimize=ReleaseFast -Dprofiling
const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

const SIZES = [_]usize{ 250, 500, 1000, 2000, 4000 }; // rows per frame
const COLS: usize = 4; // text spans per row
const ITERS: usize = 20;

var g_rows: usize = 0;

var g_io: ?std.Io.Threaded = null;
fn nowNs() i64 {
    if (g_io == null) g_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    return @intCast(std.Io.Clock.now(.awake, g_io.?.io()).nanoseconds);
}

fn buildScene(b: *fw.builder.UIBuilder) anyerror!void {
    const root = try b.openBox();
    try b.width(root, 1280, .px);
    try b.height(root, 800, .px);
    try b.background(root, 24, 24, 27);

    var buf: [64]u8 = undefined;
    var r: usize = 0;
    while (r < g_rows) : (r += 1) {
        const row = try b.openBox();
        try b.flexRow(row);
        try b.height(row, 22, .px);
        try b.padding(row, 2, 4, 2, 4);
        if (r % 2 == 0) try b.background(row, 32, 32, 36);

        var col: usize = 0;
        while (col < COLS) : (col += 1) {
            const label = try std.fmt.bufPrint(&buf, "r{d}c{d}", .{ r, col });
            _ = try b.addText(label);
        }
        b.close();
    }
    b.close();
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

/// Scans a Chrome Trace JSON (one flat `{"name":...,"dur":...}` object per
/// line — profiler.flush's exact format) for the last `count` events named
/// `zone_name` and returns their median `dur` (already in microseconds; the
/// trace stores float µs directly, see profiler.zig's flush). Trailing-window
/// rather than a full parse: `flush` is cumulative (no reset API) and this is
/// called once per size, so "the last ITERS events of this name" is exactly
/// the size just measured, regardless of everything flushed before it.
fn medianZoneUs(allocator: std.mem.Allocator, trace_path: []const u8, zone_name: []const u8, count: usize) ?f64 {
    const text = std.Io.Dir.cwd().readFileAlloc(g_io.?.io(), trace_path, std.heap.page_allocator, .unlimited) catch return null;
    defer std.heap.page_allocator.free(text);

    var matches: std.ArrayList(f64) = .empty;
    defer matches.deinit(allocator);

    var name_buf: [128]u8 = undefined;
    const name_needle = std.fmt.bufPrint(&name_buf, "\"name\":\"{s}\"", .{zone_name}) catch return null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, name_needle) == null) continue;
        const dur_key = "\"dur\":";
        const dur_at = std.mem.indexOf(u8, line, dur_key) orelse continue;
        const rest = line[dur_at + dur_key.len ..];
        const end = std.mem.indexOfAny(u8, rest, "}") orelse rest.len;
        const dur = std.fmt.parseFloat(f64, rest[0..end]) catch continue;
        matches.append(allocator, dur) catch continue;
    }
    if (matches.items.len == 0) return null;

    const tail_start = if (matches.items.len > count) matches.items.len - count else 0;
    const tail = matches.items[tail_start..];
    std.mem.sort(f64, tail, {}, std.sort.asc(f64));
    return tail[tail.len / 2];
}

pub fn main() !void {
    const config = celeris.c_api.CelerisConfig{ .is_headless = true };
    const engine_id = celeris.c_api.celeris_create_engine(&config);
    if (engine_id <= 0) return error.EngineInitFailed;
    defer celeris.c_api.celeris_deinit(engine_id);

    const allocator = std.heap.page_allocator;

    // No-op in a non-`-Dprofiling` build (see profiler.zig): harmless to call
    // unconditionally rather than gating perf_bench itself on the build option.
    celeris.c_api.celeris_profiler_enable();

    std.debug.print("\nperf_bench — full rebuild (build + shape + solve), {d} iters/size\n", .{ITERS});
    std.debug.print("{s:>8} {s:>8} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{ "rows", "nodes", "cold us", "min us", "median us", "us/node" });

    const trace_path = "perf_bench_trace.json";
    var breakdowns: [SIZES.len]struct { rows: usize, build: ?f64, solve: ?f64, bake: ?f64 } = undefined;

    for (SIZES, 0..) |rows, size_idx| {
        g_rows = rows;
        var samples: [ITERS]u64 = undefined;
        var cold: u64 = 0;
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            const t0 = nowNs();
            try celeris.c_api.rebuildUI(engine_id, buildScene);
            samples[i] = @intCast(nowNs() - t0);
            if (i == 0) cold = samples[0];
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        const nodes = rows * (COLS + 1) + 1;
        const median = samples[ITERS / 2];
        std.debug.print("{d:>8} {d:>8} {d:>12.1} {d:>12.1} {d:>12.1} {d:>12.2}\n", .{
            rows,
            nodes,
            us(cold),
            us(samples[0]),
            us(median),
            us(median) / @as(f64, @floatFromInt(nodes)),
        });

        // Cumulative flush + trailing-window read (see medianZoneUs) — the
        // ITERS events just recorded for this size, whatever a non-profiling
        // build silently skipped (flush returns without writing).
        _ = celeris.c_api.celeris_profiler_flush(trace_path);
        breakdowns[size_idx] = .{
            .rows = rows,
            .build = medianZoneUs(allocator, trace_path, "rebuildUI.build", ITERS),
            .solve = medianZoneUs(allocator, trace_path, "layout.solve", ITERS),
            .bake = medianZoneUs(allocator, trace_path, "bake", ITERS),
        };
    }

    if (breakdowns[0].build != null) {
        std.debug.print("\nphase breakdown (median us; -Dprofiling build)\n", .{});
        std.debug.print("{s:>8} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{ "rows", "build", "layout.solve", "bake", "solve/build" });
        for (breakdowns) |bd| {
            const build_us = bd.build orelse 0;
            const solve_us = bd.solve orelse 0;
            const ratio: f64 = if (build_us > 0) solve_us / build_us else 0;
            std.debug.print("{d:>8} {d:>12.1} {d:>12.1} {d:>12.1} {d:>12.2}\n", .{
                bd.rows,
                build_us,
                solve_us,
                bd.bake orelse 0,
                ratio,
            });
        }
        std.Io.Dir.cwd().deleteFile(g_io.?.io(), trace_path) catch {};
    } else {
        std.debug.print("\n(no phase breakdown — rebuild with -Dprofiling to attribute build vs. layout.solve vs. bake)\n", .{});
    }
}
