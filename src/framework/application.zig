const std = @import("std");
const log = @import("../core/log.zig");
const c_api = @import("../c_api.zig");
const builder = @import("builder.zig");
const component = @import("component.zig");
const events = @import("events.zig");
const app_bar = @import("app_bar.zig");
const window_chrome = @import("window_chrome.zig");
const tooltip = @import("tooltip.zig");
const toast = @import("toast.zig");
const theme_mod = @import("theme.zig");
const signals = @import("../core/signals.zig");
const platform = @import("../platform/platform.zig");

/// The declared type of an app struct's `build` second parameter, or null when it
/// is `anytype` (generic). Lets `runApp` pick the reactive `*BuildContext` entry
/// point vs the legacy `*UIBuilder` one at comptime.
fn appBuildParam(comptime T: type) ?type {
    return @typeInfo(@TypeOf(T.build)).@"fn".params[1].type;
}

/// Which framework-owned title bar `runApp` mounts. `.classic` is the system
/// `AppBar` (title + controls); `.custom` is `WindowChrome` — drag region and
/// window controls only, with the caption's contents supplied by `app_bar`.
pub const AppBarStyle = enum { classic, custom };

/// The app's typefaces, as font bytes it owns — `@embedFile("assets/Inter.ttf")`
/// is the intended shape, which keeps the app asset-free the way the bundled
/// Codicons icon font is. Only `primary` is required: it is the face the whole UI
/// is set in, and the one thing an app could not choose before.
///
/// The role faces are optional and follow Material's reading of a type system —
/// one family carrying every role — so supplying `primary` alone is a complete,
/// coherent answer, not a half-configured one: `.bold`/`.mono` text then degrades
/// to the primary rather than mixing in an unrelated host face. Supply them when
/// the family has real cuts to offer, and they are used verbatim.
pub const Fonts = struct {
    primary: []const u8,
    bold: ?[]const u8 = null,
    mono: ?[]const u8 = null,
    mono_bold: ?[]const u8 = null,
};

/// Hands `AppOptions.fonts` to the engine. Null leaves whatever is registered
/// alone — an app that names no faces gets the OS discovery it always got, and a
/// host that called `celeris_set_app_fonts` itself is not overruled by `runApp`.
fn registerAppFonts(fonts: ?Fonts) void {
    const f = fonts orelse return;
    c_api.setAppFonts(.{
        .primary = f.primary,
        .bold = f.bold,
        .mono = f.mono,
        .mono_bold = f.mono_bold,
    });
}

pub const AppOptions = struct {
    title: []const u8 = "Celeris App",
    width: u32 = 800,
    height: u32 = 600,
    hide_app_bar: bool = false,
    app_bar_style: AppBarStyle = .classic,
    /// Caption content for `.custom`: a type-erased `Child` (`component.slot(&.{…})`
    /// or `component.childOf(T, &instance)`) built inside the draggable region. The
    /// framework draws no wordmark, chip or logo of its own. Caller-owned — it must
    /// outlive `runApp`. Setting it implies `app_bar_style = .custom`.
    app_bar: ?component.Child = null,
    /// Caption height in px for `.custom`. The classic bar's height is fixed.
    app_bar_height: f32 = window_chrome.DEFAULT_HEIGHT,
    /// Draw the hairline under the `.custom` caption. Off when the app's own layout
    /// already separates the bar from the body.
    app_bar_divider: bool = true,
    /// Accessible names of the caption buttons (minimize / maximize / restore /
    /// close). English by default; set these to localize what screen readers announce.
    window_control_labels: component.WindowControlLabels = .{},
    is_headless: bool = false,
    /// Outer-corner rounding asked of the compositor when the window is created.
    /// Celeris windows are borderless, so they come out square by default while
    /// everything inside them is rounded. Windows 11 only; a no-op elsewhere.
    window_corners: platform.CornerPreference = .default,
    /// 1px hairline drawn around the whole frame, caption included — the only way
    /// to give a borderless window an edge against a dark desktop. It insets the
    /// app by 1px (like any border) and follows `window_corners`' curve, so the
    /// line meets the rounded corners instead of poking past them.
    ///
    /// The hairline the renderer draws honors the token's alpha, so a translucent
    /// divider like `rgba(255,255,255,.12)` answers to whatever it sits over. The
    /// DWM frame border this same token drives (needed so a rounded window doesn't
    /// show a second, system-colored hairline outside ours) is opaque-only: its
    /// alpha is dropped and the RGB is painted flat. Pass a color whose flat RGB
    /// still reads correctly against the desktop.
    window_outline: ?theme_mod.Color = null,
    /// Theme applied to the builder each frame; defaults to the curated dark preset.
    theme: theme_mod.Theme = theme_mod.Theme.dark(),
    /// The app's own typefaces. Absent (the default) keeps the OS font discovery
    /// that has always run, so nothing changes for apps that don't set it. Set, it
    /// applies to every window this process opens — one app, one type system — and
    /// makes the app's typography identical on every machine. Caller-owned bytes;
    /// they must outlive the app (`@embedFile` trivially does).
    fonts: ?Fonts = null,
};

// ── Window hosts ─────────────────────────────────────────────────────────
//
// Everything that used to be a `var` inside `runApp`'s comptime `Runner` — the
// mount table, the theme signal, the app scope, the caption configuration — is a
// field here, one instance per window. That is the whole unlock: a second window
// is a second host, so opening or closing it never touches the first one's tree
//, and configuration like `app_bar_height` stops being frozen at `runApp`
// time because it is no longer baked into a static.

/// Upper bound on live windows, matching the engine's own pool.
pub const MAX_WINDOWS = 16;

var g_hosts: [MAX_WINDOWS]?*WindowHost = [_]?*WindowHost{null} ** MAX_WINDOWS;

/// Monotonic counter behind `WindowHost.generation`.
var g_generation: u64 = 0;

/// Wraps a type-erased `Child` as a mountable component, so an app-supplied
/// window body goes through the same reactive `mountReactiveFill` path as a
/// `runApp` root: signals it reads re-run just its subtree.
const ChildRoot = struct {
    child: ?component.Child = null,
    pub fn build(self: *ChildRoot, ctx: *component.BuildContext) !void {
        if (self.child) |c| try c.build(ctx);
    }
    /// Forwarded when the window is torn down, so caller-owned content can drop
    /// anything tied to the nodes that are going away. The content instance itself
    /// is the app's and is left alone — reopening the window builds it again.
    pub fn onUnmount(self: *ChildRoot) void {
        if (self.child) |c| c.unmount();
    }
};

