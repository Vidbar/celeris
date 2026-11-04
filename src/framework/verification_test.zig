//! Verification suite.
//!
//! First-class assertions of the invariants that justify the whole declarative
//! migration, counted over the *entire* retained tree (not just one widget):
//!
//!   1. Hover is render-only: a hover touches exactly one node's `render_dirty`
//!      and zero `layout_dirty` — no relayout, no rebuild.
//!   2. Keyed reconciliation is identity-stable: reordering a large keyed list
//!      recreates zero nodes (every key keeps its NodeId; the free list stays
//!      empty and the node count never grows).
//!   3. No lifecycle leaks: repeated mount→build→unmount of each component kind
//!      under `std.testing.allocator` frees everything (scopes, signals, owned
//!      strings, tree nodes).

const std = @import("std");
const reg = @import("../core/registry.zig");
const props = @import("../core/properties.zig");
const component = @import("component.zig");
const events = @import("events.zig");
const button = @import("button.zig");
const slider = @import("slider.zig");
const tabs = @import("tabs.zig");
const tree_view = @import("tree_view.zig");
const theme = @import("theme.zig");
const signals = @import("../core/signals.zig");

const testing = std.testing;

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Clears layout_dirty/render_dirty on every live node, simulating the state
/// right after a frame's layout+render pass has settled.
fn clearAllDirty(registry: *reg.UIRegistry) void {
    for (registry.nodes.items) |*n| {
        if (!n.alive) continue;
        n.layout_dirty = false;
        n.render_dirty = false;
    }
}

const DirtyCount = struct { layout: usize, render: usize };

fn countDirty(registry: *reg.UIRegistry) DirtyCount {
    var c = DirtyCount{ .layout = 0, .render = 0 };
    for (registry.nodes.items) |*n| {
        if (!n.alive) continue;
        if (n.layout_dirty) c.layout += 1;
        if (n.render_dirty) c.render += 1;
    }
    return c;
}

// ── 1. Hover granularity ──────────────────────────────────────────────────────

test "hover touches exactly 1 render_dirty node and 0 layout_dirty" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    var bld = component.UIBuilder.init(&registry, &store);
    bld.theme = theme.Theme.dark();

    var router = events.EventRouter.init(testing.allocator);
    defer router.deinit();
    var mounts = component.MountTable.init(testing.allocator);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
    registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);

    // Canonical mount: the framework owns the Button; hover is a render-only
    // background write driven by a fine-grained effect.
    var ctx = component.BuildContext{ .builder = &bld, .router = &router, .mounts = &mounts };
    _ = try bld.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(button.Button, .{ .label = "OK" });
    bld.close();
    const anchor = registry.getNode(0).?.first_child;
    const boxn = registry.getNode(anchor).?.first_child;

    // Settle: the engine has laid out and rendered this frame.
    clearAllDirty(&registry);
    try testing.expectEqual(@as(usize, 0), countDirty(&registry).layout);
    try testing.expectEqual(@as(usize, 0), countDirty(&registry).render);

    // Hover in: the effect writes one background color into the store.
    _ = router.route(.{ .name = "mouse_enter", .id = "", .node_id = boxn });
    const after = countDirty(&registry);
    try testing.expectEqual(@as(usize, 0), after.layout); // never relayout on hover
    try testing.expectEqual(@as(usize, 1), after.render); // exactly the button box
}

test "hovering a large TreeView touches ≤2 render_dirty and 0 layout_dirty" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var bld = component.UIBuilder.init(&registry, &store);
    bld.theme = theme.Theme.dark();

    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
    registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);

    // 200 flat rows: a full-tree repaint would dirty hundreds of nodes.
    var roots = std.array_list.Managed(tree_view.TreeNode).init(a);
    defer {
        for (roots.items) |*n| n.children.deinit();
        roots.deinit();
    }
    var k: usize = 0;
    while (k < 200) : (k += 1) try roots.append(.{
        .id = k,
        .name = "row",
        .node_type = .leaf,
        .children = std.array_list.Managed(tree_view.TreeNode).init(a),
    });

    var ctx = component.BuildContext{ .builder = &bld, .router = &router, .mounts = &mounts };
    _ = try bld.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(tree_view.TreeView, .{ .roots = &roots });
    bld.close();
    const anchor = registry.getNode(0).?.first_child;
    const tv: *tree_view.TreeView = @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));

    // Settle after the mount's full paint.
    clearAllDirty(&registry);
    tv.paint_visits = 0;

    // Hover a row, then move hover: the transition repaints only the leaving and
    // entering rows — no relayout, at most two dirty rows.
    var row5: reg.NodeId = reg.NULL_NODE;
    var row6: reg.NodeId = reg.NULL_NODE;
    for (tv.row_map.items) |info| {
        if (info.node_id == 5) row5 = info.row;
        if (info.node_id == 6) row6 = info.row;
    }
    _ = router.route(.{ .name = "mouse_enter", .id = "", .node_id = row5 });
    _ = router.route(.{ .name = "mouse_leave", .id = "", .node_id = row5 });
    _ = router.route(.{ .name = "mouse_enter", .id = "", .node_id = row6 });

    const after = countDirty(&registry);
    try testing.expectEqual(@as(usize, 0), after.layout); // never relayout on hover
    try testing.expect(after.render <= 2); // only the row that lost/gained hover
    try testing.expect(tv.paint_visits <= 2); // the loop stayed bounded, not O(200)
}

