//! Declarative component model.
//!
//! A component is *any* struct with a `build(self, *BuildContext) !void` method —
//! no vtables, no `*anyopaque`, no per-widget allocation. Composition is done
//! with anonymous struct literals for props and comptime tuples for children, so
//! the ergonomics of named parameters compile down to the exact `PropertyStore`
//! calls a hand-written builder would make. Nothing about props or children
//! survives to runtime as strings or branches.
//!
//!     pub const Card = struct {
//!         title: []const u8,
//!         pub fn build(self: *Card, ctx: *BuildContext) !void {
//!             try ctx.box(.{ .direction = .column, .gap = 8, .padding = EdgeInsets.all(12),
//!                            .background = rgb(30, 30, 40), .radius = 8 }, .{
//!                 Text{ .content = self.title },
//!             });
//!         }
//!     };
//!
//! `BuildContext` is a thin wrapper over the existing `UIBuilder`; the builder's
//! reconciliation and the store's dirty-tracking are reused unchanged.

const std = @import("std");
const builder_mod = @import("builder.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const prof = @import("../core/profiler.zig");
const events = @import("events.zig");
const signals = @import("../core/signals.zig");
const theme_mod = @import("theme.zig");

pub const Handler = events.Handler;

pub const NodeId = reg.NodeId;
pub const UIBuilder = builder_mod.UIBuilder;
pub const TextMeasure = builder_mod.TextMeasure;
pub const verticalFallback = builder_mod.verticalFallback;
/// Advance per character when no measurement is injected — see `text.fallbackCharWidth`.
pub const fallbackCharWidth = @import("../render/text.zig").fallbackCharWidth;
pub const Clipboard = builder_mod.Clipboard;
pub const Theme = theme_mod.Theme;

// ── Value helpers ─────────────────────────────────────────────────────────────

/// Accessible names for the minimize / maximize / restore / close caption buttons
/// (`AppBar`, `WindowChrome`). These are what screen readers announce, so an app
/// localized into another language passes its own strings.
pub const WindowControlLabels = struct {
    minimize: []const u8 = "Minimize",
    maximize: []const u8 = "Maximize",
    restore: []const u8 = "Restore",
    close: []const u8 = "Close",
};

pub const Dim = struct {
    value: f32,
    unit: props.DimUnit,

    fn toProp(self: Dim) props.PropValue {
        return .{ .dimension = .{ .value = self.value, .unit = self.unit } };
    }
};

pub fn px(v: f32) Dim {
    return .{ .value = v, .unit = .px };
}
pub fn pt(v: f32) Dim {
    return .{ .value = v, .unit = .pt };
}
pub fn pct(v: f32) Dim {
    return .{ .value = v, .unit = .percent };
}

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    fn toProp(self: Color) props.PropValue {
        return .{ .color = .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a } };
    }
};

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = 1.0,
    };
}

pub fn rgba(r: u8, g: u8, b: u8, a: f32) Color {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = a,
    };
}

/// The canonical bind-once/update-untracked tail that every reactive widget's
/// `build()` ends with. On the first build, registers `updateFn` as an effect in
/// `scope` (so it re-runs when its signal deps change) and flips `bound`; on
/// rebuilds, runs `updateFn` once outside tracking — it repaints render-only
/// without re-subscribing. `self` is the widget instance; `updateFn` its
/// render-only visuals method (e.g. `updateVisuals`).
pub fn bindVisuals(self: anytype, scope: *signals.Scope, bound: *bool, comptime updateFn: fn (@TypeOf(self)) void) !void {
    if (!bound.*) {
        _ = try scope.createEffect(self, updateFn);
        bound.* = true;
    } else {
        const prev = signals.untrackedBegin();
        updateFn(self);
        signals.untrackedEnd(prev);
    }
}

pub const EdgeInsets = struct {
    t: f32 = 0,
    r: f32 = 0,
    b: f32 = 0,
    l: f32 = 0,

    pub fn all(v: f32) EdgeInsets {
        return .{ .t = v, .r = v, .b = v, .l = v };
    }
    pub fn symmetric(h: f32, v: f32) EdgeInsets {
        return .{ .t = v, .b = v, .l = h, .r = h };
    }
    pub fn only(t: f32, r: f32, b: f32, l: f32) EdgeInsets {
        return .{ .t = t, .r = r, .b = b, .l = l };
    }
};

pub const Direction = enum { row, column };
pub const Justify = enum { start, center, end, space_between, space_around, space_evenly };
pub const Align = enum { start, center, end, stretch, baseline };

fn justifyKeyword(j: Justify) props.Keyword {
    return switch (j) {
        .start => .flex_start,
        .center => .center,
        .end => .flex_end,
        .space_between => .space_between,
        .space_around => .space_around,
        .space_evenly => .space_evenly,
    };
}

fn alignKeyword(a: Align) props.Keyword {
    return switch (a) {
        .start => .flex_start,
        .center => .center,
        .end => .flex_end,
        .stretch => .stretch,
        .baseline => .baseline,
    };
}

// ── Context / Provider (dependency injection down the tree) ───────────────────

/// A node in the provider chain: a type-erased value made available to the subtree
/// built inside `BuildContext.provide`. Lives on the provider's stack frame for the
/// duration of that call — `use` walks parent links to find the nearest of a type.
const Provider = struct {
    type_id: usize,
    ptr: *anyopaque,
    parent: ?*const Provider,
};

/// A process-unique id per type `T` (the address of a per-T static). Lets the
/// provider chain match by type without RTTI.
fn typeId(comptime T: type) usize {
    return @intFromPtr(&(struct {
        const _t = T;
        var id: u8 = 0;
    }).id);
}

// ── BuildContext ──────────────────────────────────────────────────────────────

/// Logical-pixel size of a node's content box, as resolved by the previous layout
/// solve. Returned by `BuildContext.measuredSize` — position is deliberately not
/// included (ask for `x`/`y` off the registry directly if you ever need them).
pub const MeasuredSize = struct { w: f32, h: f32 };