/// One window's framework-side state: its component tree, its reactive plumbing
/// and its chrome configuration.
pub const WindowHost = struct {
    engine_id: i32 = 0,
    allocator: std.mem.Allocator,
    router: *events.EventRouter,
    /// True when the host allocated the router itself (secondary windows); a
    /// `runApp` host borrows the caller's.
    owns_router: bool = false,
    mounts: component.MountTable = undefined,
    app_scope: signals.Scope = undefined,
    /// The reactive theme. Shared by pointer with the parent window when the
    /// options say `.inherit`, so one `set` restyles every window at once.
    theme_signal: *signals.Signal(theme_mod.Theme) = undefined,
    owns_theme: bool = false,

    /// The window's root. `root_mount` is generated at the call site that knows the
    /// concrete type, which is what keeps this struct itself non-generic.
    root_ptr: *anyopaque = undefined,
    root_mount: *const fn (*WindowHost, *component.BuildContext) anyerror!void = undefined,
    /// Storage for the `Child`-shaped root of a secondary window (pointed to by
    /// `root_ptr`), so the caller doesn't have to keep an adapter alive.
    child_root: ChildRoot = .{},

    // Chrome. Plain fields, mutable at runtime — `setAppBarHeight` and friends
    // rewrite them and rebuild, which is the fix for the frozen caption.
    show_sys_bar: bool = false,
    bar_style: AppBarStyle = .classic,
    bar_title: []const u8 = "",
    bar_content: ?component.Child = null,
    bar_height: f32 = window_chrome.DEFAULT_HEIGHT,
    bar_divider: bool = true,
    bar_labels: component.WindowControlLabels = .{},
    outline: ?theme_mod.Color = null,
    outline_radius: f32 = 0,

    /// Bumped for every window ever opened. A `WindowHandle` records the value it
    /// was created with, so a handle kept past its window's close can never be
    /// mistaken for a live one — not even when the engine slot AND the heap address
    /// are both recycled by a later window.
    generation: u64 = 0,

    /// Owns the loop: closing it ends the app and cascades to the others.
    is_primary: bool = false,
    /// Set the moment a close begins, so a rebuild queued behind it is dropped
    /// rather than run against a half-torn-down tree.
    closing: bool = false,

    fn slot(self: *const WindowHost) usize {
        return @intCast(self.engine_id - 1);
    }

    /// Window actions the component tree reaches through `ctx.dragRegion`.
    const window_ops = component.MountTable.WindowOps{ .startDrag = startDragOf };

    fn startDragOf(engine_id: i32) void {
        c_api.celeris_window_start_drag(engine_id);
    }

    /// Wires the reactive plumbing and claims the host's slot. `engine_id` must
    /// already name a live engine.
    fn setup(self: *WindowHost, engine_id: i32, initial_theme: theme_mod.Theme, shared_theme: ?*signals.Signal(theme_mod.Theme)) !void {
        self.engine_id = engine_id;
        g_generation += 1;
        self.generation = g_generation;
        // Theme first, torn down last: the mount table's and app scope's
        // build-effects unsubscribe from this signal on teardown, so freeing it
        // ahead of them would dangle those effects.
        if (shared_theme) |sig| {
            self.theme_signal = sig;
            self.owns_theme = false;
        } else {
            const sig = try self.allocator.create(signals.Signal(theme_mod.Theme));
            sig.* = signals.Signal(theme_mod.Theme).init(self.allocator, initial_theme);
            self.theme_signal = sig;
            self.owns_theme = true;
        }
        self.mounts = component.MountTable.init(self.allocator);
        self.mounts.theme_signal = self.theme_signal;
        self.mounts.window_id = engine_id;
        self.mounts.window_ops = &window_ops;
        self.app_scope = signals.Scope.init(self.allocator);

        // Prune a node's typed handlers when reconciliation removes it, so the
        // router never dispatches to a recycled node; and tear down a reactive
        // component's effects when its anchor is removed.
        if (c_api.getEngine(engine_id)) |engine| {
            engine.registry.addNodeRemovedListener(self.router, events.EventRouter.nodeRemovedListener);
            engine.registry.addNodeRemovedListener(&self.mounts, component.MountTable.nodeRemovedListener);
        }

        g_hosts[self.slot()] = self;
        c_api.celeris_register_event_callback(engine_id, event_trampolines[self.slot()]);
    }

    /// Releases everything the host owns. Does NOT destroy the engine — the caller
    /// decides whether that happens now (`runApp`'s defer) or on the next loop tick
    /// (a deferred close from a handler).
    pub fn teardown(self: *WindowHost) void {
        // Only give the slot up if it is still ours: a deferred close unhooks the
        // host the moment `close()` is called, and a later window may already own
        // the slot by the time this runs.
        if (self.engine_id > 0 and g_hosts[self.slot()] == self) g_hosts[self.slot()] = null;
        self.app_scope.deinit();
        self.mounts.deinit();
        if (self.owns_theme) {
            self.theme_signal.deinit();
            self.allocator.destroy(self.theme_signal);
        }
        if (self.owns_router) {
            self.router.deinit();
            self.allocator.destroy(self.router);
        }
        self.engine_id = 0;
    }

    /// Re-runs this window's root build. The per-window replacement for the old
    /// global `triggerRebuild`.
    pub fn rebuild(self: *WindowHost) void {
        if (self.closing or self.engine_id <= 0) return;
        // A rebuild queued just before the window went away is a no-op, not a
        // failure worth reporting — that race is normal on close.
        if (c_api.getEngine(self.engine_id) == null) return;
        c_api.rebuildUI(self.engine_id, build_trampolines[self.slot()]) catch |err| {
            log.warn("failed to rebuild window {d}: {}\n", .{ self.engine_id, err });
        };
    }

    // The framework bar's callbacks are the public `window` controls with the
    // callback shape bolted on — a custom bar wires the same actions directly.
    // They target THIS host's window, so an overlay's caption drives the overlay.
    fn onDrag(ctx: ?*anyopaque) void {
        c_api.celeris_window_start_drag(hostFrom(ctx).engine_id);
    }
    fn onClose(ctx: ?*anyopaque) void {
        const self = hostFrom(ctx);
        // A secondary window's close button unwinds its own host; the primary's
        // closes the app, exactly as before.
        if (self.is_primary) c_api.celeris_window_close(self.engine_id) else closeHost(self);
    }
    fn onMinimize(ctx: ?*anyopaque) void {
        c_api.celeris_window_minimize(hostFrom(ctx).engine_id);
    }
    fn onMaximize(ctx: ?*anyopaque) void {
        // ShowWindow is synchronous, so the OS state reflects the toggle by the
        // time the rebuild re-reads it for the maximize/restore glyph.
        const self = hostFrom(ctx);
        c_api.celeris_window_maximize(self.engine_id);
        self.rebuild();
    }
    fn isMaximizedOf(ctx: ?*anyopaque) bool {
        return c_api.celeris_window_is_maximized(hostFrom(ctx).engine_id) != 0;
    }

    fn hostFrom(ctx: ?*anyopaque) *WindowHost {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn eventCallback(self: *WindowHost, event: *const @import("../core/events.zig").CelerisEvent) void {
        _ = self.router.dispatchEvent(event);
    }

    /// The root build for this window: the frame box, the optional caption, the
    /// app's own tree, and the tooltip/toast hosts. One per window, so an overlay
    /// gets its own tooltip layer instead of borrowing the main window's.
    fn buildWrapper(self: *WindowHost, b: *builder.UIBuilder) anyerror!void {
        b.theme = self.theme_signal.peek(); // current theme; reactive reads use ctx.theme()
        // Route this window's focus-ring color into its own engine (the renderer draws with
        // it). Done per build rather than once at startup so it follows a runtime
        // theme swap, and per window so two windows on different themes don't
        // overwrite each other's ring.
        const fr = b.theme.focus_ring;
        c_api.celeris_set_focus_ring_color(
            self.engine_id,
            @as(f32, @floatFromInt(fr.r)) / 255.0,
            @as(f32, @floatFromInt(fr.g)) / 255.0,
            @as(f32, @floatFromInt(fr.b)) / 255.0,
            @as(f32, @floatFromInt(fr.a)) / 255.0,
        );
        const root = try b.openBox();
        try b.flexColumn(root);
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);
        try b.background(root, b.theme.bg_base.r, b.theme.bg_base.g, b.theme.bg_base.b);

        // Window outline: the hairline lives on the root because the root is
        // the only box that spans the whole frame — the caption is its child, so a
        // border here closes the top corners that an app-level border cannot reach.
        // `border` sets border_width, which insets the content box, so the caption
        // and body sit inside the line instead of painting over it.
        if (self.outline) |oc| {
            try b.borderColorAlpha(root, oc.r, oc.g, oc.b, @as(f32, @floatFromInt(oc.a)) / 255.0);
            try b.borderWidth(root, 1);
            if (self.outline_radius > 0) try b.radius(root, self.outline_radius);
        }

        var ctx = component.BuildContext.initWithRouter(b, self.router);
        ctx.mounts = &self.mounts; // enable ctx.mountReactive/mountOwned

        // System title bar: framework-owned, mounted like any widget.
        // `.custom` swaps in the bare chrome primitive and hands the caption to
        // the app's slot; both share the same window-action callbacks.
        if (self.show_sys_bar) {
            switch (self.bar_style) {
                .classic => try ctx.mountOwned(app_bar.AppBar, .{
                    .title = self.bar_title,
                    .control_labels = self.bar_labels,
                    .context = @as(?*anyopaque, @ptrCast(self)),
                    .on_drag = onDrag,
                    .on_close = onClose,
                    .on_maximize = onMaximize,
                    .on_minimize = onMinimize,
                    .is_maximized = isMaximizedOf,
                }),
                .custom => try ctx.mountOwned(window_chrome.WindowChrome, .{
                    .content = self.bar_content,
                    .height = self.bar_height,
                    .divider = self.bar_divider,
                    .control_labels = self.bar_labels,
                    .context = @as(?*anyopaque, @ptrCast(self)),
                    .on_drag = onDrag,
                    .on_close = onClose,
                    .on_maximize = onMaximize,
                    .on_minimize = onMinimize,
                    .is_maximized = isMaximizedOf,
                }),
            }
        }

        const body = try b.openBox();
        try b.flexGrow(body, 1);
        try b.width(body, 100, .percent);
        try b.flexColumn(body);

        try self.root_mount(self, &ctx);

        b.close(); // body

        // Tooltip host: mounted last (direct child of root) so its high
        // z_index overlay paints over the app. Framework-owned like the app bar.
        try ctx.mountOwned(tooltip.TooltipHost, .{});

        // Toast host: mounted last too, above the tooltip so notifications
        // stack over everything. Framework-owned; raise toasts via `toast.show`.
        try ctx.mountOwned(toast.ToastHost, .{});

        b.close(); // root
    }
};

