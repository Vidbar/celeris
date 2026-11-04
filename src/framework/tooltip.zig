//! Tooltip — a singleton `TooltipHost` mounted once by `runApp`, plus the
//! declarative `.tooltip = "text"` prop any box can carry.
//!
//! The prop stores the text as a `.tooltip` modifier and marks the node hoverable
//! (see `applyBoxProps`). The host registers itself on the router's observer
//! channel (`onObserver`) so it sees every routed event without being anyone's
//! handler, and filters to the ones it cares about itself (`isRelevant`):
//!   • `mouse_enter` on a node that has a `.tooltip` modifier → arm the dwell timer;
//!     entering any other node, or `mouse_leave` / `mouse_down` / `scroll` → dismiss.
//!   • after ~`DWELL_TICKS` ticks (`onTick`) still armed → show the panel at the
//!     hovered node's resolved geometry.
//! The panel is built once (like MenuBar's overlay) and shown/hidden by a fine effect
//! that toggles its size and writes the text — no subtree rebuild. It sits at a high
//! `z_index` so it paints over the app even though the host is mounted early.
//!
//! Positioning (`onTick`) clamps against the window root's geometry (node 0) so the
//! panel never runs past the right edge, and flips above the anchor when there isn't
//! room below — the same off-screen-panel class of bug other floating widgets
//! (Menu, dropdown) still have to solve themselves; fixed once here.
//!
//! The observer and tick handler are registered against `panel_id` (the host's own
//! node), so both are pruned automatically when that node is removed — no
//! `onUnmount` needed to avoid firing into a freed instance.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;

/// Ticks of continuous hover before the tooltip appears. "tick" is the app's coarse
/// ~500ms heartbeat (see `c_api.zig`'s `should_tick` — it also drives the caret
/// blink), NOT a per-frame event: a hover armed right before a heartbeat shows
/// almost immediately, one armed right after waits up to ~500ms for the next one.
/// That average (~250-500ms) lands in the conventional dwell range without this
/// host needing its own timer. A previous version assumed a ~60fps tick and used
/// `DWELL_TICKS = 30`, which at the real ~500ms cadence meant a 15s wait before the
/// tooltip ever showed — fixed by dropping this to the next heartbeat.
pub const DWELL_TICKS: u32 = 1;

const FONT_SIZE: f32 = 13;
const PAD_X: f32 = 8;
const PAD_Y: f32 = 5;
const MAX_TEXT = 256;
/// Paints over the app, but under toasts (`ToastHost` uses 210).
const Z_INDEX: f32 = 200;