pub const BuildContext = struct {
    builder: *UIBuilder,
    /// Head of the provider chain in scope at this point of the build (see
    /// `provide`/`use`). Null at the root.
    providers: ?*const Provider = null,
    /// Event router the declarative `on_*` props register into. Null when a
    /// context is built without one (e.g. some layout-only unit tests): `on_*` props
    /// still set the hit modifier so the node is interactive, but no handler binds.
    router: ?*events.EventRouter = null,
    /// Table of mounted reactive components, keyed by anchor NodeId. Required
    /// by `mountReactive`; wired by the engine/tests. Null → `mountReactive` errors.
    mounts: ?*MountTable = null,

    pub fn init(b: *UIBuilder) BuildContext {
        return .{ .builder = b };
    }

    pub fn initWithRouter(b: *UIBuilder, router: *events.EventRouter) BuildContext {
        return .{ .builder = b, .router = router };
    }

    /// Builds a typed event `Handler` from a payload pointer (usually the owning
    /// component `*Self`, or `void`) and a comptime function
    /// `fn (@TypeOf(payload), Event) void`. The trampoline mirrors `router.on` and
    /// `Scope.createEffect`; no allocation. This is the `ctx.handler` the docs
    /// promise — the replacement for string action-ids in user code.
    pub fn handler(self: *BuildContext, payload: anytype, comptime f: anytype) Handler {
        _ = self;
        const P = @TypeOf(payload);
        const Wrap = struct {
            fn call(erased: ?*anyopaque, ev: events.Event) void {
                if (P == void) {
                    f({}, ev);
                } else {
                    const typed: P = @ptrCast(@alignCast(erased));
                    f(typed, ev);
                }
            }
        };
        return .{
            .ptr = if (P == void) null else @ptrCast(payload),
            .call = Wrap.call,
        };
    }

    /// `on_resize` for a node opened with the raw builder (`openNodeKeyed`) rather
    /// than `box`/`boxNode` — same semantics as the box prop.
    pub fn onResize(self: *BuildContext, id: NodeId, h: Handler) !void {
        try wireResize(self, id, h);
    }

    /// `on_scroll` (vertical wheel) for a node opened with the raw builder — same
    /// semantics as the box prop: marks the node scrollable and routes `.scroll`
    /// events to `h`.
    pub fn onScroll(self: *BuildContext, id: NodeId, h: Handler) !void {
        try wireHandler(self, id, .scroll, .scrollable, h);
    }

    /// `on_scroll_h` (horizontal wheel / shift+wheel) for a raw-builder node —
    /// same semantics as the box prop.
    pub fn onScrollH(self: *BuildContext, id: NodeId, h: Handler) !void {
        try wireHandler(self, id, .scroll_h, .scrollable, h);
    }

    /// A `Handler` that drives a `*Signal(bool)` from pointer events: mouse_enter /
    /// mouse_down → true, mouse_leave / mouse_up → false. Sugar for hover/press
    /// state, wired via the `.on_hover` / `.on_press` props.
    pub fn signalSetter(self: *BuildContext, sig: *signals.Signal(bool)) Handler {
        _ = self;
        const Wrap = struct {
            fn call(erased: ?*anyopaque, ev: events.Event) void {
                const s: *signals.Signal(bool) = @ptrCast(@alignCast(erased.?));
                if (std.mem.eql(u8, ev.name, "mouse_enter") or std.mem.eql(u8, ev.name, "mouse_down")) {
                    s.set(true);
                } else if (std.mem.eql(u8, ev.name, "mouse_leave") or std.mem.eql(u8, ev.name, "mouse_up")) {
                    s.set(false);
                }
            }
        };
        return .{ .ptr = @ptrCast(sig), .call = Wrap.call };
    }

    /// `on_hover` handler for a pressable widget whose instance has `hovered`
    /// and `pressed` `Signal(bool)` fields (Button, IconButton): tracks hover
    /// like `signalSetter`, and a mouse_leave also releases `pressed` — a
    /// press dragged off the widget must not leave it painted pressed.
    pub fn hoverPressSetter(self: *BuildContext, widget: anytype) Handler {
        const W = @TypeOf(widget);
        const Wrap = struct {
            fn call(w: W, ev: events.Event) void {
                if (std.mem.eql(u8, ev.name, "mouse_enter")) {
                    w.hovered.set(true);
                } else if (std.mem.eql(u8, ev.name, "mouse_leave")) {
                    w.hovered.set(false);
                    w.pressed.set(false);
                }
            }
        };
        return self.handler(widget, Wrap.call);
    }

    /// The content-box size (logical px) that `id` resolved to in the **previous**
    /// layout solve, or `null` if `id` has never been measured yet (the first
    /// build, before any solve) or the node is gone.
    ///
    /// This is the supported way to answer "how many pixels does my own node
    /// occupy?" from inside `build` — needed by widgets that must keep their work
    /// O(visible) (infinite canvases, custom virtualizers, minimaps): cull to the
    /// window, size a background grid to the real extent, etc. Notes:
    ///
    ///   • **One frame stale by construction.** `geometry` is the *output* of the
    ///     last solve, so on resize/first paint you read the prior size for one
    ///     frame. Keep a small overdraw margin; don't use it where exactness the
    ///     same frame matters.
    ///   • **Not reactive.** A window resize re-solves layout but does not re-run
    ///     `build`, so a bare read here won't refresh on resize on its own. To
    ///     react, put `.on_resize = ctx.handler(self, onResize)` on the node and
    ///     `.set()` a widget-owned signal from `ev.width/ev.height` — the engine
    ///     reports after every frame whose solve changed the node's size (and
    ///     once on the first solve), and the targeted rebuild that follows stays
    ///     O(visible). Use `measuredSize` for one-shot reads only.
    ///   • Measures the border box the layout engine placed — padding included,
    ///     margin excluded, same as `geometry.width/height`.
    pub fn measuredSize(self: *BuildContext, id: NodeId) ?MeasuredSize {
        const node = self.builder.registry.getNode(id) orelse return null;
        // `layout_w` is seeded to -1 and only set once `measure` has run on the
        // node, so it doubles as a "was this ever solved?" flag.
        if (node.layout_w < 0) return null;
        return .{ .w = node.geometry.width, .h = node.geometry.height };
    }

    /// Opens a Box, applies `props_` (an anonymous struct literal of styling /
    /// layout / modifier fields), builds `children` (a comptime tuple of
    /// components), and closes it.
    pub fn box(self: *BuildContext, props_: anytype, children: anytype) !void {
        _ = try self.boxNode(props_, children);
    }

    /// Like `box`, but returns the opened box's NodeId (e.g. so a widget can attach
    /// a fine-grained `bindStyle`/effect to it).
    pub fn boxNode(self: *BuildContext, props_: anytype, children: anytype) !NodeId {
        const id = try self.builder.openNodeKeyed(.box, extractKey(props_));
        try applyBoxProps(self, id, props_);
        try buildChildren(self, children);
        self.builder.close();
        return id;
    }

    /// A Box with props but no children.
    pub fn boxLeaf(self: *BuildContext, props_: anytype) !void {
        const id = try self.builder.openNodeKeyed(.box, extractKey(props_));
        try applyBoxProps(self, id, props_);
        self.builder.close();
    }

    /// A primitive Text node (self-closing).
    pub fn text(self: *BuildContext, content: []const u8) !NodeId {
        return self.builder.addText(content);
    }

    /// A reactive text node: creates a text leaf and binds its content to `signal`
    /// formatted with `fmt` (comptime `std.fmt`, e.g. "{d}"/"{s}"). `scope` owns the
    /// binding effect. Like `bindStyle`/`bindList`, call this once at setup (not on
    /// every reactive re-run) — the owned effect updates the node in place thereafter.
    /// Returns the text node id. Accepts `*Signal(T)` or `*Computed(T)`.
    pub fn dynText(
        self: *BuildContext,
        comptime T: type,
        scope: *signals.Scope,
        signal: anytype,
        comptime fmt: []const u8,
    ) !NodeId {
        const id = try self.builder.addText("");
        try signals.bindText(T, scope, self.builder.store, id, signal, fmt);
        return id;
    }

    /// Builds a single child component into the current parent.
    pub fn mount(self: *BuildContext, component: anytype) !void {
        try buildChild(self, component);
    }

    /// Mounts `component` (a `*T` with `build(self, *BuildContext)`) under a keyed
    /// anchor and re-runs *only its subtree* when any signal it read with `.get()`
    /// during the build changes — SolidJS/Flutter-style component reactivity built
    /// on the existing keyed reconciler. `scope` owns the build-effect (teardown in
    /// unmount). See MountRecord for the two build paths (inline vs isolated re-run).
    ///
    /// Requires `ctx.mounts` (the per-engine/per-test MountTable). Distinct sibling
    /// instances of the same `T` under one parent need distinct `.key` fields.
    pub fn mountReactive(self: *BuildContext, scope: *signals.Scope, component: anytype) !void {
        return self.mountReactiveInner(scope, component, false);
    }

    /// Like `mountReactive`, but the anchor box is sized to **fill its parent**
    /// (width/height 100%). Use for a full-window reactive root: the mount anchor
    /// would otherwise hug its content (default `align-items: flex_start`), collapsing
    /// a `width/height: 100%` app root. `runApp` mounts the app with this.
    pub fn mountReactiveFill(self: *BuildContext, scope: *signals.Scope, component: anytype) !void {
        return self.mountReactiveInner(scope, component, true);
    }

    fn mountReactiveInner(self: *BuildContext, scope: *signals.Scope, component: anytype, fill: bool) !void {
        const P = @TypeOf(component);
        const T = @typeInfo(P).pointer.child;
        const table = self.mounts orelse return error.NoMountTable;

        const key = mountKey(T, component);
        const anchor = try self.builder.openNodeKeyed(.box, key);
        if (fill) try fillAnchor(self.builder, anchor);

        var rec = table.get(anchor);
        if (rec == null) {
            // First mount. The record is framework-allocated (owned by the MountTable,
            // freed on unmount / table teardown); only the build-effect lives in the
            // caller's `scope`. component_ptr is caller-owned, so no destroy_fn.
            const r = try table.allocator.create(MountRecord);
            errdefer table.allocator.destroy(r);
            const template = mountTemplate(self.builder);
            r.* = .{
                .anchor = anchor,
                .component_ptr = @ptrCast(component),
                .build_fn = buildTramp(T),
                .scope = scope,
                .unmount_fn = if (@hasDecl(T, "onUnmount")) unmountTramp(T) else null,
                .framework_record = true,
                .template = template,
                .router = self.router,
                .mounts = table,
            };
            r.effect = try scope.createEffectDeferred(r, MountRecord.rerun, HEIGHT_BASE + depthOf(self.builder.registry, anchor));
            try table.put(anchor, r);
            rec = r;
            // First mount: the first build-effect run IS the mount, so onMount fires
            // here (before the inline build below), mirroring a constructor.
            if (@hasDecl(T, "onMount")) component.onMount();
        }

        // Inline tracked build — first mount and parent-driven re-mount both run
        // here, on the shared builder, reconciling the subtree against the reused
        // anchor's children while `rec.effect` records this build's signal reads.
        const prev = signals.pushEffect(rec.?.effect);
        component.build(self) catch {};
        signals.popEffect(prev);
        self.builder.close();

        // Stamp the anchor so that, if this component's own build-effect is also
        // queued this propagation, the drain skips it (an ancestor rebuilt us).
        if (self.builder.registry.getNode(anchor)) |n| n.built_gen = signals.currentPropagationGen();
    }

    /// Like `mountReactive`, but the framework allocates and OWNS the instance of
    /// `T`: it is created on first mount (props from `init_props`, state
    /// fields left for `onMount`), REUSED across rebuilds while its keyed anchor
    /// survives (only the props present in `init_props` are re-applied — state is
    /// preserved), and destroyed (`deinit` + free) on unmount. The
    /// build-effect lives in the table's shared scope. No `allocator.create`/`deinit`
    /// in user code. `init_props` may carry a `.key` to disambiguate sibling
    /// instances of the same `T` (also applied to a `key` field if `T` has one).
    pub fn mountOwned(self: *BuildContext, comptime T: type, init_props: anytype) !void {
        const table = self.mounts orelse return error.NoMountTable;
        const alloc = table.allocator;
        const key = ownedKey(T, init_props);
        const anchor = try self.builder.openNodeKeyed(.box, key);
        // Reserved `.fill` prop (like `.key`): sizes the anchor to fill its parent, for
        // a container widget whose root is width/height 100% (e.g. a SplitPane body).
        if (@hasField(@TypeOf(init_props), "fill") and @field(init_props, "fill")) try fillAnchor(self.builder, anchor);
        // Reserved `.hug` prop: makes the anchor a row so the widget's root
        // shrink-wraps its content horizontally. Without it, a widthless root fills
        // the anchor (a box defaults to the parent's width unless the parent is a
        // row — flexbox `measure`). Use for hug-shaped widgets like Button.
        if (@hasField(@TypeOf(init_props), "hug") and @field(init_props, "hug")) {
            try self.builder.store.setLayout(anchor, .flex_direction, .{ .keyword = .row });
            // Hug the cross axis too. `align_items` defaults to `stretch` (CSS), which
            // would grow the widget's root to the full height of whatever bar it sits
            // in — a Button's pill would fill a 48px toolbar instead of being 26px.
            // A hug anchor is exactly the place that must opt out.
            try self.builder.store.setLayout(anchor, .align_items, .{ .keyword = .flex_start });
        }

        var rec = table.get(anchor);
        var inst: *T = undefined;
        if (rec == null) {
            inst = try alloc.create(T);
            errdefer alloc.destroy(inst);
            initInstance(T, inst, init_props); // props + defaults; state → undefined
            const template = mountTemplate(self.builder);
            const r = try alloc.create(MountRecord);
            r.* = .{
                .anchor = anchor,
                .component_ptr = @ptrCast(inst),
                .build_fn = buildTramp(T),
                .scope = &table.scope,
                .unmount_fn = if (@hasDecl(T, "onUnmount")) unmountTramp(T) else null,
                .owned_ptr = @ptrCast(inst),
                .destroy_fn = destroyTramp(T),
                .framework_record = true,
                .template = template,
                .router = self.router,
                .mounts = table,
            };
            r.effect = try table.scope.createEffectDeferred(r, MountRecord.rerun, HEIGHT_BASE + depthOf(self.builder.registry, anchor));
            try table.put(anchor, r);
            rec = r;
            callOnMount(T, inst, alloc); // state signals init here (allocator provided)
        } else {
            inst = @ptrCast(@alignCast(rec.?.component_ptr));
            applyProps(T, inst, init_props); // update props, preserve state
        }

        const prev = signals.pushEffect(rec.?.effect);
        inst.build(self) catch {};
        signals.popEffect(prev);
        self.builder.close();
        if (self.builder.registry.getNode(anchor)) |n| n.built_gen = signals.currentPropagationGen();
    }

    // ── Declarative primitives ──────────────────────────────────────────────────
    //
    // Zig has no closures, so the dynamic primitives take a `payload` (typically the
    // owning component `*Self`) that is forwarded to the comptime render function —
    // the same pattern `Scope.createEffect` uses. This keeps them allocation-free and
    // fully comptime-specialized.

    /// Builds one keyed wrapper box per item of `items` into the current parent and
    /// calls `render(payload, ctx, item)` to fill each. The key (from `keyOf(item)`)
    /// drives reconciliation, so reordering/inserting/removing items reuses the
    /// matching nodes and preserves their state — the keyed-list pattern, automated.
    pub fn forEach(
        self: *BuildContext,
        items: anytype,
        payload: anytype,
        comptime keyOf: anytype,
        comptime render: anytype,
    ) !void {
        for (items) |item| {
            _ = try self.builder.openNodeKeyed(.box, hashKey(keyOf(item)));
            try render(payload, self, item);
            self.builder.close();
        }
    }

    /// `box(props)` + `forEach` in one call: opens a styled container and fills it
    /// with the keyed items. The `<ul>{items.map(...)}</ul>` of Celeris.
    pub fn list(
        self: *BuildContext,
        props_: anytype,
        items: anytype,
        payload: anytype,
        comptime keyOf: anytype,
        comptime render: anytype,
    ) !void {
        const id = try self.builder.openNodeKeyed(.box, extractKey(props_));
        try applyBoxProps(self, id, props_);
        try self.forEach(items, payload, keyOf, render);
        self.builder.close();
    }

    /// Conditional rendering: builds `render(payload, ctx)` only when `cond`. When it
    /// toggles, the subtree is added/removed by the normal reconciliation. (Give the
    /// conditional content a stable `.key`, or key its siblings, if it sits between
    /// other children whose identity must survive the toggle.)
    pub fn when(self: *BuildContext, cond: bool, payload: anytype, comptime render: anytype) !void {
        if (cond) try render(payload, self);
    }

    /// Two-branch conditional: `then_render` when `cond`, else `else_render`.
    pub fn whenElse(
        self: *BuildContext,
        cond: bool,
        payload: anytype,
        comptime then_render: anytype,
        comptime else_render: anytype,
    ) !void {
        if (cond) try then_render(payload, self) else try else_render(payload, self);
    }

    /// Makes `value` (a `*T`) available to the subtree built inside `body`, retrievable
    /// with `use(T)` — dependency injection without threading the value through every
    /// component's fields. The binding is scoped to `body` (it lives on this stack
    /// frame); nested `provide` of the same `T` shadows the outer one.
    pub fn provide(
        self: *BuildContext,
        comptime T: type,
        value: *T,
        payload: anytype,
        comptime body: anytype,
    ) !void {
        const node = Provider{ .type_id = typeId(T), .ptr = @ptrCast(value), .parent = self.providers };
        const prev = self.providers;
        self.providers = &node;
        defer self.providers = prev;
        try body(payload, self);
    }

    /// Returns the nearest provided `*T` in scope, or null if none was provided.
    pub fn use(self: *BuildContext, comptime T: type) ?*T {
        var cur = self.providers;
        while (cur) |n| : (cur = n.parent) {
            if (n.type_id == typeId(T)) return @ptrCast(@alignCast(n.ptr));
        }
        return null;
    }

    /// Makes `node` drag its own window when pressed — the caption behaviour,
    /// available to any box. A borderless overlay has no title bar, so without this
    /// the user has no way to move it out of the way; with it, any box the app
    /// nominates ("the whole bar except the buttons") becomes the grab handle.
    ///
    /// Which window it drags is the window whose tree this build belongs to, taken
    /// from the MountTable — so a node built for the overlay drags the overlay, not
    /// the main window, with nothing to pass in. A no-op with no window wired
    /// (headless / unit tests); the node still becomes interactive.
    pub fn dragRegion(self: *BuildContext, node: NodeId) !void {
        var idbuf: [16]u8 = undefined;
        const auto_id = std.fmt.bufPrint(&idbuf, "n{d}", .{node}) catch "n";
        try self.builder.clickable(node, auto_id);
        const table = self.mounts orelse return;
        if (table.window_ops == null) return;
        const r = self.router orelse return;
        const Wrap = struct {
            fn call(erased: ?*anyopaque, _: events.Event) void {
                const t: *MountTable = @ptrCast(@alignCast(erased.?));
                if (t.window_ops) |o| o.startDrag(t.window_id);
            }
        };
        try r.onNode(node, .mouse_down, .{ .ptr = @ptrCast(table), .call = Wrap.call });
    }

    /// The engine's reactive theme signal, or null when no runtime theme was
    /// wired (headless/tests). Unlike `use`, it lives on the `MountTable` so it is
    /// reachable during isolated re-runs too. Call `.get()` inside a build to
    /// subscribe the current build-effect; `.set(...)` swaps the theme reactively.
    pub fn themeSignal(self: *BuildContext) ?*signals.Signal(theme_mod.Theme) {
        return if (self.mounts) |m| m.theme_signal else null;
    }

    /// The current theme, read reactively. When a runtime theme signal is
    /// wired, this `.get()`s it — subscribing the enclosing build-effect so a later
    /// `theme_signal.set(...)` re-runs this component — and refreshes
    /// `builder.theme` so plain `ctx.builder.theme` reads later in the same build
    /// see the current value. With no signal it falls back to `builder.theme`.
    pub fn theme(self: *BuildContext) theme_mod.Theme {
        if (self.themeSignal()) |sig| {
            const t = sig.get();
            self.builder.theme = t;
            return t;
        }
        return self.builder.theme;
    }
};

// ── Reactive component mounting ─────────────────────────────────────────

/// Height floor for component build-effects. Larger than any realistic `Computed`
/// height so every computed recomputes before any build re-runs, and (with the
/// anchor's depth added) ancestor builds run before descendant builds in the drain.
pub const HEIGHT_BASE: u32 = 1024;

/// One mounted reactive component. Two build paths keep the keyed reconciler happy:
///  • **Inline** (`mountReactive`, first mount and parent-driven re-mount): builds
///    on the shared builder while its `effect` tracks reads, reconciling the subtree
///    against the reused anchor's children.
///  • **Isolated** (`rerun`, fired by the drain on a signal change): rebuilds with a
///    fresh builder positioned via `rootAt(anchor)`, since the shared builder can't
///    be re-entered mid-drain.
/// The record is owned by the mounting `Scope`; the MountTable only borrows it.
pub const MountRecord = struct {
    anchor: NodeId,
    component_ptr: *anyopaque,
    build_fn: *const fn (*anyopaque, *BuildContext) anyerror!void,
    effect: *signals.Effect = undefined,
    /// Scope owning `effect`; on unmount the layer tears down just this effect.
    scope: *signals.Scope,
    /// `component.onUnmount()` trampoline, or null if the component declares none.
    unmount_fn: ?*const fn (*anyopaque) void = null,
    /// For framework-owned instances (`mountOwned`): the instance pointer and a
    /// trampoline that `deinit`s + frees it on unmount. Null for `mountReactive`
    /// (the caller owns the component).
    owned_ptr: ?*anyopaque = null,
    destroy_fn: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
    /// True when the record itself was framework-allocated (mountOwned) and must be
    /// freed on unmount / table teardown, rather than owned by a caller Scope.
    framework_record: bool = false,
    /// Builder config for isolated re-runs (registry+store+theme; no measure/clipboard,
    /// mirroring the partial-rebuild precedent in tabs.zig).
    template: UIBuilder,
    router: ?*events.EventRouter,
    mounts: *MountTable,

    fn rerun(self: *MountRecord) void {
        const gen = signals.currentPropagationGen();
        // Subsumption: an ancestor already rebuilt this subtree this propagation.
        if (self.template.registry.getNode(self.anchor)) |n| {
            if (n.built_gen == gen) return;
        } else return; // anchor gone (removed) — nothing to rebuild
        var b = self.template;
        b.parent_stack = .{};
        b.rootAt(self.anchor) catch return;
        var ctx = BuildContext{ .builder = &b, .router = self.router, .mounts = self.mounts, .providers = null };
        self.build_fn(self.component_ptr, &ctx) catch {};
        std.debug.assert(b.parent_stack.len == 1); // balance guard: only our rootAt frame remains
        b.close();
        self.template.registry.markLayoutDirty(self.anchor);
        // Re-fetch: the build may have grown registry.nodes and moved it.
        if (self.template.registry.getNode(self.anchor)) |n| n.built_gen = gen;
    }
};

