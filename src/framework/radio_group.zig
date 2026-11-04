//! RadioGroup — a set of mutually-exclusive options driven by ONE signal.
//!
//! Framework-owned via `ctx.mountOwned(RadioGroup, .{ .options = &.{ "A", "B" } })`:
//! no `init`/`register`/`deinit`/action-id in user code. Unlike a bag of standalone
//! `Radio`s (each with its own `checked`), the group owns a single
//! `selected: Signal(usize)` that is the source of truth — the option rows read it,
//! so selecting one row deselects the rest for free. Each row is built once (ring +
//! always-present inner dot + label); a render-only effect drives every dot's alpha
//! and every ring's border off `selected`/`hovered` — selection never relays out.
//!
//! Per-row clicks/hover use ONE typed handler each that resolves the index by matching
//! the event's `node_id` against the captured row ids (no per-index string ids), the
//! same trick Dropdown uses for its option rows.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;
const Text = component.Text;
const EdgeInsets = component.EdgeInsets;

const NO_HOVER: usize = std.math.maxInt(usize);

pub const RadioGroup = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    options: []const []const u8 = &.{},
    on_change: ?events.Handler = null,
    initial_selected: usize = 0,
    disabled: bool = false,

    // State (auto-created in onMount; preserved across rebuilds).
    selected: signals.Signal(usize) = undefined,
    hovered: signals.Signal(usize) = undefined,
    scope: signals.Scope = undefined,
    /// Per-row ids for the current build (index ↔ option); repopulated each build.
    row_ids: std.array_list.Managed(reg.NodeId) = undefined,
    ring_ids: std.array_list.Managed(reg.NodeId) = undefined,
    dot_ids: std.array_list.Managed(reg.NodeId) = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    root_id: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,

    pub fn onMount(self: *RadioGroup, allocator: std.mem.Allocator) void {
        self.selected = signals.Signal(usize).init(allocator, self.initial_selected);
        self.hovered = signals.Signal(usize).init(allocator, NO_HOVER);
        self.scope = signals.Scope.init(allocator);
        self.row_ids = std.array_list.Managed(reg.NodeId).init(allocator);
        self.ring_ids = std.array_list.Managed(reg.NodeId).init(allocator);
        self.dot_ids = std.array_list.Managed(reg.NodeId).init(allocator);
    }

    pub fn deinit(self: *RadioGroup) void {
        self.scope.deinit();
        self.selected.deinit();
        self.hovered.deinit();
        self.row_ids.deinit();
        self.ring_ids.deinit();
        self.dot_ids.deinit();
    }

    /// Selects an option programmatically (e.g. syncing from external state).
    pub fn select(self: *RadioGroup, index: usize) void {
        self.selected.set(index);
    }

    /// One handler for every row: resolves the picked index by matching the event's
    /// node against the captured row ids, then selects (a radio never toggles off).
    fn onRowClick(self: *RadioGroup, ev: events.Event) void {
        if (self.disabled) return;
        for (self.row_ids.items, 0..) |it, i| {
            if (it == ev.node_id) {
                if (self.selected.peek() != i) {
                    self.selected.set(i);
                    if (self.on_change) |h| h.call(h.ptr, ev);
                }
                return;
            }
        }
    }

    fn onRowEnter(self: *RadioGroup, ev: events.Event) void {
        if (self.disabled) return;
        for (self.row_ids.items, 0..) |it, i| {
            if (it == ev.node_id) {
                self.hovered.set(i);
                return;
            }
        }
    }

    fn onRowLeave(self: *RadioGroup, ev: events.Event) void {
        _ = ev;
        self.hovered.set(NO_HOVER);
    }

    /// Arrows move the selection (clamped), notifying on change.
    fn onKey(self: *RadioGroup, ev: events.Event) void {
        if (self.disabled) return;
        const n = self.options.len;
        if (n == 0) return;
        const cur = self.selected.peek();
        const next = switch (ev.key_code) {
            38, 37 => if (cur == 0) 0 else cur - 1, // ↑ / ←
            40, 39 => @min(cur + 1, n - 1), // ↓ / →
            else => return,
        };
        if (next != cur) {
            self.selected.set(next);
            if (self.on_change) |h| h.call(h.ptr, ev);
        }
    }

    pub fn build(self: *RadioGroup, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;
        self.theme = t;
        self.store = b.store;
        self.row_ids.clearRetainingCapacity();
        self.ring_ids.clearRetainingCapacity();
        self.dot_ids.clearRetainingCapacity();

        self.root_id = try b.openNodeKeyed(.box, null);
        try b.role(self.root_id, "radiogroup");

        try ctx.box(.{
            .direction = .column,
            .focusable = !self.disabled,
            .on_key = if (self.disabled) null else ctx.handler(self, onKey),
        }, .{
            Rows{ .grp = self },
        });

        b.close(); // root

        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn updateVisuals(self: *RadioGroup) void {
        const store = self.store orelse return;
        const t = self.theme;
        const sel = self.selected.get();
        const hov = self.hovered.get();

        for (self.ring_ids.items, self.dot_ids.items, 0..) |ring_id, dot_id, i| {
            const checked = (i == sel);
            // Surface selection per row for accessibility (SelectionItem.get_IsSelected
            // reads `.checked`). row_ids is parallel to ring/dot ids.
            if (i < self.row_ids.items.len) store.setModifier(self.row_ids.items[i], .checked, .{ .boolean = checked }) catch {};
            const border = if (checked)
                props.PropValue.colorA(t.accent, 1.0)
            else if (i == hov)
                props.PropValue.colorA(t.accent, 150.0 / 255.0)
            else
                props.PropValue.rgbA(t.border_color.r, t.border_color.g, t.border_color.b, @as(f32, @floatFromInt(t.border_color.a)) / 255.0);
            store.setStyle(ring_id, .border_color, border) catch {};
            store.setStyle(dot_id, .background, props.PropValue.colorA(t.accent, if (checked) 1.0 else 0.0)) catch {};
        }
    }
};

