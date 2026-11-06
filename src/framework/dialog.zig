//! Dialog / modal in-window.
//!
//! An in-window modal (not an OS window): a full-window scrim that catches outside
//! clicks + a centered panel with a title, a `content` slot and whatever action
//! buttons the caller puts in the slot. It follows the canonical reactive-widget
//! pattern: framework-owned via `ctx.mountOwned(Dialog, .{ .open = &sig })`,
//! no `init`/`register`/`deinit`/action-id in user code.
//!
//! Controlled by a caller-owned `open: *Signal(bool)` (same model as `Tabs.active`):
//! the app opens/closes the dialog by writing that signal. One effect drives the
//! scrim size (0 → clipped, not hit-testable — the closed dialog is inert), the
//! scrim alpha, and the focus scope: on open it pushes a focus scope on the
//! panel (trapping Tab + landing focus inside); on close it pops it (restoring the
//! previously-focused node). Escape and a backdrop click dismiss it (the latter only
//! when `dismissable`), firing `on_close`. A click inside the panel is swallowed by
//! the panel's own (no-op) click handler, so it never dismisses.

const std = @import("std");
const component = @import("component.zig");
const builder_mod = @import("builder.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;
const EdgeInsets = component.EdgeInsets;

const PANEL_W: f32 = 360;
const Z_OVERLAY: f32 = 200; // above menus/dropdowns (z 100)

pub const Dialog = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    /// Caller-owned control signal: write it to open/close the dialog.
    open: ?*signals.Signal(bool) = null,
    title: []const u8 = "",
    /// Composed body content (caller-owned; must outlive the dialog). Rendered
    /// under the title.
    content: ?component.Child = null,
    /// When true (default), a backdrop click and Escape dismiss the dialog.
    dismissable: bool = true,
    /// Fired when the dialog dismisses itself (Escape / backdrop). Not fired when
    /// the app closes it by writing `open` directly.
    on_close: ?events.Handler = null,

    // State (auto-created in onMount; preserved across rebuilds).
    scope: signals.Scope = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    backdrop_id: reg.NodeId = reg.NULL_NODE,
    panel_id: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,
    /// Focus-scope control captured from the live builder. Null headless →
    /// the modal still works, but Tab isn't trapped.
    focus_scope: ?builder_mod.FocusScopeHooks = null,
    /// True while this dialog holds a pushed focus scope (open). Drives the
    /// push-once/pop-once transition in the effect + teardown on unmount.
    scope_pushed: bool = false,
    /// `open`'s value the last time `updateVisuals` ran — used to detect the
    /// closed→open transition that refreshes the panel body (see there).
    was_open: bool = false,
    /// Router + mounts captured from the live `BuildContext` (mirrors
    /// `focus_scope`), needed to build one for the panel-body refresh below.
    router: ?*events.EventRouter = null,
    mounts: ?*component.MountTable = null,

    pub fn onMount(self: *Dialog, allocator: std.mem.Allocator) void {
        self.scope = signals.Scope.init(allocator);
    }

    pub fn onUnmount(self: *Dialog) void {
        // Pop a still-held focus scope so unmounting an open dialog restores focus.
        if (self.scope_pushed) {
            self.scope_pushed = false;
            if (self.focus_scope) |fs| _ = fs.pop();
        }
    }

    pub fn deinit(self: *Dialog) void {
        self.scope.deinit();
    }

    fn isOpen(self: *Dialog) bool {
        const o = self.open orelse return false;
        return o.peek();
    }

    /// Closes the dialog (writes `open` false) and fires `on_close`. The effect
    /// pops the focus scope on the resulting transition.
    fn close(self: *Dialog) void {
        if (self.open) |o| o.set(false);
        if (self.on_close) |h| h.call(h.ptr, .{ .name = "close", .id = "" });
    }

    /// Backdrop click: dismiss (on mouse_up / "click" only — a press bubbling up
    /// from the panel is a mouse_down and must not tear the modal down mid-click).
    fn onBackdrop(self: *Dialog, ev: events.Event) void {
        if (!std.mem.eql(u8, ev.name, "click")) return;
        if (!self.dismissable) return;
        self.close();
    }

    /// The panel is clickable purely to swallow clicks landing on it: the engine
    /// hit-test resolves a click inside the panel to the panel (nearest interactive
    /// ancestor), so it never reaches the backdrop's dismiss handler.
    fn onPanelClick(_: *Dialog, _: events.Event) void {}

    /// Escape closes the dialog when dismissable. Focus is trapped on the panel
    /// (the pushed scope), so key_down routes here.
    fn onKey(self: *Dialog, ev: events.Event) void {
        if (!std.mem.eql(u8, ev.name, "key_down")) return;
        if (events.Key.fromCode(ev.key_code) == .escape and self.dismissable) self.close();
    }

    pub fn build(self: *Dialog, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;
        self.theme = t;
        self.store = b.store;

        // Scrim: a full-window box (when open) that centers the panel and catches
        // outside clicks. Sized to 0 + clipped when closed → inert. Its size/color
        // are driven by the effect.
        self.backdrop_id = try ctx.boxNode(.{
            .direction = .column,
            .justify = .center,
            .@"align" = .center,
            .on_click = ctx.handler(self, onBackdrop),
        }, .{
            Panel{ .dlg = self },
        });
        try b.positionAbsolute(self.backdrop_id, 0, 0);
        try b.overflowHidden(self.backdrop_id);
        try b.zIndex(self.backdrop_id, Z_OVERLAY);
        // Without this, `mountOwned`'s anchor is an ordinary in-flow flex
        // item — sandwiched between whatever siblings the app root has (a
        // header, a status bar), it has no explicit size of its own, so a
        // hug-content box collapses to 0 height (nothing but this OUT-OF-FLOW
        // backdrop lives inside it — CSS 9.3 excludes absolute children from
        // their parent's content-size hug). The backdrop's width:100%/
        // height:100% (set below by the effect) then resolve against that 0x0
        // containing block and the dialog never becomes visible — the same
        // failure `openOverlay`'s doc comment describes for TooltipHost/
        // ToastHost. Two changes fix it: take the anchor out of ITS parent's
        // flow too (`position: absolute`, pinned at the app root's origin, so
        // it no longer competes with the header/status-bar siblings for flex
        // space or shifts them), and give it an EXPLICIT 100%/100% size — a
        // percentage, unlike hug, resolves against a real size (its immediate
        // parent's, whatever that node's own resolved dimensions are) instead
        // of collapsing.
        //
        // That still means the mount anchor's IMMEDIATE PARENT must itself be
        // the full window size for the backdrop to cover the window — true
        // when Dialog is a direct child of the app's window root (a sibling
        // among a header/status-bar is fine: taking the anchor out of THEIR
        // flow, above, means it isn't shrunk by their sizes), but NOT if
        // Dialog is mounted deeper, e.g. inline inside a fixed-height caption
        // row with no full-window wrapper in between — there it sizes against
        // that row instead. See `FRAMEWORK_API.md`'s Dialog section for the
        // mount-point rule (same as `Menu`'s) and `builder.zig`'s
        // `openOverlay` for the coordinate half of this pattern.
        if (b.registry.getNode(self.backdrop_id)) |n| {
            if (n.parent != reg.NULL_NODE) {
                const anchor_id = n.parent;
                try b.positionAbsolute(anchor_id, 0, 0);
                try b.width(anchor_id, 100, .percent);
                try b.height(anchor_id, 100, .percent);
            }
        }

        self.focus_scope = b.focus_scope;
        self.router = ctx.router;
        self.mounts = ctx.mounts;

        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    /// `title`/`content` are captured once, as of whichever `build()` call
    /// happened to run when this Dialog's mount anchor was last reached — a
    /// plain field, not a `Signal`. An app that sets them and opens the dialog
    /// from a menu/shortcut handler (`title = "..."; open.set(true)`, `Dialog`
    /// never rebuilt again in between) got a dialog that resized and tinted
    /// correctly (that part IS driven by the `open` effect below) but whose
    /// title and `content` slot stayed frozen at their first-mount values —
    /// typically the empty string, so nothing painted.
    ///
    /// Fix: re-run the panel body (title + `content`) — a partial, `rootAt`
    /// rebuild of `panel_id`'s children, the same technique `rebuildTreeBody`
    /// uses for TreeView — every time `open` transitions false → true. That is
    /// exactly the moment an app is expected to have just set `title`/`content`
    /// for THIS open (`MessageDialog.show()`'s pattern: fill the buffers, then
    /// `open.set(true)`), so the refresh always sees the current values.
    ///
    /// Known gap: calling the caller's `show()`-equivalent again while the
    /// dialog is ALREADY open does not refresh it — `Signal.set` is a no-op on
    /// an unchanged value, so `open`'s effect never reruns, and `title`/
    /// `content` have no reactive channel of their own. Close and reopen it,
    /// or lift `title`/`content` to signals the app owns if that pattern is
    /// needed.
    fn refreshPanelBody(self: *Dialog) void {
        const store = self.store orelse return;
        const registry = store.registry orelse return;
        if (self.panel_id == reg.NULL_NODE) return;
        var b = builder_mod.UIBuilder.init(registry, store);
        b.theme = self.theme;
        b.focus_scope = self.focus_scope;
        b.rootAt(self.panel_id) catch return;
        var ctx = BuildContext{ .builder = &b, .router = self.router, .mounts = self.mounts };
        var body = PanelBody{ .dlg = self };
        body.build(&ctx) catch {};
        b.close();
        registry.markLayoutDirty(self.panel_id);
    }

    fn updateVisuals(self: *Dialog) void {
        const store = self.store orelse return;
        if (self.backdrop_id == reg.NULL_NODE) return;
        // .get() (not peek) so the effect subscribes to the control signal.
        const open = if (self.open) |o| o.get() else false;

        // See `refreshPanelBody`'s doc comment: catch the app having just set
        // title/content for THIS open, before anything painted the old ones.
        if (open and !self.was_open) self.refreshPanelBody();
        self.was_open = open;

        // Scrim size: full window when open, 0 (clipped) when closed.
        const full: props.PropValue = .{ .dimension = .{ .value = 100, .unit = .percent } };
        const zero: props.PropValue = .{ .dimension = .{ .value = 0, .unit = .px } };
        store.setLayout(self.backdrop_id, .width, if (open) full else zero) catch {};
        store.setLayout(self.backdrop_id, .height, if (open) full else zero) catch {};

        // Scrim tint (theme overlay_scrim alpha when open, transparent otherwise).
        const scrim = self.theme.overlay_scrim;
        const a: f32 = if (open) @as(f32, @floatFromInt(scrim.a)) / 255.0 else 0.0;
        store.setStyle(self.backdrop_id, .background, props.PropValue.rgbA(scrim.r, scrim.g, scrim.b, a)) catch {};

        // Focus scope transition (push once on open, pop once on close).
        if (open and !self.scope_pushed) {
            if (self.panel_id != reg.NULL_NODE) {
                if (self.focus_scope) |fs| {
                    // Unlike Menu.popup (a direct call whose caller knows
                    // the trigger), Dialog opens reactively off `self.open`
                    // going true — the effect has no record of what set it.
                    // Defaults to `.keyboard` (ring visible): dialogs commonly
                    // open from non-pointer triggers too (a shortcut, an async
                    // event), and per the CSS `:focus-visible` heuristic,
                    // focus that isn't demonstrably a direct pointer click
                    // defaults to visible.
                    if (fs.push(self.panel_id, .keyboard)) self.scope_pushed = true;
                }
            }
        } else if (!open and self.scope_pushed) {
            self.scope_pushed = false;
            if (self.focus_scope) |fs| _ = fs.pop();
        }
    }
};

/// The centered panel: title + content slot. Built as a slot child so the panel box
/// can use the declarative props path (focusable, role, click/key handlers); it
/// captures `panel_id` for the focus scope + click swallowing.
const Panel = struct {
    dlg: *Dialog,
    pub fn build(self: *Panel, ctx: *BuildContext) !void {
        const dlg = self.dlg;
        const b = ctx.builder;
        const t = dlg.theme;

        dlg.panel_id = try ctx.boxNode(.{
            .direction = .column,
            .gap = 12,
            .padding = EdgeInsets.all(20),
            .background = component.rgb(t.surface_high.r, t.surface_high.g, t.surface_high.b),
            .border_width = 1,
            .radius = t.radius_base,
            .focusable = true, // Focus lands here while open
            .role = "dialog",
            .on_click = ctx.handler(dlg, Dialog.onPanelClick),
            .on_key = ctx.handler(dlg, Dialog.onKey),
        }, .{
            PanelBody{ .dlg = dlg },
        });
        try b.width(dlg.panel_id, PANEL_W, .px);
        try b.borderColorOf(dlg.panel_id, t.border_color);
        try b.zIndex(dlg.panel_id, Z_OVERLAY + 1);
    }
    pub fn deinit(_: *Panel) void {}
};

/// The panel's inner content: an optional title heading followed by the caller's
/// `content` slot. Kept separate from `Panel` so the panel box owns the styling and
/// this owns the (runtime-optional) children the declarative tuple can't express.
const PanelBody = struct {
    dlg: *Dialog,
    pub fn build(self: *PanelBody, ctx: *BuildContext) !void {
        const dlg = self.dlg;
        const b = ctx.builder;
        const t = dlg.theme;
        if (dlg.title.len > 0) {
            const tid = try b.addText(dlg.title);
            try b.fontSize(tid, 16);
            try b.textColor(tid, t.text.r, t.text.g, t.text.b);
        }
        if (dlg.content) |c| try c.build(ctx);
    }
    pub fn deinit(_: *PanelBody) void {}
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const dark = theme_mod.Theme.dark();

/// Mounts a Dialog with the given props and returns the instance.
fn mountDialog(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    router: *events.EventRouter,
    mounts: *component.MountTable,
    focus_scope: ?builder_mod.FocusScopeHooks,
    init_props: anytype,
) !*Dialog {
    var b = component.UIBuilder.init(registry, store);
    b.theme = dark;
    b.focus_scope = focus_scope;
    var ctx = BuildContext{ .builder = &b, .router = router, .mounts = mounts };
    _ = try b.openNodeKeyed(.box, null); // app root (node 0 is excluded from typed dispatch)
    try ctx.mountOwned(Dialog, init_props);
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

test "Dialog: closed → scrim zero-sized + inert; open → full window with scrim tint" {
    const a = testing.allocator;
    // open outlives mounts: the dialog's effect subscribes to it, so it must be
    // torn down (mounts.deinit) before the signal is freed.
    var open = signals.Signal(bool).init(a, false);
    defer open.deinit();
    var registry: reg.UIRegistry = undefined;
    var store: props.PropertyStore = undefined;
    var router: events.EventRouter = undefined;
    var mounts: component.MountTable = undefined;
    setup(a, &registry, &store, &router, &mounts);
    defer registry.deinit();
    defer store.deinit();
    defer router.deinit();
    defer mounts.deinit();

    const dlg = try mountDialog(&registry, &store, &router, &mounts, null, .{
        .open = &open,
        .title = "Confirm",
    });

    // Closed: scrim is 0-sized and transparent; the panel is focusable.
    try testing.expectApproxEqAbs(@as(f32, 0), store.getLayout(dlg.backdrop_id, .width).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), store.getStyle(dlg.backdrop_id, .background).?.color.a, 0.001);
    try testing.expect(store.getModifier(dlg.panel_id, .focusable) != null);

    // Open: full window + scrim alpha from the theme.
    open.set(true);
    try testing.expectEqual(props.DimUnit.percent, store.getLayout(dlg.backdrop_id, .width).?.dimension.unit);
    try testing.expectApproxEqAbs(@as(f32, 100), store.getLayout(dlg.backdrop_id, .height).?.dimension.value, 0.001);
    const want_a = @as(f32, @floatFromInt(dark.overlay_scrim.a)) / 255.0;
    try testing.expectApproxEqAbs(want_a, store.getStyle(dlg.backdrop_id, .background).?.color.a, 0.001);
}

test "Dialog: Escape closes and fires on_close; a backdrop click also dismisses" {
    const a = testing.allocator;
    var open = signals.Signal(bool).init(a, true);
    defer open.deinit(); // outlives mounts (see note in the first test)
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
        var closes: u32 = 0;
        fn onClose(_: ?*anyopaque, _: events.Event) void {
            closes += 1;
        }
    };
    Sink.closes = 0;

    const dlg = try mountDialog(&registry, &store, &router, &mounts, null, .{
        .open = &open,
        .on_close = events.Handler{ .ptr = null, .call = Sink.onClose },
    });
    try testing.expect(dlg.isOpen());

    // Escape on the panel closes + fires on_close.
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dlg.panel_id, .key_code = events.Key.escape.code() });
    try testing.expect(!open.peek());
    try testing.expectEqual(@as(u32, 1), Sink.closes);

    // Reopen; a click inside the panel is swallowed (no dismiss).
    open.set(true);
    _ = router.route(.{ .name = "click", .id = "", .node_id = dlg.panel_id });
    try testing.expect(open.peek());
    try testing.expectEqual(@as(u32, 1), Sink.closes);

    // A backdrop click (mouse_up) dismisses; a bare mouse_down does not.
    _ = router.route(.{ .name = "mouse_down", .id = "", .node_id = dlg.backdrop_id });
    try testing.expect(open.peek());
    _ = router.route(.{ .name = "click", .id = "", .node_id = dlg.backdrop_id });
    try testing.expect(!open.peek());
    try testing.expectEqual(@as(u32, 2), Sink.closes);
}