/// Maps a component anchor NodeId → its MountRecord. Lives per engine (and per test);
/// records are owned by their Scope, so `deinit` only frees the map.
pub const MountTable = struct {
    map: std.AutoHashMapUnmanaged(NodeId, *MountRecord) = .{},
    allocator: std.mem.Allocator,
    /// Shared owner of the build-effects created for framework-owned components
    /// (`mountOwned`). `mountReactive` records use the caller's scope instead.
    scope: signals.Scope,
    /// Reactive runtime theme. Engine-lifetime handle reachable from every
    /// `BuildContext` via `ctx.mounts` — including isolated re-runs, where the
    /// stack-frame provider chain (`provide`/`use`) is gone (`providers = null`).
    /// A component reads it with `ctx.theme()`; `theme_signal.set(...)` re-runs
    /// every build-effect that read it (batched, one pass), swapping the theme with
    /// no global rebuild. Null in tests / headless setups that don't wire a theme.
    theme_signal: ?*signals.Signal(theme_mod.Theme) = null,
    /// Which window this tree belongs to, and how to act on it. Set by the
    /// framework's window host; null in tests / headless setups. Lives here for the
    /// same reason `theme_signal` does: an isolated re-run has no provider chain, so
    /// a component rebuilt on its own must still reach its own window.
    window_id: i32 = 0,
    window_ops: ?*const WindowOps = null,

    /// The window actions a component tree needs, type-erased so the component layer
    /// stays free of any engine import (the same shape as the builder's clipboard and
    /// focus-scope hooks).
    pub const WindowOps = struct {
        startDrag: *const fn (window_id: i32) void,
    };

    pub fn init(allocator: std.mem.Allocator) MountTable {
        return .{ .allocator = allocator, .scope = signals.Scope.init(allocator) };
    }
    pub fn deinit(self: *MountTable) void {
        // Every mounted component is being unmounted, so `onUnmount` fires here just
        // as it does when a single anchor is reconciled away. Tearing the whole table
        // down used to skip it, which only showed up once windows could close
        // independently: a caller-owned component kept bindings pointing at the
        // closed window's nodes, and the next `set()` on a signal it had read wrote
        // into a freed store.
        var un = self.map.valueIterator();
        while (un.next()) |recp| {
            const rec = recp.*;
            if (rec.unmount_fn) |uf| uf(rec.component_ptr);
        }
        // Free any still-mounted framework-owned instances + their records (the
        // scope below drops their build-effects). mountReactive records are owned by
        // their caller scopes, so they're skipped here.
        var it = self.map.valueIterator();
        while (it.next()) |recp| {
            const rec = recp.*;
            if (rec.framework_record) {
                if (rec.destroy_fn) |df| df(rec.owned_ptr.?, self.allocator);
                self.allocator.destroy(rec);
            }
        }
        self.map.deinit(self.allocator);
        self.scope.deinit();
    }
    pub fn get(self: *MountTable, anchor: NodeId) ?*MountRecord {
        return self.map.get(anchor);
    }
    pub fn put(self: *MountTable, anchor: NodeId, rec: *MountRecord) !void {
        try self.map.put(self.allocator, anchor, rec);
    }
    pub fn remove(self: *MountTable, anchor: NodeId) void {
        _ = self.map.remove(anchor);
    }

    /// Registry node-removed listener: when a mounted anchor is
    /// reconciled away, run `onUnmount`, destroy the build-effect (so a later
    /// `set()` on a signal it read does nothing), free a framework-owned instance +
    /// record, then drop the entry. Safe mid-drain — `Scope.destroyEffect`
    /// unschedules the effect first. `ctx` is the `*MountTable`.
    pub fn nodeRemovedListener(ctx: ?*anyopaque, id: NodeId) void {
        const self: *MountTable = @ptrCast(@alignCast(ctx.?));
        const rec = self.map.get(id) orelse return;
        if (rec.unmount_fn) |uf| uf(rec.component_ptr);
        rec.scope.destroyEffect(rec.effect);
        if (rec.destroy_fn) |df| df(rec.owned_ptr.?, self.allocator);
        _ = self.map.remove(id);
        if (rec.framework_record) self.allocator.destroy(rec);
    }
};

/// Stable reconciliation key for a component anchor: the type name, XOR'd with the
/// component's explicit `.key` field when it has one (to disambiguate siblings).
fn mountKey(comptime T: type, component: *T) u64 {
    var k = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, @typeName(T));
    if (@hasField(T, "key")) k ^= hashKey(@field(component, "key"));
    return k;
}

/// Anchor key for a `mountOwned` instance: the type name, XOR'd with `init_props.key`
/// when present (to disambiguate sibling instances of the same `T`).
fn ownedKey(comptime T: type, init_props: anytype) u64 {
    var k = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, @typeName(T));
    if (@hasField(@TypeOf(init_props), "key")) k ^= hashKey(@field(init_props, "key"));
    return k;
}

/// Props `mountOwned` consumes itself rather than assigning to the instance: `.key`
/// (reconciliation) and `.fill` / `.hug` (anchor sizing). A component may still
/// declare a field of the same name — `.key` is also copied onto `T.key` when it has
/// one — but it does not have to.
const RESERVED_PROPS = [_][]const u8{ "key", "fill", "hug" };

/// Rejects an `init_props` field that is neither a field of `T` nor reserved. Without
/// this a typo (`.hugg`) or a prop left over from a refactor (`.expanded` on a Button)
/// silently does nothing forever — it compiles, it just never applies.
fn validateProps(comptime T: type, comptime IP: type) void {
    comptime {
        for (std.meta.fields(IP)) |f| {
            if (@hasField(T, f.name)) continue;
            var reserved = false;
            for (RESERVED_PROPS) |r| {
                if (std.mem.eql(u8, r, f.name)) reserved = true;
            }
            if (reserved) continue;
            @compileError("unknown prop '." ++ f.name ++ "' for " ++ @typeName(T) ++
                " — it is not a field of the component and not a reserved prop (.key/.fill/.hug)");
        }
    }
}

/// Initializes a freshly-allocated `mountOwned` instance: each field is set from
/// `init_props` if present, else its declared default, else left `undefined` (a
/// state field the component initializes in `onMount`).
/// Assigns one prop, bridging the one conversion Zig won't do on its own: a struct
/// literal written for a `?SomeStruct` prop (`.text_style = .{ .size = 13 }`) is
/// already a value of an anonymous struct type by the time it reaches here, and an
/// anonymous struct value does not coerce through an optional. Without this bridge
/// every optional-struct prop forces the caller to spell the type out
/// (`fw.theme.TextStyle{...}`), and the error when they don't points at an
/// assignment deep in the mount machinery rather than at the call site.
///
/// The bridge rebuilds the named struct field by field: fields the literal names are
/// copied (each coercing on its own, so `.weight = .bold` still works), the rest take
/// their declared defaults.
fn assignProp(comptime FT: type, dst: *FT, value: anytype) void {
    const VT = @TypeOf(value);
    if (comptime @typeInfo(FT) == .optional and VT != FT) {
        const Inner = @typeInfo(FT).optional.child;
        if (comptime VT != Inner and @typeInfo(Inner) == .@"struct" and
            @typeInfo(VT) == .@"struct" and !@typeInfo(VT).@"struct".is_tuple)
        {
            comptime for (std.meta.fields(VT)) |vf| {
                if (!@hasField(Inner, vf.name)) @compileError("unknown field '." ++ vf.name ++
                    "' in the literal for a " ++ @typeName(Inner) ++ " prop");
            };
            var built: Inner = undefined;
            inline for (std.meta.fields(Inner)) |inf| {
                if (@hasField(VT, inf.name)) {
                    @field(built, inf.name) = @field(value, inf.name);
                } else if (inf.default_value_ptr) |ptr| {
                    @field(built, inf.name) = @as(*const inf.type, @ptrCast(@alignCast(ptr))).*;
                } else {
                    @compileError("literal for a " ++ @typeName(Inner) ++ " prop is missing '." ++
                        inf.name ++ "', which has no default — write " ++ @typeName(Inner) ++ "{...}");
                }
            }
            dst.* = built;
            return;
        }
    }
    dst.* = value;
}

fn initInstance(comptime T: type, inst: *T, init_props: anytype) void {
    const IP = @TypeOf(init_props);
    comptime validateProps(T, IP);
    inline for (std.meta.fields(T)) |f| {
        if (@hasField(IP, f.name)) {
            assignProp(f.type, &@field(inst, f.name), @field(init_props, f.name));
        } else if (f.default_value_ptr) |ptr| {
            @field(inst, f.name) = @as(*const f.type, @ptrCast(@alignCast(ptr))).*;
        } else {
            @field(inst, f.name) = undefined;
        }
    }
}

/// Re-applies only the props present in `init_props` to an existing instance on
/// rebuild; state fields (absent from `init_props`) are left untouched.
fn applyProps(comptime T: type, inst: *T, init_props: anytype) void {
    comptime validateProps(T, @TypeOf(init_props));
    inline for (std.meta.fields(@TypeOf(init_props))) |f| {
        if (@hasField(T, f.name)) assignProp(
            @FieldType(T, f.name),
            &@field(inst, f.name),
            @field(init_props, f.name),
        );
    }
}

fn buildTramp(comptime T: type) *const fn (*anyopaque, *BuildContext) anyerror!void {
    return struct {
        fn call(ptr: *anyopaque, ctx: *BuildContext) anyerror!void {
            const c: *T = @ptrCast(@alignCast(ptr));
            return c.build(ctx);
        }
    }.call;
}

fn unmountTramp(comptime T: type) *const fn (*anyopaque) void {
    return struct {
        fn call(ptr: *anyopaque) void {
            const c: *T = @ptrCast(@alignCast(ptr));
            c.onUnmount();
        }
    }.call;
}

fn destroyTramp(comptime T: type) *const fn (*anyopaque, std.mem.Allocator) void {
    return struct {
        fn call(ptr: *anyopaque, a: std.mem.Allocator) void {
            const c: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "deinit")) c.deinit();
            a.destroy(c);
        }
    }.call;
}

/// Invokes `T.onMount` if declared, passing the allocator when it takes one
/// (`onMount(self, allocator)`) — the hook where a component initializes its
/// `Signal`/`Scope` state fields — or nothing (`onMount(self)`).
fn callOnMount(comptime T: type, inst: *T, alloc: std.mem.Allocator) void {
    if (!@hasDecl(T, "onMount")) return;
    const params = @typeInfo(@TypeOf(T.onMount)).@"fn".params;
    if (params.len >= 2) inst.onMount(alloc) else inst.onMount();
}

/// Builds the isolated-rerun builder config for a mount record. Carries theme AND
/// `measure`/`clipboard` from the live builder: these are engine-lifetime handles
/// (text measurement, system clipboard) that `TextInput`/`TextArea` capture in their
/// `build()`; dropping them would null out caret metrics and copy/paste whenever a
/// signal-driven rebuild re-ran those widgets.
fn mountTemplate(src: *UIBuilder) UIBuilder {
    var t = UIBuilder.init(src.registry, src.store);
    t.theme = src.theme;
    t.measure = src.measure;
    t.clipboard = src.clipboard;
    t.focus_scope = src.focus_scope;
    t.animator = src.animator;
    return t;
}

/// Sizes a mount anchor to fill its parent's content box (width/height 100%). The
/// anchor is an implementation detail of reactive mounting; without this it hugs its
/// content (default `align-items: flex_start`), so a `width/height: 100%` component
/// root resolves against a zero-ish box. Idempotent (no-op writes are filtered).
fn fillAnchor(builder: *UIBuilder, anchor: NodeId) !void {
    try builder.store.setLayout(anchor, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
    try builder.store.setLayout(anchor, .height, .{ .dimension = .{ .value = 100, .unit = .percent } });
}

/// Number of ancestors of `id` (root = 0). Bounds the walk at the tree-depth cap.
fn depthOf(registry: *reg.UIRegistry, id: NodeId) u32 {
    var d: u32 = 0;
    var cur = id;
    while (registry.getNode(cur)) |n| {
        if (n.parent == reg.NULL_NODE) break;
        cur = n.parent;
        d += 1;
        if (d >= reg.MAX_TREE_DEPTH) break;
    }
    return d;
}

// ── Runtime child handle ───────────────────────────────────────────────────────
//
// Containers that hold heterogeneous children chosen at runtime (ScrollView,
// Tabs, SplitPane) can't use the comptime `buildChild`/tuple path — they need a
// type-erased handle. `Child` is the minimal one: just `build(*BuildContext)`
// and `deinit` (events go through the EventRouter, so there is no `handleEvent`,
// unlike the retired `widget.Widget` vtable).

pub const Child = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        build: *const fn (*anyopaque, *BuildContext) anyerror!void,
        deinit: *const fn (*anyopaque) void,
        /// `T.onUnmount()`, when the wrapped type declares one. Distinct from
        /// `deinit`: the instance is caller-owned and stays alive (it may be built
        /// again later), but the nodes it built are gone. Null when `T` declares no
        /// `onUnmount`, or for a `slot()` of plain values.
        unmount: ?*const fn (*anyopaque) void = null,
    };

    pub fn build(self: Child, ctx: *BuildContext) !void {
        return self.vtable.build(self.ptr, ctx);
    }

    pub fn deinit(self: Child) void {
        self.vtable.deinit(self.ptr);
    }

    /// Tells the wrapped component its nodes are gone — reset anything that refers
    /// to them (bindings, cached NodeIds) here. Fires when the window or subtree it
    /// was built into is torn down.
    pub fn unmount(self: Child) void {
        if (self.vtable.unmount) |f| f(self.ptr);
    }
};

/// Byte column within `line` nearest to local x — the inverse of caret
/// positioning (font hit-test, midpoint rule). Uses exact measurement when
/// present, else the size-scaled fallback advance. `line` must not contain newlines.
pub fn columnAtX(measure: ?TextMeasure, line: []const u8, font_size: f32, local_x: f32) usize {
    if (local_x <= 0) return 0;
    if (measure) |m| {
        var acc: f32 = 0;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const adv = m.width(line[i .. i + 1], font_size);
            if (local_x < acc + adv / 2.0) return i;
            acc += adv;
        }
        return line.len;
    }
    const c: usize = @intFromFloat(@round(local_x / fallbackCharWidth(font_size)));
    return @min(c, line.len);
}

// ── Shared text-editing helpers (TextInput / TextArea) ────────────────────────
// cursor positions are BYTE indices into a UTF-8 buffer; edits must move/cut whole
// codepoints (a CJK char is 3 bytes — byte-stepping would corrupt it).
// Continuation bytes are 0b10xxxxxx.

/// Byte index of the codepoint boundary at or before `i` (steps the cursor left
/// by one whole codepoint). Returns 0 at the start of the buffer.
pub fn prevBoundary(buf: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and (buf[j] & 0xC0) == 0x80) j -= 1;
    return j;
}

/// Byte index of the next codepoint boundary after `i` (steps right by one whole
/// codepoint). Returns buf.len at or past the end.
pub fn nextBoundary(buf: []const u8, i: usize) usize {
    if (i >= buf.len) return buf.len;
    const len = std.unicode.utf8ByteSequenceLength(buf[i]) catch 1;
    return @min(i + len, buf.len);
}

/// A half-open byte range `[start, end)` into a UTF-8 buffer.
pub const Range = struct { start: usize, end: usize };

/// The active selection over a buffer of length `buf_len`, given a selection
/// anchor and a cursor (both BYTE indices that callers may leave stale after an
/// edit). Clamps both ends to `buf_len` so an out-of-range end can't drive an
/// `orderedRemove` off the end. Returns null when there's no anchor or the range
/// is empty (anchor == cursor).
pub fn selectionRange(buf_len: usize, anchor: ?usize, cursor: usize) ?Range {
    const a = anchor orelse return null;
    const lo = @min(@min(a, cursor), buf_len);
    const hi = @min(@max(a, cursor), buf_len);
    return if (lo == hi) null else .{ .start = lo, .end = hi };
}

