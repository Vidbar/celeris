//! StatusBar — reactive component migrated to the canonical pattern.
//!
//! Framework-owned via `ctx.mountOwned(StatusBar, .{ .items = items, .rev = &rev })`:
//! no `init`/`register`/`deinit` in user code. A thin row of read-only slots; each
//! slot is a colored status dot followed by a value label (e.g. "● Connected",
//! "● 45ms"). There is no clickable/hoverable wiring — slots are indicators.
//!
//! Live updates are signal-driven (imperative `setItem` API replaced):
//! the caller owns the `items` slice AND an optional revision signal `rev`. To
//! update a slot, mutate the slice in place and bump `rev` — a fine-grained
//! effect re-applies every slot WITHOUT rebuilding the tree:
//!   • the dot color is a paint-only `setStyle(.background)` → render-only.
//!   • the value text goes through `setTextContent`, which re-shapes and relays
//!     out that one tiny subtree. That is NOT render-only (a text's measured size
//!     depends on its content), but it is cheap and localized — clean subtrees
//!     are skipped and shaping is cached.
//!
//! Anchoring is the parent's job: drop this as the last child of a flex-column
//! layout. A built-in 1px top divider stands in for a top-only border (the
//! builder only has uniform borders today).

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme = @import("theme.zig");

const BuildContext = component.BuildContext;

pub const StatusKind = enum(u3) {
    ok = 0,
    neutral = 1,
    warn = 2,
    err = 3,
    busy = 4,
};

const KIND_COUNT = 5;

/// Built-in palette used for any kind the active Theme leaves unset.
const FALLBACK = [KIND_COUNT]theme.Color{
    .{ .r = 40, .g = 167, .b = 69 }, // ok      — green
    .{ .r = 128, .g = 128, .b = 128 }, // neutral — gray
    .{ .r = 255, .g = 193, .b = 7 }, // warn    — amber
    .{ .r = 220, .g = 53, .b = 69 }, // err     — red
    .{ .r = 0, .g = 122, .b = 204 }, // busy    — blue
};

pub const StatusItem = struct {
    value: []const u8,
    kind: StatusKind = .neutral,
};

const Slot = struct {
    dot_node: reg.NodeId = reg.NULL_NODE,
    text_node: reg.NodeId = reg.NULL_NODE,
};

pub const StatusBar = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    /// Caller-owned slots. Mutate in place and bump `rev` to update live.
    items: []StatusItem = &.{},
    /// External, caller-owned revision signal: `rev.set(rev.peek() + 1)` after
    /// mutating `items` re-applies every slot without a rebuild. Optional for
    /// static bars.
    rev: ?*signals.Signal(u32) = null,

    // State (auto-created in onMount; preserved across rebuilds).
    scope: signals.Scope = undefined,
    /// Slot node ids for the current build (index ↔ item); repopulated each build.
    slots: std.array_list.Managed(Slot) = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    /// Status colors resolved against the theme (with fallbacks) at build time.
    colors: [KIND_COUNT]theme.Color = FALLBACK,
    bound: bool = false,

    pub fn onMount(self: *StatusBar, allocator: std.mem.Allocator) void {
        self.scope = signals.Scope.init(allocator);
        self.slots = std.array_list.Managed(Slot).init(allocator);
    }

    /// Tears down reactive state on unmount. The framework owns and frees
    /// the instance itself; text content is owned by the PropertyStore.
    pub fn deinit(self: *StatusBar) void {
        self.scope.deinit();
        self.slots.deinit();
    }

    pub fn build(self: *StatusBar, ctx: *BuildContext) !void {
        const b = ctx.builder;
        self.store = b.store;
        self.resolveColors(b.theme);
        self.slots.clearRetainingCapacity();

        const root = try b.openNodeKeyed(.box, null);
        try b.width(root, 100, .percent);
        try b.height(root, 26, .px);
        try b.flexColumn(root);
        try setBg(b, root, b.theme.bg_surface);
        try b.role(root, "status_bar");

        // Top-only border, faked with a 1px divider (no per-side borders today).
        const divider = try b.openNodeKeyed(.box, null);
        try b.width(divider, 100, .percent);
        try b.height(divider, 1, .px);
        try setBg(b, divider, b.theme.border_color);
        b.close();

        // Content row.
        const row = try b.openNodeKeyed(.box, null);
        try b.flexRow(row);
        try b.flexGrow(row, 1);
        try b.width(row, 100, .percent);
        try b.alignItems(row, .center);
        try b.gap(row, 16);
        try b.padding(row, 0, 8, 0, 8);

        for (self.items) |item| {
            const slot_node = try b.openNodeKeyed(.box, null);
            try b.flexRow(slot_node);
            try b.alignItems(slot_node, .center);
            try b.gap(slot_node, 6);

            const dot = try b.openNodeKeyed(.box, null);
            try b.width(dot, 8, .px);
            try b.height(dot, 8, .px);
            try b.radius(dot, 4); // circle
            b.close(); // dot — background applied by the effect below

            const txt = try b.addText(item.value);
            try b.fontSize(txt, 12);
            try b.textColor(txt, b.theme.text.r, b.theme.text.g, b.theme.text.b);

            b.close(); // slot
            try self.slots.append(.{ .dot_node = dot, .text_node = txt });
        }
        b.close(); // row
        b.close(); // root

        // Slot painting is a fine-grained effect watching `rev` (created once,
        // re-applied untracked after a structural rebuild) — same as IconButton.
        try component.bindVisuals(self, &self.scope, &self.bound, applySlots);
    }

    /// Re-applies every slot from `items`: dot color (render-only) + value text
    /// (localized re-shape). Subscribed to `rev` via its `.get()` read.
    fn applySlots(self: *StatusBar) void {
        if (self.rev) |r| _ = r.get(); // subscribe to caller bumps
        const store = self.store orelse return;
        for (self.slots.items, 0..) |slot, i| {
            if (i >= self.items.len) break;
            const item = self.items[i];
            if (slot.dot_node != reg.NULL_NODE) {
                const c = self.colors[@intFromEnum(item.kind)];
                store.setStyle(slot.dot_node, .background, propColor(c)) catch {};
            }
            if (slot.text_node != reg.NULL_NODE) {
                // Skip the (relayouting) text write when the content is unchanged.
                const cur = store.getTextContent(slot.text_node) orelse "";
                if (!std.mem.eql(u8, cur, item.value)) {
                    // setTextContent stores the pointer (and frees the old one),
                    // so hand it a copy owned by the store.
                    const owned = store.stringAllocator().dupe(u8, item.value) catch continue;
                    store.setTextContent(slot.text_node, owned);
                }
            }
        }
    }

    fn resolveColors(self: *StatusBar, t: theme.Theme) void {
        const themed = [KIND_COUNT]theme.Color{
            t.status_ok, t.status_neutral, t.status_warn, t.status_err, t.status_busy,
        };
        for (&self.colors, themed, FALLBACK) |*c, th, fb| {
            c.* = if (th.a == 0) fb else th; // a==0 → theme left it unset
        }
    }
};

