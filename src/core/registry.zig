const std = @import("std");
const text_mod = @import("../render/text.zig");
const BoundedArray = @import("bounded_array.zig").BoundedArray;

/// Subscriber notified when a node slot is recycled by `removeNode`/reconciliation.
/// Multiple subsystems listen: the PropertyStore (clears props), the EventRouter
/// (drops node handlers), and the component MountTable (teardown).
pub const NodeRemovedListener = struct {
    ctx: ?*anyopaque,
    cb: *const fn (ctx: ?*anyopaque, id: NodeId) void,
};

pub const NodeType = enum {
    box,
    text,
    image,
    /// A stroked vector path (`core/path.zig`). Geometry lives in
    /// `PropertyStore.path_data`; the renderer flattens + strokes it.
    path,
};

pub const NodeId = u32;
pub const NULL_NODE: NodeId = std.math.maxInt(u32);

/// Hard cap on tree nesting. Every recursive traversal (parse, layout, removal,
/// serialization, focus walk) is bounded by this so untrusted or malformed
/// input cannot overflow the native stack. 256 levels is far beyond any real
/// UI and keeps worst-case stack usage tiny.
pub const MAX_TREE_DEPTH: usize = 256;

pub const Geometry = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

/// A retained node in the UI tree, using data-oriented design: stored by value in
/// a contiguous array and referenced by `NodeId`, never by pointer. This is the
/// engine's render-tree element — distinct from a framework `component` (the
/// declarative `Button`/`TextInput` structs with a `build()` method).
pub const Node = struct {
    id: NodeId,
    node_type: NodeType,
    geometry: Geometry,

    // Tree hierarchy via IDs instead of pointers
    parent: NodeId = NULL_NODE,
    first_child: NodeId = NULL_NODE,
    next_sibling: NodeId = NULL_NODE,
    /// Tail of this node's own child list, kept in sync by `appendChild` and
    /// `detachChild` so `appendChild` never has to walk the sibling list to
    /// find where to attach. Without this, N `appendChild` calls onto the
    /// same parent (the common case: a builder emitting rows/children in a
    /// loop) cost O(N) each — O(N²) total — because the old implementation
    /// walked from `first_child` every time. Found by instrumenting
    /// perf_bench's superlinear us/node growth (1.34 -> 2.38 across 1.2k-20k
    /// nodes): the "build" phase, not layout.solve, was the dominant driver,
    /// and its cost scaled almost exactly quadratically in row count.
    last_child: NodeId = NULL_NODE,

    /// Optional reconciliation key. When set, the UIBuilder matches this node
    /// across rebuilds by key (stable identity under reorder/insert) instead of
    /// by position. null = positional reconciliation (the default fast path).
    key: ?u64 = null,

    /// False once the node has been removed and its slot returned to the free
    /// list. `getNode` rejects dead slots so a stale NodeId held by a host can
    /// no longer read or mutate freed state. (Note: once the slot is recycled
    /// by `createNode` the id becomes live again for the *new* node — callers
    /// must not retain ids across a remove + create.)
    alive: bool = true,

    // Dirty flags and cache for layout/render
    layout_dirty: bool = true,
    render_dirty: bool = true,
    last_avail_w: f32 = -1.0,
    last_avail_h: f32 = -1.0,

    /// True when the text content or font size changed and the shaped layout must
    /// be recomputed. Distinct from `layout_dirty` so a pure available-height
    /// change (which can't affect line wrapping) never forces a re-shape.
    text_dirty: bool = true,
    /// The wrap width (`last_avail_w` minus horizontal padding) the cached
    /// `text_layout` was shaped at. A change here is the only geometric reason to
    /// re-shape; height changes are ignored.
    last_shaped_w: f32 = -1.0,
    /// One-slot history of a previously shaped width + its layout. The two measure
    /// passes per solve hand a grow-child two different wrap widths (base then
    /// grown), so the width alternates every solve; keeping the prior layout lets
    /// us swap it back in instead of re-running HarfBuzz. Invalidated on content
    /// change. See updateTextLayout.
    prev_text_layout: ?*text_mod.TextLayoutInfo = null,
    prev_shaped_w: f32 = -1.0,
    /// Solve generation in which this node last did real measurement work (i.e.
    /// did not hit the measure cache). `place` reads it to skip subtrees whose
    /// geometry is unchanged this solve. See LayoutEngine.gen.
    measured_gen: u64 = 0,
    /// The width/height this node resolved to at the end of the measure pass. The
    /// place pass re-measures a box's children only when its final size differs from
    /// these (flex grow/shrink or a percent parent changed it) — a hug-content box
    /// whose size is unchanged keeps its measure-pass children as-is, avoiding a
    /// second, tighter text measure that would re-wrap glyphs (HarfBuzz shaping is
    /// narrower than the per-codepoint advances the wrap loop sums).
    layout_w: f32 = -1.0,
    layout_h: f32 = -1.0,

    /// Size observation (`on_resize`). `observe_resize` marks membership in
    /// `UIRegistry.resize_observers`; `resize_last_w/h` is the size last reported
    /// (seeded -1 so the first solve after observation always reports). A recycled
    /// slot is re-initialized by `createNode`, so these never leak across nodes.
    observe_resize: bool = false,
    resize_last_w: f32 = -1.0,
    resize_last_h: f32 = -1.0,

    /// Propagation generation in which this node (a component anchor) was last
    /// rebuilt by the reactive build layer. If it equals the current
    /// propagation gen when the node's own build-effect fires, the effect skips —
    /// an ancestor rebuild already reconciled this subtree (subsumption).
    built_gen: u32 = 0,

    // Cached Layouts
    text_layout: ?*text_mod.TextLayoutInfo = null,
};