/// One C-ABI build trampoline per window slot, generated at comptime. `rebuildUI`
/// takes a bare `fn (*UIBuilder)` with no context parameter, so each slot gets its
/// own function with the slot index baked in — the same trick the per-engine event
/// trampolines in `window.zig` use, and the reason none of this needs a C-ABI change.
const build_trampolines: [MAX_WINDOWS]*const fn (*builder.UIBuilder) anyerror!void = blk: {
    var arr: [MAX_WINDOWS]*const fn (*builder.UIBuilder) anyerror!void = undefined;
    for (0..MAX_WINDOWS) |i| {
        arr[i] = struct {
            const slot = i;
            fn build(b: *builder.UIBuilder) anyerror!void {
                const host = g_hosts[slot] orelse return;
                return host.buildWrapper(b);
            }
        }.build;
    }
    break :blk arr;
};

/// Likewise for input: `celeris_register_event_callback` carries no engine id, so
/// each slot routes to exactly its own window's router (an overlay's clicks
/// never reach the main window's handlers).
const event_trampolines: [MAX_WINDOWS]*const fn (*const @import("../core/events.zig").CelerisEvent) callconv(.c) void = blk: {
    var arr: [MAX_WINDOWS]*const fn (*const @import("../core/events.zig").CelerisEvent) callconv(.c) void = undefined;
    for (0..MAX_WINDOWS) |i| {
        arr[i] = struct {
            const slot = i;
            fn cb(ev: *const @import("../core/events.zig").CelerisEvent) callconv(.c) void {
                if (g_hosts[slot]) |h| h.eventCallback(ev);
            }
        }.cb;
    }
    break :blk arr;
};

/// The primary window's host, or null before `runApp`.
fn primaryHost() ?*WindowHost {
    for (g_hosts) |h| {
        if (h) |host| {
            if (host.is_primary) return host;
        }
    }
    return null;
}

fn hostFor(engine_id: i32) ?*WindowHost {
    if (engine_id <= 0 or engine_id > MAX_WINDOWS) return null;
    return g_hosts[@intCast(engine_id - 1)];
}

var global_engine_id: i32 = 0;

/// Rebuilds the primary window. Kept for compatibility — prefer the per-window
/// `WindowHandle.rebuild` (or plain signals, which need no rebuild at all).
pub fn triggerRebuild() void {
    if (primaryHost()) |h| h.rebuild();
}

/// C-ABI maximize-change hook (set in runApp): rebuilds so the AppBar's
/// maximize/restore glyph tracks OS-driven state changes (e.g. drag-to-restore).
fn onMaximizeChange(_: i32) callconv(.c) void {
    triggerRebuild();
}

/// Where a secondary window is placed when it opens.
pub const Placement = union(enum) {
    /// Let the platform choose (Win32's historical spot).
    platform_default,
    /// Absolute top-left in logical screen px.
    position: struct { x: i32, y: i32 },
    /// A corner of the primary display's work area, inset by `margin` px. The
    /// ergonomic choice for a HUD: it lands clear of the taskbar without the app
    /// doing screen arithmetic. Falls back to `platform_default` where the platform
    /// exposes no work area (Wayland).
    anchored: struct { at: Anchor, margin: i32 = 0 },

    pub const Anchor = enum { top_left, top_right, bottom_left, bottom_right, center };
};

/// Where a secondary window's theme comes from.
pub const ThemeSource = union(enum) {
    /// Share the parent window's theme signal: one `set` restyles every window.
    inherit,
    /// This window's own theme, independent of the rest of the app.
    own: theme_mod.Theme,
};