/// The option rows. Each row is clickable/hoverable and shares one typed handler per
/// event; the ring/dot ids are captured for the selection effect and index resolution.
const Rows = struct {
    grp: *RadioGroup,
    pub fn build(self: *Rows, ctx: *BuildContext) !void {
        const grp = self.grp;
        const t = grp.theme;
        for (grp.options) |opt| {
            const row = try ctx.boxNode(.{
                .direction = .row,
                .@"align" = .center,
                .padding = EdgeInsets.symmetric(0, 4),
                .role = "radio", // each option row is a UIA SelectionItem
                .on_click = if (grp.disabled) null else ctx.handler(grp, RadioGroup.onRowClick),
                .on_hover_enter = if (grp.disabled) null else ctx.handler(grp, RadioGroup.onRowEnter),
                .on_hover_leave = if (grp.disabled) null else ctx.handler(grp, RadioGroup.onRowLeave),
            }, .{
                Indicator{ .grp = grp },
                Text{ .content = opt, .color = component.rgb(t.text.r, t.text.g, t.text.b), .style = t.typography.body_medium },
            });
            try grp.row_ids.append(row);
        }
    }
    pub fn deinit(_: *Rows) void {}
};

/// The 18×18 ring with the always-present inner dot. Built as its own slot so the
/// row can use the declarative props path; captures the ring/dot node ids.
const Indicator = struct {
    grp: *RadioGroup,
    pub fn build(self: *Indicator, ctx: *BuildContext) !void {
        const ring = try ctx.boxNode(.{
            .width = 18,
            .height = 18,
            .radius = 9,
            .border_width = 1,
            .@"align" = .center,
            .justify = .center,
            .margin = EdgeInsets.only(0, 8, 0, 0),
        }, .{
            Dot{},
        });
        try self.grp.ring_ids.append(ring);
        try self.grp.dot_ids.append(ctx.builder.registry.getNode(ring).?.first_child);
    }
    pub fn deinit(_: *Indicator) void {}
};

