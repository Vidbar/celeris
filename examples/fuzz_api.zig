//! fuzz_api — adversarial smoke test for the C-API boundary (headless).
//!
//! The C API is the only surface a non-Zig host touches, so it is the one that
//! must survive garbage: invalid handles, out-of-range node ids, malformed
//! UTF-8, NaN/Inf geometry, cycles, and use-after-free of engine slots. Every
//! case below is expected to return an error code — not to crash, hang, or read
//! out of bounds.
//!
//!   zig build fuzz_api -Doptimize=ReleaseSafe
//!
//! Run it under ReleaseSafe (not ReleaseFast) so bounds/overflow checks are live.
const std = @import("std");
const celeris = @import("celeris");
const c_api = celeris.c_api;
const fw = celeris.framework;

fn step(name: []const u8) void {
    std.debug.print("  [case] {s}\n", .{name});
}

fn emptyUI(b: *fw.builder.UIBuilder) anyerror!void {
    const root = try b.openBox();
    try b.width(root, 800, .px);
    try b.height(root, 600, .px);
    b.close();
}

/// Nests boxes far deeper than MAX_TREE_DEPTH (256) to exercise the builder's
/// bounded parent stack and the solver's depth guard, then over-closes.
fn deepUI(b: *fw.builder.UIBuilder) anyerror!void {
    const root = try b.openBox();
    try b.width(root, 800, .px);
    try b.height(root, 600, .px);
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const n = b.openBox() catch break;
        b.padding(n, 1, 1, 1, 1) catch break;
        _ = b.addText("x") catch break;
    }
    var j: usize = 0;
    while (j < 6000) : (j += 1) b.close(); // close() on an empty stack must not underflow
}