/// A secondary window. Every field beyond placement mirrors `AppOptions`, so
/// an overlay is configured exactly like the main window.
pub const WindowOptions = struct {
    /// The window's root content. Caller-owned — typically
    /// `component.childOf(T, &app.some_component)`, whose state lives in the app
    /// struct and therefore survives the window being closed and reopened.
    content: component.Child,
    title: []const u8 = "Celeris Window",
    width: u32 = 400,
    height: u32 = 300,
    placement: Placement = .platform_default,
    /// Float above other windows, including other applications'.
    always_on_top: bool = false,
    /// Resizable windows get a drag border; a fixed-size bar should turn this off,
    /// or the 8px resize margin eats clicks along its edges.
    resizable: bool = true,
    /// No caption and no window controls — the usual choice for an overlay,
    /// which is then moved with `ctx.dragRegion`.
    hide_app_bar: bool = false,
    app_bar_style: AppBarStyle = .classic,
    app_bar: ?component.Child = null,
    app_bar_height: f32 = window_chrome.DEFAULT_HEIGHT,
    app_bar_divider: bool = true,
    /// Accessible names of the caption buttons (minimize / maximize / restore /
    /// close). English by default; set these to localize what screen readers announce.
    window_control_labels: component.WindowControlLabels = .{},
    window_corners: platform.CornerPreference = .default,
    window_outline: ?theme_mod.Color = null,
    theme: ThemeSource = .inherit,
};

/// A live secondary window. Valid until `close()`; calling anything afterwards is
/// a no-op rather than a crash, so a stale handle in app state can't take the app
/// down.
pub const WindowHandle = struct {
    host: *WindowHost,
    engine_id: i32,
    generation: u64,

    fn live(self: WindowHandle) ?*WindowHost {
        const h = hostFor(self.engine_id) orelse return null;
        return if (h.generation == self.generation and !h.closing) h else null;
    }

    /// True while the window is still open.
    pub fn isOpen(self: WindowHandle) bool {
        return self.live() != null;
    }

    /// Moves and resizes the window (logical px).
    pub fn setBounds(self: WindowHandle, x: i32, y: i32, w: u32, h: u32) void {
        if (self.live() == null) return;
        c_api.celeris_window_set_bounds(self.engine_id, x, y, w, h);
    }

    pub fn bounds(self: WindowHandle) ?platform.Rect {
        if (self.live() == null) return null;
        return getBoundsOf(self.engine_id);
    }

    pub fn setAlwaysOnTop(self: WindowHandle, on: bool) void {
        if (self.live() == null) return;
        c_api.celeris_window_set_always_on_top(self.engine_id, on);
    }

    pub fn show(self: WindowHandle) void {
        if (self.live() == null) return;
        c_api.celeris_window_set_visible(self.engine_id, true);
    }

    pub fn hide(self: WindowHandle) void {
        if (self.live() == null) return;
        c_api.celeris_window_set_visible(self.engine_id, false);
    }

    pub fn startDrag(self: WindowHandle) void {
        if (self.live() == null) return;
        c_api.celeris_window_start_drag(self.engine_id);
    }

    /// Swaps the caption height at runtime (the fix for the value being frozen at
    /// creation) and rebuilds. `0` with `setAppBarVisible(false)` gives the whole
    /// window to the content.
    pub fn setAppBarHeight(self: WindowHandle, height: f32) void {
        const h = self.live() orelse return;
        h.bar_height = height;
        h.rebuild();
    }

    pub fn setAppBarVisible(self: WindowHandle, visible: bool) void {
        const h = self.live() orelse return;
        h.show_sys_bar = visible;
        h.rebuild();
    }

    /// Re-runs the window's root build. Rarely needed — signal writes already
    /// re-run the subtrees that read them.
    pub fn rebuild(self: WindowHandle) void {
        if (self.live()) |h| h.rebuild();
    }

    /// The platform handle (HWND on Windows). The documented escape hatch; nothing
    /// in this API requires an app to touch it.
    pub fn nativeHandle(self: WindowHandle) ?*anyopaque {
        if (self.live() == null) return null;
        return c_api.celeris_window_native_handle(self.engine_id);
    }

    /// Closes the window and frees its tree. Safe from an event handler — including
    /// a handler belonging to this very window: the window stops taking input and
    /// rendering at once, but the engine, the tree and the router are all released
    /// on the next loop tick, not underneath the frame that is currently running.
    pub fn close(self: WindowHandle) void {
        const h = self.live() orelse return;
        closeHost(h);
    }
};

/// Hosts whose close has begun but whose state is still live: `close()` is
/// documented as safe from an event handler, and the commonest call site — a
/// button in the window closing its own window — runs with `EventRouter.route`
/// iterating that very router's handler lists one frame down the stack. Freeing
/// the router (and the mounts, and the host) there is a use-after-free the moment
/// `route` reads the next handler. So the frees wait for the next loop tick, in
/// step with the engine's own deferred destroy.
var g_pending_teardown: [MAX_WINDOWS]?*WindowHost = [_]?*WindowHost{null} ** MAX_WINDOWS;

/// Tears a secondary host down: hide first (so nothing renders against a tree that
/// is going away), unhook it so nothing new can reach it, then queue both the
/// framework state and the engine for release on the next tick.
fn closeHost(host: *WindowHost) void {
    if (host.closing or host.is_primary) return;
    host.closing = true;
    const engine_id = host.engine_id;
    c_api.celeris_window_set_visible(engine_id, false);
    // Unhooking is free-less, so it is safe here and takes effect immediately: no
    // further build or event trampoline can reach this host, even though its
    // memory outlives the current frame.
    if (engine_id > 0 and g_hosts[host.slot()] == host) g_hosts[host.slot()] = null;
    queueTeardown(host);
    c_api.celeris_window_destroy_deferred(engine_id);
}

fn queueTeardown(host: *WindowHost) void {
    for (&g_pending_teardown) |*entry| {
        if (entry.* != null) continue;
        entry.* = host;
        postTask(flushPendingTeardowns, {});
        return;
    }
    // The queue holds one entry per possible window, so this is unreachable in
    // practice; releasing in place beats leaking the host if it ever isn't.
    releaseHost(host);
}

/// Drains the queue above. Runs as a posted task (next loop tick) and once more
/// when the loop ends, so nothing is left pending at exit.
fn flushPendingTeardowns() void {
    // Releasing a host runs its content's `onUnmount`, which may close a further
    // window (an overlay owning an overlay), so keep sweeping until a pass frees
    // nothing — otherwise a host queued behind the cursor would wait for a tick
    // that never comes at exit.
    while (true) {
        var freed = false;
        for (&g_pending_teardown) |*entry| {
            const host = entry.* orelse continue;
            entry.* = null;
            freed = true;
            releaseHost(host);
        }
        if (!freed) return;
    }
}

fn releaseHost(host: *WindowHost) void {
    const alloc = host.allocator;
    host.teardown();
    alloc.destroy(host);
}

/// C-ABI hook for a user-initiated close on a secondary window (its own close
/// button, Alt+F4): unwind the host first, exactly like `WindowHandle.close`.
fn onCloseRequest(engine_id: i32) callconv(.c) void {
    if (hostFor(engine_id)) |h| {
        closeHost(h);
    } else {
        c_api.celeris_window_destroy_deferred(engine_id);
    }
}

fn getBoundsOf(engine_id: i32) ?platform.Rect {
    var x: i32 = 0;
    var y: i32 = 0;
    var w: u32 = 0;
    var h: u32 = 0;
    if (c_api.celeris_window_get_bounds(engine_id, &x, &y, &w, &h) != 0) return null;
    return .{ .x = x, .y = y, .w = w, .h = h };
}