// ── 2. Keyed reconciliation: 0 nodes recreated on reorder ──────────────────────

fn buildKeyedList(b: *component.UIBuilder, root: reg.NodeId, keys: []const u64) !void {
    try b.rootAt(root);
    for (keys) |k| {
        _ = try b.openNodeKeyed(.box, k);
        b.close();
    }
    b.close();
}

/// Maps each child's reconciliation key to its NodeId by walking the sibling chain.
fn collectKeyIds(registry: *reg.UIRegistry, root: reg.NodeId, out: *std.AutoHashMap(u64, reg.NodeId)) !void {
    out.clearRetainingCapacity();
    var c = registry.getNode(root).?.first_child;
    while (c != reg.NULL_NODE) {
        const node = registry.getNode(c).?;
        if (node.key) |k| try out.put(k, c);
        c = node.next_sibling;
    }
}

test "reordering a 1000-item keyed list recreates zero nodes" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = component.UIBuilder.init(&registry, &store);

    const N = 1000;
    var keys = std.array_list.Managed(u64).init(testing.allocator);
    defer keys.deinit();
    var i: u64 = 0;
    while (i < N) : (i += 1) try keys.append(i);

    // Initial build: a stable root holding N keyed children.
    const root = try b.openNodeKeyed(.box, null);
    b.close();
    try buildKeyedList(&b, root, keys.items);

    const count_after_build = registry.nodes.items.len;
    try testing.expectEqual(@as(usize, 0), registry.free_list.items.len);

    var before = std.AutoHashMap(u64, reg.NodeId).init(testing.allocator);
    defer before.deinit();
    try collectKeyIds(&registry, root, &before);
    try testing.expectEqual(@as(usize, N), before.count());

    // Reverse the order and rebuild the subtree in place.
    std.mem.reverse(u64, keys.items);
    try buildKeyedList(&b, root, keys.items);

    // No node was recreated: count is unchanged and nothing hit the free list.
    try testing.expectEqual(count_after_build, registry.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), registry.free_list.items.len);

    // Every key kept its exact NodeId (stable identity under reorder).
    var after = std.AutoHashMap(u64, reg.NodeId).init(testing.allocator);
    defer after.deinit();
    try collectKeyIds(&registry, root, &after);
    try testing.expectEqual(@as(usize, N), after.count());
    var it = before.iterator();
    while (it.next()) |e| {
        try testing.expectEqual(e.value_ptr.*, after.get(e.key_ptr.*).?);
    }

    // And the order really did flip (first child is now the last key).
    const first_child = registry.getNode(root).?.first_child;
    try testing.expectEqual(@as(u64, N - 1), registry.getNode(first_child).?.key.?);
}

// ── 3. No lifecycle leaks across repeated mount/unmount ────────────────────────