pub const TooltipHost = struct {
    // State (auto-created in onMount).
    rev: signals.Signal(u32) = undefined,
    scope: signals.Scope = undefined,
    dwell: u32 = 0,
    showing: bool = false,
    pending_node: reg.NodeId = reg.NULL_NODE,
    text_buf: [MAX_TEXT]u8 = undefined,
    text_len: usize = 0,
    px_x: f32 = 0,
    px_y: f32 = 0,
    panel_w: f32 = 0,
    panel_h: f32 = 0,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    registry: ?*reg.UIRegistry = null,
    router: ?*events.EventRouter = null,
    measure: ?component.TextMeasure = null,
    panel_id: reg.NodeId = reg.NULL_NODE,
    text_id: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,

    pub fn onMount(self: *TooltipHost, allocator: std.mem.Allocator) void {
        self.rev = signals.Signal(u32).init(allocator, 0);
        self.scope = signals.Scope.init(allocator);
    }

    pub fn deinit(self: *TooltipHost) void {
        self.scope.deinit();
        self.rev.deinit();
    }

    fn text(self: *const TooltipHost) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    /// Events this observer reacts to: hover to arm/track the dwell, and
    /// leave/press/scroll to dismiss. `onObserver` delivers every routed event,
    /// so this filter — which used to live in the router as `isTooltipRelevant`
    /// — now lives here, next to the only code that needs it.
    fn isRelevant(name: []const u8) bool {
        return std.mem.eql(u8, name, "mouse_enter") or
            std.mem.eql(u8, name, "mouse_leave") or
            std.mem.eql(u8, name, "mouse_down") or
            std.mem.eql(u8, name, "scroll");
    }

    /// Router observer: arm on hover of a tooltip node, dismiss otherwise.
    fn onObserve(self: *TooltipHost, ev: events.Event) void {
        if (!isRelevant(ev.name)) return;
        const store = self.store orelse return;
        if (std.mem.eql(u8, ev.name, "mouse_enter")) {
            if (ev.node_id != 0) {
                if (store.getModifier(ev.node_id, .tooltip)) |mod| {
                    const t = mod.string;
                    const n = @min(t.len, MAX_TEXT);
                    @memcpy(self.text_buf[0..n], t[0..n]);
                    self.text_len = n;
                    self.pending_node = ev.node_id;
                    self.dwell = 0;
                    self.hide(); // hide any tooltip from a previous node until re-dwell
                    return;
                }
            }
            self.dismiss(); // hovered a non-tooltip node
        } else {
            // leave / press / scroll.
            self.dismiss();
        }
    }

    fn dismiss(self: *TooltipHost) void {
        self.pending_node = reg.NULL_NODE;
        self.dwell = 0;
        self.hide();
    }

    fn hide(self: *TooltipHost) void {
        if (self.showing) {
            self.showing = false;
            self.rev.set(self.rev.peek() + 1);
        }
    }

    fn onTick(self: *TooltipHost) void {
        if (self.pending_node == reg.NULL_NODE or self.showing) return;
        self.dwell += 1;
        if (self.dwell < DWELL_TICKS) return;
        const registry = self.registry orelse return;
        const node = registry.getNode(self.pending_node) orelse return;

        const tw: f32 = if (self.measure) |m| m.width(self.text(), FONT_SIZE) else @as(f32, @floatFromInt(self.text_len)) * 7.0;
        self.panel_w = tw + 2 * PAD_X;
        self.panel_h = FONT_SIZE + 2 * PAD_Y;

        // Anchor below-left of the node, then clamp/flip so the panel never runs off
        // the window (the same off-screen-panel class of bug other floating widgets
        // have hit — solved once here rather than per call site).
        // A zero-sized root (no layout solved yet, e.g. in a test harness) means
        // "unknown" — treat it as unbounded rather than clamping/flipping against it.
        const win = registry.getNode(0);
        const win_w: f32 = if (win) |w| (if (w.geometry.width > 0) w.geometry.width else std.math.floatMax(f32)) else std.math.floatMax(f32);
        const win_h: f32 = if (win) |w| (if (w.geometry.height > 0) w.geometry.height else std.math.floatMax(f32)) else std.math.floatMax(f32);

        var x = node.geometry.x;
        var y = node.geometry.y + node.geometry.height + 4;
        if (x + self.panel_w > win_w) x = win_w - self.panel_w;
        if (y + self.panel_h > win_h) y = node.geometry.y - self.panel_h - 4; // flip above
        self.px_x = @max(0, x);
        self.px_y = @max(0, y);
        self.showing = true;
        self.rev.set(self.rev.peek() + 1);
    }

    pub fn build(self: *TooltipHost, ctx: *BuildContext) !void {
        const b = ctx.builder;
        self.theme = b.theme;
        self.store = b.store;
        self.registry = b.registry;
        self.router = ctx.router;
        self.measure = b.measure;

        // Panel built once; the effect toggles its size/position and writes the text.
        const t = b.theme;
        // Window-coordinate overlay (see `openOverlay` for why the anchor matters).
        self.panel_id = try b.openOverlay(Z_INDEX);
        try b.width(self.panel_id, 0, .px);
        try b.height(self.panel_id, 0, .px);
        try b.padding(self.panel_id, PAD_Y, PAD_X, PAD_Y, PAD_X);
        try b.radius(self.panel_id, 4);
        try b.backgroundAlpha(self.panel_id, t.surface_highest.r, t.surface_highest.g, t.surface_highest.b, 255);
        try b.borderWidth(self.panel_id, 1);
        try b.borderColorOf(self.panel_id, t.border_color);
        try b.overflowHidden(self.panel_id);
        self.text_id = try b.addText("");
        try b.store.setStyle(self.text_id, .font_size, .{ .dimension = .{ .value = FONT_SIZE, .unit = .px } });
        try b.store.setStyle(self.text_id, .color, .{ .color = .{
            .r = @as(f32, @floatFromInt(t.text.r)) / 255.0,
            .g = @as(f32, @floatFromInt(t.text.g)) / 255.0,
            .b = @as(f32, @floatFromInt(t.text.b)) / 255.0,
            .a = 1.0,
        } });
        b.close();

        // Unconditional every build: both replace in place per owner (see
        // events.zig), and the node-removed hook prunes them on unmount.
        if (ctx.router) |r| {
            try r.onObserver(self.panel_id, self, onObserve);
            try r.onTick(self.panel_id, self, onTick);
        }
        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn updateVisuals(self: *TooltipHost) void {
        const store = self.store orelse return;
        _ = self.rev.get(); // subscribe: show/hide/text bumps
        if (self.panel_id == reg.NULL_NODE) return;
        if (self.showing and self.text_len > 0) {
            // setTextContent takes ownership of a store-allocator slice (it frees the
            // previous one and the final one in deinit), so hand it an owned dup —
            // never the instance buffer.
            const owned = store.stringAllocator().dupe(u8, self.text()) catch return;
            store.setTextContent(self.text_id, owned);
            store.setLayout(self.panel_id, .width, .{ .dimension = .{ .value = self.panel_w, .unit = .px } }) catch {};
            store.setLayout(self.panel_id, .height, .{ .dimension = .{ .value = self.panel_h, .unit = .px } }) catch {};
            store.setLayout(self.panel_id, .left, .{ .dimension = .{ .value = self.px_x, .unit = .px } }) catch {};
            store.setLayout(self.panel_id, .top, .{ .dimension = .{ .value = self.px_y, .unit = .px } }) catch {};
        } else {
            store.setLayout(self.panel_id, .width, .{ .dimension = .{ .value = 0, .unit = .px } }) catch {};
            store.setLayout(self.panel_id, .height, .{ .dimension = .{ .value = 0, .unit = .px } }) catch {};
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const dark = theme_mod.Theme.dark();

const TestEnv = @import("test_support.zig").Harness;

/// Mounts the host + one hoverable node carrying a `.tooltip`. Returns the host and
/// the target node id.
fn mountHostAndTarget(env: *TestEnv) !struct { host: *TooltipHost, target: reg.NodeId } {
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(TooltipHost, .{});
    const target = try ctx.boxNode(.{ .width = component.px(50), .height = 20, .tooltip = "Hola" }, .{});
    _ = root;
    b.close();
    const anchor = env.registry.getNode(0).?.first_child;
    const host: *TooltipHost = @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));
    // Simulate a solved layout for the target so the panel can position itself.
    env.registry.getNode(target).?.geometry = .{ .x = 30, .y = 40, .width = 50, .height = 20 };
    return .{ .host = host, .target = target };
}

fn tick(env: *TestEnv, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) _ = env.router.route(.{ .name = "tick", .id = "" });
}

test "Tooltip appears after the dwell and carries the node's text" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const h = try mountHostAndTarget(&env);

    // Hidden initially.
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getLayout(h.host.panel_id, .width).?.dimension.value, 0.001);

    // Hover the target, then dwell past the threshold.
    _ = env.router.route(.{ .name = "mouse_enter", .id = "", .node_id = h.target });
    tick(&env, DWELL_TICKS + 2);

    try testing.expect(h.host.showing);
    try testing.expect(env.store.getLayout(h.host.panel_id, .width).?.dimension.value > 0);
    try testing.expectEqualStrings("Hola", env.store.getTextContent(h.host.text_id).?);
    // Positioned below the node (y + height + 4 = 64).
    try testing.expectApproxEqAbs(@as(f32, 64.0), env.store.getLayout(h.host.panel_id, .top).?.dimension.value, 0.001);
}