fn setBg(b: *component.UIBuilder, id: reg.NodeId, c: theme.Color) !void {
    try b.backgroundAlpha(id, c.r, c.g, c.b, @as(f32, @floatFromInt(c.a)) / 255.0);
}

fn propColor(c: theme.Color) props.PropValue {
    return .{ .color = .{
        .r = @as(f32, @floatFromInt(c.r)) / 255.0,
        .g = @as(f32, @floatFromInt(c.g)) / 255.0,
        .b = @as(f32, @floatFromInt(c.b)) / 255.0,
        .a = @as(f32, @floatFromInt(c.a)) / 255.0,
    } };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mountBar(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    mounts: *component.MountTable,
    t: theme.Theme,
    init_props: anytype,
) !*StatusBar {
    var b = component.UIBuilder.init(registry, store);
    b.theme = t;
    var ctx = BuildContext{ .builder = &b, .mounts = mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(StatusBar, init_props);
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
}

fn expectColor(store: *props.PropertyStore, node: reg.NodeId, fb: theme.Color) !void {
    const c = store.getStyle(node, .background).?.color;
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(fb.r)) / 255.0, c.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(fb.g)) / 255.0, c.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(fb.b)) / 255.0, c.b, 0.001);
}

test "StatusBar (mountOwned) paints each dot with its kind's fallback color" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    var items = [_]StatusItem{
        .{ .value = "Connected", .kind = .ok },
        .{ .value = "Idle", .kind = .neutral },
    };
    const bar = try mountBar(&registry, &store, &mounts, .{}, .{ .items = &items });

    try expectColor(&store, bar.slots.items[0].dot_node, FALLBACK[@intFromEnum(StatusKind.ok)]);
    try expectColor(&store, bar.slots.items[1].dot_node, FALLBACK[@intFromEnum(StatusKind.neutral)]);
    try testing.expectEqualStrings("Connected", store.getTextContent(bar.slots.items[0].text_node).?);
}

test "StatusBar rev bump re-applies a mutated slot: dot render-only, text relayouts" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    // Declared before `mounts` so the LIFO defers destroy the bar's effect
    // (mounts.deinit) before the signal it subscribes to.
    var rev = signals.Signal(u32).init(a, 0);
    defer rev.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);
    var items = [_]StatusItem{
        .{ .value = "Connected", .kind = .ok },
        .{ .value = "Idle", .kind = .neutral },
    };
    const bar = try mountBar(&registry, &store, &mounts, .{}, .{ .items = &items, .rev = &rev });

    const dot = bar.slots.items[0].dot_node;
    const txt = bar.slots.items[0].text_node;
    const other_txt = bar.slots.items[1].text_node;

    // Clear dirty flags so we can observe exactly what the update touches.
    for (registry.nodes.items) |*n| {
        n.layout_dirty = false;
        n.render_dirty = false;
    }

    items[0] = .{ .value = "Disconnected", .kind = .err };
    rev.set(rev.peek() + 1);

    // Dot: recolored to err, render-only (no layout invalidation).
    try expectColor(&store, dot, FALLBACK[@intFromEnum(StatusKind.err)]);
    try testing.expect(registry.getNode(dot).?.render_dirty);
    try testing.expect(!registry.getNode(dot).?.layout_dirty);

    // Value: content swapped and the text subtree relaid out.
    try testing.expectEqualStrings("Disconnected", store.getTextContent(txt).?);
    try testing.expect(registry.getNode(txt).?.layout_dirty);

    // The untouched slot's text is not rewritten (no relayout).
    try testing.expect(!registry.getNode(other_txt).?.layout_dirty);
}

test "StatusBar theme status color overrides the fallback" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    const custom = theme.Color{ .r = 10, .g = 20, .b = 30, .a = 255 };
    var items = [_]StatusItem{.{ .value = "Connected", .kind = .ok }};
    const bar = try mountBar(&registry, &store, &mounts, .{ .status_ok = custom }, .{ .items = &items });

    try expectColor(&store, bar.slots.items[0].dot_node, custom);
}