/// The 10×10 inner dot (its fill alpha encodes selection, painted by the effect).
const Dot = struct {
    pub fn build(_: *Dot, ctx: *BuildContext) !void {
        try ctx.boxLeaf(.{ .width = 10, .height = 10, .radius = 5 });
    }
    pub fn deinit(_: *Dot) void {}
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const dark = theme_mod.Theme.dark();

const OPTS = [_][]const u8{ "One", "Two", "Three" };

fn mountGroup(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    router: *events.EventRouter,
    mounts: *component.MountTable,
    init_props: anytype,
) !*RadioGroup {
    var b = component.UIBuilder.init(registry, store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = router, .mounts = mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(RadioGroup, init_props);
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
}

fn setup(a: std.mem.Allocator, registry: *reg.UIRegistry, store: *props.PropertyStore, router: *events.EventRouter, mounts: *component.MountTable) void {
    registry.* = reg.UIRegistry.init(a);
    store.* = props.PropertyStore.init(a);
    store.setRegistry(registry);
    router.* = events.EventRouter.init(a);
    mounts.* = component.MountTable.init(a);
    registry.addNodeRemovedListener(mounts, component.MountTable.nodeRemovedListener);
}

test "RadioGroup click selects a row and deselects the previous one" {
    const a = testing.allocator;
    var registry: reg.UIRegistry = undefined;
    var store: props.PropertyStore = undefined;
    var router: events.EventRouter = undefined;
    var mounts: component.MountTable = undefined;
    setup(a, &registry, &store, &router, &mounts);
    defer registry.deinit();
    defer store.deinit();
    defer router.deinit();
    defer mounts.deinit();

    const Sink = struct {
        var changes: u32 = 0;
        fn onChange(_: ?*anyopaque, _: events.Event) void {
            changes += 1;
        }
    };
    Sink.changes = 0;

    const grp = try mountGroup(&registry, &store, &router, &mounts, .{
        .options = &OPTS,
        .on_change = events.Handler{ .ptr = null, .call = Sink.onChange },
    });

    // Default selection is index 0: its dot is filled, the others are empty.
    try testing.expectEqual(@as(usize, 0), grp.selected.peek());
    try testing.expectApproxEqAbs(@as(f32, 1.0), store.getStyle(grp.dot_ids.items[0], .background).?.color.a, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getStyle(grp.dot_ids.items[1], .background).?.color.a, 0.001);

    // Click row 2 (index 1): it becomes selected, row 0 clears — render-only.
    registry.getNode(grp.dot_ids.items[1]).?.layout_dirty = false;
    _ = router.route(.{ .name = "click", .id = "", .node_id = grp.row_ids.items[1] });

    try testing.expectEqual(@as(usize, 1), grp.selected.peek());
    try testing.expectApproxEqAbs(@as(f32, 1.0), store.getStyle(grp.dot_ids.items[1], .background).?.color.a, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getStyle(grp.dot_ids.items[0], .background).?.color.a, 0.001);
    try testing.expect(!registry.getNode(grp.dot_ids.items[1]).?.layout_dirty);
    try testing.expectEqual(@as(u32, 1), Sink.changes);

    // Clicking the already-selected row is a no-op (no extra on_change).
    _ = router.route(.{ .name = "click", .id = "", .node_id = grp.row_ids.items[1] });
    try testing.expectEqual(@as(u32, 1), Sink.changes);
}

test "RadioGroup honors initial_selected" {
    const a = testing.allocator;
    var registry: reg.UIRegistry = undefined;
    var store: props.PropertyStore = undefined;
    var router: events.EventRouter = undefined;
    var mounts: component.MountTable = undefined;
    setup(a, &registry, &store, &router, &mounts);
    defer registry.deinit();
    defer store.deinit();
    defer router.deinit();
    defer mounts.deinit();

    const grp = try mountGroup(&registry, &store, &router, &mounts, .{ .options = &OPTS, .initial_selected = 2 });
    try testing.expectEqual(@as(usize, 2), grp.selected.peek());
    try testing.expectApproxEqAbs(@as(f32, 1.0), store.getStyle(grp.dot_ids.items[2], .background).?.color.a, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getStyle(grp.dot_ids.items[0], .background).?.color.a, 0.001);
}

test "RadioGroup arrow keys move the selection, clamped at the ends" {
    const a = testing.allocator;
    var registry: reg.UIRegistry = undefined;
    var store: props.PropertyStore = undefined;
    var router: events.EventRouter = undefined;
    var mounts: component.MountTable = undefined;
    setup(a, &registry, &store, &router, &mounts);
    defer registry.deinit();
    defer store.deinit();
    defer router.deinit();
    defer mounts.deinit();

    const grp = try mountGroup(&registry, &store, &router, &mounts, .{ .options = &OPTS });
    const root = grp.root_id;
    // The focusable node is the inner column (first child of the anchor's root).
    const col = registry.getNode(root).?.first_child;

    _ = router.route(.{ .name = "key_down", .id = "", .node_id = col, .key_code = 40 }); // ↓
    try testing.expectEqual(@as(usize, 1), grp.selected.peek());
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = col, .key_code = 40 }); // ↓
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = col, .key_code = 40 }); // ↓ (clamped)
    try testing.expectEqual(@as(usize, 2), grp.selected.peek());
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = col, .key_code = 38 }); // ↑
    try testing.expectEqual(@as(usize, 1), grp.selected.peek());
}

const Host = struct {
    show: *signals.Signal(bool),
    scope: *signals.Scope,
    pub fn build(self: *Host, ctx: *BuildContext) !void {
        if (self.show.get()) try ctx.mountOwned(RadioGroup, .{ .options = &OPTS });
    }
};

test "RadioGroup mount/unmount ×64 leaves no leaks" {
    const a = testing.allocator;
    var registry: reg.UIRegistry = undefined;
    var store: props.PropertyStore = undefined;
    var router: events.EventRouter = undefined;
    var mounts: component.MountTable = undefined;
    setup(a, &registry, &store, &router, &mounts);
    defer registry.deinit();
    defer store.deinit();
    defer router.deinit();
    defer mounts.deinit();

    var show = signals.Signal(bool).init(a, true);
    defer show.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();

    var host = Host{ .show = &show, .scope = &scope };

    var b = component.UIBuilder.init(&registry, &store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountReactive(&scope, &host);
    b.close();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        show.set(false);
        show.set(true);
    }
    // Balanced mount/unmount; testing.allocator asserts no leak at teardown.
}