test "Dialog: dismissable=false ignores backdrop click and Escape" {
    const a = testing.allocator;
    var open = signals.Signal(bool).init(a, true);
    defer open.deinit(); // outlives mounts (see note in the first test)
    var registry: reg.UIRegistry = undefined;
    var store: props.PropertyStore = undefined;
    var router: events.EventRouter = undefined;
    var mounts: component.MountTable = undefined;
    setup(a, &registry, &store, &router, &mounts);
    defer registry.deinit();
    defer store.deinit();
    defer router.deinit();
    defer mounts.deinit();

    const dlg = try mountDialog(&registry, &store, &router, &mounts, null, .{
        .open = &open,
        .dismissable = false,
    });

    _ = router.route(.{ .name = "click", .id = "", .node_id = dlg.backdrop_id });
    try testing.expect(open.peek()); // still open
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dlg.panel_id, .key_code = events.Key.escape.code() });
    try testing.expect(open.peek()); // still open
}

test "Dialog: opening pushes a focus scope on the panel; closing pops it (once)" {
    const a = testing.allocator;
    var open = signals.Signal(bool).init(a, false);
    defer open.deinit(); // outlives mounts (see note in the first test)
    var registry: reg.UIRegistry = undefined;
    var store: props.PropertyStore = undefined;
    var router: events.EventRouter = undefined;
    var mounts: component.MountTable = undefined;
    setup(a, &registry, &store, &router, &mounts);
    defer registry.deinit();
    defer store.deinit();
    defer router.deinit();
    defer mounts.deinit();

    const FS = struct {
        var pushes: u32 = 0;
        var pops: u32 = 0;
        var last_root: reg.NodeId = reg.NULL_NODE;
        fn push(_: *anyopaque, root: reg.NodeId, _: events.FocusOrigin) bool {
            pushes += 1;
            last_root = root;
            return true;
        }
        fn pop(_: *anyopaque) bool {
            pops += 1;
            return true;
        }
    };
    FS.pushes = 0;
    FS.pops = 0;
    var dummy: u8 = 0;
    const hooks = builder_mod.FocusScopeHooks{ .ctx = @ptrCast(&dummy), .pushFn = FS.push, .popFn = FS.pop };

    const dlg = try mountDialog(&registry, &store, &router, &mounts, hooks, .{ .open = &open });

    // Closed on mount: nothing pushed yet.
    try testing.expectEqual(@as(u32, 0), FS.pushes);

    open.set(true);
    try testing.expectEqual(@as(u32, 1), FS.pushes);
    try testing.expectEqual(dlg.panel_id, FS.last_root);

    open.set(false);
    try testing.expectEqual(@as(u32, 1), FS.pops);
    // Idempotent: re-setting false doesn't pop again.
    open.set(false);
    try testing.expectEqual(@as(u32, 1), FS.pops);

    // Escape (via close) after reopening pops exactly once more.
    open.set(true);
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dlg.panel_id, .key_code = events.Key.escape.code() });
    try testing.expectEqual(@as(u32, 2), FS.pushes);
    try testing.expectEqual(@as(u32, 2), FS.pops);
}