/// Word characters for double-click selection: ASCII alphanumerics + '_'.
/// (Multi-byte letters aren't classified as word chars in v1 — good enough for
/// the common case; a full Unicode word-break is out of scope.)
fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// The word range containing byte position `pos`: expands left/right over the run
/// of ASCII word bytes. On a non-word byte, selects that single codepoint. Never
/// crosses a newline (a '\n' is a non-word byte), so it's safe for multi-line
/// buffers too.
pub fn wordRangeAt(buf: []const u8, pos: usize) Range {
    if (buf.len == 0) return .{ .start = 0, .end = 0 };
    var p = pos;
    if (p > buf.len) p = buf.len;
    var start = p;
    while (start > 0 and isWordByte(buf[start - 1])) start = prevBoundary(buf, start);
    var end = p;
    while (end < buf.len and isWordByte(buf[end])) end = nextBoundary(buf, end);
    if (start == end) {
        // On a non-word char: select just that codepoint (if any).
        if (p < buf.len) end = nextBoundary(buf, p) else if (p > 0) start = prevBoundary(buf, p);
    }
    return .{ .start = start, .end = end };
}

/// Handles the shared IME `text_composition` / `text_commit` events. Returns true
/// when the event was an IME event (and was handled) so the caller can `return`.
/// `widget` must expose `preedit` (ArrayList(u8)), `insertText([]const u8) void`
/// and `bumpRev() void`; `ev` must expose `name` and `text`.
pub fn handleImeEvent(widget: anytype, ev: anytype) bool {
    if (std.mem.eql(u8, ev.name, "text_composition")) {
        widget.preedit.clearRetainingCapacity();
        widget.preedit.appendSlice(ev.text) catch {};
        widget.bumpRev();
        return true;
    }
    if (std.mem.eql(u8, ev.name, "text_commit")) {
        widget.preedit.clearRetainingCapacity();
        widget.insertText(ev.text);
        widget.bumpRev();
        return true;
    }
    return false;
}

/// Filters pasted `text` for insertion: drops C0 control bytes, keeping '\n' only
/// when `keep_newlines`. Returns freshly-allocated bytes the caller must free.
pub fn filteredPaste(allocator: std.mem.Allocator, text: []const u8, keep_newlines: bool) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (text) |byte| {
        if (byte >= 32 or (keep_newlines and byte == '\n')) try out.append(byte);
    }
    return out.toOwnedSlice();
}

// ── Undo/redo ────────────────────────────────────────────────────────────
// A single `applyEdit` primitive funnels every buffer mutation (typing, delete,
// paste, cut, IME commit) through the history, so undo/redo is uniform. Each Edit
// captures the removed and inserted byte runs at a byte offset plus the caret
// before/after; undo replays the inverse, redo the forward.

fn isSeparatorByte(b: u8) bool {
    return b == ' ' or b == '\n' or b == '\t';
}

pub const Edit = struct {
    at: usize,
    removed: []const u8, // owned by the history allocator
    inserted: []const u8, // owned by the history allocator
    caret_before: usize,
    caret_after: usize,
};

/// Bounded undo/redo stack. New edits truncate any redo branch; consecutive
/// single-codepoint inserts coalesce into one edit up to a separator so undo
/// removes whole words, not one letter at a time. The `removed`/`inserted` slices
/// are duped to `allocator` and freed on overwrite, cap eviction and `deinit`.
pub const EditHistory = struct {
    const CAP = 256;

    allocator: std.mem.Allocator,
    edits: std.array_list.Managed(Edit),
    /// Number of applied edits: undo point. undo decrements, redo increments, a
    /// new record truncates everything at/after it.
    cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator) EditHistory {
        return .{ .allocator = allocator, .edits = std.array_list.Managed(Edit).init(allocator) };
    }

    pub fn deinit(self: *EditHistory) void {
        for (self.edits.items) |*e| self.freeEdit(e);
        self.edits.deinit();
    }

    fn freeEdit(self: *EditHistory, e: *Edit) void {
        self.allocator.free(e.removed);
        self.allocator.free(e.inserted);
    }

    /// Records an edit that removed `removed` and inserted `inserted` at byte `at`.
    /// `coalesce` (a single-codepoint insert) may merge into the previous insert.
    pub fn record(self: *EditHistory, at: usize, removed: []const u8, inserted: []const u8, caret_before: usize, caret_after: usize, coalesce: bool) !void {
        // Drop the redo branch.
        while (self.edits.items.len > self.cursor) {
            var e = self.edits.pop().?;
            self.freeEdit(&e);
        }
        // Coalesce with the previous pure-insert edit (same run, not past a separator).
        if (coalesce and self.cursor > 0 and removed.len == 0) {
            const last = &self.edits.items[self.cursor - 1];
            if (last.removed.len == 0 and at == last.at + last.inserted.len and
                (last.inserted.len == 0 or !isSeparatorByte(last.inserted[last.inserted.len - 1])))
            {
                const merged = try self.allocator.alloc(u8, last.inserted.len + inserted.len);
                @memcpy(merged[0..last.inserted.len], last.inserted);
                @memcpy(merged[last.inserted.len..], inserted);
                self.allocator.free(last.inserted);
                last.inserted = merged;
                last.caret_after = caret_after;
                return;
            }
        }
        const removed_dup = try self.allocator.dupe(u8, removed);
        errdefer self.allocator.free(removed_dup);
        const inserted_dup = try self.allocator.dupe(u8, inserted);
        errdefer self.allocator.free(inserted_dup);
        try self.edits.append(.{
            .at = at,
            .removed = removed_dup,
            .inserted = inserted_dup,
            .caret_before = caret_before,
            .caret_after = caret_after,
        });
        // Cap: evict the oldest edit.
        if (self.edits.items.len > CAP) {
            var old = self.edits.orderedRemove(0);
            self.freeEdit(&old);
        }
        self.cursor = self.edits.items.len;
    }

    fn applyToBuf(buf: *std.array_list.Managed(u8), at: usize, remove_len: usize, insert: []const u8) void {
        var k: usize = 0;
        while (k < remove_len) : (k += 1) _ = buf.orderedRemove(at);
        if (insert.len > 0) buf.insertSlice(at, insert) catch {};
    }

    /// Undoes the last edit, mutating `buf`. Returns the caret to restore, or null
    /// if there's nothing to undo.
    pub fn undo(self: *EditHistory, buf: *std.array_list.Managed(u8)) ?usize {
        if (self.cursor == 0) return null;
        self.cursor -= 1;
        const e = self.edits.items[self.cursor];
        applyToBuf(buf, e.at, e.inserted.len, e.removed);
        return e.caret_before;
    }

    /// Redoes the next edit, mutating `buf`. Returns the caret to restore, or null.
    pub fn redo(self: *EditHistory, buf: *std.array_list.Managed(u8)) ?usize {
        if (self.cursor >= self.edits.items.len) return null;
        const e = self.edits.items[self.cursor];
        self.cursor += 1;
        applyToBuf(buf, e.at, e.removed.len, e.inserted);
        return e.caret_after;
    }
};

/// Applies an edit to a text widget AND records it for undo: removes `remove_len`
/// bytes at `at`, inserts `insert`, moves the cursor after it and clears the
/// selection. `widget` must expose `text_buffer` (ArrayList(u8)), `cursor_pos`,
/// `sel_anchor: ?usize` and `history: EditHistory`. `coalesce` merges consecutive
/// single-codepoint inserts (typing) into one undo step.
pub fn applyEdit(widget: anytype, at: usize, remove_len: usize, insert: []const u8, coalesce: bool) void {
    const buf = &widget.text_buffer;
    const n = buf.items.len;
    const a = @min(at, n);
    const rl = @min(remove_len, n - a);
    widget.history.record(a, buf.items[a .. a + rl], insert, widget.cursor_pos, a + insert.len, coalesce) catch {};
    var k: usize = 0;
    while (k < rl) : (k += 1) _ = buf.orderedRemove(a);
    if (insert.len > 0) buf.insertSlice(a, insert) catch {};
    widget.cursor_pos = a + insert.len;
    widget.sel_anchor = null;
    // Fire the change handler on real mutations only (a no-op edit — an empty cut,
    // a paste of nothing — touches neither side and must not notify).
    if (rl > 0 or insert.len > 0) notifyTextChange(widget);
}

/// Fires a text widget's optional `on_change` handler with the current buffer
/// contents. Called from the shared edit primitives (`applyEdit`, `editUndo`,
/// `editRedo`) so it runs on real buffer mutations only — caret and selection
/// moves route through `bumpRev` without touching the buffer, and never fire it.
/// A no-op when the widget type has no `on_change` field or it's null. The event
/// carries the mutated text (`ev.text`) and the widget's root node id, matching
/// the `value_changed` kind ("emitted by widgets internally").
pub fn notifyTextChange(widget: anytype) void {
    if (!@hasField(@TypeOf(widget.*), "on_change")) return;
    const h = widget.on_change orelse return;
    h.call(h.ptr, .{
        .name = "value_changed",
        .id = "",
        .node_id = widget.root_id,
        .text = widget.text_buffer.items,
    });
}

/// True when `text` is exactly one codepoint that isn't a separator — the
/// condition under which a typed insert coalesces into the previous undo step.
pub fn coalescesInsert(text: []const u8) bool {
    if (text.len == 0) return false;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return false;
    if (len != text.len) return false; // more than one codepoint
    return !(text.len == 1 and isSeparatorByte(text[0]));
}

// ── Shared text-edit helpers (TextInput / TextArea) ───────────────────────────
// Duck-typed like `applyEdit`: the widget just has to expose the fields/methods
// each helper documents. This is the shared edit core — the widgets keep
// their own geometry/render code and only their genuinely common operations live
// here, so there's one implementation of undo/redo/clipboard instead of two.

/// Undo one recorded edit: restores the buffer, moves the caret to the step's
/// recorded position, clears the selection and repaints. No-op on an empty
/// stack. `widget` must expose `history`, `text_buffer`, `cursor_pos`,
/// `sel_anchor` and `bumpRev()`.
pub fn editUndo(widget: anytype) void {
    if (widget.history.undo(&widget.text_buffer)) |caret| {
        widget.cursor_pos = caret;
        widget.sel_anchor = null;
        widget.bumpRev();
        notifyTextChange(widget); // real buffer mutation — after bumpRev, text is consistent
    }
}

/// Redo one previously-undone edit (mirror of `editUndo`).
pub fn editRedo(widget: anytype) void {
    if (widget.history.redo(&widget.text_buffer)) |caret| {
        widget.cursor_pos = caret;
        widget.sel_anchor = null;
        widget.bumpRev();
        notifyTextChange(widget); // real buffer mutation — after bumpRev, text is consistent
    }
}

/// Copies the selection — or the whole buffer when nothing is selected — to the
/// clipboard. No-op without a clipboard. Callers that mask secrets (password
/// fields) must guard before calling. `widget` must expose `clipboard`,
/// `text_buffer` and `selRange()`.
pub fn clipboardCopySelection(widget: anytype) void {
    const cb = widget.clipboard orelse return;
    if (widget.selRange()) |r| {
        _ = cb.set(widget.text_buffer.items[r.start..r.end]);
    } else {
        _ = cb.set(widget.text_buffer.items);
    }
}

/// Pastes clipboard text at the caret, replacing any selection, as one undo
/// step. `keep_newlines` selects multi-line (TextArea) vs single-line
/// (TextInput drops newlines). `widget` must expose `clipboard`, `allocator`,
/// `selRange()`, `cursor_pos` and `bumpRev()`.
pub fn clipboardPaste(widget: anytype, keep_newlines: bool) void {
    const cb = widget.clipboard orelse return;
    const text = cb.get(widget.allocator) orelse return;
    defer widget.allocator.free(text);
    const filtered = filteredPaste(widget.allocator, text, keep_newlines) catch return;
    defer widget.allocator.free(filtered);
    const r = widget.selRange();
    const at = if (r) |rr| rr.start else widget.cursor_pos;
    const rl = if (r) |rr| rr.end - rr.start else 0;
    applyEdit(widget, at, rl, filtered, false);
    widget.bumpRev();
}

// ── Shared tree-widget helpers (TreeView / TreeList) ──────────────────────────

/// Re-runs a tree widget's body into its existing root, in place, after a
/// structural change (expand/collapse): a partial rebuild via `UIBuilder.rootAt`
/// instead of a whole-tree rebuild. `widget` must expose `store`
/// (?*PropertyStore), `root_id` (NodeId), `theme`, `buildBody(*UIBuilder) !void`
/// and `updateVisuals() void`.
pub fn rebuildTreeBody(widget: anytype) void {
    const store = widget.store orelse return;
    const registry = store.registry orelse return;
    if (widget.root_id == reg.NULL_NODE) return;
    var b = builder_mod.UIBuilder.init(registry, store);
    b.theme = widget.theme;
    b.rootAt(widget.root_id) catch return;
    widget.buildBody(&b) catch {};
    b.close();
    registry.markLayoutDirty(widget.root_id);
    widget.updateVisuals();
}

/// Wraps a comptime children tuple as a single type-erased `Child` — the slot
/// content a widget renders in place of its default label. `tuple_ptr` is a
/// pointer to a tuple of child components (e.g. `&.{ Icon{...}, Text{...} }`) and
/// must outlive the slot: composed content is owned by the parent that builds it,
/// not by the widget. `build` expands the tuple into the widget's slot parent; the
/// tuple entries are values, so `deinit` is a no-op.
pub fn slot(tuple_ptr: anytype) Child {
    const P = @TypeOf(tuple_ptr);
    const Wrap = struct {
        fn build(p: *anyopaque, ctx: *BuildContext) anyerror!void {
            const tp: P = @ptrCast(@alignCast(p));
            try buildChildren(ctx, tp.*);
        }
        fn deinit(_: *anyopaque) void {}
    };
    return .{ .ptr = @constCast(tuple_ptr), .vtable = &.{ .build = Wrap.build, .deinit = Wrap.deinit } };
}

/// Wraps a pointer to a component as a `Child`. `T` must expose
/// `build(*T, *BuildContext) !void` and `deinit(*T) void`.
pub fn childOf(comptime T: type, instance: *T) Child {
    const Wrap = struct {
        fn build(p: *anyopaque, ctx: *BuildContext) anyerror!void {
            // Per-component-type zone: labels structural rebuilds by the concrete
            // type (e.g. "framework.button.Button") so the trace shows which
            // component's build() dominates a partial rebuild.
            const z = prof.zoneNamed(@typeName(T));
            defer z.end();
            try @as(*T, @ptrCast(@alignCast(p))).build(ctx);
        }
        fn deinit(p: *anyopaque) void {
            @as(*T, @ptrCast(@alignCast(p))).deinit();
        }
        fn unmount(p: *anyopaque) void {
            @as(*T, @ptrCast(@alignCast(p))).onUnmount();
        }
    };
    return .{
        .ptr = instance,
        .vtable = &.{
            .build = Wrap.build,
            .deinit = Wrap.deinit,
            .unmount = if (@hasDecl(T, "onUnmount")) Wrap.unmount else null,
        },
    };
}