/// Resolves a `Placement` to an absolute top-left, or null to leave placement to
/// the platform.
fn resolvePlacement(p: Placement, w: u32, h: u32) ?struct { x: i32, y: i32 } {
    return switch (p) {
        .platform_default => null,
        .position => |pos| .{ .x = pos.x, .y = pos.y },
        .anchored => |a| blk: {
            const area = platform.workArea() orelse break :blk null;
            const iw: i32 = @intCast(w);
            const ih: i32 = @intCast(h);
            const aw: i32 = @intCast(area.w);
            const ah: i32 = @intCast(area.h);
            const m = a.margin;
            break :blk switch (a.at) {
                .top_left => .{ .x = area.x + m, .y = area.y + m },
                .top_right => .{ .x = area.x + aw - iw - m, .y = area.y + m },
                .bottom_left => .{ .x = area.x + m, .y = area.y + ah - ih - m },
                .bottom_right => .{ .x = area.x + aw - iw - m, .y = area.y + ah - ih - m },
                .center => .{ .x = area.x + @divTrunc(aw - iw, 2), .y = area.y + @divTrunc(ah - ih, 2) },
            };
        },
    };
}

/// Window controls. Without arguments they drive the `runApp`-owned window
/// (`fw.window.startDrag()`, …) — the escape hatch for `hide_app_bar = true`, where
/// the window is borderless and an app mounting its own title bar must be able to
/// drive the same actions the framework bar does. `open` adds a second window with
/// its own component tree. All no-ops before `runApp` has created the window.
pub const window = struct {
    pub fn startDrag() void {
        c_api.celeris_window_start_drag(global_engine_id);
    }
    pub fn close() void {
        c_api.celeris_window_close(global_engine_id);
    }
    pub fn minimize() void {
        c_api.celeris_window_minimize(global_engine_id);
    }
    /// Toggles maximize/restore and rebuilds, so a custom bar's glyph re-reads the
    /// new state (a resize alone relayouts but doesn't re-run `build`).
    pub fn toggleMaximize() void {
        c_api.celeris_window_maximize(global_engine_id);
        triggerRebuild();
    }
    pub fn isMaximized() bool {
        return c_api.celeris_window_is_maximized(global_engine_id) != 0;
    }

    /// Moves/resizes the main window (logical px) — e.g. shrinking it to a compact
    /// bar and restoring the saved rect afterwards.
    pub fn setBounds(x: i32, y: i32, w: u32, h: u32) void {
        c_api.celeris_window_set_bounds(global_engine_id, x, y, w, h);
    }

    /// The main window's current outer bounds, to save before shrinking it.
    pub fn bounds() ?platform.Rect {
        return getBoundsOf(global_engine_id);
    }

    /// Hides the main window without tearing anything down: its tree, scroll
    /// positions and panel state are all still there when `show()` brings it back.
    pub fn hide() void {
        c_api.celeris_window_set_visible(global_engine_id, false);
    }

    pub fn show() void {
        c_api.celeris_window_set_visible(global_engine_id, true);
    }

    pub fn setAlwaysOnTop(on: bool) void {
        c_api.celeris_window_set_always_on_top(global_engine_id, on);
    }

    /// The main window's platform handle (HWND on Windows) — the escape hatch.
    pub fn nativeHandle() ?*anyopaque {
        return c_api.celeris_window_native_handle(global_engine_id);
    }

    /// Swaps the main window's caption height at runtime. `AppOptions.app_bar_height`
    /// used to be frozen at `runApp`; it is a host field now, so this works.
    pub fn setAppBarHeight(height: f32) void {
        const h = primaryHost() orelse return;
        h.bar_height = height;
        h.rebuild();
    }

    /// Shows/hides the main window's caption at runtime.
    pub fn setAppBarVisible(visible: bool) void {
        const h = primaryHost() orelse return;
        h.show_sys_bar = visible;
        h.rebuild();
    }

    /// The primary display's work area (screen minus taskbar), logical px.
    pub fn workArea() ?platform.Rect {
        return platform.workArea();
    }

    /// Opens a secondary window with its own component tree, layout and render loop
    ///. The main window is untouched: nothing is unmounted, no state is lost —
    /// which is the whole point, versus swapping the root build to a different
    /// branch.
    ///
    /// The returned handle moves, resizes, hides and closes it. `close()` frees the
    /// window's tree; closing the main window closes every secondary one.
    pub fn open(options: WindowOptions) !WindowHandle {
        const parent = primaryHost() orelse return error.NoPrimaryWindow;
        const allocator = parent.allocator;

        const pos = resolvePlacement(options.placement, options.width, options.height);
        const config = c_api.CelerisWindowConfig{
            .is_headless = false,
            .width = options.width,
            .height = options.height,
            // Owned by the main window: the engine cascades the close, and the
            // platform knows this window must not end the event loop.
            .parent_engine_id = parent.engine_id,
            .modal = false,
            .title = options.title.ptr,
            .corner_preference = @intFromEnum(options.window_corners),
            .border_color = if (options.window_outline) |c|
                0xFF00_0000 | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.b)
            else
                0,
            .x = if (pos) |p| p.x else 0,
            .y = if (pos) |p| p.y else 0,
            .has_position = pos != null,
            .always_on_top = options.always_on_top,
            .fixed_size = !options.resizable,
        };

        const engine_id = c_api.celeris_create_window(&config);
        if (engine_id <= 0) return error.WindowCreationFailed;
        errdefer c_api.celeris_deinit(engine_id);

        const host = try allocator.create(WindowHost);
        errdefer allocator.destroy(host);
        const router = try allocator.create(events.EventRouter);
        errdefer allocator.destroy(router);
        router.* = events.EventRouter.init(allocator);

        host.* = .{
            .allocator = allocator,
            .router = router,
            .owns_router = true,
            .child_root = .{ .child = options.content },
            .show_sys_bar = !options.hide_app_bar,
            .bar_style = if (options.app_bar != null) .custom else options.app_bar_style,
            .bar_title = options.title,
            .bar_content = options.app_bar,
            .bar_height = options.app_bar_height,
            .bar_divider = options.app_bar_divider,
            .bar_labels = options.window_control_labels,
            .outline = options.window_outline,
            .outline_radius = outlineRadius(options.window_corners),
        };
        host.root_ptr = @ptrCast(&host.child_root);
        host.root_mount = mountChildRoot;

        const shared: ?*signals.Signal(theme_mod.Theme) = switch (options.theme) {
            .inherit => parent.theme_signal,
            .own => null,
        };
        const initial = switch (options.theme) {
            .inherit => parent.theme_signal.peek(),
            .own => |t| t,
        };
        try host.setup(engine_id, initial, shared);

        host.rebuild();
        return .{ .host = host, .engine_id = engine_id, .generation = host.generation };
    }
};

/// Root mount for a `Child`-shaped window body: the same reactive fill path a
/// `runApp` root gets, so the overlay's tree is as reactive as the main one.
fn mountChildRoot(host: *WindowHost, ctx: *component.BuildContext) anyerror!void {
    try ctx.mountReactiveFill(&host.app_scope, &host.child_root);
}

/// The outline has to follow the window's own curve or its corners poke past the
/// clip. These match the radii Windows 11 uses for each preference (logical px —
/// the renderer scales them with DPI just like the window's).
fn outlineRadius(corners: platform.CornerPreference) f32 {
    return switch (corners) {
        .round => 8,
        .round_small => 4,
        .default, .square => 0,
    };
}