// Dialog mounted (mountOwned) as the MIDDLE child of a flex-column app
// root — a header above it, a status bar below — must still cover the whole
// window when open. Real solve, resolved geometry (not store props): a
// store-only assertion passed even while TooltipHost/ToastHost were 0x0 on
// screen (see test_support.Harness's doc comment).
test "Dialog mounted mid-column still covers the whole window when open (geometry)" {
    const Harness = @import("test_support.zig").Harness;
    // `open` must outlive `env`: the dialog's effect subscribes to it, so
    // it has to be torn down (env.deinit, which tears down the mounts) before
    // the signal is freed — LIFO defers, so `open` is declared (and its
    // defer registered) first.
    var open = signals.Signal(bool).init(testing.allocator, false);
    defer open.deinit();
    var env = Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try b.flexColumn(root);
    try b.width(root, 100, .percent);
    try b.height(root, 100, .percent);

    // Header sibling before the dialog.
    const header = try b.openNodeKeyed(.box, null);
    try b.height(header, 40, .px);
    b.close();

    try ctx.mountOwned(Dialog, .{ .open = &open, .title = "Confirm" });

    // Status bar sibling after the dialog.
    const status = try b.openNodeKeyed(.box, null);
    try b.height(status, 24, .px);
    b.close();
    b.close(); // root

    const dialog_anchor = blk: {
        var id = env.registry.getNode(root).?.first_child;
        var count: u32 = 0;
        while (id != reg.NULL_NODE) : (id = env.registry.getNode(id).?.next_sibling) {
            if (count == 1) break :blk id;
            count += 1;
        }
        unreachable;
    };
    const dlg: *Dialog = @ptrCast(@alignCast(env.mounts.get(dialog_anchor).?.component_ptr));

    env.solve(root, 800, 600);
    // Closed: the backdrop is 0-sized, not covering anything.
    try testing.expect(!env.isVisible(dlg.backdrop_id));

    open.set(true);
    env.solve(root, 800, 600);
    // Open: the backdrop covers the WHOLE window (not just the leftover flex
    // space between the header and the status bar).
    const g = env.geom(dlg.backdrop_id);
    try testing.expectApproxEqAbs(@as(f32, 800), g.width, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 600), g.height, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), g.x, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), g.y, 0.5);
}