// ── Comptime props → store mapping ────────────────────────────────────────────

fn applyBoxProps(ctx: *BuildContext, id: NodeId, props_: anytype) !void {
    const store = ctx.builder.store;
    const T = @TypeOf(props_);
    inline for (std.meta.fields(T)) |f| {
        const v = @field(props_, f.name);
        const name = f.name;
        if (comptime std.mem.eql(u8, name, "width")) {
            try store.setLayout(id, .width, asDim(v).toProp());
        } else if (comptime std.mem.eql(u8, name, "height")) {
            try store.setLayout(id, .height, asDim(v).toProp());
        } else if (comptime std.mem.eql(u8, name, "gap")) {
            try store.setLayout(id, .gap, .{ .dimension = .{ .value = numF32(v), .unit = .px } });
        } else if (comptime std.mem.eql(u8, name, "row_gap")) {
            try store.setLayout(id, .row_gap, .{ .dimension = .{ .value = numF32(v), .unit = .px } });
        } else if (comptime std.mem.eql(u8, name, "column_gap")) {
            try store.setLayout(id, .column_gap, .{ .dimension = .{ .value = numF32(v), .unit = .px } });
        } else if (comptime std.mem.eql(u8, name, "align_self")) {
            try store.setLayout(id, .align_self, .{ .keyword = alignKeyword(v) });
        } else if (comptime std.mem.eql(u8, name, "grow")) {
            try store.setLayout(id, .flex_grow, .{ .number = numF32(v) });
        } else if (comptime std.mem.eql(u8, name, "shrink")) {
            try store.setLayout(id, .flex_shrink, .{ .number = numF32(v) });
        } else if (comptime std.mem.eql(u8, name, "direction")) {
            const kw: props.Keyword = if (v == .row) .row else .column;
            try store.setLayout(id, .flex_direction, .{ .keyword = kw });
        } else if (comptime std.mem.eql(u8, name, "justify")) {
            try store.setLayout(id, .justify_content, .{ .keyword = justifyKeyword(v) });
        } else if (comptime std.mem.eql(u8, name, "align")) {
            try store.setLayout(id, .align_items, .{ .keyword = alignKeyword(v) });
        } else if (comptime std.mem.eql(u8, name, "padding")) {
            const e: EdgeInsets = v;
            try store.setLayout(id, .padding_top, .{ .dimension = .{ .value = e.t, .unit = .px } });
            try store.setLayout(id, .padding_right, .{ .dimension = .{ .value = e.r, .unit = .px } });
            try store.setLayout(id, .padding_bottom, .{ .dimension = .{ .value = e.b, .unit = .px } });
            try store.setLayout(id, .padding_left, .{ .dimension = .{ .value = e.l, .unit = .px } });
        } else if (comptime std.mem.eql(u8, name, "margin")) {
            const e: EdgeInsets = v;
            try store.setLayout(id, .margin_top, .{ .dimension = .{ .value = e.t, .unit = .px } });
            try store.setLayout(id, .margin_right, .{ .dimension = .{ .value = e.r, .unit = .px } });
            try store.setLayout(id, .margin_bottom, .{ .dimension = .{ .value = e.b, .unit = .px } });
            try store.setLayout(id, .margin_left, .{ .dimension = .{ .value = e.l, .unit = .px } });
        } else if (comptime std.mem.eql(u8, name, "background")) {
            try store.setStyle(id, .background, asColor(v).toProp());
        } else if (comptime std.mem.eql(u8, name, "color")) {
            try store.setStyle(id, .color, asColor(v).toProp());
        } else if (comptime std.mem.eql(u8, name, "border_color")) {
            try store.setStyle(id, .border_color, asColor(v).toProp());
        } else if (comptime std.mem.eql(u8, name, "border_width")) {
            try store.setStyle(id, .border_width, .{ .dimension = .{ .value = numF32(v), .unit = .px } });
        } else if (comptime std.mem.eql(u8, name, "radius")) {
            try store.setStyle(id, .radius, .{ .dimension = .{ .value = numF32(v), .unit = .px } });
        } else if (comptime std.mem.eql(u8, name, "opacity")) {
            try store.setStyle(id, .opacity, .{ .number = numF32(v) });
        } else if (comptime std.mem.eql(u8, name, "font_size")) {
            try store.setStyle(id, .font_size, .{ .dimension = .{ .value = numF32(v), .unit = .px } });
        } else if (comptime std.mem.eql(u8, name, "line_height")) {
            try store.setStyle(id, .line_height, .{ .number = numF32(v) });
        } else if (comptime std.mem.eql(u8, name, "id")) {
            try ctx.builder.nodeId(id, v);
        } else if (comptime std.mem.eql(u8, name, "clickable")) {
            try ctx.builder.clickable(id, v);
        } else if (comptime std.mem.eql(u8, name, "right_clickable")) {
            try ctx.builder.rightClickable(id, v);
        } else if (comptime std.mem.eql(u8, name, "hoverable")) {
            try ctx.builder.hoverable(id, v);
        } else if (comptime std.mem.eql(u8, name, "focusable")) {
            // Boolean prop: true → focusable with an autogenerated action id.
            if (v) {
                var idbuf: [16]u8 = undefined;
                const auto_id = std.fmt.bufPrint(&idbuf, "n{d}", .{id}) catch "n";
                try ctx.builder.focusable(id, auto_id);
            }
        } else if (comptime std.mem.eql(u8, name, "scrollable")) {
            try ctx.builder.scrollable(id, v);
        } else if (comptime std.mem.eql(u8, name, "role")) {
            try ctx.builder.role(id, v);
        } else if (comptime std.mem.eql(u8, name, "on_click")) {
            try wireHandler(ctx, id, .click, .clickable, v);
        } else if (comptime std.mem.eql(u8, name, "on_right_click")) {
            try wireHandler(ctx, id, .right_click, .right_clickable, v);
        } else if (comptime std.mem.eql(u8, name, "on_hover_enter")) {
            try wireHandler(ctx, id, .mouse_enter, .hoverable, v);
        } else if (comptime std.mem.eql(u8, name, "on_hover_leave")) {
            try wireHandler(ctx, id, .mouse_leave, .hoverable, v);
        } else if (comptime std.mem.eql(u8, name, "on_hover")) {
            // One handler for both hover edges (see ctx.signalSetter).
            try wireHandler(ctx, id, .mouse_enter, .hoverable, v);
            try wireHandler(ctx, id, .mouse_leave, .hoverable, v);
        } else if (comptime std.mem.eql(u8, name, "on_press")) {
            // One handler for both press edges (see ctx.signalSetter).
            try wireHandler(ctx, id, .mouse_down, .clickable, v);
            try wireHandler(ctx, id, .mouse_up, .clickable, v);
        } else if (comptime std.mem.eql(u8, name, "on_mouse_down")) {
            try wireHandler(ctx, id, .mouse_down, .clickable, v);
        } else if (comptime std.mem.eql(u8, name, "on_mouse_up")) {
            try wireHandler(ctx, id, .mouse_up, .clickable, v);
        } else if (comptime std.mem.eql(u8, name, "on_focus")) {
            try wireHandler(ctx, id, .focus, .focusable, v);
        } else if (comptime std.mem.eql(u8, name, "on_blur")) {
            try wireHandler(ctx, id, .blur, .focusable, v);
        } else if (comptime std.mem.eql(u8, name, "on_key")) {
            try wireHandler(ctx, id, .key_down, .focusable, v);
        } else if (comptime std.mem.eql(u8, name, "on_scroll")) {
            try wireHandler(ctx, id, .scroll, .scrollable, v);
        } else if (comptime std.mem.eql(u8, name, "on_scroll_h")) {
            try wireHandler(ctx, id, .scroll_h, .scrollable, v);
        } else if (comptime std.mem.eql(u8, name, "on_resize")) {
            try wireResize(ctx, id, v);
        } else if (comptime std.mem.eql(u8, name, "tooltip")) {
            // Store the text as a modifier and make the node hoverable so the
            // TooltipHost observer receives its enter/leave (autogenerated action id,
            // like the other hit modifiers — keeps the C-ABI hit path unchanged).
            const owned = try store.stringAllocator().dupe(u8, v);
            try store.setModifier(id, .tooltip, .{ .string = owned });
            var idbuf: [16]u8 = undefined;
            const auto_id = std.fmt.bufPrint(&idbuf, "n{d}", .{id}) catch "n";
            try ctx.builder.hoverable(id, auto_id);
        } else if (comptime std.mem.eql(u8, name, "key")) {
            // Reconciliation key — already consumed by `extractKey` in box()/boxLeaf()
            // and passed to `openNodeKeyed`; nothing to apply to the store here.
        } else {
            @compileError("unknown box prop: '" ++ name ++ "'");
        }
    }
}

/// The hit modifier a given `on_*` prop needs so the engine emits its event kind.
const HitKind = enum { clickable, right_clickable, hoverable, focusable, scrollable };

/// Normalizes an `on_*` prop value to `?Handler` (accepts `Handler` or `?Handler`).
fn optHandler(v: anytype) ?Handler {
    const V = @TypeOf(v);
    if (V == Handler) return v;
    if (V == ?Handler) return v;
    @compileError("on_* prop expects a Handler (use ctx.handler(...)), got " ++ @typeName(V));
}

/// Wires a declarative `on_*` prop: sets the hit modifier with an autogenerated
/// action id (`"n{node_id}"`, kept so the C-ABI hit-testing/event path is unchanged)
/// and registers the typed handler by (node, kind) in the router. A null handler
/// (e.g. a disabled button's `on_click`) is a no-op — the node stays non-interactive.
fn wireHandler(ctx: *BuildContext, id: NodeId, kind: events.EventKind, hit: HitKind, v: anytype) !void {
    const h = optHandler(v) orelse return;
    var idbuf: [16]u8 = undefined;
    const auto_id = std.fmt.bufPrint(&idbuf, "n{d}", .{id}) catch "n";
    switch (hit) {
        .clickable => try ctx.builder.clickable(id, auto_id),
        .right_clickable => try ctx.builder.rightClickable(id, auto_id),
        .hoverable => try ctx.builder.hoverable(id, auto_id),
        .focusable => try ctx.builder.focusable(id, auto_id),
        .scrollable => try ctx.builder.scrollable(id, auto_id),
    }
    if (ctx.router) |r| try r.onNode(id, kind, h);
}

/// Wires `on_resize`: opts the node into size observation (no hit modifier — a
/// resize is not a pointer event, so it must not make the node hit-testable) and
/// registers the handler. The engine reports after the frame in which the solved
/// size changed; the first solve after the node is observed always reports, so the
/// handler also replaces the "first build has no size" case of `measuredSize`.
///
/// A rebuild that re-applies the same handler reports nothing new. One that binds
/// a *different* receiver to an already-observed node (a remounted widget on a
/// reconciled node) re-arms the report so that receiver learns the current size
/// too, even if the size itself didn't change.
fn wireResize(ctx: *BuildContext, id: NodeId, v: anytype) !void {
    const h = optHandler(v) orelse return;
    const registry = ctx.builder.registry;
    if (ctx.router) |r| {
        if (r.nodeHandler(id, .resize)) |prev| {
            if (prev.ptr != h.ptr or prev.call != h.call) {
                if (registry.getNode(id)) |n| {
                    n.resize_last_w = -1;
                    n.resize_last_h = -1;
                }
                registry.markLayoutDirty(id);
            }
        }
        try r.onNode(id, .resize, h);
    }
    try registry.observeResize(id);
}

/// Reads an optional `.key` prop and hashes it to a u64 reconciliation key.
fn extractKey(props_: anytype) ?u64 {
    const T = @TypeOf(props_);
    if (!@hasField(T, "key")) return null;
    return hashKey(@field(props_, "key"));
}

fn hashKey(v: anytype) u64 {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => @intCast(v),
        .@"enum" => @intFromEnum(v),
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) break :blk std.hash.Wyhash.hash(0, v);
            // String literals arrive as *const [N:0]u8 — coerce to a slice.
            if (p.size == .one) {
                const ai = @typeInfo(p.child);
                if (ai == .array and ai.array.child == u8) break :blk std.hash.Wyhash.hash(0, v);
            }
            @compileError("unhashable key pointer: " ++ @typeName(T));
        },
        else => @compileError("unhashable key type: " ++ @typeName(T)),
    };
}

/// Accepts either a `Dim` (px/pt/pct) or a bare number (treated as px).
fn asDim(v: anytype) Dim {
    const T = @TypeOf(v);
    if (T == Dim) return v;
    return .{ .value = numF32(v), .unit = .px };
}

fn asColor(v: anytype) Color {
    return v; // must be a Color (rgb/rgba)
}

fn numF32(v: anytype) f32 {
    return switch (@typeInfo(@TypeOf(v))) {
        .float, .comptime_float => @floatCast(v),
        .int, .comptime_int => @floatFromInt(v),
        else => @compileError("expected a number, got " ++ @typeName(@TypeOf(v))),
    };
}

// ── Comptime children ─────────────────────────────────────────────────────────

pub fn buildChildren(ctx: *BuildContext, children: anytype) !void {
    const T = @TypeOf(children);
    inline for (std.meta.fields(T)) |f| {
        try buildChild(ctx, @field(children, f.name));
    }
}

/// Builds one child. The child is any value (or pointer to a value) whose type
/// has a `build(self, *BuildContext) !void` method.
pub fn buildChild(ctx: *BuildContext, child: anytype) !void {
    const T = @TypeOf(child);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (!@hasDecl(p.child, "build"))
                @compileError("child '" ++ @typeName(p.child) ++ "' has no build() method");
            try child.build(ctx);
        },
        .@"struct" => {
            if (!@hasDecl(T, "build"))
                @compileError("child '" ++ @typeName(T) ++ "' has no build() method");
            var tmp = child;
            try tmp.build(ctx);
        },
        else => @compileError("invalid child type: " ++ @typeName(T)),
    }
}

// ── Built-in primitive components ─────────────────────────────────────────────

