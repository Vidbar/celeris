//! Toast / in-app notification — a singleton `ToastHost` mounted once by
//! `runApp`, stacking auto-dismissing panels in the bottom-right corner.
//!
//! The host follows the same shape as `TooltipHost`: it builds a fixed set of
//! overlay slots ONCE (a bottom-right absolute column of `MAX_TOASTS` panels), and a
//! fine effect toggles each slot's size / colour / text — no subtree rebuild. Panels
//! sit at a high `z_index` so they paint over the app even though the host mounts
//! early.
//!
//!   • `show(text, kind, duration_ms)` appends a toast (dropping the oldest when the
//!     stack is full) and bumps a revision signal so the effect repaints.
//!   • `onTick` decrements every live toast's remaining ticks and drops the expired
//!     ones (compacting the stack), then repaints if anything changed.
//!
//! A file-global pointer to the mounted host (`g_host`) backs the free function
//! `toast.show(...)`, so app code can raise a toast without threading the instance
//! around. It is set on first build and cleared in `onUnmount`.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;

/// Maximum number of toasts visible at once; older ones are dropped past this.
pub const MAX_TOASTS: usize = 4;
const MAX_TEXT = 256;

const FONT_SIZE: f32 = 13;
const PAD_X: f32 = 12;
const PAD_Y: f32 = 9;
const TOAST_W: f32 = 280;
const PANEL_H: f32 = FONT_SIZE + 2 * PAD_Y;
const GAP: f32 = 8;
const MARGIN: f32 = 16;

/// Above `TooltipHost` (200), so a notification stacks over a hover hint.
const Z_INDEX: f32 = 210;
/// Default lifetime when `show` is given a zero/omitted duration. Converted to a
/// tick count with `events.ticksForMs` — NOT with an assumed frame rate: this used
/// to be `ms * 60 / 1000` under a "ticks fire per frame" comment, which made the
/// default 4s toast last 240 ticks ≈ 2 MINUTES on screen.
const DEFAULT_MS: u32 = 4000;

pub const ToastKind = enum { info, success, warning, danger };

const Toast = struct {
    buf: [MAX_TEXT]u8 = undefined,
    len: usize = 0,
    kind: ToastKind = .info,
    remaining: u32 = 0,
};