// Dialog title / content-slot text must actually paint.
const BodyText = struct {
    text: []const u8,
    node: reg.NodeId = reg.NULL_NODE,
    pub fn build(self: *BodyText, ctx: *BuildContext) !void {
        self.node = try ctx.builder.addText(self.text);
        try ctx.builder.textColor(self.node, 200, 200, 200);
    }
    pub fn deinit(_: *BodyText) void {}
};

test "Dialog title and content-slot text resolve to real, non-empty geometry when open" {
    const Harness = @import("test_support.zig").Harness;
    var open = signals.Signal(bool).init(testing.allocator, false);
    defer open.deinit();
    var env = Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var body = BodyText{ .text = "This action cannot be undone." };
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try b.width(root, 100, .percent);
    try b.height(root, 100, .percent);
    try ctx.mountOwned(Dialog, .{
        .open = &open,
        .title = "Delete node?",
        .content = component.childOf(BodyText, &body),
    });
    b.close();

    const dialog_anchor = env.registry.getNode(root).?.first_child;
    const dlg: *Dialog = @ptrCast(@alignCast(env.mounts.get(dialog_anchor).?.component_ptr));

    open.set(true);
    env.solve(root, 800, 600);

    // The panel itself must be visible (sanity check before blaming text).
    try testing.expect(env.isVisible(dlg.panel_id));

    // Title: first child of the panel's body (a text node, not the panel itself).
    const title_id = env.registry.getNode(dlg.panel_id).?.first_child;
    try testing.expect(title_id != reg.NULL_NODE);
    try testing.expect(env.isVisible(title_id));

    try testing.expect(body.node != reg.NULL_NODE);
    try testing.expect(env.isVisible(body.node));
}