test "repeated mount/unmount of each component kind leaks nothing" {
    const ROUNDS = 64;

    // Leaf stateful, framework-owned: mount + unmount via mountOwned in one
    // registry, proving the MountTable frees the instance + build-effect each cycle.
    {
        var registry = reg.UIRegistry.init(testing.allocator);
        defer registry.deinit();
        var store = props.PropertyStore.init(testing.allocator);
        defer store.deinit();
        store.setRegistry(&registry);
        var router = events.EventRouter.init(testing.allocator);
        defer router.deinit();
        var mounts = component.MountTable.init(testing.allocator);
        defer mounts.deinit();
        registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
        registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);
        var bld = component.UIBuilder.init(&registry, &store);
        bld.theme = theme.Theme.dark();
        const root = try bld.openNodeKeyed(.box, null);
        bld.close();

        var i: usize = 0;
        while (i < ROUNDS) : (i += 1) {
            var ctx = component.BuildContext{ .builder = &bld, .router = &router, .mounts = &mounts };
            try bld.rootAt(root);
            try ctx.mountOwned(button.Button, .{ .label = "OK" });
            bld.close();
            // Unmount: rebuild the root empty → the button anchor is reconciled away.
            try bld.rootAt(root);
            bld.close();
        }
    }

    // Hit-math widget: Slider — framework-owned, mount/unmount via mountOwned.
    // Also proves onUnmount removes the global drag handler each cycle.
    {
        var registry = reg.UIRegistry.init(testing.allocator);
        defer registry.deinit();
        var store = props.PropertyStore.init(testing.allocator);
        defer store.deinit();
        store.setRegistry(&registry);
        var router = events.EventRouter.init(testing.allocator);
        defer router.deinit();
        var mounts = component.MountTable.init(testing.allocator);
        defer mounts.deinit();
        registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
        registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);
        var bld = component.UIBuilder.init(&registry, &store);
        bld.theme = theme.Theme.dark();
        const root = try bld.openNodeKeyed(.box, null);
        bld.close();

        var j: usize = 0;
        while (j < ROUNDS) : (j += 1) {
            var ctx = component.BuildContext{ .builder = &bld, .router = &router, .mounts = &mounts };
            try bld.rootAt(root);
            try ctx.mountOwned(slider.Slider, .{ .initial_value = 0.5 });
            bld.close();
            try bld.rootAt(root);
            bld.close();
        }
        // Every cycle unregistered its global handler — none leaked.
        try testing.expectEqual(@as(usize, 0), router.global_handlers.items.len);
    }

    // Structural widget with caller-owned data: TreeView, framework-
    // owned, mount/unmount ROUNDS times against the same data.
    {
        var registry = reg.UIRegistry.init(testing.allocator);
        defer registry.deinit();
        var store = props.PropertyStore.init(testing.allocator);
        defer store.deinit();
        store.setRegistry(&registry);
        var router = events.EventRouter.init(testing.allocator);
        defer router.deinit();

        var roots = std.array_list.Managed(tree_view.TreeNode).init(testing.allocator);
        defer {
            for (roots.items) |*n| deinitTreeNode(n);
            roots.deinit();
        }
        var branch = tree_view.TreeNode{ .id = 1, .name = "src", .node_type = .branch, .expanded = true, .children = std.array_list.Managed(tree_view.TreeNode).init(testing.allocator) };
        try branch.children.append(.{ .id = 2, .name = "a.zig", .node_type = .leaf, .children = std.array_list.Managed(tree_view.TreeNode).init(testing.allocator) });
        try roots.append(branch);

        var mounts = component.MountTable.init(testing.allocator);
        defer mounts.deinit();
        registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
        registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);
        var bld = component.UIBuilder.init(&registry, &store);
        bld.theme = theme.Theme.dark();
        const root = try bld.openNodeKeyed(.box, null);
        bld.close();

        var j: usize = 0;
        while (j < ROUNDS) : (j += 1) {
            var ctx = component.BuildContext{ .builder = &bld, .router = &router, .mounts = &mounts };
            try bld.rootAt(root);
            try ctx.mountOwned(tree_view.TreeView, .{ .roots = &roots });
            bld.close();
            try bld.rootAt(root);
            bld.close();
        }
    }

    // Container holding a Child: Tabs (framework-owned) with one tab, mount/unmount.
    {
        var registry = reg.UIRegistry.init(testing.allocator);
        defer registry.deinit();
        var store = props.PropertyStore.init(testing.allocator);
        defer store.deinit();
        store.setRegistry(&registry);
        var router = events.EventRouter.init(testing.allocator);
        defer router.deinit();
        var mounts = component.MountTable.init(testing.allocator);
        defer mounts.deinit();
        registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
        registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);
        var bld = component.UIBuilder.init(&registry, &store);
        bld.theme = theme.Theme.dark();
        const root = try bld.openNodeKeyed(.box, null);
        bld.close();

        var leaf = LeafStub{};
        const items = [_]tabs.TabItem{.{ .title = "one", .child = component.childOf(LeafStub, &leaf) }};
        var active = signals.Signal(usize).init(testing.allocator, 0);
        defer active.deinit();

        var j: usize = 0;
        while (j < ROUNDS) : (j += 1) {
            var ctx = component.BuildContext{ .builder = &bld, .router = &router, .mounts = &mounts };
            try bld.rootAt(root);
            try ctx.mountOwned(tabs.Tabs, .{ .items = &items, .active = &active });
            bld.close();
            try bld.rootAt(root);
            bld.close();
        }
    }
}

fn deinitTreeNode(node: *tree_view.TreeNode) void {
    for (node.children.items) |*child| deinitTreeNode(child);
    node.children.deinit();
}

const LeafStub = struct {
    pub fn build(_: *LeafStub, ctx: *component.BuildContext) !void {
        const n = try ctx.builder.openNodeKeyed(.box, null);
        ctx.builder.close();
        _ = n;
    }
    pub fn deinit(_: *LeafStub) void {}
};