/// Posts a task to be executed on the main thread during the next event loop tick.
/// This is thread-safe and can be called from any thread.
/// `ctx` must be a pointer or `void`.
pub fn postTask(comptime func: anytype, ctx: anytype) void {
    const CtxType = @TypeOf(ctx);
    if (CtxType != void and @typeInfo(CtxType) != .pointer) {
        @compileError("postTask ctx must be a pointer or void");
    }
    const Wrapper = struct {
        fn call(erased_ctx: ?*anyopaque) callconv(.c) void {
            if (CtxType == void) {
                func();
            } else {
                const typed_ctx: CtxType = @ptrCast(@alignCast(erased_ctx));
                func(typed_ctx);
            }
        }
    };

    const erased: ?*anyopaque = if (CtxType == void) null else @ptrCast(ctx);
    c_api.celeris_post_task(Wrapper.call, erased);
}

/// Requests a repaint of the app window from any thread (thread-safe). Forces a
/// frame without re-running `build`; for content changes use `triggerRebuild`
/// (which is what `postTask` callbacks typically call). See `celeris_request_redraw`.
pub fn requestRedraw() void {
    c_api.celeris_request_redraw(global_engine_id);
}

fn dialogOptPtr(s: ?[:0]const u8) [*c]const u8 {
    return if (s) |v| v.ptr else null;
}

/// Native OS file dialogs, window-scoped.
///
/// Every call blocks the calling thread until the user picks a path or cancels.
/// A native modal runs its own message loop but Celeris' frame loop is stalled
/// inside the blocking call, so the window stops repainting until it returns —
/// run the dialog on a worker (`std.Thread.spawn`) and marshal the path back
/// with `application.postTask`, exactly as `examples/dashboard.zig` does. The
/// C-ABI exports underneath are worker-safe by design.
///
/// The returned path is engine-owned; free it with `dialogs.freeString`, passing
/// the same `window`. Platform matrix: Win32 (full), Linux (XDG portal; `filter`
/// is ignored for now), macOS (no native dialog — always returns null).
pub const dialogs = struct {
    pub const Options = struct {
        title: ?[:0]const u8 = null,
        /// A glob like `"*.png"`. Win32 only.
        filter: ?[:0]const u8 = null,
        /// Window the modal is owned by (for correct modality with multiple
        /// windows). Null → the primary `runApp` window.
        window: ?WindowHandle = null,
    };

    fn engineId(w: ?WindowHandle) i32 {
        return if (w) |h| h.engine_id else global_engine_id;
    }

    /// Native "open file" dialog. Null on cancel / unsupported.
    pub fn openFile(opts: Options) ?[*:0]const u8 {
        const p = c_api.celeris_open_file_dialog(engineId(opts.window), dialogOptPtr(opts.title), dialogOptPtr(opts.filter));
        return if (p == null) null else @ptrCast(p);
    }

    /// Native "save file" dialog. `default_name` pre-fills the filename field.
    pub fn saveFile(opts: Options, default_name: ?[:0]const u8) ?[*:0]const u8 {
        const p = c_api.celeris_save_file_dialog(engineId(opts.window), dialogOptPtr(opts.title), dialogOptPtr(opts.filter), dialogOptPtr(default_name));
        return if (p == null) null else @ptrCast(p);
    }

    /// Native folder-selection dialog. Null on cancel / unsupported.
    pub fn pickFolder(opts: Options) ?[*:0]const u8 {
        const p = c_api.celeris_pick_directory(engineId(opts.window), dialogOptPtr(opts.title), null);
        return if (p == null) null else @ptrCast(p);
    }

    /// Frees a path returned by `openFile` / `saveFile` / `pickFolder`. `window`
    /// must match the one the dialog was opened with (the owning string table is
    /// per-engine).
    pub fn freeString(ptr: [*:0]const u8, owning_window: ?WindowHandle) void {
        c_api.celeris_free_string(engineId(owning_window), @ptrCast(ptr));
    }
};

/// Deprecated: use `dialogs.pickFolder`.
pub fn pickDirectory(title: ?[:0]const u8) ?[*:0]const u8 {
    return dialogs.pickFolder(.{ .title = title });
}

/// Deprecated: use `dialogs.freeString`.
pub fn freeString(ptr: [*:0]const u8) void {
    c_api.celeris_free_string(global_engine_id, @ptrCast(ptr));
}

/// A Flutter-like runApp entry point.
/// `app_instance` must be a pointer to a struct implementing:
///   `pub fn build(self: *AppType, b: *builder.UIBuilder) !void`
pub fn runApp(app_instance: anytype, router: *events.EventRouter, options: AppOptions) !void {
    const AppType = @TypeOf(app_instance.*);

    // Before the first window: the atlas is built at engine init, so a face
    // registered later would not reach it.
    registerAppFonts(options.fonts);

    const config = c_api.CelerisWindowConfig{
        .is_headless = options.is_headless,
        .width = options.width,
        .height = options.height,
        .parent_engine_id = 0,
        .modal = false,
        .title = options.title.ptr,
        .corner_preference = @intFromEnum(options.window_corners),
        // The outline also drives DWM's frame border. Rounding the window turns
        // that border on in a system color, so without this the app shows two
        // hairlines in different colors — the one we draw, and the one outside it.
        .border_color = if (options.window_outline) |c|
            0xFF00_0000 | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.b)
        else
            0,
    };

    const engine_id = c_api.celeris_create_window(&config);
    if (engine_id <= 0) {
        log.warn("failed to create the engine/window: {s}\n", .{std.mem.span(c_api.celeris_last_error())});
        return error.EngineInitFailed;
    }
    // Defer deinit. In normal flow, start_loop blocks forever until closed.
    // Destroying the primary engine cascades to every secondary window, so an
    // app that exits with an overlay still open leaks nothing.
    defer c_api.celeris_deinit(engine_id);

    // The root mount, specialized here where `AppType` is known — this is the only
    // generic part of a window host, and closing over it as a function pointer is
    // what lets `WindowHost` itself stay a plain runtime struct.
    const Root = struct {
        fn mount(host: *WindowHost, ctx: *component.BuildContext) anyerror!void {
            const app: *AppType = @ptrCast(@alignCast(host.root_ptr));
            // Unified root entry: an app whose `build` takes `*BuildContext`
            // is mounted reactively — a signal it reads re-runs the root build with
            // no `triggerRebuild`. A legacy `*UIBuilder` / `anytype` app is built
            // directly (backward-compatible for one release).
            const use_ctx = comptime blk: {
                const p = appBuildParam(AppType);
                break :blk p != null and p.? == *component.BuildContext;
            };
            if (use_ctx) {
                // Fill anchor: the app root is width/height 100%, so its mount anchor
                // must fill `body` rather than hug content (reactive root).
                try ctx.mountReactiveFill(&host.app_scope, app);
            } else {
                try app.build(ctx.builder);
            }
        }
    };

    // The primary host lives on this stack frame: `celeris_start_loop` blocks here
    // until the window closes, so the frame outlives every build that reads it.
    var host = WindowHost{
        .allocator = std.heap.c_allocator,
        .router = router,
        .is_primary = true,
        .root_ptr = @ptrCast(app_instance),
        .root_mount = Root.mount,
        // The system AppBar is framework-owned: buildWrapper mounts it with
        // ctx.mountOwned — no init/register/deinit choreography here.
        .show_sys_bar = !options.hide_app_bar and !options.is_headless,
        // A caption slot implies custom chrome: the classic bar has nowhere to put it.
        .bar_style = if (options.app_bar != null) .custom else options.app_bar_style,
        .bar_title = options.title,
        .bar_content = options.app_bar,
        .bar_height = options.app_bar_height,
        .bar_divider = options.app_bar_divider,
        .bar_labels = options.window_control_labels,
        .outline = options.window_outline,
        .outline_radius = outlineRadius(options.window_corners),
    };
    try host.setup(engine_id, options.theme, null);
    defer {
        host.teardown();
        // The primary's own unmount can close a window it owns; nothing else runs
        // after this, so drain what that queued.
        flushPendingTeardowns();
    }

    // The focus-ring color is no longer set here: `buildWrapper` routes each
    // window's own theme into its own engine on every build, so it also follows a
    // runtime theme swap.

    global_engine_id = engine_id;

    // Rebuild the UI when the OS changes the maximized state without a button click
    // (dragging a maximized window restores it), so the AppBar glyph stays in sync.
    c_api.celeris_set_maximize_change_callback(&onMaximizeChange);
    // A user-initiated close on a secondary window unwinds its host first.
    c_api.celeris_set_close_request_callback(&onCloseRequest);

    host.rebuild();

    _ = c_api.celeris_start_loop();

    // The loop has ended: close any secondary window still open, so its tree is
    // released through the same path a manual `close()` takes rather than being
    // dropped on the floor when the engine pool is torn down.
    closeAllSecondary();
}