/// Central registry that stores the AST in memory using contiguous storage.
pub const UIRegistry = struct {
    nodes: std.array_list.Managed(Node),
    free_list: std.array_list.Managed(NodeId),
    allocator: std.mem.Allocator,

    /// Frame-level "anything dirty?" flags, a conservative superset of the per-node
    /// `layout_dirty`/`render_dirty` bits. The frame loop reads these in O(1) instead
    /// of scanning every node, and clears them once it has solved layout / rendered.
    /// Set true whenever any node is marked dirty (so they're never false while a
    /// per-node flag is true); default true so the first frame always renders.
    global_layout_dirty: bool = true,
    global_render_dirty: bool = true,

    /// Monotonic counter bumped once per layout solve. The LayoutEngine stamps
    /// `measured_gen` on every node it re-measures, so the place pass can tell a
    /// node that changed this solve from one whose subtree is untouched.
    solve_generation: u64 = 0,

    /// Per-solve diagnostic counters (reset at the start of each solve). Read by
    /// the CELERIS_PROFILE frame profiler to see how much work the incremental
    /// layout actually skipped. Cheap to maintain; ignore when not profiling.
    dbg_measured: u32 = 0,
    dbg_reshaped: u32 = 0,
    dbg_placed: u32 = 0,
    dbg_skipped: u32 = 0,

    /// Fan-out of node-removal subscribers (see `NodeRemovedListener`). Fixed small
    /// capacity — a `runApp` app wires four (store, router, mount table, focus
    /// clearer) and the devtools inspector adds two more on its own registry.
    /// The margin over the current five is deliberately thin; raise it here if a
    /// new subsystem needs a slot.
    node_removed_listeners: BoundedArray(NodeRemovedListener, 8) = .{},

    /// Nodes with `observe_resize` set (see `observeResize`). Kept as a list so the
    /// post-solve diff is O(observers), not O(tree) — a frame with no observers
    /// costs nothing extra.
    resize_observers: std.ArrayListUnmanaged(NodeId) = .empty,

    pub fn init(allocator: std.mem.Allocator) UIRegistry {
        return .{
            .nodes = std.array_list.Managed(Node).init(allocator),
            .free_list = std.array_list.Managed(NodeId).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UIRegistry) void {
        self.clear();
        self.nodes.deinit();
        self.free_list.deinit();
        self.resize_observers.deinit(self.allocator);
    }

    /// One size change found by `collectResized`.
    pub const Resized = struct { id: NodeId, w: f32, h: f32 };

    /// Sub-pixel jitter below this (logical px) is not reported as a resize.
    pub const RESIZE_EPSILON: f32 = 0.5;

    /// Opt `id` into size observation: after every layout solve in which its
    /// solved size differs from the size last reported, `collectResized` yields
    /// it. Idempotent (re-applying on rebuild keeps the last reported size, so a
    /// rebuild does not re-report an unchanged size). The first solve after the
    /// node is first observed always reports.
    pub fn observeResize(self: *UIRegistry, id: NodeId) !void {
        if (id >= self.nodes.items.len) return;
        const node = &self.nodes.items[id];
        if (!node.alive or node.observe_resize) return;
        try self.resize_observers.append(self.allocator, id);
        node.observe_resize = true;
        node.resize_last_w = -1;
        node.resize_last_h = -1;
    }

    /// Appends to `out` every observed node whose solved border-box size changed
    /// (beyond `RESIZE_EPSILON`) since it was last reported, and records the new
    /// size as reported. Call right after a layout solve. Collected into a list
    /// (not a callback) on purpose: delivering a resize runs user code that may
    /// rebuild or remove nodes, which mutates `resize_observers`.
    pub fn collectResized(self: *UIRegistry, out: *std.ArrayListUnmanaged(Resized), gpa: std.mem.Allocator) !void {
        for (self.resize_observers.items) |id| {
            const node = &self.nodes.items[id];
            // Never solved yet (e.g. inside a display:none subtree): nothing to say.
            if (node.layout_w < 0) continue;
            const w = node.geometry.width;
            const h = node.geometry.height;
            if (@abs(w - node.resize_last_w) < RESIZE_EPSILON and @abs(h - node.resize_last_h) < RESIZE_EPSILON) continue;
            try out.append(gpa, .{ .id = id, .w = w, .h = h });
            node.resize_last_w = w;
            node.resize_last_h = h;
        }
    }

    /// Clears all nodes and frees associated caches (e.g., text layout)
    pub fn clear(self: *UIRegistry) void {
        for (self.nodes.items) |*node| {
            if (node.text_layout) |tl| {
                tl.deinit();
                self.allocator.destroy(tl);
                node.text_layout = null;
            }
            if (node.prev_text_layout) |tl| {
                tl.deinit();
                self.allocator.destroy(tl);
                node.prev_text_layout = null;
            }
        }
        self.nodes.clearRetainingCapacity();
        self.free_list.clearRetainingCapacity();
        self.resize_observers.clearRetainingCapacity();
    }

    /// Creates a new node and adds it to the registry.
    pub fn createNode(self: *UIRegistry, node_type: NodeType) !NodeId {
        // A new node (created dirty by default) means the frame must re-render.
        self.global_layout_dirty = true;
        self.global_render_dirty = true;
        if (self.free_list.items.len > 0) {
            const id = self.free_list.pop().?;
            const index: usize = @intCast(id);
            self.nodes.items[index] = .{
                .id = id,
                .node_type = node_type,
                .geometry = .{},
            };
            return id;
        }

        const id: NodeId = @intCast(self.nodes.items.len);

        try self.nodes.append(.{
            .id = id,
            .node_type = node_type,
            .geometry = .{},
        });

        // Keep the free list's capacity >= node count so `removeSubtree` (which
        // recycles at most one id per live node) never has to allocate on the
        // teardown path — an alloc failure there would silently leak the slot
        // forever. If this reservation itself fails we've still created the
        // node; the rare drop is logged where it happens.
        self.free_list.ensureTotalCapacity(self.nodes.items.len) catch {};

        return id;
    }

    /// Gets a pointer to a node by its ID.
    /// Note: The pointer may be invalidated if new nodes are added and the ArrayList is reallocated.
    pub fn getNode(self: *UIRegistry, id: NodeId) ?*Node {
        if (id >= self.nodes.items.len) return null;
        const node = &self.nodes.items[id];
        if (!node.alive) return null;
        return node;
    }

    /// Appends a child to a parent node.
    /// Uses direct index access (never stores intermediate pointers) to avoid
    /// pointer invalidation if the ArrayList is reallocated between lookups.
    pub fn appendChild(self: *UIRegistry, parent_id: NodeId, child_id: NodeId) void {
        if (!self.prepareLink(parent_id, child_id)) return;

        // Set child's parent — direct index, no pointer stored
        self.nodes.items[child_id].parent = parent_id;
        self.nodes.items[child_id].next_sibling = NULL_NODE;

        if (self.nodes.items[parent_id].first_child == NULL_NODE) {
            // Parent has no children yet
            self.nodes.items[parent_id].first_child = child_id;
        } else {
            // O(1): attach directly after the tracked tail instead of walking
            // the sibling list to find it. Falls back to the walk if
            // `last_child` is somehow out of sync (bounds-checked instead of
            // trusted blindly — this is the tree's core linkage, and an
            // out-of-bounds `last_child` must degrade to "slow" here, not to
            // an OOB index into `nodes.items`).
            var tail = self.nodes.items[parent_id].last_child;
            if (tail == NULL_NODE or tail >= self.nodes.items.len) {
                tail = self.nodes.items[parent_id].first_child;
                while (self.nodes.items[tail].next_sibling != NULL_NODE) : (tail = self.nodes.items[tail].next_sibling) {}
            }
            self.nodes.items[tail].next_sibling = child_id;
        }
        self.nodes.items[parent_id].last_child = child_id;
    }

    /// True if making `child_id` a child of `parent_id` would create a cycle —
    /// i.e. `child_id` IS `parent_id` or one of its ancestors. Bounded by
    /// MAX_TREE_DEPTH so it terminates even on an already-malformed tree.
    ///
    /// This is deliberately NOT called from the hot `appendChild` path (the
    /// builder reconciliation appends every node every pass and never forms a
    /// cycle — it clears a node's links before re-attaching it). It guards the
    /// host-facing node APIs, which can be handed arbitrary ids.
    pub fn wouldCreateCycle(self: *UIRegistry, parent_id: NodeId, child_id: NodeId) bool {
        var curr = parent_id;
        var depth: usize = 0;
        while (curr != NULL_NODE and depth < MAX_TREE_DEPTH) : (depth += 1) {
            if (curr == child_id) return true;
            if (curr >= self.nodes.items.len) break;
            curr = self.nodes.items[curr].parent;
        }
        return false;
    }

    /// Inserts child_id before ref_child_id. If ref_child_id is NULL_NODE or not found, appends to the end.
    /// A child attached elsewhere is detached first.
    pub fn insertBefore(self: *UIRegistry, parent_id: NodeId, child_id: NodeId, ref_child_id: NodeId) void {
        // Prevent cyclic insertion: child_id must not be parent_id or an ancestor of it.
        // Checked BEFORE prepareLink so a refused insert leaves the tree untouched.
        if (self.wouldCreateCycle(parent_id, child_id)) return;
        if (!self.prepareLink(parent_id, child_id)) return;

        if (ref_child_id == NULL_NODE) {
            self.appendChild(parent_id, child_id);
            return;
        }

        self.nodes.items[child_id].parent = parent_id;
        self.nodes.items[child_id].next_sibling = NULL_NODE;

        if (self.nodes.items[parent_id].first_child == ref_child_id) {
            self.nodes.items[child_id].next_sibling = ref_child_id;
            self.nodes.items[parent_id].first_child = child_id;
            return;
        }

        var current_id = self.nodes.items[parent_id].first_child;
        var prev_id: NodeId = NULL_NODE;

        while (current_id != NULL_NODE) {
            if (current_id == ref_child_id) {
                if (prev_id != NULL_NODE) {
                    self.nodes.items[prev_id].next_sibling = child_id;
                }
                self.nodes.items[child_id].next_sibling = ref_child_id;
                return;
            }
            prev_id = current_id;
            current_id = self.nodes.items[current_id].next_sibling;
        }

        // Fallback if ref_child_id not found
        self.appendChild(parent_id, child_id);
    }

    /// Common precondition of appendChild / insertBefore: both ids in range and
    /// ALIVE (a removed node keeps its slot until reused; linking it back corrupts
    /// the tree), and the child unlinked from wherever it currently is. Re-linking
    /// an attached child without detaching it first is what produced a sibling
    /// self-loop (`tail.next_sibling = tail`) and hung every tree walk.
    fn prepareLink(self: *UIRegistry, parent_id: NodeId, child_id: NodeId) bool {
        if (parent_id >= self.nodes.items.len or child_id >= self.nodes.items.len) return false;
        if (!self.nodes.items[parent_id].alive or !self.nodes.items[child_id].alive) return false;
        const old_parent = self.nodes.items[child_id].parent;
        if (old_parent != NULL_NODE) self.detachChild(old_parent, child_id);
        return true;
    }

    pub fn detachChild(self: *UIRegistry, parent_id: NodeId, child_id: NodeId) void {
        if (parent_id >= self.nodes.items.len) return;
        if (child_id >= self.nodes.items.len) return;

        var current_id = self.nodes.items[parent_id].first_child;
        var prev_id: NodeId = NULL_NODE;

        while (current_id != NULL_NODE) {
            if (current_id == child_id) {
                const next = self.nodes.items[child_id].next_sibling;
                if (prev_id == NULL_NODE) {
                    self.nodes.items[parent_id].first_child = next;
                } else {
                    self.nodes.items[prev_id].next_sibling = next;
                }
                // Keep `last_child` (see appendChild) in sync: removing the
                // tail moves it back to the previous sibling (NULL_NODE if
                // the list is now empty).
                if (self.nodes.items[parent_id].last_child == child_id) {
                    self.nodes.items[parent_id].last_child = prev_id;
                }
                self.nodes.items[child_id].parent = NULL_NODE;
                self.nodes.items[child_id].next_sibling = NULL_NODE;
                break;
            }
            prev_id = current_id;
            current_id = self.nodes.items[current_id].next_sibling;
        }
    }

    /// Subscribes `cb` to node removals. Silently ignored past capacity (the engine
    /// wires a fixed, small set at init). Order of notification is registration order.
    pub fn addNodeRemovedListener(self: *UIRegistry, ctx: ?*anyopaque, cb: *const fn (ctx: ?*anyopaque, id: NodeId) void) void {
        // Fixed capacity, no allocation — overflow means a listener silently
        // stops receiving removals, which turns into a use-after-free the next
        // time one of its tracked nodes is freed. That's a wiring bug, not a
        // runtime condition: fail loudly instead of dropping it.
        self.node_removed_listeners.append(.{ .ctx = ctx, .cb = cb }) catch {
            std.debug.panic(
                "addNodeRemovedListener: capacity {d} exhausted — raise BoundedArray size",
                .{self.node_removed_listeners.buffer.len},
            );
        };
    }

    pub fn removeNode(self: *UIRegistry, id: NodeId) void {
        if (id >= self.nodes.items.len) return;
        if (!self.nodes.items[id].alive) return; // already removed — no double free
        // Removing a node reflows its parent and changes the scene.
        self.global_layout_dirty = true;
        self.global_render_dirty = true;
        // Detach from the parent once; children are freed by the depth-limited
        // recursion which only unlinks within the subtree.
        const parent = self.nodes.items[id].parent;
        if (parent != NULL_NODE) {
            self.detachChild(parent, id);
        }
        self.removeSubtree(id, 0);
    }

    /// Frees `id` and all descendants. Bounded by `MAX_TREE_DEPTH` so a deeply
    /// nested tree (which can be built via the node C-API) cannot overflow the
    /// stack. Past the cap the remaining descendants are left orphaned but the
    /// process stays alive.
    fn removeSubtree(self: *UIRegistry, id: NodeId, depth: usize) void {
        if (id >= self.nodes.items.len) return;
        if (!self.nodes.items[id].alive) return;

        if (depth < MAX_TREE_DEPTH) {
            var child_id = self.nodes.items[id].first_child;
            while (child_id != NULL_NODE) {
                const next = self.nodes.items[child_id].next_sibling;
                self.removeSubtree(child_id, depth + 1);
                child_id = next;
            }
        }

        // Clear caches
        if (self.nodes.items[id].text_layout) |tl| {
            tl.deinit();
            self.allocator.destroy(tl);
            self.nodes.items[id].text_layout = null;
        }
        if (self.nodes.items[id].prev_text_layout) |tl| {
            tl.deinit();
            self.allocator.destroy(tl);
            self.nodes.items[id].prev_text_layout = null;
        }

        // Drop from the size-observer list (order is irrelevant → swap-remove).
        if (self.nodes.items[id].observe_resize) {
            self.nodes.items[id].observe_resize = false;
            for (self.resize_observers.items, 0..) |oid, i| {
                if (oid == id) {
                    _ = self.resize_observers.swapRemove(i);
                    break;
                }
            }
        }

        // Mark the slot dead before recycling so a stale id stops resolving.
        self.nodes.items[id].alive = false;

        // Notify subscribers (property store, event router, mount table).
        for (self.node_removed_listeners.constSlice()) |l| {
            l.cb(l.ctx, id);
        }

        // Add to free list. Capacity is kept ahead of the node count in
        // `createNode`, so the common path never allocates here; if a prior
        // reservation failed under memory pressure, log the leaked slot rather
        // than swallowing it.
        if (self.free_list.items.len < self.free_list.capacity) {
            self.free_list.appendAssumeCapacity(id);
        } else {
            self.free_list.append(id) catch {
                std.log.err("registry: node slot {d} not recycled (free-list alloc failed); id permanently retired", .{id});
            };
        }
    }

    /// Marks `id` and its ancestors `layout_dirty`, stopping early once an
    /// already-dirty ancestor is reached (same propagation as a `setLayout`
    /// write). Use after a structural change (subtree rebuild via `rootAt`) so
    /// the layout pass revisits the affected branch. Bounded by `MAX_TREE_DEPTH`.
    pub fn markLayoutDirty(self: *UIRegistry, id: NodeId) void {
        // A structural/layout change always needs a repaint too.
        self.global_layout_dirty = true;
        self.global_render_dirty = true;
        var cur = id;
        var depth: usize = 0;
        while (cur != NULL_NODE and depth < MAX_TREE_DEPTH) : (depth += 1) {
            const node = self.getNode(cur) orelse break;
            if (node.layout_dirty) break;
            node.layout_dirty = true;
            cur = node.parent;
        }
    }

    pub fn getChildAt(self: *UIRegistry, parent_id: NodeId, index: usize) NodeId {
        if (parent_id >= self.nodes.items.len) return NULL_NODE;

        var current_id = self.nodes.items[parent_id].first_child;
        var count: usize = 0;
        while (current_id != NULL_NODE) {
            if (count == index) return current_id;
            current_id = self.nodes.items[current_id].next_sibling;
            count += 1;
        }
        return NULL_NODE;
    }
};

test "UIRegistry hierarchy operations" {
    const allocator = std.testing.allocator;
    var registry = UIRegistry.init(allocator);
    defer registry.deinit();

    const parent_id = try registry.createNode(.box);
    const child1_id = try registry.createNode(.text);
    const child2_id = try registry.createNode(.box);

    registry.appendChild(parent_id, child1_id);
    registry.appendChild(parent_id, child2_id);

    const parent = registry.getNode(parent_id).?;
    const child1 = registry.getNode(child1_id).?;
    const child2 = registry.getNode(child2_id).?;

    // Parent should point to first child
    try std.testing.expectEqual(child1_id, parent.first_child);

    // First child should point to second child as next sibling
    try std.testing.expectEqual(child2_id, child1.next_sibling);

    // Both children should point to parent
    try std.testing.expectEqual(parent_id, child1.parent);
    try std.testing.expectEqual(parent_id, child2.parent);
}

test "UIRegistry free list reuse" {
    const allocator = std.testing.allocator;
    var registry = UIRegistry.init(allocator);
    defer registry.deinit();

    const id1 = try registry.createNode(.box);
    const id2 = try registry.createNode(.text);
    const id3 = try registry.createNode(.image);

    try std.testing.expectEqual(@as(usize, 3), registry.nodes.items.len);

    registry.removeNode(id2);
    try std.testing.expectEqual(@as(usize, 1), registry.free_list.items.len);

    const id4 = try registry.createNode(.box);
    try std.testing.expectEqual(id2, id4); // should reuse
    try std.testing.expectEqual(@as(usize, 0), registry.free_list.items.len);

    // Verify it was reset properly
    const node4 = registry.getNode(id4).?;
    try std.testing.expectEqual(NodeType.box, node4.node_type);
    try std.testing.expectEqual(NULL_NODE, node4.parent);
    try std.testing.expectEqual(NULL_NODE, node4.first_child);
    _ = id1;
    _ = id3;
}

test "UIRegistry removed node stops resolving via getNode" {
    const allocator = std.testing.allocator;
    var registry = UIRegistry.init(allocator);
    defer registry.deinit();

    const a = try registry.createNode(.box);
    const b = try registry.createNode(.box);
    registry.appendChild(a, b);

    registry.removeNode(b);
    // A stale id no longer resolves — a host holding it can't read/mutate it.
    try std.testing.expectEqual(@as(?*Node, null), registry.getNode(b));

    // The slot is recycled by the next create and becomes live again.
    const c = try registry.createNode(.box);
    try std.testing.expectEqual(b, c); // reused slot
    try std.testing.expect(registry.getNode(c) != null);
}

test "UIRegistry removeNode is idempotent (no double free-list entry)" {
    const allocator = std.testing.allocator;
    var registry = UIRegistry.init(allocator);
    defer registry.deinit();

    const id = try registry.createNode(.box);
    registry.removeNode(id);
    registry.removeNode(id); // second call must be a no-op
    try std.testing.expectEqual(@as(usize, 1), registry.free_list.items.len);
}

test "UIRegistry wouldCreateCycle detects self/ancestor; insertBefore refuses cycles" {
    const allocator = std.testing.allocator;
    var registry = UIRegistry.init(allocator);
    defer registry.deinit();

    const root = try registry.createNode(.box);
    const mid = try registry.createNode(.box);
    const leaf = try registry.createNode(.box);
    registry.appendChild(root, mid);
    registry.appendChild(mid, leaf);

    // Self, direct ancestor, and transitive ancestor → cycle.
    try std.testing.expect(registry.wouldCreateCycle(leaf, leaf)); // self
    try std.testing.expect(registry.wouldCreateCycle(leaf, mid)); // parent of leaf
    try std.testing.expect(registry.wouldCreateCycle(leaf, root)); // grandparent
    // A non-ancestor is fine (leaf is below mid, so mid→leaf is a normal move).
    try std.testing.expect(!registry.wouldCreateCycle(root, leaf));

    // insertBefore must refuse the cycle: trying to put `root` under `leaf` is a
    // no-op, so root stays a root (parent == NULL_NODE) and leaf gains no child.
    registry.insertBefore(leaf, root, NULL_NODE);
    try std.testing.expectEqual(NULL_NODE, registry.getNode(root).?.parent);
    try std.testing.expectEqual(NULL_NODE, registry.getNode(leaf).?.first_child);
}

test "UIRegistry insertBefore" {
    const allocator = std.testing.allocator;
    var registry = UIRegistry.init(allocator);
    defer registry.deinit();

    const p = try registry.createNode(.box);
    const c1 = try registry.createNode(.box);
    const c2 = try registry.createNode(.box);
    const c3 = try registry.createNode(.box);
    const c_new = try registry.createNode(.box);

    registry.appendChild(p, c1);
    registry.appendChild(p, c2);
    registry.appendChild(p, c3);

    // Insert before c2
    registry.insertBefore(p, c_new, c2);

    const parent_node = registry.getNode(p).?;
    try std.testing.expectEqual(c1, parent_node.first_child);

    const node_c1 = registry.getNode(c1).?;
    try std.testing.expectEqual(c_new, node_c1.next_sibling);

    const node_cnew = registry.getNode(c_new).?;
    try std.testing.expectEqual(c2, node_cnew.next_sibling);
    try std.testing.expectEqual(p, node_cnew.parent);

    // Insert before first child (c1)
    const c_new2 = try registry.createNode(.box);
    registry.insertBefore(p, c_new2, c1);
    try std.testing.expectEqual(c_new2, registry.getNode(p).?.first_child);
    try std.testing.expectEqual(c1, registry.getNode(c_new2).?.next_sibling);

    // Insert with NULL_NODE (should append to end)
    const c_new3 = try registry.createNode(.box);
    registry.insertBefore(p, c_new3, NULL_NODE);
    try std.testing.expectEqual(c_new3, registry.getNode(c3).?.next_sibling);
    try std.testing.expectEqual(NULL_NODE, registry.getNode(c_new3).?.next_sibling);
}

/// Walks the sibling list from `first_child` and collects ids in order — the
/// ground truth to check `last_child` bookkeeping against, independent of
/// whatever `last_child` itself claims.
fn childOrder(registry: *UIRegistry, parent_id: NodeId, out: *std.array_list.Managed(NodeId)) void {
    var cur = registry.getNode(parent_id).?.first_child;
    while (cur != NULL_NODE) {
        out.append(cur) catch unreachable;
        cur = registry.getNode(cur).?.next_sibling;
    }
}

test "PERF: appendChild is O(1) via last_child, not a walk from first_child" {
    // The bug this fixes: N appendChild calls onto the same parent used to
    // walk the full sibling list each time (O(N) per call), so building a
    // flat list of N children cost O(N^2). Found by instrumenting
    // perf_bench's "build" zone, which grew ~2.3-2.6x per doubling of row
    // count instead of ~2x. This test pins the *correctness* of the O(1)
    // path (last_child always names the true tail); the win itself is a
    // perf_bench A/B (total time at 20k nodes: 47.6ms -> 30.7ms), not
    // something a unit test times.
    const allocator = std.testing.allocator;
    var registry = UIRegistry.init(allocator);
    defer registry.deinit();

    const parent = try registry.createNode(.box);
    const N = 300;
    var ids: [N]NodeId = undefined;
    for (&ids) |*id| {
        id.* = try registry.createNode(.box);
        registry.appendChild(parent, id.*);
        // last_child must always be the node just appended.
        try std.testing.expectEqual(id.*, registry.getNode(parent).?.last_child);
    }

    var order = std.array_list.Managed(NodeId).init(allocator);
    defer order.deinit();
    childOrder(&registry, parent, &order);
    try std.testing.expectEqualSlices(NodeId, &ids, order.items);

    // Detaching the tail must move last_child back, not leave it dangling.
    registry.detachChild(parent, ids[N - 1]);
    try std.testing.expectEqual(ids[N - 2], registry.getNode(parent).?.last_child);

    // Detaching a middle child must NOT move last_child at all.
    registry.detachChild(parent, ids[5]);
    try std.testing.expectEqual(ids[N - 2], registry.getNode(parent).?.last_child);

    // Appending again after those detaches must land after the true tail,
    // not silently overwrite/skip — this is exactly what would break if
    // last_child were stale.
    const tail_new = try registry.createNode(.box);
    registry.appendChild(parent, tail_new);
    order.clearRetainingCapacity();
    childOrder(&registry, parent, &order);
    try std.testing.expectEqual(tail_new, order.items[order.items.len - 1]);
    try std.testing.expectEqual(tail_new, registry.getNode(parent).?.last_child);

    // Detaching the ONLY child must clear both first_child and last_child.
    var registry2 = UIRegistry.init(allocator);
    defer registry2.deinit();
    const p2 = try registry2.createNode(.box);
    const only = try registry2.createNode(.box);
    registry2.appendChild(p2, only);
    registry2.detachChild(p2, only);
    try std.testing.expectEqual(NULL_NODE, registry2.getNode(p2).?.first_child);
    try std.testing.expectEqual(NULL_NODE, registry2.getNode(p2).?.last_child);

    // And appending after the list is fully emptied must still work (the
    // "no children yet" branch), landing correctly as the sole child.
    const fresh = try registry2.createNode(.box);
    registry2.appendChild(p2, fresh);
    try std.testing.expectEqual(fresh, registry2.getNode(p2).?.first_child);
    try std.testing.expectEqual(fresh, registry2.getNode(p2).?.last_child);
}

test "PERF: rootAt / builder-style first_child reset also clears last_child" {
    // The two sites that reset first_child = NULL_NODE to let a builder
    // rebuild a node's children from scratch (UIBuilder.rootAt and
    // openNodeKeyed's reuse path) must reset last_child too — otherwise the
    // first fresh appendChild after the reset writes next_sibling on a stale,
    // now-unlinked node instead of setting first_child, silently dropping
    // every subsequent child from the rebuilt list.
    const allocator = std.testing.allocator;
    var registry = UIRegistry.init(allocator);
    defer registry.deinit();

    const parent = try registry.createNode(.box);
    const old_child = try registry.createNode(.box);
    registry.appendChild(parent, old_child);
    try std.testing.expectEqual(old_child, registry.getNode(parent).?.last_child);

    // Simulate what rootAt/openNodeKeyed's reuse path do: reset first_child
    // (and, with the fix, last_child) to rebuild fresh, without going through
    // detachChild (the builder intentionally skips it here — the old
    // children are reconciled or deleted separately).
    registry.nodes.items[parent].first_child = NULL_NODE;
    registry.nodes.items[parent].last_child = NULL_NODE;

    const new_child1 = try registry.createNode(.box);
    const new_child2 = try registry.createNode(.box);
    registry.appendChild(parent, new_child1);
    registry.appendChild(parent, new_child2);

    var order = std.array_list.Managed(NodeId).init(allocator);
    defer order.deinit();
    childOrder(&registry, parent, &order);
    try std.testing.expectEqualSlices(NodeId, &.{ new_child1, new_child2 }, order.items);
    try std.testing.expectEqual(new_child2, registry.getNode(parent).?.last_child);
}

// Repro (C-ABI fuzzer): appending a child that is already the parent's tail set
// `tail.next_sibling = child` on the child itself — a one-node sibling cycle that
// made every later tree walk (removeNode, layout, hit-test) spin forever.
test "appendChild twice with the same child keeps one link, no sibling self-loop" {
    var r = UIRegistry.init(std.testing.allocator);
    defer r.deinit();
    const p = try r.createNode(.box);
    const c = try r.createNode(.box);
    r.appendChild(p, c);
    r.appendChild(p, c);
    try std.testing.expect(r.nodes.items[c].next_sibling != c);
    try std.testing.expectEqual(c, r.nodes.items[p].first_child);
    try std.testing.expectEqual(NULL_NODE, r.nodes.items[c].next_sibling);
    // Same through insertBefore's "ref not found → append" fallback.
    r.insertBefore(p, c, p);
    try std.testing.expectEqual(NULL_NODE, r.nodes.items[c].next_sibling);
    r.removeNode(p); // must terminate
}

test "a removed node cannot be linked back into the tree" {
    var r = UIRegistry.init(std.testing.allocator);
    defer r.deinit();
    const p = try r.createNode(.box);
    const c = try r.createNode(.box);
    r.removeNode(c);
    r.appendChild(p, c);
    r.insertBefore(p, c, NULL_NODE);
    try std.testing.expectEqual(NULL_NODE, r.nodes.items[p].first_child);
}
