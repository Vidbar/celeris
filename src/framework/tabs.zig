//! Tabs — reactive component migrated to the canonical pattern.
//!
//! Framework-owned via `ctx.mountOwned(Tabs, .{ .fill = true, .items = &tab_items,
//! .active = &app.active_tab })`: no `init`/`register`/`addTab`/action-id in user code.
//!
//!  • **items**: a `[]const TabItem{ title, child }` prop (caller-owned Child handles).
//!  • **active**: optional caller-owned `?*Signal(usize)` (lifted state), so the app
//!    can switch tabs (e.g. "Run Agent" → Agent tab) by writing the signal — no widget
//!    pointer. Omit it to use the internal fallback seeded from `initial_active`.
//!
//! A single effect watches `active`: it partial-rebuilds the content area for the new
//! tab (via `rootAt`, carrying measure/clipboard so hosted text widgets keep caret
//! metrics) and repaints the header highlight. The child build runs **untracked** so
//! the child's own signals aren't attributed to the Tabs effect. Tab clicks resolve
//! the index by matching the event node against the captured header-button ids.

const std = @import("std");
const builder_mod = @import("builder.zig");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");

pub const TabItem = struct {
    title: []const u8,
    child: component.Child,
};

pub const Tabs = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    items: []const TabItem = &.{},
    /// Optional caller-owned active index (two-way, lifted-state convention).
    /// Pass it to drive tab switching from the app; omit to use the internal
    /// `active_state` seeded from `initial_active`.
    active: ?*signals.Signal(usize) = null,
    initial_active: usize = 0,

    // State (auto-created in onMount; preserved across rebuilds). `active_state`
    // is the fallback when the caller passes no `active` signal.
    scope: signals.Scope = undefined,
    active_state: signals.Signal(usize) = undefined,
    tab_btn_ids: std.array_list.Managed(reg.NodeId) = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    theme: @import("theme.zig").Theme = .{},
    router: ?*events.EventRouter = null,
    mounts: ?*component.MountTable = null,
    measure: ?builder_mod.TextMeasure = null,
    clipboard: ?builder_mod.Clipboard = null,
    content_node: reg.NodeId = reg.NULL_NODE,
    bound: bool = false,

    pub fn onMount(self: *Tabs, allocator: std.mem.Allocator) void {
        self.scope = signals.Scope.init(allocator);
        self.active_state = signals.Signal(usize).init(allocator, self.initial_active);
        self.tab_btn_ids = std.array_list.Managed(reg.NodeId).init(allocator);
    }

    /// The active-index signal: caller-owned if provided, else the internal one.
    fn activeSig(self: *Tabs) *signals.Signal(usize) {
        return self.active orelse &self.active_state;
    }

    pub fn deinit(self: *Tabs) void {
        self.scope.deinit();
        self.active_state.deinit();
        self.tab_btn_ids.deinit();
    }

    /// Resolves the clicked header button to its index and drives the active signal.
    fn onTabClick(self: *Tabs, ev: events.Event) void {
        for (self.tab_btn_ids.items, 0..) |btn, i| {
            if (btn == ev.node_id) {
                if (i != self.activeSig().peek()) self.activeSig().set(i);
                return;
            }
        }
    }

    /// ←/→ on a focused header button cycle the active tab (with wrap).
    /// Enter/Space are the engine's click synthesis → they select the focused tab.
    fn onTabKey(self: *Tabs, ev: events.Event) void {
        const n = self.items.len;
        if (n == 0) return;
        const cur = self.activeSig().peek();
        const next = switch (ev.key_code) {
            37 => if (cur == 0) n - 1 else cur - 1, // ←
            39 => (cur + 1) % n, // →
            else => return,
        };
        if (next != cur) self.activeSig().set(next);
    }

    pub fn build(self: *Tabs, ctx: *component.BuildContext) !void {
        const b = ctx.builder;
        self.store = b.store;
        self.theme = b.theme;
        self.router = ctx.router;
        self.mounts = ctx.mounts;
        self.measure = b.measure;
        self.clipboard = b.clipboard;
        self.tab_btn_ids.clearRetainingCapacity();

        const container = try b.openNodeKeyed(.box, null);
        try b.flexColumn(container);
        try b.width(container, 100, .percent);
        try b.height(container, 100, .percent);

        // Header row.
        const header = try b.openNodeKeyed(.box, null);
        try b.flexRow(header);
        try b.width(header, 100, .percent);
        try b.height(header, 35, .px);
        try b.background(header, b.theme.bg_surface.r, b.theme.bg_surface.g, b.theme.bg_surface.b);

        for (self.items) |item| {
            const tab_btn = try b.openNodeKeyed(.box, null);
            try self.tab_btn_ids.append(tab_btn);
            try b.flexRow(tab_btn);
            try b.padding(tab_btn, 8, 16, 8, 16);
            var idbuf: [16]u8 = undefined;
            const aid = std.fmt.bufPrint(&idbuf, "n{d}", .{tab_btn}) catch "n";
            try b.clickable(tab_btn, aid);
            try b.hoverable(tab_btn, aid);
            try b.focusable(tab_btn, aid); // Tabs are reachable + arrow-operable
            if (ctx.router) |r| {
                try r.onNode(tab_btn, .click, ctx.handler(self, onTabClick));
                try r.onNode(tab_btn, .key_down, ctx.handler(self, onTabKey));
            }

            const text_node = try b.addText(item.title);
            const tsec = b.theme.text_secondary;
            try b.store.setStyle(text_node, .color, .{ .color = .{ .r = @as(f32, @floatFromInt(tsec.r)) / 255.0, .g = @as(f32, @floatFromInt(tsec.g)) / 255.0, .b = @as(f32, @floatFromInt(tsec.b)) / 255.0, .a = 1.0 } });
            try b.pointerEventsNone(text_node);
            b.close(); // tab_btn
        }
        b.close(); // header

        // Content area — filled by the sync effect (initial + on active change).
        const content_area = try b.openNodeKeyed(.box, null);
        self.content_node = content_area;
        try b.flexGrow(content_area, 1);
        try b.width(content_area, 100, .percent);
        b.close();

        b.close(); // container

        try component.bindVisuals(self, &self.scope, &self.bound, sync);
    }

    /// Effect body: rebuild the active tab's content and repaint the header. Reads
    /// `active` (subscribing on the first run) so writing it — by a tab click or by
    /// the app — switches tabs reactively.
    fn sync(self: *Tabs) void {
        const active = self.activeSig().get();
        self.rebuildContent(active);
        self.updateHeader(active);
    }

    /// Partial rebuild of the content area for tab `idx` — the subtree rebuild
    /// via `rootAt`. Carries measure/clipboard so a hosted text widget keeps caret
    /// metrics; builds the child untracked so its signals aren't tied to this effect.
    fn rebuildContent(self: *Tabs, idx: usize) void {
        const store = self.store orelse return;
        const registry = store.registry orelse return;
        if (self.content_node == reg.NULL_NODE) return;
        if (idx >= self.items.len) return;

        var b = builder_mod.UIBuilder.init(registry, store);
        b.theme = self.theme;
        b.measure = self.measure;
        b.clipboard = self.clipboard;
        b.rootAt(self.content_node) catch return;
        var bctx = component.BuildContext{ .builder = &b, .router = self.router, .mounts = self.mounts };
        const prev = signals.untrackedBegin();
        self.items[idx].child.build(&bctx) catch {};
        signals.untrackedEnd(prev);
        std.debug.assert(b.parent_stack.len == 1);
        b.close();
        registry.markLayoutDirty(self.content_node);
    }

    fn updateHeader(self: *Tabs, active: usize) void {
        const store = self.store orelse return;
        for (self.tab_btn_ids.items, 0..) |btn, i| {
            const shade: f32 = if (i == active) 40.0 / 255.0 else 30.0 / 255.0;
            store.setStyle(btn, .background, .{ .color = .{ .r = shade, .g = shade, .b = shade, .a = 1.0 } }) catch {};
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const ts = @import("test_support.zig");

/// A stub leaf that tags its root node via a height so tests can tell tabs apart.
fn StubTab(comptime h: f32) type {
    return struct {
        const Self = @This();
        pub fn build(_: *Self, ctx: *component.BuildContext) !void {
            const n = try ctx.builder.openNodeKeyed(.box, null);
            try ctx.builder.height(n, h, .px);
            ctx.builder.close();
        }
        pub fn deinit(_: *Self) void {}
    };
}

/// Mounts a Tabs via mountOwned and returns (instance, anchor).
fn mountTabs(
    env: *ts.Harness,
    items: []const TabItem,
    active: *signals.Signal(usize),
) !*Tabs {
    var b = component.UIBuilder.init(&env.registry, &env.store);
    var ctx = component.BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(Tabs, .{ .items = items, .active = active });
    b.close();
    const anchor = env.registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));
}