pub fn main() !void {
    const config = c_api.CelerisConfig{ .is_headless = true };
    const eid = c_api.celeris_create_engine(&config);
    if (eid <= 0) return error.EngineInitFailed;

    std.debug.print("\nfuzz_api: hammering the C-API boundary\n", .{});

    step("invalid engine ids");
    for ([_]i32{ -1, 0, 999, std.math.maxInt(i32), std.math.minInt(i32) }) |bad| {
        _ = c_api.celeris_node_create(bad, 0);
        _ = c_api.celeris_node_append_child(bad, 1, 2);
        _ = c_api.celeris_node_remove(bad, 1);
        _ = c_api.celeris_dispatch_mouse_click(bad, 10, 10);
        _ = c_api.celeris_signal_get_f32(bad, 0);
        c_api.celeris_request_redraw(bad);
        c_api.celeris_deinit(bad);
    }

    step("baseline UI");
    try c_api.rebuildUI(eid, emptyUI);

    step("out-of-range node ids");
    const wild = [_]u32{ 0, 1, 12345, 0xFFFF_FFFE, 0xFFFF_FFFF, std.math.maxInt(u32) / 2 };
    for (wild) |a| {
        for (wild) |bn| {
            _ = c_api.celeris_node_append_child(eid, a, bn);
            _ = c_api.celeris_node_insert_before(eid, a, bn, 0xFFFF_FFFF);
            _ = c_api.celeris_node_insert_before(eid, a, bn, bn);
        }
        _ = c_api.celeris_node_remove(eid, a);
        _ = c_api.celeris_node_set_text_content(eid, a, "hi");
        _ = c_api.celeris_dispatch_set_text(eid, a, "hi", 2);
    }

    step("self-cycle and ancestor-cycle attempts");
    const p = c_api.celeris_node_create(eid, 0);
    const c1 = c_api.celeris_node_create(eid, 0);
    const c2 = c_api.celeris_node_create(eid, 0);
    _ = c_api.celeris_node_append_child(eid, @intCast(p), @intCast(c1));
    _ = c_api.celeris_node_append_child(eid, @intCast(c1), @intCast(c2));
    _ = c_api.celeris_node_append_child(eid, @intCast(p), @intCast(p)); // self
    _ = c_api.celeris_node_append_child(eid, @intCast(c2), @intCast(p)); // ancestor
    _ = c_api.celeris_node_insert_before(eid, @intCast(c2), @intCast(p), @intCast(c2));
    _ = c_api.celeris_node_insert_before(eid, @intCast(p), @intCast(p), @intCast(c1));
    var bx: f32 = 0;
    var by: f32 = 0;
    var bw: f32 = 0;
    var bh: f32 = 0;
    _ = c_api.celeris_node_get_bounds(eid, p, &bx, &by, &bw, &bh);
    c_api.celeris_free_string(eid, c_api.celeris_get_dom_json(eid)); // walks the tree — hangs if a cycle got in
    c_api.celeris_free_string(eid, c_api.celeris_get_accessibility_json(eid));

    step("malformed text (invalid UTF-8, lone surrogates, NUL, truncated)");
    const nasty = [_][]const u8{
        "\xff\xfe\xfd",
        "\xed\xa0\x80", // lone surrogate D800 (CESU-8)
        "\xf4\x90\x80\x80", // beyond U+10FFFF
        "\xc0\x80", // overlong NUL
        "a\x00b",
        "\xe2\x82", // truncated 3-byte sequence
        "\xf0\x9f\x98", // truncated emoji
        "\r\n\t\x0b\x0c",
        "\u{202e}reversed\u{202d}", // bidi override
        "\u{0301}\u{0301}\u{0301}combining",
    };
    var xo: f32 = 0;
    var yo: f32 = 0;
    var lho: f32 = 0;
    for (nasty) |s| {
        _ = c_api.celeris_measure_text(eid, s.ptr, s.len, 14);
        _ = c_api.celeris_measure_text(eid, s.ptr, s.len, 0);
        _ = c_api.celeris_get_char_index_at(eid, s.ptr, s.len, 14, 100, 5, 5);
        // caret indices deliberately past the end and mid-codepoint
        for ([_]usize{ 0, 1, 2, 3, s.len, s.len + 1, s.len * 4, std.math.maxInt(u32) }) |ci| {
            _ = c_api.celeris_get_caret_metrics(eid, s.ptr, s.len, 14, 100, ci, &xo, &yo, &lho);
        }
        _ = c_api.celeris_dispatch_set_text(eid, @intCast(c1), s.ptr, s.len);
    }

    step("degenerate floats (NaN/Inf/negative) into text + input");
    const floats = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), -1, 0, 1e30, -1e30 };
    for (floats) |f| {
        _ = c_api.celeris_measure_text(eid, "hello world", 11, f);
        _ = c_api.celeris_get_char_index_at(eid, "hello world", 11, 14, f, f, f);
        _ = c_api.celeris_get_caret_metrics(eid, "hello world", 11, f, f, 3, &xo, &yo, &lho);
        _ = c_api.celeris_dispatch_mouse_click(eid, f, f);
        _ = c_api.celeris_dispatch_scroll_event(eid, f, f, f);
        _ = c_api.celeris_dispatch_drop(eid, f, f, "dropped");
    }

    step("null / zero-length text pointers");
    _ = c_api.celeris_measure_text(eid, null, 0, 14);
    _ = c_api.celeris_measure_text(eid, null, 999, 14);
    _ = c_api.celeris_dispatch_set_text(eid, @intCast(c1), null, 0);
    _ = c_api.celeris_dispatch_set_text(eid, @intCast(c1), null, 999);
    _ = c_api.celeris_get_caret_metrics(eid, null, 0, 14, 100, 5, &xo, &yo, &lho);

    step("bogus signal handles");
    const sig = c_api.celeris_signal_create(eid);
    for ([_]i32{ -1, -999, 0, 1, 4096, std.math.maxInt(i32) }) |h| {
        _ = c_api.celeris_signal_set_f32(eid, h, std.math.nan(f32));
        _ = c_api.celeris_signal_set_dimension(eid, h, std.math.inf(f32), 999);
        _ = c_api.celeris_signal_set_color(eid, h, 255, 0, 0, 99);
        _ = c_api.celeris_signal_get_f32(eid, h);
    }
    _ = c_api.celeris_signal_set_f32(eid, sig, 1);

    step("keyboard / focus-scope abuse");
    for ([_]u32{ 0, 1, 2, 7, 0xFFFF_FFFF }) |et| {
        for ([_]u32{ 0, 8, 9, 13, 27, 0xFFFF_FFFF }) |kc| {
            _ = c_api.celeris_dispatch_keyboard_event(eid, et, kc);
        }
    }
    for (wild) |n| _ = c_api.celeris_push_focus_scope(eid, n);
    var k: usize = 0;
    while (k < 64) : (k += 1) _ = c_api.celeris_pop_focus_scope(eid); // unbalanced pops

    step("tree deeper than MAX_TREE_DEPTH + unbalanced close()");
    try c_api.rebuildUI(eid, deepUI);
    c_api.celeris_free_string(eid, c_api.celeris_get_dom_json(eid));
    c_api.celeris_free_string(eid, c_api.celeris_get_accessibility_json(eid));
    _ = c_api.celeris_dispatch_mouse_click(eid, 5, 5);

    step("id recycling: create/remove churn must not resurrect dead state");
    var churn: usize = 0;
    while (churn < 500) : (churn += 1) {
        const n = c_api.celeris_node_create(eid, @intCast(churn % 2));
        if (n < 0) continue;
        _ = c_api.celeris_node_set_text_content(eid, @intCast(n), "recycled");
        _ = c_api.celeris_node_append_child(eid, 0, @intCast(n));
        _ = c_api.celeris_node_remove(eid, @intCast(n));
        _ = c_api.celeris_node_set_text_content(eid, @intCast(n), "after free"); // dead id
        _ = c_api.celeris_node_get_bounds(eid, n, &bx, &by, &bw, &bh);
    }

    step("remove the root, then keep driving the engine");
    _ = c_api.celeris_node_remove(eid, 0);
    _ = c_api.celeris_dispatch_mouse_click(eid, 10, 10);
    _ = c_api.celeris_dispatch_scroll_event(eid, 10, 10, -120);
    c_api.celeris_free_string(eid, c_api.celeris_get_dom_json(eid));
    c_api.celeris_free_string(eid, c_api.celeris_get_accessibility_json(eid));
    try c_api.rebuildUI(eid, emptyUI); // must recover

    step("devtools snapshot churn (arena-owned buffer, never host-freed)");
    var s: usize = 0;
    while (s < 200) : (s += 1) _ = c_api.celeris_get_devtools_snapshot(eid);

    step("clipboard round-trip with hostile text");
    for (nasty) |bad_text| {
        var z: [64]u8 = undefined;
        const n = @min(bad_text.len, z.len - 1);
        @memcpy(z[0..n], bad_text[0..n]);
        z[n] = 0;
        _ = c_api.celeris_clipboard_set_text(eid, &z);
    }
    _ = c_api.celeris_clipboard_set_text(eid, null);

    step("concurrent celeris_post_task producers against real engine mutation");
    {
        // Unlike dispatch.zig's TaskQueue tests (a synthetic counter, no
        // engine involved), this drives the actual production queue
        // (`c_api.getTaskQueue`, the same one `celeris_start_loop` drains
        // every iteration) with callbacks that call a real state-mutating
        // export — celeris_signal_set_f32 — so the UI-thread-affinity guard
        // (assertUiThread, added after the dangling-TextMeasure crash) sees
        // exactly the pattern it exists to allow: many worker threads only
        // ever calling celeris_post_task (which never touches engine state),
        // and every actual mutation running on drain, on this thread — the
        // one that created the engine and therefore owns it. A false-positive
        // panic here would mean the guard is too strict for legitimate use.
        const Ctx = struct {
            var eid_field: i32 = 0;
            var sig_field: i32 = 0;
            var done = std.atomic.Value(u32).init(0);
        };
        Ctx.eid_field = eid;
        Ctx.sig_field = c_api.celeris_signal_create(eid);
        Ctx.done.store(0, .monotonic);

        const producers = 6;
        const per_producer = 500;

        const Worker = struct {
            fn mutate(_: ?*anyopaque) callconv(.c) void {
                // Runs on drain, which only ever happens on the UI thread
                // below — never on the worker that pushed it.
                _ = c_api.celeris_signal_set_f32(Ctx.eid_field, Ctx.sig_field, 1.0);
                _ = Ctx.done.fetchAdd(1, .monotonic);
            }
            fn run() void {
                var i: usize = 0;
                while (i < per_producer) : (i += 1) {
                    c_api.celeris_post_task(&mutate, null);
                }
            }
        };

        var threads: [producers]std.Thread = undefined;
        for (&threads) |*t| t.* = std.Thread.spawn(.{}, Worker.run, .{}) catch continue;

        // Drain on this thread — the same one that created `eid` — exactly as
        // celeris_start_loop does each iteration, concurrently with the
        // workers still pushing.
        var spins: usize = 0;
        while (spins < 4000 and Ctx.done.load(.monotonic) < producers * per_producer) : (spins += 1) {
            c_api.getTaskQueue().drain();
        }
        for (threads) |t| t.join();
        c_api.getTaskQueue().drain(); // whatever landed after the last spin

        const expected: u32 = producers * per_producer;
        const got = Ctx.done.load(.monotonic);
        if (got != expected) {
            std.debug.print("fuzz_api: FAILED — concurrent post_task lost tasks: {d}/{d} ran\n", .{ got, expected });
            std.process.exit(1);
        }
    }

    step("multi-window/modal lifecycle: pool exhaustion, parent chains, cascade close");
    {
        // Pool exhaustion: 16 live engines is the cap (`eid` already holds one
        // slot). Create until the pool refuses, then confirm the refusal is a
        // clean -1, not a wraparound into a live slot.
        var created: [32]i32 = undefined;
        var n: usize = 0;
        while (n < created.len) : (n += 1) {
            var cfg = c_api.CelerisWindowConfig{
                .is_headless = true,
                .width = 100,
                .height = 100,
                .parent_engine_id = 0,
                .modal = false,
                .title = null,
            };
            const id = c_api.celeris_create_window(&cfg);
            created[n] = id;
            if (id < 0) break;
            _ = &cfg;
        }

        // Modal parent chain: A <- B <- C, three deep, then deinit the root
        // and confirm cascade close reaches C without a host tearing down
        // each level manually.
        var cfg_a = c_api.CelerisWindowConfig{ .is_headless = true, .width = 100, .height = 100, .parent_engine_id = 0, .modal = false, .title = null };
        const a = c_api.celeris_create_window(&cfg_a);
        if (a > 0) {
            var cfg_b = c_api.CelerisWindowConfig{ .is_headless = true, .width = 100, .height = 100, .parent_engine_id = a, .modal = true, .title = null };
            const bwin = c_api.celeris_create_window(&cfg_b);
            if (bwin > 0) {
                var cfg_c = c_api.CelerisWindowConfig{ .is_headless = true, .width = 100, .height = 100, .parent_engine_id = bwin, .modal = true, .title = null };
                const cwin = c_api.celeris_create_window(&cfg_c);
                _ = cwin;
            }
            c_api.celeris_deinit(a); // cascades through B and C
        }

        // A stale parent_engine_id (recycled/garbage/self/out-of-range) must be
        // rejected, not silently accepted.
        for (wild) |bad_parent| {
            var cfg = c_api.CelerisWindowConfig{
                .is_headless = true,
                .width = 100,
                .height = 100,
                .parent_engine_id = @bitCast(bad_parent),
                .modal = true,
                .title = null,
            };
            _ = c_api.celeris_create_window(&cfg);
        }

        // Clean up whatever the exhaustion loop actually created.
        for (created[0..n]) |id| {
            if (id > 0) c_api.celeris_deinit(id);
        }

        // Churn: rapid create/deinit of windows parented to the still-live
        // `eid` — the pattern an overlay bar or a tooltip-as-window would hit
        // continuously.
        var churn2: usize = 0;
        while (churn2 < 100) : (churn2 += 1) {
            var cfg = c_api.CelerisWindowConfig{ .is_headless = true, .width = 50, .height = 50, .parent_engine_id = eid, .modal = false, .title = null };
            const id = c_api.celeris_create_window(&cfg);
            if (id > 0) c_api.celeris_deinit(id);
        }

        // Double-close a modal chain: deinit the parent twice in a row (the
        // second call must be a clean no-op, not a double-free of the already
        // cascaded children).
        var cfg_d = c_api.CelerisWindowConfig{ .is_headless = true, .width = 100, .height = 100, .parent_engine_id = 0, .modal = false, .title = null };
        const d = c_api.celeris_create_window(&cfg_d);
        if (d > 0) {
            var cfg_e = c_api.CelerisWindowConfig{ .is_headless = true, .width = 100, .height = 100, .parent_engine_id = d, .modal = true, .title = null };
            _ = c_api.celeris_create_window(&cfg_e);
            c_api.celeris_deinit(d);
            c_api.celeris_deinit(d); // double
            c_api.celeris_deinit(d); // triple, for good measure
        }
    }

    step("deinit, then use the dead engine id");
    c_api.celeris_deinit(eid);
    _ = c_api.celeris_node_create(eid, 0);
    _ = c_api.celeris_node_append_child(eid, 1, 2);
    _ = c_api.celeris_dispatch_mouse_click(eid, 1, 1);
    _ = c_api.celeris_signal_get_f32(eid, sig);
    _ = c_api.celeris_get_dom_json(eid);
    c_api.celeris_deinit(eid); // double free
    c_api.celeris_deinit(eid);

    // Not surviving the cases is table stakes; leaking through them is a
    // silent failure that a nonzero exit code turns into a loud one. Read
    // AFTER the last celeris_deinit above (the counter only moves at deinit).
    const leaks = c_api.debug_leak_count.load(.monotonic);
    if (leaks > 0) {
        std.debug.print("fuzz_api: FAILED — {d} engine deinit(s) reported leaked memory (see DebugAllocator traces above)\n", .{leaks});
        std.process.exit(1);
    }

    std.debug.print("fuzz_api: survived all cases, 0 leaks\n", .{});
}