/// A text leaf usable inside a children tuple. Optional `color`/`size` set the
/// glyph color and font size on the text node. `style` (a theme `TextStyle`)
/// sets the size and, when the style has one, the line height. `line_height`
/// overrides the line-height multiplier either way.
pub const Text = struct {
    content: []const u8,
    color: ?Color = null,
    size: ?f32 = null,
    style: ?theme_mod.TextStyle = null,
    line_height: ?f32 = null,

    pub fn build(self: *Text, ctx: *BuildContext) !void {
        const id = try ctx.text(self.content);
        const store = ctx.builder.store;
        if (self.color) |c| try store.setStyle(id, .color, c.toProp());

        if (self.style) |st| {
            try store.setStyle(id, .font_size, .{ .dimension = .{ .value = st.size, .unit = .px } });
        } else if (self.size) |s| {
            try store.setStyle(id, .font_size, .{ .dimension = .{ .value = s, .unit = .px } });
        }
        const lh: ?f32 = self.line_height orelse if (self.style) |st| st.line_height else null;
        if (lh) |f| try store.setStyle(id, .line_height, .{ .number = f });
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testCtx(registry: *reg.UIRegistry, store: *props.PropertyStore, b: *UIBuilder) BuildContext {
    b.* = UIBuilder.init(registry, store);
    return BuildContext.init(b);
}

test "DragRegion makes any box drag its own window, and only its own" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = MountTable.init(a);
    defer mounts.deinit();

    const Spy = struct {
        var dragged: i32 = 0;
        fn startDrag(window_id: i32) void {
            dragged = window_id;
        }
    };
    Spy.dragged = 0;
    const ops = MountTable.WindowOps{ .startDrag = Spy.startDrag };
    mounts.window_ops = &ops;
    mounts.window_id = 4; // this tree belongs to window 4

    var b = UIBuilder.init(&registry, &store);
    var ctx = BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    const bar = try b.openNodeKeyed(.box, null);
    try ctx.dragRegion(bar);
    b.close(); // bar
    b.close(); // root

    // The box became interactive…
    try testing.expect(store.getModifier(bar, .clickable) != null);
    // …and pressing it drags the window this tree belongs to, with nothing passed in
    // — an overlay's bar moves the overlay, not the main window.
    _ = router.route(.{ .name = "mouse_down", .id = "", .node_id = bar });
    try testing.expectEqual(@as(i32, 4), Spy.dragged);
}

test "DragRegion with no window wired still makes the node interactive" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);

    // Headless / unit-test context: no MountTable at all. The call must degrade to
    // a plain clickable box rather than erroring out of the caller's build.
    var b = UIBuilder.init(&registry, &store);
    var ctx = BuildContext.init(&b);
    _ = try b.openNodeKeyed(.box, null); // root
    const box_id = try b.openNodeKeyed(.box, null);
    try ctx.dragRegion(box_id);
    b.close(); // box
    b.close(); // root
    try testing.expect(store.getModifier(box_id, .clickable) != null);
}

test "BuildContext — props map to the store at comptime" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    var b: UIBuilder = undefined;
    var ctx = testCtx(&registry, &store, &b);

    try ctx.boxLeaf(.{
        .width = pct(100),
        .height = px(48),
        .gap = 8,
        .direction = .row,
        .justify = .space_between,
        .padding = EdgeInsets.all(12),
        .background = rgb(30, 30, 40),
        .radius = 8,
        .clickable = "save_btn",
    });

    const id: NodeId = 0;
    try testing.expectEqual(props.DimUnit.percent, store.getLayout(id, .width).?.dimension.unit);
    try testing.expectEqual(@as(f32, 100), store.getLayout(id, .width).?.dimension.value);
    try testing.expectEqual(@as(f32, 48), store.getLayout(id, .height).?.dimension.value);
    try testing.expectEqual(@as(f32, 8), store.getLayout(id, .gap).?.dimension.value);
    try testing.expectEqual(props.Keyword.row, store.getLayout(id, .flex_direction).?.keyword);
    try testing.expectEqual(props.Keyword.space_between, store.getLayout(id, .justify_content).?.keyword);
    try testing.expectEqual(@as(f32, 12), store.getLayout(id, .padding_top).?.dimension.value);
    try testing.expectEqual(@as(f32, 12), store.getLayout(id, .padding_left).?.dimension.value);
    try testing.expectApproxEqAbs(@as(f32, 30.0 / 255.0), store.getStyle(id, .background).?.color.r, 0.001);
    try testing.expectEqual(@as(f32, 8), store.getStyle(id, .radius).?.dimension.value);
    try testing.expectEqualStrings("save_btn", store.getModifier(id, .clickable).?.string);
}

test "BuildContext — children tuple builds a nested tree" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    var b: UIBuilder = undefined;
    var ctx = testCtx(&registry, &store, &b);

    try ctx.box(.{ .direction = .column, .gap = 4 }, .{
        Text{ .content = "header" },
        Text{ .content = "body" },
    });

    // root box + 2 text children
    try testing.expectEqual(@as(usize, 3), registry.nodes.items.len);
    const root = registry.getNode(0).?;
    try testing.expectEqual(reg.NodeType.box, root.node_type);
    const first = registry.getNode(root.first_child).?;
    try testing.expectEqual(reg.NodeType.text, first.node_type);
    try testing.expectEqualStrings("header", store.getTextContent(root.first_child).?);
    const second = registry.getNode(first.next_sibling).?;
    try testing.expectEqualStrings("body", store.getTextContent(first.next_sibling).?);
    _ = second;
}

test "BuildContext — user component composes via build()" {
    const Card = struct {
        title: []const u8,
        pub fn build(self: *@This(), ctx: *BuildContext) !void {
            try ctx.box(.{
                .direction = .column,
                .padding = EdgeInsets.all(10),
                .background = rgb(20, 20, 20),
            }, .{
                Text{ .content = self.title },
            });
        }
    };

    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    var b: UIBuilder = undefined;
    var ctx = testCtx(&registry, &store, &b);

    var card = Card{ .title = "Hello" };
    try ctx.mount(&card);

    try testing.expectEqual(@as(usize, 2), registry.nodes.items.len); // box + text
    try testing.expectEqualStrings("Hello", store.getTextContent(1).?);
    try testing.expectEqual(props.Keyword.column, store.getLayout(0, .flex_direction).?.keyword);
}

test "forEach — keyed items reuse their nodes across reorder (automatic keys)" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();

    const Item = struct { id: u64, label: []const u8 };
    const R = struct {
        fn keyOf(it: Item) u64 {
            return it.id;
        }
        fn render(_: *const anyopaque, c: *BuildContext, it: Item) !void {
            _ = try c.text(it.label);
        }
    };

    // Build a column of three keyed items.
    const list1 = [_]Item{ .{ .id = 1, .label = "a" }, .{ .id = 2, .label = "b" }, .{ .id = 3, .label = "c" } };
    {
        var bb = UIBuilder.init(&registry, &store);
        var c = BuildContext.init(&bb);
        const root = try c.builder.openNodeKeyed(.box, null);
        c.builder.flexColumn(root) catch {};
        try c.forEach(&list1, @as(*const anyopaque, undefined), R.keyOf, R.render);
        c.builder.close();
    }

    const wrap1 = childByKey(&registry, 0, 1).?;
    const wrap2 = childByKey(&registry, 0, 2).?;
    const wrap3 = childByKey(&registry, 0, 3).?;
    const n_after_first = registry.nodes.items.len;

    // Reorder to 3,1,2 — same keys must reuse the same wrapper node ids.
    const list2 = [_]Item{ .{ .id = 3, .label = "c" }, .{ .id = 1, .label = "a" }, .{ .id = 2, .label = "b" } };
    {
        var bb = UIBuilder.init(&registry, &store);
        var c = BuildContext.init(&bb);
        const root = try c.builder.openNodeKeyed(.box, null);
        c.builder.flexColumn(root) catch {};
        try c.forEach(&list2, @as(*const anyopaque, undefined), R.keyOf, R.render);
        c.builder.close();
    }

    try testing.expectEqual(wrap1, childByKey(&registry, 0, 1).?);
    try testing.expectEqual(wrap2, childByKey(&registry, 0, 2).?);
    try testing.expectEqual(wrap3, childByKey(&registry, 0, 3).?);
    try testing.expectEqual(n_after_first, registry.nodes.items.len); // nothing recreated
    try testing.expectEqual(@as(usize, 0), registry.free_list.items.len);
}

fn childByKey(registry: *reg.UIRegistry, root: reg.NodeId, k: u64) ?reg.NodeId {
    var c = registry.getNode(root).?.first_child;
    while (c != reg.NULL_NODE) {
        const node = registry.getNode(c).?;
        if (node.key != null and node.key.? == k) return c;
        c = node.next_sibling;
    }
    return null;
}

test "when / whenElse — conditional rendering" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    var b: UIBuilder = undefined;
    var ctx = testCtx(&registry, &store, &b);

    const R = struct {
        fn yes(_: *const anyopaque, c: *BuildContext) !void {
            _ = try c.text("shown");
        }
        fn no(_: *const anyopaque, c: *BuildContext) !void {
            _ = try c.text("hidden");
        }
    };

    const root = try ctx.builder.openNodeKeyed(.box, null);
    _ = root;
    try ctx.when(true, @as(*const anyopaque, undefined), R.yes);
    try ctx.when(false, @as(*const anyopaque, undefined), R.no);
    try ctx.whenElse(false, @as(*const anyopaque, undefined), R.yes, R.no);
    ctx.builder.close();

    // root + "shown" (when true) + "hidden" (whenElse false → else branch).
    try testing.expectEqual(@as(usize, 3), registry.nodes.items.len);
    const first = registry.getNode(0).?.first_child;
    try testing.expectEqualStrings("shown", store.getTextContent(first).?);
    try testing.expectEqualStrings("hidden", store.getTextContent(registry.getNode(first).?.next_sibling).?);
}

test "provide / use — nearest typed value is injected into the subtree" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    var b: UIBuilder = undefined;
    var ctx = testCtx(&registry, &store, &b);

    const Injected = struct { accent: []const u8 };
    const Other = struct { x: i32 };

    const R = struct {
        fn body(_: *const anyopaque, c: *BuildContext) !void {
            // The provided value is visible here; an unprovided type is null.
            const th = c.use(Injected).?;
            try testing.expectEqualStrings("blue", th.accent);
            try testing.expectEqual(@as(?*Other, null), c.use(Other));
            _ = try c.text(th.accent);
        }
    };

    // Outside the provide scope, nothing is visible.
    try testing.expectEqual(@as(?*Injected, null), ctx.use(Injected));

    var injected = Injected{ .accent = "blue" };
    try ctx.provide(Injected, &injected, @as(*const anyopaque, undefined), R.body);

    // The binding is scoped: gone again after provide returns.
    try testing.expectEqual(@as(?*Injected, null), ctx.use(Injected));
    try testing.expectEqualStrings("blue", store.getTextContent(0).?);
}

test "Ctx.dynText creates a text node bound to a signal" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var ctx = BuildContext.init(&b);

    var count = signals.Signal(i32).init(testing.allocator, 0);
    defer count.deinit();
    var scope = signals.Scope.init(testing.allocator);
    defer scope.deinit();

    const id = try ctx.dynText(i32, &scope, &count, "count: {d}");
    try testing.expectEqualStrings("count: 0", store.getTextContent(id).?);

    count.set(7);
    try testing.expectEqualStrings("count: 7", store.getTextContent(id).?);
}

// ── Typed per-node handlers ──────────────────────────────────────────────

const HandlerProbe = struct {
    var clicks: u32 = 0;
    var seen_tag: u8 = 0;
    tag: u8,
    fn onClick(self: *@This(), ev: events.Event) void {
        clicks += 1;
        seen_tag = self.tag;
        _ = ev;
    }
    // The interactive node lives under a root so its id is >= 1 (id 0 == "none"
    // in CelerisEvent, so a handler on the app root is intentionally not routable).
    pub fn build(self: *@This(), ctx: *BuildContext) !void {
        const root = try ctx.builder.openNodeKeyed(.box, null);
        _ = root;
        try ctx.box(.{ .on_click = ctx.handler(self, @This().onClick) }, .{});
        ctx.builder.close();
    }
};

test "Ctx.handler + .on_click routes a typed event by node id (no strings)" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var router = events.EventRouter.init(testing.allocator);
    defer router.deinit();
    var ctx = BuildContext.initWithRouter(&b, &router);

    HandlerProbe.clicks = 0;
    HandlerProbe.seen_tag = 0;
    var probe = HandlerProbe{ .tag = 42 };
    try probe.build(&ctx);

    // The interactive box is node 1 (root is 0). It got the clickable modifier with
    // an autogenerated id, and a node handler was registered.
    try testing.expect(store.getModifier(1, .clickable) != null);
    try testing.expectEqual(@as(usize, 1), router.node_handlers.items.len);

    // A click targeting node 1 invokes the typed handler with the right payload.
    _ = router.dispatch("click", "{\"node_id\":1}");
    try testing.expectEqual(@as(u32, 1), HandlerProbe.clicks);
    try testing.expectEqual(@as(u8, 42), HandlerProbe.seen_tag);

    // An event for a different node does not.
    _ = router.dispatch("click", "{\"node_id\":2}");
    try testing.expectEqual(@as(u32, 1), HandlerProbe.clicks);
}

test "Rebuilding the same tree rewrites handlers in place (table doesn't grow)" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var router = events.EventRouter.init(testing.allocator);
    defer router.deinit();
    var ctx = BuildContext.initWithRouter(&b, &router);

    HandlerProbe.clicks = 0;
    var probe = HandlerProbe{ .tag = 7 };
    try probe.build(&ctx);
    try testing.expectEqual(@as(usize, 1), router.node_handlers.items.len);
    const node_count = registry.nodes.items.len;

    // Rebuild the same subtree: reconciliation reuses nodes and re-applies props, so
    // onNode overwrites the (node,kind) entry instead of appending a duplicate.
    try b.rootAt(0);
    try ctx.box(.{ .on_click = ctx.handler(&probe, HandlerProbe.onClick) }, .{});
    b.close();

    try testing.expectEqual(@as(usize, 1), router.node_handlers.items.len);
    try testing.expectEqual(node_count, registry.nodes.items.len);
}

test "A node removed by reconciliation drops its handler (no dangling entry)" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var router = events.EventRouter.init(testing.allocator);
    defer router.deinit();
    // Wire the same node-removed pruning the live app installs.
    registry.addNodeRemovedListener(&router, events.EventRouter.nodeRemovedListener);
    var ctx = BuildContext.initWithRouter(&b, &router);

    var probe = HandlerProbe{ .tag = 1 };
    try probe.build(&ctx);
    try testing.expectEqual(@as(usize, 1), router.node_handlers.items.len);

    // Rebuild the root with no children: node 1 is reconciled away, and its handler
    // entry is pruned via the registry hook.
    try b.rootAt(0);
    b.close();

    try testing.expectEqual(@as(usize, 0), router.node_handlers.items.len);
}

// ── Reactive component mounting ──────────────────────────────────────────

const RbList = struct {
    var builds: u32 = 0;
    n: *signals.Signal(i32),
    pub fn build(self: *@This(), ctx: *BuildContext) !void {
        builds += 1;
        const count = self.n.get();
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            _ = try ctx.builder.openNodeKeyed(.box, @intCast(i));
            ctx.builder.close();
        }
    }
};