test "Tabs (mountOwned) click drives the active signal, repaints header, rebuilds content" {
    const a = testing.allocator;
    // Declared before `mounts` so it outlives the sync effect that subscribes to it.
    var active = signals.Signal(usize).init(a, 0);
    defer active.deinit();
    var env = ts.Harness.init(a);
    defer env.deinit();
    env.wire();

    const A = StubTab(11.0);
    const B = StubTab(22.0);
    var stub_a = A{};
    var stub_b = B{};
    const items = [_]TabItem{
        .{ .title = "a.zig", .child = component.childOf(A, &stub_a) },
        .{ .title = "b.zig", .child = component.childOf(B, &stub_b) },
    };

    const tabs = try mountTabs(&env, &items, &active);

    // Active tab 0: content child has height 11; header highlights tab 0.
    const c0 = env.registry.getChildAt(tabs.content_node, 0);
    try testing.expectApproxEqAbs(@as(f32, 11.0), env.store.getLayout(c0, .height).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40.0 / 255.0), env.store.getStyle(tabs.tab_btn_ids.items[0], .background).?.color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 30.0 / 255.0), env.store.getStyle(tabs.tab_btn_ids.items[1], .background).?.color.r, 0.001);

    // Click tab 1 → active signal = 1, content height 22, header highlight moves.
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = tabs.tab_btn_ids.items[1] });
    try testing.expectEqual(@as(usize, 1), active.peek());
    const c1 = env.registry.getChildAt(tabs.content_node, 0);
    try testing.expectApproxEqAbs(@as(f32, 22.0), env.store.getLayout(c1, .height).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40.0 / 255.0), env.store.getStyle(tabs.tab_btn_ids.items[1], .background).?.color.r, 0.001);
}

