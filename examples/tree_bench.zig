//! tree_bench — a large, virtualized TreeView for re-measuring bake/render cost.
//!
//! It builds the worst-case DevTools pattern — a fully-expanded tree of ~6 000 rows —
//! wired through the scroll bridge, so the TreeView materializes only its visible
//! window. It is kept as the standing regression bench for scroll cost.
//!
//! History: this bench was built to decide whether a bake-vertex cache was worth it.
//! The answer was no — with virtualization bounding the node count, `bake` measured
//! ~0.43 ms. The real cost was a ~15 ms `layout.solve` per scroll that re-shaped
//! unchanged, reused text, because `clearProperties` wiped `text_content` on keyed
//! reuse and defeated the `setTextContent` short-circuit. Fixing that took the scroll
//! solve to ~0.6 ms (~25x) and `reshaped` from 312 to 8.
//!
//! How to measure:
//!   1. The per-second `[PROFILE]` summary is gated on the CELERIS_PROFILE env var
//!      (NOT on -Dprofiling). Set it, then run — PowerShell:
//!        $env:CELERIS_PROFILE = "1"; zig build tree_bench
//!   2. Hover rows and scroll (wheel / drag the thumb). Each hover or scroll dirties
//!      the frame, so the loop bakes+renders (idle frames don't render, so
//!      `renders/s` stays 0 until you move the mouse). Read the once-per-second line:
//!        [PROFILE] ... | bake+render xN avg=<us> max=<us>
//!      That avg/max is the combined CPU bake + GPU submit for a changed frame. Any
//!      frame over 5 ms also prints a `bake=<us>` breakdown isolating the CPU bake
//!      from the GPU phases — no Perfetto needed for spikes.
//!   3. For a full flame chart of the `bake` zone, build with `-Dprofiling`, set
//!      CELERIS_TRACE=<path> before running, press F12 to dump a Chrome Trace, and
//!      open it in Perfetto (see the zone profiler, src/core/profiler.zig).
//!
//! Regression watch: a one-row scroll should report `reshaped` in the single digits
//! (roughly 4x the rows entering the window), not the full window. A jump back to
//! triple digits means text shaping is being invalidated on node reuse again.
//!
//! A/B: flip `USE_SCROLL_BRIDGE` to false to measure the same tree WITHOUT
//! virtualization (every visible row materialized) — the contrast shows how much of
//! the bake cost virtualization already removed.

const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

const TreeNode = fw.tree_view.TreeNode;
const NodeList = std.array_list.Managed(TreeNode);

// Scene knobs. Total flat rows ≈ GROUPS * (1 + LEAVES).
const GROUPS: usize = 120;
const LEAVES: usize = 50;
const ROW_H: f32 = 22; // must match TreeView's fixed row height
const VIEWPORT_H: f32 = 680;
const USE_SCROLL_BRIDGE = true; // false → non-virtualized A/B baseline

/// Builds the whole tree into `arena` (strings + child lists included), so a single
/// `arena.deinit()` frees it after the app exits.
fn buildTree(arena: std.mem.Allocator) !NodeList {
    var roots = NodeList.init(arena);
    var id: usize = 0;
    var g: usize = 0;
    while (g < GROUPS) : (g += 1) {
        id += 1;
        var group = TreeNode{
            .id = id,
            .name = try std.fmt.allocPrint(arena, "group_{d}", .{g}),
            .node_type = .branch,
            .expanded = true, // DevTools worst case: everything open
            .icon = "#",
            .children = NodeList.init(arena),
        };
        var l: usize = 0;
        while (l < LEAVES) : (l += 1) {
            id += 1;
            try group.children.append(.{
                .id = id,
                .name = try std.fmt.allocPrint(arena, "node_{d}", .{id}),
                .node_type = .leaf,
                .decorator = try std.fmt.allocPrint(arena, "[x:{d} y:{d} w:120 h:22]", .{ id % 400, (id * 7) % 300 }),
                .decorator_color = .{ 130, 130, 145 },
                .children = NodeList.init(arena),
            });
        }
        try roots.append(group);
    }
    return roots;
}

/// Hosts the TreeView as the ScrollView's content. A plain `childOf` can't host
/// TreeView directly (TreeView needs `onMount`, which `mountOwned` runs), so this
/// tiny wrapper mounts it and forwards the caller-owned data + scroll bridge.
const TreeHost = struct {
    roots: *NodeList,
    scroll: *fw.signals.Signal(f32),
    selected: *fw.signals.Signal(?usize),

    pub fn build(self: *TreeHost, ctx: *fw.component.BuildContext) !void {
        try ctx.mountOwned(fw.tree_view.TreeView, .{
            .roots = self.roots,
            .selected = self.selected,
            .toggle_on_row_click = false, // DevTools: row click only selects
            .scroll_offset = if (USE_SCROLL_BRIDGE) self.scroll else null,
            .viewport_height = if (USE_SCROLL_BRIDGE) VIEWPORT_H else 0,
        });
    }
    pub fn deinit(_: *TreeHost) void {}
};

const BenchApp = struct {
    roots: *NodeList,
    scroll: *fw.signals.Signal(f32),
    selected: *fw.signals.Signal(?usize),
    host: TreeHost,

    pub fn build(self: *BenchApp, ctx: *fw.component.BuildContext) !void {
        const total_rows: usize = GROUPS * (1 + LEAVES);
        try ctx.mountOwned(fw.scroll_view.ScrollView, .{
            .fill = true,
            .viewport_height = VIEWPORT_H,
            .content_height = @as(f32, @floatFromInt(total_rows)) * ROW_H,
            .offset = self.scroll,
            .content = fw.component.childOf(TreeHost, &self.host),
        });
    }
    pub fn deinit(_: *BenchApp) void {}
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var roots = try buildTree(arena);
    const total_rows: usize = GROUPS * (1 + LEAVES);
    std.debug.print("tree_bench: {d} flat rows, virtualized={}\n", .{ total_rows, USE_SCROLL_BRIDGE });

    var router = fw.events.EventRouter.init(std.heap.c_allocator);
    defer router.deinit();

    // Shared scroll bridge + selection, owned by the app (declared before runApp so
    // its internal teardown — which unsubscribes the widgets' effects — runs first).
    var scroll = fw.signals.Signal(f32).init(std.heap.c_allocator, 0);
    defer scroll.deinit();
    var selected = fw.signals.Signal(?usize).init(std.heap.c_allocator, null);
    defer selected.deinit();

    var app = BenchApp{
        .roots = &roots,
        .scroll = &scroll,
        .selected = &selected,
        .host = .{ .roots = &roots, .scroll = &scroll, .selected = &selected },
    };

    try fw.runApp(&app, &router, .{
        .title = "Celeris TreeView bench",
        .width = 900,
        .height = 760,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