test "A set() re-runs only the component's subtree, reusing keyed nodes" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var mounts = MountTable.init(a);
    defer mounts.deinit();

    var n = signals.Signal(i32).init(a, 2);
    defer n.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();

    RbList.builds = 0;
    var comp = RbList{ .n = &n };

    // Root holds a static sibling box (key 999) + the reactive component's anchor.
    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };
    const root = try b.openNodeKeyed(.box, null);
    const sibling = try b.openNodeKeyed(.box, 999);
    b.close();
    try ctx.mountReactive(&scope, &comp);
    b.close(); // root

    try testing.expectEqual(@as(u32, 1), RbList.builds);
    const anchor = childByKey(&registry, root, mountKey(RbList, &comp)).?;
    const box0 = childByKey(&registry, anchor, 0).?;
    const box1 = childByKey(&registry, anchor, 1).?;
    try testing.expectEqual(@as(?reg.NodeId, null), childByKey(&registry, anchor, 2));
    const nodes_before = registry.nodes.items.len;

    // Grow the list: the two existing keyed boxes keep their NodeIds; one new box.
    n.set(3);
    try testing.expectEqual(@as(u32, 2), RbList.builds); // only this component re-ran
    try testing.expectEqual(box0, childByKey(&registry, anchor, 0).?);
    try testing.expectEqual(box1, childByKey(&registry, anchor, 1).?);
    try testing.expect(childByKey(&registry, anchor, 2) != null);
    try testing.expectEqual(nodes_before + 1, registry.nodes.items.len); // exactly one new node

    // The sibling outside the anchor was never touched (same id, still there).
    try testing.expectEqual(sibling, childByKey(&registry, root, 999).?);
}

const RbChild = struct {
    var builds: u32 = 0;
    s: *signals.Signal(i32),
    pub fn build(self: *@This(), ctx: *BuildContext) !void {
        builds += 1;
        _ = self.s.get();
        _ = try ctx.builder.openNodeKeyed(.box, 1);
        ctx.builder.close();
    }
};

const RbParent = struct {
    var builds: u32 = 0;
    reads_s: bool,
    s: *signals.Signal(i32),
    child: *RbChild,
    scope: *signals.Scope,
    pub fn build(self: *@This(), ctx: *BuildContext) !void {
        builds += 1;
        if (self.reads_s) _ = self.s.get();
        try ctx.mountReactive(self.scope, self.child);
    }
};

test "Subsumption: a parent rebuild re-runs each child exactly once" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var mounts = MountTable.init(a);
    defer mounts.deinit();

    var s = signals.Signal(i32).init(a, 0);
    defer s.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();

    RbParent.builds = 0;
    RbChild.builds = 0;
    var child = RbChild{ .s = &s };
    var parent = RbParent{ .reads_s = true, .s = &s, .child = &child, .scope = &scope };

    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountReactive(&scope, &parent);
    b.close();

    try testing.expectEqual(@as(u32, 1), RbParent.builds);
    try testing.expectEqual(@as(u32, 1), RbChild.builds);

    // Both read `s`, so both effects are queued. The parent (lower depth) runs first
    // and re-mounts the child inline; the child's own queued effect is then subsumed.
    s.set(1);
    try testing.expectEqual(@as(u32, 2), RbParent.builds); // once
    try testing.expectEqual(@as(u32, 2), RbChild.builds); // once, NOT twice
}

test "A signal read only by the child re-runs only the child" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var mounts = MountTable.init(a);
    defer mounts.deinit();

    var s = signals.Signal(i32).init(a, 0);
    defer s.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();

    RbParent.builds = 0;
    RbChild.builds = 0;
    var child = RbChild{ .s = &s };
    var parent = RbParent{ .reads_s = false, .s = &s, .child = &child, .scope = &scope };

    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountReactive(&scope, &parent);
    b.close();

    try testing.expectEqual(@as(u32, 1), RbParent.builds);
    try testing.expectEqual(@as(u32, 1), RbChild.builds);

    // Parent never read `s`; only the child re-runs.
    s.set(1);
    try testing.expectEqual(@as(u32, 1), RbParent.builds); // untouched
    try testing.expectEqual(@as(u32, 2), RbChild.builds);
}

const RbTwoSig = struct {
    var builds: u32 = 0;
    x: *signals.Signal(i32),
    y: *signals.Signal(i32),
    pub fn build(self: *@This(), ctx: *BuildContext) !void {
        builds += 1;
        _ = self.x.get() + self.y.get();
        _ = try ctx.builder.openNodeKeyed(.box, 1);
        ctx.builder.close();
    }
};

test "A batch of two signals of one component triggers a single rebuild" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var mounts = MountTable.init(a);
    defer mounts.deinit();

    var x = signals.Signal(i32).init(a, 0);
    defer x.deinit();
    var y = signals.Signal(i32).init(a, 0);
    defer y.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();

    RbTwoSig.builds = 0;
    var comp = RbTwoSig{ .x = &x, .y = &y };
    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountReactive(&scope, &comp);
    b.close();
    try testing.expectEqual(@as(u32, 1), RbTwoSig.builds);

    const Ctx = struct { x: *signals.Signal(i32), y: *signals.Signal(i32) };
    signals.batch(a, Ctx{ .x = &x, .y = &y }, struct {
        fn body(c: Ctx) void {
            c.x.set(1);
            c.y.set(2);
        }
    }.body);
    try testing.expectEqual(@as(u32, 2), RbTwoSig.builds); // one rebuild for the whole batch
}

test "After the anchor is removed, a set() no longer runs the build (safe)" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var mounts = MountTable.init(a);
    defer mounts.deinit();

    var n = signals.Signal(i32).init(a, 1);
    defer n.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();

    RbList.builds = 0;
    var comp = RbList{ .n = &n };
    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountReactive(&scope, &comp);
    b.close();
    try testing.expectEqual(@as(u32, 1), RbList.builds);

    // Rebuild the root with no children: the anchor is reconciled away.
    try b.rootAt(root);
    b.close();

    // The build-effect is still alive in the scope, but its anchor is gone: a set()
    // must not rebuild (and must not crash). Full teardown is handled by MountTable teardown.
    n.set(5);
    try testing.expectEqual(@as(u32, 1), RbList.builds);
}

// ── Lifecycle from reconciliation (automatic unmount) ────────────────────

const Lifecycle = struct {
    var mounts: u32 = 0;
    var unmounts: u32 = 0;
    var builds: u32 = 0;
    s: *signals.Signal(i32),
    pub fn build(self: *@This(), ctx: *BuildContext) !void {
        builds += 1;
        _ = self.s.get();
        _ = try ctx.builder.openNodeKeyed(.box, 1);
        ctx.builder.close();
    }
    pub fn onMount(_: *@This()) void {
        mounts += 1;
    }
    pub fn onUnmount(_: *@This()) void {
        unmounts += 1;
    }
};

const Host = struct {
    show: *signals.Signal(bool),
    child: *Lifecycle,
    scope: *signals.Scope,
    pub fn build(self: *@This(), ctx: *BuildContext) !void {
        if (self.show.get()) try ctx.mountReactive(self.scope, self.child);
    }
};

test "Unmount destroys the build-effect and fires onUnmount; remount fires onMount" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var mounts_tbl = MountTable.init(a);
    defer mounts_tbl.deinit();
    registry.addNodeRemovedListener(&mounts_tbl, MountTable.nodeRemovedListener);

    var show = signals.Signal(bool).init(a, true);
    defer show.deinit();
    var s = signals.Signal(i32).init(a, 0);
    defer s.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();

    Lifecycle.mounts = 0;
    Lifecycle.unmounts = 0;
    Lifecycle.builds = 0;
    var child = Lifecycle{ .s = &s };
    var host = Host{ .show = &show, .child = &child, .scope = &scope };

    var ctx = BuildContext{ .builder = &b, .mounts = &mounts_tbl };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountReactive(&scope, &host);
    b.close();

    // Mounted: onMount fired once, child built once.
    try testing.expectEqual(@as(u32, 1), Lifecycle.mounts);
    try testing.expectEqual(@as(u32, 1), Lifecycle.builds);

    // Hide: the host re-runs, no longer mounts the child → child anchor removed →
    // onUnmount fires and the child's build-effect is destroyed.
    show.set(false);
    try testing.expectEqual(@as(u32, 1), Lifecycle.unmounts);

    // A set() on the child's signal no longer runs its build (effect is gone).
    s.set(1);
    try testing.expectEqual(@as(u32, 1), Lifecycle.builds);

    // Show again: a fresh mount → onMount fires again and the child builds.
    show.set(true);
    try testing.expectEqual(@as(u32, 2), Lifecycle.mounts);
    try testing.expectEqual(@as(u32, 2), Lifecycle.builds);
}

test "Mount/unmount x64 leaks nothing" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var mounts_tbl = MountTable.init(a);
    defer mounts_tbl.deinit();
    registry.addNodeRemovedListener(&mounts_tbl, MountTable.nodeRemovedListener);

    var show = signals.Signal(bool).init(a, true);
    defer show.deinit();
    var s = signals.Signal(i32).init(a, 0);
    defer s.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();

    Lifecycle.mounts = 0;
    Lifecycle.unmounts = 0;
    var child = Lifecycle{ .s = &s };
    var host = Host{ .show = &show, .child = &child, .scope = &scope };

    var ctx = BuildContext{ .builder = &b, .mounts = &mounts_tbl };
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountReactive(&scope, &host);
    b.close();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        show.set(false);
        show.set(true);
    }
    // 1 initial + 64 remounts; each hide unmounts. Balanced, and the testing
    // allocator asserts no leak at scope/registry teardown.
    try testing.expectEqual(@as(u32, 65), Lifecycle.mounts);
    try testing.expectEqual(@as(u32, 64), Lifecycle.unmounts);
}

// ── Framework-owned instances (mountOwned) ───────────────────────────────

const OwnedComp = struct {
    var live: i32 = 0; // net live instances (onMount/deinit balance)
    label: []const u8, // prop
    ticks: u32 = 0, // state (default; preserved across rebuilds)
    pub fn build(self: *@This(), ctx: *BuildContext) !void {
        _ = self;
        _ = try ctx.builder.openNodeKeyed(.box, 1);
        ctx.builder.close();
    }
    pub fn onMount(_: *@This()) void {
        live += 1;
    }
    pub fn deinit(_: *@This()) void {
        live -= 1;
    }
};

fn ownedInstance(table: *MountTable, registry: *reg.UIRegistry, root: reg.NodeId, comptime k: u32) ?*OwnedComp {
    const anchor = childByKey(registry, root, ownedKey(OwnedComp, .{ .key = @as(u32, k) })) orelse return null;
    const rec = table.get(anchor) orelse return null;
    return @ptrCast(@alignCast(rec.component_ptr));
}

test "MountOwned: framework owns state, preserved across reorder, freed on remove" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var mounts = MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, MountTable.nodeRemovedListener);

    OwnedComp.live = 0;
    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };

    // First build: two owned instances, keyed 1 and 2.
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(OwnedComp, .{ .key = @as(u32, 1), .label = "a" });
    try ctx.mountOwned(OwnedComp, .{ .key = @as(u32, 2), .label = "b" });
    b.close();

    try testing.expectEqual(@as(i32, 2), OwnedComp.live); // framework created both
    // Mutate internal state on each.
    ownedInstance(&mounts, &registry, root, 1).?.ticks = 11;
    ownedInstance(&mounts, &registry, root, 2).?.ticks = 22;

    // Reorder (2 then 1) with updated props: instances persist by key, state kept.
    try b.rootAt(root);
    try ctx.mountOwned(OwnedComp, .{ .key = @as(u32, 2), .label = "B" });
    try ctx.mountOwned(OwnedComp, .{ .key = @as(u32, 1), .label = "A" });
    b.close();

    try testing.expectEqual(@as(i32, 2), OwnedComp.live); // no new instances
    const one = ownedInstance(&mounts, &registry, root, 1).?;
    const two = ownedInstance(&mounts, &registry, root, 2).?;
    try testing.expectEqual(@as(u32, 11), one.ticks); // state preserved
    try testing.expectEqual(@as(u32, 22), two.ticks);
    try testing.expectEqualStrings("A", one.label); // prop updated
    try testing.expectEqualStrings("B", two.label);

    // Remove key 2: its anchor is reconciled away → instance deinit'd + freed.
    try b.rootAt(root);
    try ctx.mountOwned(OwnedComp, .{ .key = @as(u32, 1), .label = "A" });
    b.close();

    try testing.expectEqual(@as(i32, 1), OwnedComp.live); // one destroyed
    try testing.expectEqual(@as(?*OwnedComp, null), ownedInstance(&mounts, &registry, root, 2));
    // Remaining instance freed by mounts.deinit at scope exit — no leak (testing.allocator).
}

// ── Isolated rerun carries measure/clipboard ─────────────────────────────

const MeasureCapture = struct {
    n: *signals.Signal(i32),
    var had_measure: bool = false;
    pub fn build(self: *MeasureCapture, ctx: *BuildContext) !void {
        _ = self.n.get(); // subscribe → a set() drives the isolated rerun path
        had_measure = ctx.builder.measure != null;
        _ = try ctx.builder.openNodeKeyed(.box, 1);
        ctx.builder.close();
    }
};

fn dummyMeasure(_: *anyopaque, text: []const u8, _: f32) f32 {
    return @floatFromInt(text.len);
}

test "An isolated rerun still carries measure/clipboard (text widgets)" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var dummy: u8 = 0;
    b.measure = .{ .ctx = @ptrCast(&dummy), .measureFn = dummyMeasure };
    var mounts = MountTable.init(a);
    defer mounts.deinit();
    var n = signals.Signal(i32).init(a, 0);
    defer n.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();

    var comp = MeasureCapture{ .n = &n };
    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountReactive(&scope, &comp);
    b.close();
    try testing.expect(MeasureCapture.had_measure); // present on the inline first build

    // A signal change re-runs the build via the ISOLATED path (template builder).
    // Before the fix that builder had no measure; now it must carry it.
    MeasureCapture.had_measure = false;
    n.set(1);
    try testing.expect(MeasureCapture.had_measure);
}

// ── Reactive root fills its parent ───────────────────────────────────────