test "Tabs arrow keys on a focused header button cycle the active tab with wrap" {
    const a = testing.allocator;
    var active = signals.Signal(usize).init(a, 0);
    defer active.deinit();
    var env = ts.Harness.init(a);
    defer env.deinit();
    env.wire();

    const A = StubTab(11.0);
    const B = StubTab(22.0);
    var stub_a = A{};
    var stub_b = B{};
    const items = [_]TabItem{
        .{ .title = "a", .child = component.childOf(A, &stub_a) },
        .{ .title = "b", .child = component.childOf(B, &stub_b) },
    };

    const tabs = try mountTabs(&env, &items, &active);
    const btn0 = tabs.tab_btn_ids.items[0];

    // Header buttons are focusable (Tab-reachable).
    try testing.expect(env.store.getModifier(btn0, .focusable) != null);

    // → advances; → again wraps back to 0; ← wraps to the last.
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = btn0, .key_code = 39 });
    try testing.expectEqual(@as(usize, 1), active.peek());
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = btn0, .key_code = 39 });
    try testing.expectEqual(@as(usize, 0), active.peek());
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = btn0, .key_code = 37 });
    try testing.expectEqual(@as(usize, 1), active.peek());
}

test "Tabs (mountOwned) app-driven active switch rebuilds content without a click" {
    const a = testing.allocator;
    var active = signals.Signal(usize).init(a, 0);
    defer active.deinit();
    var env = ts.Harness.init(a);
    defer env.deinit();
    env.wire();

    const A = StubTab(11.0);
    const B = StubTab(22.0);
    var stub_a = A{};
    var stub_b = B{};
    const items = [_]TabItem{
        .{ .title = "a", .child = component.childOf(A, &stub_a) },
        .{ .title = "b", .child = component.childOf(B, &stub_b) },
    };

    const tabs = try mountTabs(&env, &items, &active);

    // The app writes the external signal (as "Run Agent" does) → content switches.
    active.set(1);
    const c1 = env.registry.getChildAt(tabs.content_node, 0);
    try testing.expectApproxEqAbs(@as(f32, 22.0), env.store.getLayout(c1, .height).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40.0 / 255.0), env.store.getStyle(tabs.tab_btn_ids.items[1], .background).?.color.r, 0.001);
}

/// Reproduces the dashboard ComponentsTab pattern inside a tab: a body that env.mounts a
/// widget with `ctx.mountOwned`. Guards the env.mounts+env.router threading + real rendering.
const WidgetHost = struct {
    pub fn build(_: *WidgetHost, ctx: *component.BuildContext) !void {
        const checkbox = @import("checkbox.zig");
        try ctx.mountOwned(checkbox.Checkbox, .{ .label = "Enable", .initial_checked = true });
    }
    pub fn deinit(_: *WidgetHost) void {}
};

test "Tabs (mountOwned) a mountOwned widget hosted in a tab builds and cleans up on switch" {
    const checkbox = @import("checkbox.zig");
    const a = testing.allocator;
    var active = signals.Signal(usize).init(a, 0);
    defer active.deinit();
    var env = ts.Harness.init(a);
    defer env.deinit();
    env.wire();

    const A = StubTab(11.0);
    var stub_a = A{};
    var host = WidgetHost{};
    const items = [_]TabItem{
        .{ .title = "a", .child = component.childOf(A, &stub_a) },
        .{ .title = "w", .child = component.childOf(WidgetHost, &host) },
    };

    const tabs = try mountTabs(&env, &items, &active);
    _ = tabs;
    // Switch to the widget tab: the checkbox env.mounts (1 record: the checkbox; Tabs
    // itself uses the caller's env.mounts table too, so filter by type via role).
    active.set(1);
    var found = false;
    var it = env.mounts.map.iterator();
    while (it.next()) |e| {
        const rec = e.value_ptr.*;
        // The checkbox instance exposes role "checkbox" on its root once built.
        const cb: *checkbox.Checkbox = @ptrCast(@alignCast(rec.component_ptr));
        _ = cb;
        if (env.store.getModifier(env.registry.getNode(e.key_ptr.*).?.first_child, .role)) |m| {
            if (std.mem.eql(u8, m.string, "checkbox")) found = true;
        }
    }
    try testing.expect(found);

    // Switch away → the checkbox anchor is reconciled out and its record removed.
    active.set(0);
    var still_cb = false;
    var it2 = env.mounts.map.iterator();
    while (it2.next()) |e| {
        if (env.store.getModifier(env.registry.getNode(e.key_ptr.*).?.first_child, .role)) |m| {
            if (std.mem.eql(u8, m.string, "checkbox")) still_cb = true;
        }
    }
    try testing.expect(!still_cb);
}