pub const ToastHost = struct {
    // State (auto-created in onMount).
    rev: signals.Signal(u32) = undefined,
    scope: signals.Scope = undefined,
    items: [MAX_TOASTS]Toast = undefined,
    count: usize = 0,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    registry: ?*reg.UIRegistry = null,
    router: ?*events.EventRouter = null,
    theme: theme_mod.Theme = .{},
    container_id: reg.NodeId = reg.NULL_NODE,
    panel_ids: [MAX_TOASTS]reg.NodeId = [_]reg.NodeId{reg.NULL_NODE} ** MAX_TOASTS,
    text_ids: [MAX_TOASTS]reg.NodeId = [_]reg.NodeId{reg.NULL_NODE} ** MAX_TOASTS,
    bound: bool = false,

    pub fn onMount(self: *ToastHost, allocator: std.mem.Allocator) void {
        self.rev = signals.Signal(u32).init(allocator, 0);
        self.scope = signals.Scope.init(allocator);
        self.count = 0;
    }

    pub fn deinit(self: *ToastHost) void {
        self.scope.deinit();
        self.rev.deinit();
    }

    pub fn onUnmount(self: *ToastHost) void {
        if (g_host == self) g_host = null;
    }

    /// Pushes a toast onto the stack. `duration_ms == 0` uses the default lifetime.
    /// Dropping the oldest keeps the newest `MAX_TOASTS`.
    pub fn show(self: *ToastHost, text: []const u8, kind: ToastKind, duration_ms: u32) void {
        const ms = if (duration_ms == 0) DEFAULT_MS else duration_ms;
        const ticks: u32 = events.ticksForMs(ms);

        if (self.count == MAX_TOASTS) {
            // Drop the oldest (front) and shift the rest down.
            var i: usize = 1;
            while (i < MAX_TOASTS) : (i += 1) self.items[i - 1] = self.items[i];
            self.count -= 1;
        }
        var t = &self.items[self.count];
        const n = @min(text.len, MAX_TEXT);
        @memcpy(t.buf[0..n], text[0..n]);
        t.len = n;
        t.kind = kind;
        t.remaining = ticks;
        self.count += 1;
        self.rev.set(self.rev.peek() + 1);
    }

    fn onTick(self: *ToastHost) void {
        if (self.count == 0) return;
        var changed = false;
        var i: usize = 0;
        while (i < self.count) {
            if (self.items[i].remaining <= 1) {
                // Expired: remove and compact.
                var j = i + 1;
                while (j < self.count) : (j += 1) self.items[j - 1] = self.items[j];
                self.count -= 1;
                changed = true;
                // Don't advance i: the shifted-in item now sits at i.
            } else {
                self.items[i].remaining -= 1;
                i += 1;
            }
        }
        if (changed) self.rev.set(self.rev.peek() + 1);
    }

    fn kindColor(self: *const ToastHost, kind: ToastKind) struct { bg: theme_mod.Color, fg: theme_mod.Color } {
        const t = self.theme;
        return switch (kind) {
            .info => .{ .bg = t.inverse_surface, .fg = t.inverse_on_surface },
            .success => .{ .bg = t.success, .fg = t.text_on_accent },
            .warning => .{ .bg = t.warning, .fg = t.text_on_accent },
            .danger => .{ .bg = t.danger, .fg = t.text_on_accent },
        };
    }

    pub fn build(self: *ToastHost, ctx: *BuildContext) !void {
        const b = ctx.builder;
        self.theme = b.theme;
        self.store = b.store;
        self.registry = b.registry;
        self.router = ctx.router;

        // Bottom-right column, built once and toggled by the effect. `updateVisuals`
        // recomputes left/top from the root geometry in WINDOW coordinates, which is
        // exactly the space `openOverlay` establishes (see it for why the anchor has
        // to be pinned for that to hold).
        self.container_id = try b.openOverlay(Z_INDEX);
        try b.flexColumn(self.container_id);
        try b.width(self.container_id, TOAST_W, .px);

        var i: usize = 0;
        while (i < MAX_TOASTS) : (i += 1) {
            const panel = try b.openNodeKeyed(.box, null);
            self.panel_ids[i] = panel;
            try b.width(panel, TOAST_W, .px);
            try b.height(panel, 0, .px);
            try b.padding(panel, PAD_Y, PAD_X, PAD_Y, PAD_X);
            try b.radius(panel, 6);
            try b.overflowHidden(panel);
            const tx = try b.addText("");
            self.text_ids[i] = tx;
            try b.store.setStyle(tx, .font_size, .{ .dimension = .{ .value = FONT_SIZE, .unit = .px } });
            b.close(); // panel
        }
        b.close(); // container

        if (!self.bound) {
            _ = try self.scope.createEffect(self, updateVisuals);
            g_host = self;
            self.bound = true;
        } else {
            g_host = self;
            const prev = signals.untrackedBegin();
            self.updateVisuals();
            signals.untrackedEnd(prev);
        }
        // Unconditional every build: onTick replaces in place per owner (see
        // ProgressBar/events.zig), and the node-removed hook prunes it on unmount.
        if (ctx.router) |r| try r.onTick(self.container_id, self, onTick);
    }

    fn updateVisuals(self: *ToastHost) void {
        const store = self.store orelse return;
        _ = self.rev.get(); // subscribe: show / expiry bumps
        if (self.container_id == reg.NULL_NODE) return;
        var i: usize = 0;
        while (i < MAX_TOASTS) : (i += 1) {
            const panel = self.panel_ids[i];
            const tx = self.text_ids[i];
            if (i < self.count) {
                const item = &self.items[i];
                // setTextContent takes ownership of a store-allocator slice, so hand
                // it an owned dup — never the instance buffer.
                const owned = store.stringAllocator().dupe(u8, item.buf[0..item.len]) catch continue;
                store.setTextContent(tx, owned);
                const colors = self.kindColor(item.kind);
                store.setStyle(panel, .background, props.PropValue.rgbA(colors.bg.r, colors.bg.g, colors.bg.b, 1.0)) catch {};
                store.setStyle(tx, .color, props.PropValue.colorA(colors.fg, 1.0)) catch {};
                store.setLayout(panel, .height, .{ .dimension = .{ .value = PANEL_H, .unit = .px } }) catch {};
                store.setLayout(panel, .margin_top, .{ .dimension = .{ .value = if (i == 0) 0 else GAP, .unit = .px } }) catch {};
            } else {
                store.setTextContent(tx, store.stringAllocator().dupe(u8, "") catch continue);
                store.setLayout(panel, .height, .{ .dimension = .{ .value = 0, .unit = .px } }) catch {};
                store.setLayout(panel, .margin_top, .{ .dimension = .{ .value = 0, .unit = .px } }) catch {};
            }
        }

        // Anchor the column bottom-right within the window (root geometry).
        const stack_h = if (self.count == 0) 0 else @as(f32, @floatFromInt(self.count)) * PANEL_H + @as(f32, @floatFromInt(self.count - 1)) * GAP;
        var left: f32 = MARGIN;
        var top: f32 = MARGIN;
        if (self.registry) |registry| {
            if (registry.getNode(0)) |root| {
                left = @max(0, root.geometry.width - TOAST_W - MARGIN);
                top = @max(0, root.geometry.height - stack_h - MARGIN);
            }
        }
        store.setLayout(self.container_id, .left, .{ .dimension = .{ .value = left, .unit = .px } }) catch {};
        store.setLayout(self.container_id, .top, .{ .dimension = .{ .value = top, .unit = .px } }) catch {};
    }
};

/// File-global handle to the mounted host, backing the free `show` below.
var g_host: ?*ToastHost = null;

