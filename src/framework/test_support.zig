//! Shared scaffolding for widget tests. Referenced only from `test` blocks, so
//! nothing here reaches release builds. Centralizes the registry+store+router+
//! mounts wiring (previously copy-pasted as a `TestEnv` struct in every widget
//! file) and the text-measurement/clipboard stubs shared by TextInput/TextArea.
//!
//! Imports only lower-level modules (component, events, theme, core/*) — never a
//! widget — so widgets can depend on it without an import cycle.
const std = @import("std");
const component = @import("component.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const flexbox = @import("../layout/flexbox.zig");

/// registry + store + router + mounts, wired together. A single `deinit` tears
/// down all four in the correct order. `with_measure`/`with_clipboard` let the
/// text widgets opt into the stubs below without redefining them per file.
pub const Harness = struct {
    registry: reg.UIRegistry,
    store: props.PropertyStore,
    router: events.EventRouter,
    mounts: component.MountTable,
    with_measure: bool = false,
    with_clipboard: bool = false,

    pub fn init(a: std.mem.Allocator) Harness {
        return .{
            .registry = reg.UIRegistry.init(a),
            .store = props.PropertyStore.init(a),
            .router = events.EventRouter.init(a),
            .mounts = component.MountTable.init(a),
        };
    }

    /// Point the store at the registry and register the mount table's and
    /// router's node-removed listeners (mirrors the production wiring in
    /// `application.zig`). Call once before building. The router listener is
    /// load-bearing for any widget whose tick/global/observer/node handlers are
    /// meant to be pruned automatically on unmount — omitting it doesn't fail
    /// loudly, it just leaks (see the inspector.zig fix this mirrors).
    pub fn wire(self: *Harness) void {
        self.store.setRegistry(&self.registry);
        self.registry.addNodeRemovedListener(&self.mounts, component.MountTable.nodeRemovedListener);
        self.registry.addNodeRemovedListener(&self.router, events.EventRouter.nodeRemovedListener);
    }

    pub fn deinit(self: *Harness) void {
        self.mounts.deinit();
        self.router.deinit();
        self.store.deinit();
        self.registry.deinit();
    }

    /// Route an event, discarding the handled flag (the common test shape).
    pub fn route(self: *Harness, ev: events.Event) void {
        _ = self.router.route(ev);
    }

    /// Run a REAL layout solve over the built tree, sizing the root to `w`x`h`.
    ///
    /// Assert against RESOLVED GEOMETRY (`self.geom(id)`) whenever a test's claim is
    /// "the user can see this". Reading the property store instead only proves the
    /// widget *asked* for a size — and the two genuinely disagree: `TooltipHost` and
    /// `ToastHost` both shipped with store-only tests passing while the panels were
    /// 0x0 on screen, because the engine never measured out-of-flow children whose
    /// parent hugged its content. A store assertion cannot catch that class of bug;
    /// this can.
    ///
    /// No font atlas, so text falls back to the engine's headless metrics — fine for
    /// box geometry, not for glyph-accurate assertions.
    pub fn solve(self: *Harness, root: reg.NodeId, w: f32, h: f32) void {
        var engine = flexbox.LayoutEngine.init(&self.registry, &self.store, null);
        engine.solve(root, 0, 0, w, h);
    }

    /// Deliver `on_resize` events for the last `solve`, exactly as the engine does
    /// after a rendered frame (`c_api.emitResizes`): collect the changed observed
    /// nodes, then route one `resize` per node that is still alive and observed.
    /// Returns how many were delivered.
    pub fn deliverResizes(self: *Harness) !usize {
        const gpa = self.registry.allocator;
        var changed: std.ArrayListUnmanaged(reg.UIRegistry.Resized) = .empty;
        defer changed.deinit(gpa);
        try self.registry.collectResized(&changed, gpa);
        var n: usize = 0;
        for (changed.items) |r| {
            const node = self.registry.getNode(r.id) orelse continue;
            if (!node.observe_resize) continue;
            _ = self.router.route(.{ .name = "resize", .id = "", .node_id = r.id, .width = r.w, .height = r.h });
            n += 1;
        }
        return n;
    }

    /// `solve` followed by `deliverResizes` — one frame as the observer sees it.
    pub fn frame(self: *Harness, root: reg.NodeId, w: f32, h: f32) !usize {
        self.solve(root, w, h);
        return self.deliverResizes();
    }

    /// Resolved geometry of `id` after `solve` — all zeroes if the node is gone.
    pub fn geom(self: *Harness, id: reg.NodeId) reg.Geometry {
        const node = self.registry.getNode(id) orelse return .{};
        return node.geometry;
    }

    /// The public `LayoutReader` over this harness's registry — the same value a
    /// widget gets from `ctx.layoutReader()`.
    pub fn reader(self: *Harness) component.LayoutReader {
        return .{ .registry = &self.registry };
    }

    /// Whether `id` ended up with a non-zero box after `solve` — the cheapest
    /// "would a user actually see this?" assertion.
    pub fn isVisible(self: *Harness, id: reg.NodeId) bool {
        const g = self.geom(id);
        return g.width > 0 and g.height > 0;
    }
};

// ── Text stubs (shared by text_input.zig and text_area.zig) ────────────────────

/// Opaque context for the stubs below; its address is all the hooks need.
pub var text_dummy: u8 = 0;

/// Deterministic monospace metric: 10px per byte, distinct from the real
/// `fallbackCharWidth(16) = 8` so tests can tell measured layout from the fallback.
pub fn mockMeasure(_: *anyopaque, text: []const u8, _: f32) f32 {
    return @as(f32, @floatFromInt(text.len)) * 10.0;
}

pub var stub_clip_buf: [256]u8 = undefined;
pub var stub_clip_len: usize = 0;

pub fn stubClipSet(_: *anyopaque, text: []const u8) bool {
    const n = @min(text.len, stub_clip_buf.len);
    @memcpy(stub_clip_buf[0..n], text[0..n]);
    stub_clip_len = n;
    return true;
}

pub fn stubClipGet(_: *anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    return allocator.dupe(u8, stub_clip_buf[0..stub_clip_len]) catch null;
}