const FillComp = struct {
    pub fn build(_: *FillComp, ctx: *BuildContext) !void {
        const n = try ctx.builder.openNodeKeyed(.box, null);
        try ctx.builder.store.setLayout(n, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
        try ctx.builder.store.setLayout(n, .height, .{ .dimension = .{ .value = 100, .unit = .percent } });
        ctx.builder.close();
    }
};

// A theme-consuming component: reads `ctx.theme()` reactively and paints a
// single keyed box with the theme's base background. Counts its builds so the test
// can assert it re-ran exactly once when the theme signal flipped.
const ThemedBox = struct {
    var builds: u32 = 0;
    key: u32,
    box_id: NodeId = undefined,
    pub fn build(self: *@This(), ctx: *BuildContext) !void {
        builds += 1;
        const t = ctx.theme(); // reactive read → subscribes this build-effect
        self.box_id = try ctx.builder.openNodeKeyed(.box, 1);
        try ctx.builder.background(self.box_id, t.bg_base.r, t.bg_base.g, t.bg_base.b);
        ctx.builder.close();
    }
};

test "Theme_signal.set re-runs each themed component once, swapping colors, 0 nodes recreated" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);

    // Wire the reactive theme (as runApp does), starting from the dark preset.
    // Declared before the scope/table so its `deinit` runs LAST — the build-effects
    // unsubscribe from it on teardown (mirrors runApp's ordering).
    var theme_sig = signals.Signal(theme_mod.Theme).init(a, theme_mod.Theme.dark());
    defer theme_sig.deinit();
    var mounts = MountTable.init(a);
    defer mounts.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();
    mounts.theme_signal = &theme_sig;

    ThemedBox.builds = 0;
    var c1 = ThemedBox{ .key = 1 };
    var c2 = ThemedBox{ .key = 2 };

    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountReactive(&scope, &c1);
    try ctx.mountReactive(&scope, &c2);
    b.close();

    try testing.expectEqual(@as(u32, 2), ThemedBox.builds); // one build each
    const dark = theme_mod.Theme.dark();
    const expectChan = struct {
        fn f(s: *props.PropertyStore, id: NodeId, byte: u8) !void {
            const bg = s.getStyle(id, .background).?;
            try testing.expectApproxEqAbs(@as(f32, @floatFromInt(byte)) / 255.0, bg.color.r, 0.001);
        }
    }.f;
    try expectChan(&store, c1.box_id, dark.bg_base.r);
    try expectChan(&store, c2.box_id, dark.bg_base.r);
    const nodes_before = registry.nodes.items.len;
    const box1_id = c1.box_id;
    const box2_id = c2.box_id;

    // Flip the theme: both build-effects that read the signal re-run once (batched),
    // repainting with the light preset. No new nodes are created (keyed reuse).
    theme_sig.set(theme_mod.Theme.light());

    try testing.expectEqual(@as(u32, 4), ThemedBox.builds); // exactly one re-run each
    try testing.expectEqual(nodes_before, registry.nodes.items.len); // 0 nodes recreated
    try testing.expectEqual(box1_id, c1.box_id); // same keyed node reused
    try testing.expectEqual(box2_id, c2.box_id);
    const light = theme_mod.Theme.light();
    try expectChan(&store, c1.box_id, light.bg_base.r);
    try expectChan(&store, c2.box_id, light.bg_base.r);
}

test "MountReactiveFill sizes the anchor to fill its parent (full-window root)" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var mounts = MountTable.init(a);
    defer mounts.deinit();
    var scope = signals.Scope.init(a);
    defer scope.deinit();

    // Parent: a 400×300 column (mirrors runApp's `body`). The reactive component's
    // root is width/height 100% — without a filling anchor it would collapse.
    var comp = FillComp{};
    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };
    const root = try b.openNodeKeyed(.box, null);
    try b.store.setLayout(root, .width, .{ .dimension = .{ .value = 400, .unit = .px } });
    try b.store.setLayout(root, .height, .{ .dimension = .{ .value = 300, .unit = .px } });
    try b.store.setLayout(root, .flex_direction, .{ .keyword = .column });
    try ctx.mountReactiveFill(&scope, &comp);
    b.close();

    const flexbox = @import("../layout/flexbox.zig");
    var engine = flexbox.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 400, 300);

    // The mount anchor filled the parent, and the component root filled the anchor.
    const anchor = childByKey(&registry, root, mountKey(FillComp, &comp)).?;
    try testing.expectEqual(@as(f32, 400), registry.getNode(anchor).?.geometry.width);
    try testing.expectEqual(@as(f32, 300), registry.getNode(anchor).?.geometry.height);
    const inner = registry.getNode(anchor).?.first_child;
    try testing.expectEqual(@as(f32, 400), registry.getNode(inner).?.geometry.width);
    try testing.expectEqual(@as(f32, 300), registry.getNode(inner).?.geometry.height);
}

test "Ctx.measuredSize: null before the first solve, resolved size after" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var b = UIBuilder.init(&registry, &store);
    var ctx = BuildContext{ .builder = &b };

    const root = try b.openNodeKeyed(.box, null);
    try b.store.setLayout(root, .width, .{ .dimension = .{ .value = 640, .unit = .px } });
    try b.store.setLayout(root, .height, .{ .dimension = .{ .value = 480, .unit = .px } });
    const child = try b.openNodeKeyed(.box, null);
    try b.store.setLayout(child, .width, .{ .dimension = .{ .value = 50, .unit = .percent } });
    try b.store.setLayout(child, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    b.close();
    b.close();

    // First build, no solve yet → the caller's one-frame fallback path.
    try testing.expect(ctx.measuredSize(child) == null);
    try testing.expect(ctx.measuredSize(9999) == null); // missing node

    const flexbox = @import("../layout/flexbox.zig");
    var engine = flexbox.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 640, 480);

    // After a solve the resolved content box is readable (percent width resolved
    // against the 640px parent).
    const sz = ctx.measuredSize(child).?;
    try testing.expectApproxEqAbs(@as(f32, 320), sz.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100), sz.h, 0.01);
    const rootsz = ctx.measuredSize(root).?;
    try testing.expectApproxEqAbs(@as(f32, 640), rootsz.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 480), rootsz.h, 0.01);
}

/// Component with an optional-struct prop — the shape that used to force callers to
/// spell the type out at the call site.
const StyledComp = struct {
    text_style: ?theme_mod.TextStyle = null,
    pub fn build(_: *StyledComp, _: *BuildContext) !void {}
};

test "An optional struct prop accepts a plain `.{...}` literal, and a typed value" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var mounts = MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, MountTable.nodeRemovedListener);

    var b = UIBuilder.init(&registry, &store);
    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };
    const root = try b.openNodeKeyed(.box, null);
    // Anonymous literal: coerces through the optional (initInstance path).
    try ctx.mountOwned(StyledComp, .{ .text_style = .{ .size = 13, .weight = .bold } });
    b.close();

    const anchor = registry.getNode(root).?.first_child;
    const inst: *StyledComp = @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
    try testing.expectEqual(@as(f32, 13), inst.text_style.?.size);
    try testing.expect(inst.text_style.?.weight == .bold);

    // Rebuild with a fully-typed value: the applyProps path still assigns plainly.
    try b.rootAt(root);
    try ctx.mountOwned(StyledComp, .{ .text_style = theme_mod.TextStyle{ .size = 20 } });
    b.close();
    try testing.expectEqual(@as(f32, 20), inst.text_style.?.size);
}

test "Without measurement, the column hit-test scales with the font size" {
    // The estimate is only ever used when no measurement was injected — but it has
    // to *scale*, or clicking in a 24px control lands on the wrong character. At
    // 16px it is 8px/char, the number the widgets used to hardcode.
    try testing.expectApproxEqAbs(@as(f32, 8), fallbackCharWidth(16), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 12), fallbackCharWidth(24), 0.001);

    // Clicking just past the third character picks column 3 at either size.
    try testing.expectEqual(@as(usize, 3), columnAtX(null, "abcdef", 16, 3 * 8));
    try testing.expectEqual(@as(usize, 3), columnAtX(null, "abcdef", 24, 3 * 12));
    // The old fixed 8px/char would have read that same x as column 4½ at 24px.
    try testing.expectEqual(@as(usize, 5), columnAtX(null, "abcdef", 16, 3 * 12 + 4));
}

// ── on_resize ─────────────────────────────────────────────────────────────────

const ResizeProbe = struct {
    w: f32 = -1,
    h: f32 = -1,
    calls: usize = 0,
    fn onResize(self: *ResizeProbe, ev: events.Event) void {
        self.w = ev.width;
        self.h = ev.height;
        self.calls += 1;
    }
};

/// root (100%×100%) → panel (100% × 50%) observed via `on_resize`.
fn buildResizeTree(env: anytype, probe: *ResizeProbe) !struct { root: NodeId, panel: NodeId } {
    var b = UIBuilder.init(&env.registry, &env.store);
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    var panel: NodeId = reg.NULL_NODE;
    const root = try b.openNodeKeyed(.box, null);
    try b.width(root, 100, .percent);
    try b.height(root, 100, .percent);
    panel = try ctx.boxNode(.{
        .width = pct(100),
        .height = pct(50),
        .on_resize = ctx.handler(probe, ResizeProbe.onResize),
    }, .{});
    b.close();
    return .{ .root = root, .panel = panel };
}

test "on_resize: reports on the first solve, not on an unchanged re-solve, again on resize" {
    var env = @import("test_support.zig").Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var probe = ResizeProbe{};
    const t = try buildResizeTree(&env, &probe);

    // Frame 1: the first solve always reports — this is the case `measuredSize`
    // could only answer with `null`.
    try testing.expectEqual(@as(usize, 1), try env.frame(t.root, 800, 400));
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectApproxEqAbs(@as(f32, 800), probe.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), probe.h, 0.01);
    // The report matches the geometry the user actually sees.
    try testing.expectApproxEqAbs(env.geom(t.panel).height, probe.h, 0.01);

    // Same window → nothing to say.
    try testing.expectEqual(@as(usize, 0), try env.frame(t.root, 800, 400));
    try testing.expectEqual(@as(usize, 1), probe.calls);

    // Window grows → exactly one report with the new size.
    try testing.expectEqual(@as(usize, 1), try env.frame(t.root, 800, 900));
    try testing.expectEqual(@as(usize, 2), probe.calls);
    try testing.expectApproxEqAbs(@as(f32, 450), probe.h, 0.01);
}

test "on_resize: sub-pixel jitter is not a resize" {
    var env = @import("test_support.zig").Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var probe = ResizeProbe{};
    const t = try buildResizeTree(&env, &probe);
    _ = try env.frame(t.root, 800, 400);
    // 50% of 400.6 = 200.3 → 0.3px change, below RESIZE_EPSILON.
    try testing.expectEqual(@as(usize, 0), try env.frame(t.root, 800, 400.6));
    try testing.expectEqual(@as(usize, 1), probe.calls);
}

test "on_resize: a removed node leaves the observer list and never reports" {
    var env = @import("test_support.zig").Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var probe = ResizeProbe{};
    const t = try buildResizeTree(&env, &probe);
    _ = try env.frame(t.root, 800, 400);
    try testing.expectEqual(@as(usize, 1), env.registry.resize_observers.items.len);

    env.registry.removeNode(t.panel);
    try testing.expectEqual(@as(usize, 0), env.registry.resize_observers.items.len);
    try testing.expect(env.router.nodeHandler(t.panel, .resize) == null);

    // The recycled slot is a fresh, unobserved node.
    const reused = try env.registry.createNode(.box);
    try testing.expectEqual(t.panel, reused);
    try testing.expect(!env.registry.getNode(reused).?.observe_resize);

    try testing.expectEqual(@as(usize, 0), try env.frame(t.root, 800, 900));
    try testing.expectEqual(@as(usize, 1), probe.calls);
}

test "on_resize: rebuild with the same handler doesn't re-report; a new receiver does" {
    var env = @import("test_support.zig").Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var probe = ResizeProbe{};
    const t = try buildResizeTree(&env, &probe);
    _ = try env.frame(t.root, 800, 400);

    // Same receiver re-applied (an ordinary rebuild): observation is idempotent.
    var b = UIBuilder.init(&env.registry, &env.store);
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    try b.rootAt(t.root);
    const p2 = try ctx.boxNode(.{ .width = pct(100), .height = pct(50), .on_resize = ctx.handler(&probe, ResizeProbe.onResize) }, .{});
    b.close();
    try testing.expectEqual(t.panel, p2); // reconciled, same node
    try testing.expectEqual(@as(usize, 1), env.registry.resize_observers.items.len);
    try testing.expectEqual(@as(usize, 0), try env.frame(t.root, 800, 400));

    // A different receiver bound to the same node learns the current size even
    // though the size didn't change.
    var other = ResizeProbe{};
    try b.rootAt(t.root);
    _ = try ctx.boxNode(.{ .width = pct(100), .height = pct(50), .on_resize = ctx.handler(&other, ResizeProbe.onResize) }, .{});
    b.close();
    try testing.expectEqual(@as(usize, 1), try env.frame(t.root, 800, 400));
    try testing.expectEqual(@as(usize, 1), other.calls);
    try testing.expectApproxEqAbs(@as(f32, 200), other.h, 0.01);
    try testing.expectEqual(@as(usize, 1), probe.calls);
}

test "on_resize: no observers → nothing collected (idle frames pay nothing)" {
    var env = @import("test_support.zig").Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var b = UIBuilder.init(&env.registry, &env.store);
    const root = try b.openNodeKeyed(.box, null);
    b.close();
    try testing.expectEqual(@as(usize, 0), env.registry.resize_observers.items.len);
    try testing.expectEqual(@as(usize, 0), try env.frame(root, 800, 400));
}

test "on_resize: C-ABI resize event carries width/height in x/y and routes by node" {
    var env = @import("test_support.zig").Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var probe = ResizeProbe{};
    const t = try buildResizeTree(&env, &probe);
    const core_events = @import("../core/events.zig");
    const cev = core_events.CelerisEvent{
        .event_type = @intFromEnum(core_events.EventType.resize),
        .node_id = t.panel,
        .action_id = "",
        .x = 321,
        .y = 123,
        .key_code = 0,
        .scroll_delta = 0,
        .text = "",
        .modifiers = 0,
    };
    try testing.expectEqual(@as(usize, 1), env.router.dispatchEvent(&cev));
    try testing.expectApproxEqAbs(@as(f32, 321), probe.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 123), probe.h, 0.01);
}

test "Text applies a theme style's line height; an explicit line_height wins; plain size leaves the default" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var mounts = MountTable.init(a);
    defer mounts.deinit();

    var b = UIBuilder.init(&registry, &store);
    var ctx = BuildContext{ .builder = &b, .mounts = &mounts };
    const root = try b.openNodeKeyed(.box, null);
    var styled = Text{ .content = "a", .style = .{ .size = 14, .line_height = 1.42 } };
    try styled.build(&ctx);
    var overridden = Text{ .content = "b", .style = .{ .size = 14, .line_height = 1.42 }, .line_height = 1.0 };
    try overridden.build(&ctx);
    var plain = Text{ .content = "c", .style = .{ .size = 13 } };
    try plain.build(&ctx);
    b.close();

    const n0 = registry.getNode(root).?.first_child;
    const n1 = registry.getNode(n0).?.next_sibling;
    const n2 = registry.getNode(n1).?.next_sibling;
    try testing.expectApproxEqAbs(@as(f32, 1.42), store.getStyle(n0, .line_height).?.number, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), store.getStyle(n1, .line_height).?.number, 0.0001);
    try testing.expect(store.getStyle(n2, .line_height) == null);
}

test "ctx.onScroll / onScrollH wire scroll handlers on a raw-builder node, like the box props" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = MountTable.init(a);
    defer mounts.deinit();

    const Spy = struct {
        var hits: u32 = 0;
        fn on(_: ?*anyopaque, _: events.Event) void {
            hits += 1;
        }
    };
    var b = UIBuilder.init(&registry, &store);
    var ctx = BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    const id = try b.openNodeKeyed(.box, null);
    try ctx.onScroll(id, .{ .ptr = null, .call = Spy.on });
    try ctx.onScrollH(id, .{ .ptr = null, .call = Spy.on });
    b.close();

    try testing.expect(router.nodeHandler(id, .scroll) != null);
    try testing.expect(router.nodeHandler(id, .scroll_h) != null);
}