/// Raise a toast from anywhere in app code (no instance threading required). A no-op
/// if no `ToastHost` is mounted (e.g. headless).
pub fn show(text: []const u8, kind: ToastKind, duration_ms: u32) void {
    if (g_host) |h| h.show(text, kind, duration_ms);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const dark = theme_mod.Theme.dark();

const TestEnv = @import("test_support.zig").Harness;

fn mountHost(env: *TestEnv) !*ToastHost {
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(ToastHost, .{});
    b.close();
    // Simulate a solved window so the column can anchor bottom-right.
    env.registry.getNode(0).?.geometry = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const anchor = env.registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));
}

fn tick(env: *TestEnv, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) _ = env.router.route(.{ .name = "tick", .id = "" });
}

test "Toast: the panel is really on screen after a layout solve" {
    // Mirrors TooltipHost's equivalent test, and for the same reason: the store-only
    // assertions below stayed green while every toast in a real app painted ~776px
    // BELOW the window (the mount anchor sat in-flow under a flex-grow `body`, and
    // the container's window-coordinate math was offset by it) — and, before the
    // layout-engine fix, resolved to 0x0 on top of that.
    const WIN_W: f32 = 800;
    const WIN_H: f32 = 600;

    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };

    const root = try b.openNodeKeyed(.box, null);
    try b.flexColumn(root);
    try b.width(root, WIN_W, .px);
    try b.height(root, WIN_H, .px);

    const body = try b.openNodeKeyed(.box, null);
    try b.width(body, 100, .percent);
    try b.flexGrow(body, 1);
    b.close();

    try ctx.mountOwned(ToastHost, .{});
    b.close(); // root

    const anchor = env.registry.getNode(body).?.next_sibling;
    const host: *ToastHost = @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));

    env.solve(root, WIN_W, WIN_H);
    host.show("Saved", .success, 4000);
    env.solve(root, WIN_W, WIN_H);

    const panel = env.geom(host.panel_ids[0]);
    try testing.expect(panel.width > 0);
    try testing.expect(panel.height > 0);

    // Fully inside the window — this is the assertion that was off by a window height.
    try testing.expect(panel.x >= 0);
    try testing.expect(panel.y >= 0);
    try testing.expect(panel.x + panel.width <= WIN_W);
    try testing.expect(panel.y + panel.height <= WIN_H);

    // And in the bottom-right quadrant, where a toast belongs.
    try testing.expect(panel.x > WIN_W / 2);
    try testing.expect(panel.y > WIN_H / 2);
}

test "Toast show presents a panel with its text" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const host = try mountHost(&env);

    // Nothing visible initially.
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getLayout(host.panel_ids[0], .height).?.dimension.value, 0.001);

    host.show("Saved", .success, 200);
    try testing.expectEqual(@as(usize, 1), host.count);
    try testing.expect(env.store.getLayout(host.panel_ids[0], .height).?.dimension.value > 0);
    try testing.expectEqualStrings("Saved", env.store.getTextContent(host.text_ids[0]).?);
}

test "Toast auto-dismisses after its duration" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const host = try mountHost(&env);

    // Durations are wall-clock ms, converted against the router's real tick cadence
    // — assert that conversion here, so a widget that starts deriving tick counts
    // from an assumed frame rate again (the 4s-toast-lasts-2-minutes bug) fails loudly.
    const dur_ms: u32 = 2 * events.TICK_MS;
    try testing.expectEqual(@as(u32, 2), events.ticksForMs(dur_ms));

    host.show("Bye", .info, dur_ms);
    try testing.expectEqual(@as(usize, 1), host.count);

    tick(&env, 1); // one tick short of the duration → still up
    try testing.expectEqual(@as(usize, 1), host.count);

    tick(&env, 1);
    try testing.expectEqual(@as(usize, 0), host.count);
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getLayout(host.panel_ids[0], .height).?.dimension.value, 0.001);
}

test "Toasts stack in show order and cap at MAX_TOASTS" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const host = try mountHost(&env);

    host.show("one", .info, 5000);
    host.show("two", .info, 5000);
    host.show("three", .info, 5000);

    try testing.expectEqual(@as(usize, 3), host.count);
    try testing.expectEqualStrings("one", env.store.getTextContent(host.text_ids[0]).?);
    try testing.expectEqualStrings("two", env.store.getTextContent(host.text_ids[1]).?);
    try testing.expectEqualStrings("three", env.store.getTextContent(host.text_ids[2]).?);

    // Overflow drops the oldest, keeping the newest MAX_TOASTS in order.
    host.show("four", .info, 5000);
    host.show("five", .info, 5000);
    try testing.expectEqual(MAX_TOASTS, host.count);
    try testing.expectEqualStrings("two", env.store.getTextContent(host.text_ids[0]).?);
    try testing.expectEqualStrings("five", env.store.getTextContent(host.text_ids[MAX_TOASTS - 1]).?);
}

test "Toast tick handler is removed on unmount" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(ToastHost, .{});
    b.close();
    try testing.expectEqual(@as(usize, 1), env.router.tick_handlers.items.len);

    try b.rootAt(root);
    b.close();
    try testing.expectEqual(@as(usize, 0), env.router.tick_handlers.items.len);
    try testing.expect(g_host == null);
}