// The real-world trigger — `MessageDialog.show(title, msg)`
// writes plain fields, THEN flips `open`, from a menu-action EVENT HANDLER, with
// no ancestor rebuild in between (`Dialog.build()` itself is never re-invoked).
// `title`/`content` are mountOwned PROPS (re-applied only when the caller's
// `mountOwned(Dialog, ...)` runs again), so they were frozen at their
// first-mount values — here, deliberately empty, mirroring `title_len == 0`
// before the app ever calls `show()`.
test "title/content set after mount, only `open` flips: panel body still refreshes" {
    const Harness = @import("test_support.zig").Harness;
    var open = signals.Signal(bool).init(testing.allocator, false);
    defer open.deinit();
    var env = Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();

    var body = BodyText{ .text = "" }; // nothing to show yet, like MessageDialog at startup
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try b.width(root, 100, .percent);
    try b.height(root, 100, .percent);
    try ctx.mountOwned(Dialog, .{
        .open = &open,
        .title = "", // empty at mount time, exactly like MessageDialog before show()
        .content = component.childOf(BodyText, &body),
    });
    b.close();
    env.solve(root, 800, 600);

    const dialog_anchor = env.registry.getNode(root).?.first_child;
    const dlg: *Dialog = @ptrCast(@alignCast(env.mounts.get(dialog_anchor).?.component_ptr));

    // "show()": mutate the fields directly (no mountOwned re-invocation — the
    // ancestor tree never rebuilds again), then flip `open` via the signal,
    // exactly like MessageDialog.show() does.
    dlg.title = "Delete node?";
    body.text = "This action cannot be undone.";
    open.set(true);
    env.solve(root, 800, 600);

    try testing.expect(env.isVisible(dlg.panel_id));

    const title_id = env.registry.getNode(dlg.panel_id).?.first_child;
    try testing.expect(title_id != reg.NULL_NODE);
    try testing.expect(env.isVisible(title_id));
    try testing.expectEqualStrings("Delete node?", env.store.getTextContent(title_id) orelse "");

    try testing.expect(body.node != reg.NULL_NODE);
    try testing.expect(env.isVisible(body.node));
    try testing.expectEqualStrings("This action cannot be undone.", env.store.getTextContent(body.node) orelse "");
}