test "Tooltip hides on leave" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const h = try mountHostAndTarget(&env);

    _ = env.router.route(.{ .name = "mouse_enter", .id = "", .node_id = h.target });
    tick(&env, DWELL_TICKS + 2);
    try testing.expect(h.host.showing);

    _ = env.router.route(.{ .name = "mouse_leave", .id = "", .node_id = h.target });
    try testing.expect(!h.host.showing);
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getLayout(h.host.panel_id, .width).?.dimension.value, 0.001);
}

test "Tooltip never appears if the hover ends before the dwell" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const h = try mountHostAndTarget(&env);

    _ = env.router.route(.{ .name = "mouse_enter", .id = "", .node_id = h.target });
    tick(&env, DWELL_TICKS / 2); // short dwell
    _ = env.router.route(.{ .name = "mouse_leave", .id = "", .node_id = h.target });
    tick(&env, DWELL_TICKS + 5); // more ticks, but no longer armed

    try testing.expect(!h.host.showing);
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getLayout(h.host.panel_id, .width).?.dimension.value, 0.001);
}

test "Tooltip: the panel is really on screen after a layout solve" {
    // The regression this file most needed. Every other test here asserts what the
    // host WROTE to the property store — which stayed correct the whole time the
    // tooltip was invisible in every real app. Two bugs hid behind that:
    //   • the layout engine never measured out-of-flow children of a hug-content
    //     box, so the panel resolved to 0x0 whatever width it asked for; and
    //   • the mount anchor sat in-flow below a flex-grow sibling, offsetting the
    //     panel a full window-height past the viewport.
    // Both are invisible to a store assertion and both are caught by solving the
    // real layout and asking where the box actually landed.
    const WIN_W: f32 = 800;
    const WIN_H: f32 = 600;

    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    // runApp's shape: a flex-grow body that eats the full height, with the overlay
    // host mounted after it.
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
    const target = try ctx.boxNode(.{ .width = component.px(50), .height = 20, .tooltip = "Hola" }, .{});
    b.close(); // body

    try ctx.mountOwned(TooltipHost, .{});
    b.close(); // root

    const anchor = env.registry.getNode(body).?.next_sibling;
    const host: *TooltipHost = @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));

    // Solve once so the hover target (and the window root) have real geometry for
    // the host to position against.
    env.solve(root, WIN_W, WIN_H);
    try testing.expect(env.isVisible(target)); // premise: the anchor node is real

    env.route(.{ .name = "mouse_enter", .id = "", .node_id = target });
    tick(&env, DWELL_TICKS + 1);
    try testing.expect(host.showing);

    // Re-solve: this is where a 0x0 panel or an off-screen one shows up.
    env.solve(root, WIN_W, WIN_H);

    const panel = env.geom(host.panel_id);
    try testing.expect(panel.width > 0);
    try testing.expect(panel.height > 0);

    // And it lands inside the window, not below/right of it.
    try testing.expect(panel.x >= 0);
    try testing.expect(panel.y >= 0);
    try testing.expect(panel.x + panel.width <= WIN_W);
    try testing.expect(panel.y + panel.height <= WIN_H);

    // Anchored to the hovered node, not parked at the origin.
    const tgt = env.geom(target);
    try testing.expect(panel.y >= tgt.y);
}

test "Tooltip observer is cleared on unmount" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(TooltipHost, .{});
    b.close();
    try testing.expectEqual(@as(usize, 1), env.router.observers.items.len);

    try b.rootAt(root);
    b.close();
    try testing.expectEqual(@as(usize, 0), env.router.observers.items.len);
}