/// Closes every secondary window's host. Called when the primary window's loop
/// ends: the engines themselves are cascaded by `celeris_deinit`, but their
/// framework state — trees, scopes, routers — is ours to release.
fn closeAllSecondary() void {
    for (g_hosts) |maybe| {
        if (maybe) |h| {
            if (!h.is_primary) closeHost(h);
        }
    }
    // No more loop ticks are coming, so the deferred frees have to happen here.
    flushPendingTeardowns();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "AppBuildParam classifies build signatures for the reactive/legacy split" {
    const Reactive = struct {
        pub fn build(_: *@This(), _: *component.BuildContext) !void {}
    };
    const LegacyPtr = struct {
        pub fn build(_: *@This(), _: *builder.UIBuilder) !void {}
    };
    const LegacyAny = struct {
        pub fn build(_: *@This(), _: anytype) !void {}
    };

    try std.testing.expect(appBuildParam(Reactive).? == *component.BuildContext);
    try std.testing.expect(appBuildParam(LegacyPtr).? == *builder.UIBuilder);
    try std.testing.expectEqual(@as(?type, null), appBuildParam(LegacyAny)); // anytype → null
}

test "Anchored placement lands the window inside the work area, inset by the margin" {
    const area = platform.Rect{ .x = 0, .y = 0, .w = 1920, .h = 1040 }; // 1080 minus a taskbar
    // resolvePlacement queries the platform, which is unavailable in a test, so the
    // arithmetic is exercised through the same expressions with a fixed area.
    const w: i32 = 460;
    const h: i32 = 56;
    const m: i32 = 16;
    const aw: i32 = @intCast(area.w);
    const ah: i32 = @intCast(area.h);

    // top_right: flush to the right edge and the top, inside the margin.
    try std.testing.expectEqual(@as(i32, 1920 - 460 - 16), area.x + aw - w - m);
    try std.testing.expectEqual(@as(i32, 16), area.y + m);
    // bottom_right sits above the taskbar, not under it — the reason placement
    // uses the work area rather than the full screen.
    try std.testing.expectEqual(@as(i32, 1040 - 56 - 16), area.y + ah - h - m);

    // An explicit position is passed through untouched.
    const p = resolvePlacement(.{ .position = .{ .x = 40, .y = 900 } }, 460, 56).?;
    try std.testing.expectEqual(@as(i32, 40), p.x);
    try std.testing.expectEqual(@as(i32, 900), p.y);
    // …and platform_default means "no opinion".
    try std.testing.expect(resolvePlacement(.platform_default, 460, 56) == null);
}

test "The outline radius follows the window's own corner preference" {
    // The hairline has to curve with the frame or its corners poke past the clip.
    try std.testing.expectEqual(@as(f32, 8), outlineRadius(.round));
    try std.testing.expectEqual(@as(f32, 4), outlineRadius(.round_small));
    try std.testing.expectEqual(@as(f32, 0), outlineRadius(.square));
    try std.testing.expectEqual(@as(f32, 0), outlineRadius(.default));
}

test "Each window slot gets its own build and event trampoline, routing to its own host" {
    const a = std.testing.allocator;

    // Two hosts in slots 0 and 1, each with its own router — no engines involved:
    // what's under test is that the comptime trampoline tables keep the two windows'
    // input apart, which is what keeps each window's input separate.
    var r1 = events.EventRouter.init(a);
    defer r1.deinit();
    var r2 = events.EventRouter.init(a);
    defer r2.deinit();
    var h1 = WindowHost{ .allocator = a, .router = &r1, .engine_id = 1 };
    var h2 = WindowHost{ .allocator = a, .router = &r2, .engine_id = 2 };

    g_hosts[0] = &h1;
    g_hosts[1] = &h2;
    defer {
        g_hosts[0] = null;
        g_hosts[1] = null;
    }

    const Sink = struct {
        var a_hits: u32 = 0;
        var b_hits: u32 = 0;
        fn onA(_: ?*anyopaque, _: events.Event) void {
            a_hits += 1;
        }
        fn onB(_: ?*anyopaque, _: events.Event) void {
            b_hits += 1;
        }
    };
    Sink.a_hits = 0;
    Sink.b_hits = 0;
    try r1.onNode(7, .click, .{ .ptr = null, .call = Sink.onA });
    try r2.onNode(7, .click, .{ .ptr = null, .call = Sink.onB });

    const CelerisEvent = @import("../core/events.zig").CelerisEvent;
    var ev = CelerisEvent{
        .event_type = @intFromEnum(@import("../core/events.zig").EventType.click),
        .node_id = 7,
        .action_id = "n7",
        .x = 0,
        .y = 0,
        .key_code = 0,
        .scroll_delta = 0,
        .text = "",
        .modifiers = 0,
    };

    // A click delivered for window 2 must reach only window 2's handlers.
    event_trampolines[1](&ev);
    try std.testing.expectEqual(@as(u32, 0), Sink.a_hits);
    try std.testing.expectEqual(@as(u32, 1), Sink.b_hits);

    event_trampolines[0](&ev);
    try std.testing.expectEqual(@as(u32, 1), Sink.a_hits);
    try std.testing.expectEqual(@as(u32, 1), Sink.b_hits);

    // An empty slot's trampoline is inert rather than a crash — a window can be
    // destroyed while an event for it is still in flight.
    event_trampolines[5](&ev);
    try std.testing.expectEqual(@as(u32, 1), Sink.a_hits);
    try std.testing.expectEqual(@as(u32, 1), Sink.b_hits);
}

test "A host's caption config is per-window state, not frozen at creation" {
    const a = std.testing.allocator;
    var r = events.EventRouter.init(a);
    defer r.deinit();
    var host = WindowHost{ .allocator = a, .router = &r, .engine_id = 1, .bar_height = 44, .is_primary = true };
    g_hosts[0] = &host;
    defer g_hosts[0] = null;

    // This is the concrete complaint behind the request: `app_bar_height` used to be
    // a comptime static inside runApp, so a 56px bar kept an immovable 44px caption.
    try std.testing.expectEqual(@as(f32, 44), host.bar_height);
    window.setAppBarHeight(0);
    try std.testing.expectEqual(@as(f32, 0), host.bar_height);
    window.setAppBarVisible(false);
    try std.testing.expect(!host.show_sys_bar);
}

test "Close() from a handler of the same window defers the teardown past the dispatch" {
    // The bug: the Stop button of an overlay called `handle.close()`, `closeHost`
    // freed the router synchronously, and `EventRouter.route` — one frame down the
    // stack, mid-iteration over that router's handler lists — read freed memory.
    // The window must go inert immediately but stay allocated until the next tick.
    const a = std.testing.allocator;

    const router = try a.create(events.EventRouter);
    router.* = events.EventRouter.init(a);
    const host = try a.create(WindowHost);
    host.* = .{ .allocator = a, .router = router, .owns_router = true };
    // Engine 4 does not exist; every engine call on this path is a lookup miss and
    // a no-op, which is what lets the framework side be tested on its own.
    try host.setup(4, theme_mod.Theme.dark(), null);
    try std.testing.expect(g_hosts[3] == host);

    const H = struct {
        var after_close_hits: u32 = 0;
        fn close(h: *WindowHost, _: events.Event) void {
            closeHost(h);
        }
        fn after(_: *WindowHost, _: events.Event) void {
            after_close_hits += 1;
        }
    };
    H.after_close_hits = 0;
    // Two handlers on the same action id: the first closes the window, the second is
    // the one `route` walks to next — the `for (self.handlers.items)` loop at the top
    // of the reported stack. Under the synchronous free that read is the crash.
    try router.on("stop", host, H.close);
    try router.on("stop", host, H.after);

    const CelerisEvent = @import("../core/events.zig").CelerisEvent;
    const ev = CelerisEvent{
        .event_type = @intFromEnum(@import("../core/events.zig").EventType.click),
        .node_id = 9,
        .action_id = "stop",
        .x = 0,
        .y = 0,
        .key_code = 0,
        .scroll_delta = 0,
        .text = "",
        .modifiers = 0,
    };
    // Dispatched through the trampoline, i.e. exactly the frame the crash came from.
    event_trampolines[3](&ev);
    try std.testing.expectEqual(@as(u32, 1), H.after_close_hits);

    // Inert at once: unhooked from the slot, closing, and its handle stale — so no
    // further build or event can reach the tree that is about to go.
    try std.testing.expect(g_hosts[3] == null);
    try std.testing.expect(host.closing);
    try std.testing.expect(g_pending_teardown[0] == host);
    // A second close (say the OS close-request racing the button) must not queue
    // the host twice — that would be a double free on the next tick.
    closeHost(host);
    try std.testing.expect(g_pending_teardown[1] == null);
    // Still allocated: the router the frame above is iterating is untouched.
    try std.testing.expectEqual(@as(usize, 2), router.handlers.items.len);

    // Next tick: everything goes. `testing.allocator` is the assertion — a leak or
    // a double free fails the test.
    flushPendingTeardowns();
    try std.testing.expect(g_pending_teardown[0] == null);
    // Draining twice is a no-op, as the extra flush at loop exit relies on.
    flushPendingTeardowns();
}

test "Opening and closing a window repeatedly leaks nothing framework-side" {
    // Attribution for the exit leaks reported alongside the use-after-free: run the
    // full open → build → close → drain cycle three times on a real (headless)
    // engine, with the host, its router, its mounts and its scopes all on
    // `testing.allocator`. Anything the close path forgets shows up here, and shows
    // up three times over.
    const a = std.testing.allocator;
    const cfg = c_api.CelerisWindowConfig{
        .is_headless = true,
        .width = 320,
        .height = 64,
        .title = "probe",
        .parent_engine_id = 0,
        .modal = false,
        .corner_preference = 0,
        .border_color = 0,
        .x = 0,
        .y = 0,
        .has_position = false,
    };

    for (0..3) |_| {
        const engine_id = c_api.celeris_create_window(&cfg);
        if (engine_id < 0) return error.SkipZigTest; // no engine slot: nothing to measure
        defer c_api.celeris_deinit(engine_id);

        const router = try a.create(events.EventRouter);
        router.* = events.EventRouter.init(a);
        const host = try a.create(WindowHost);
        host.* = .{ .allocator = a, .router = router, .owns_router = true, .show_sys_bar = true };
        host.root_ptr = @ptrCast(&host.child_root);
        host.root_mount = mountChildRoot;
        try host.setup(engine_id, theme_mod.Theme.dark(), null);

        // A real build: the caption, the tooltip and toast hosts, the mount table —
        // the state the teardown is responsible for.
        host.rebuild();

        closeHost(host);
        flushPendingTeardowns();
    }
}

test "A stale handle is inert — every call is a no-op once the window is gone" {
    const a = std.testing.allocator;
    var r = events.EventRouter.init(a);
    defer r.deinit();
    var host = WindowHost{ .allocator = a, .router = &r, .engine_id = 3, .generation = 7 };
    g_hosts[2] = &host;

    const handle = WindowHandle{ .host = &host, .engine_id = 3, .generation = 7 };
    try std.testing.expect(handle.isOpen());

    // The nastiest case first: the slot AND the heap address are recycled by a
    // later window. Only the generation stamp tells the two apart.
    host.generation = 8;
    try std.testing.expect(!handle.isOpen());
    host.generation = 7;

    // And the plain case — the window is simply gone (as `closeHost` leaves things).
    g_hosts[2] = null;
    try std.testing.expect(!handle.isOpen());
    try std.testing.expect(handle.bounds() == null);
    try std.testing.expect(handle.nativeHandle() == null);
    // These must not touch the engine at all — an app holding a stale handle in its
    // state should not be able to take the process down with it.
    handle.setBounds(0, 0, 10, 10);
    handle.setAlwaysOnTop(true);
    handle.hide();
    handle.close();
}

test "AppOptions.fonts reaches the engine; no fonts leaves the registration untouched" {
    const saved = c_api.appFonts();
    defer c_api.setAppFonts(saved);

    // An app that names no faces must not clear a registration made elsewhere
    // (a C host calling celeris_set_app_fonts before handing control to runApp).
    c_api.setAppFonts(.{ .primary = "sentinel" });
    registerAppFonts(null);
    try std.testing.expectEqualSlices(u8, "sentinel", c_api.appFonts().primary.?);

    registerAppFonts(.{ .primary = "brand", .mono = "brand-mono" });
    const got = c_api.appFonts();
    try std.testing.expectEqualSlices(u8, "brand", got.primary.?);
    try std.testing.expectEqualSlices(u8, "brand-mono", got.mono.?);
    // Roles the app didn't name stay unset, so the system scan still fills them.
    try std.testing.expect(got.bold == null);
    try std.testing.expect(got.mono_bold == null);
}
