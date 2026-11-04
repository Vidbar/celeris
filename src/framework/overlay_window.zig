//! OverlayWindow — a secondary window bound to a signal (declarative form).
//!
//! `window.open` / `handle.close` are the imperative API: an app that needs to
//! move, resize or reposition a floating bar wants exactly that. This widget is
//! the other half — for the common case where a window's existence simply tracks a
//! piece of state ("the recorder bar is up while we are recording"), the way
//! Flutter's `Overlay` and Compose's `Popup` do it:
//!
//! ```zig
//! try ctx.mountOwned(OverlayWindow, .{
//!     .open = &self.is_recording,                   // ?*Signal(bool), caller-owned
//!     .options = .{
//!         .content = component.childOf(RecorderBar, &self.recorder_bar),
//!         .width = 460, .height = 56,
//!         .placement = .{ .anchored = .{ .at = .top_right, .margin = 16 } },
//!         .always_on_top = true,
//!         .hide_app_bar = true,
//!     },
//! });
//! ```
//!
//! `is_recording.set(true)` opens the window; `set(false)` closes it. Nothing in
//! the main window's tree is unmounted either way — that is the whole point of the
//! feature, and it holds for both the imperative and the declarative path, because
//! this widget is a thin layer over the same `window.open`.
//!
//! The content is caller-owned (`childOf(T, &instance)`), so its state lives in the
//! app struct and survives the window closing and reopening.
//!
//! Lifted state, per the framework's convention: the signal belongs to the caller,
//! and this widget only reads it. It never writes back — a window that closed
//! itself would otherwise fight the app for control of the flag.

const std = @import("std");
const log = @import("../core/log.zig");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const application = @import("application.zig");

pub const OverlayWindow = struct {
    // Props.
    /// Drives the window's existence. Null keeps the window open for as long as the
    /// widget is mounted.
    open: ?*signals.Signal(bool) = null,
    /// Everything `window.open` takes, `content` included.
    options: ?application.WindowOptions = null,

    // State.
    handle: ?application.WindowHandle = null,
    /// An open/close already queued for the next loop tick, so a burst of rebuilds
    /// doesn't queue several.
    pending: bool = false,
    /// The state the last build asked for; applied off the build, on the next tick.
    desired: bool = false,

    pub fn onMount(self: *OverlayWindow, _: std.mem.Allocator) void {
        self.handle = null;
        self.pending = false;
        self.desired = false;
    }

    pub fn deinit(self: *OverlayWindow) void {
        if (self.handle) |h| h.close();
        self.handle = null;
    }

    pub fn build(self: *OverlayWindow, ctx: *component.BuildContext) !void {
        // `.get()`, not `.peek()`: this subscribes the enclosing build-effect, so
        // flipping the signal re-runs exactly this widget and nothing else.
        const want = if (self.open) |s| s.get() else true;
        self.desired = want;

        // Opening a window means creating an engine and a GPU surface. Doing that
        // from inside a build — which runs mid-propagation, with a builder in
        // flight over the parent's registry — is asking for trouble, so the actual
        // work is posted to the next loop tick. The delay is invisible: it is the
        // same frame boundary any state change waits for.
        if (!self.pending and want != self.isOpen()) {
            self.pending = true;
            application.postTask(apply, self);
        }

        // The widget itself draws nothing in the parent window; its anchor is an
        // empty box.
        _ = ctx;
    }

    /// True while the secondary window is up. Cheap enough to call from a build.
    pub fn isOpen(self: *const OverlayWindow) bool {
        return if (self.handle) |h| h.isOpen() else false;
    }

    /// The live window handle, for the imperative moves the declarative form does
    /// not cover — `overlay.handle.?.setBounds(...)` while it is open.
    pub fn window(self: *OverlayWindow) ?application.WindowHandle {
        if (self.handle) |h| {
            if (h.isOpen()) return h;
        }
        return null;
    }

    fn apply(self: *OverlayWindow) void {
        self.pending = false;
        if (self.desired == self.isOpen()) return;
        if (self.desired) {
            const opts = self.options orelse return;
            self.handle = application.window.open(opts) catch |err| {
                log.warn("OverlayWindow: open failed: {}\n", .{err});
                return;
            };
        } else {
            if (self.handle) |h| h.close();
            self.handle = null;
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "OverlayWindow: the signal drives the desired state without touching the parent tree" {
    const a = testing.allocator;
    const reg = @import("../core/registry.zig");
    const props = @import("../core/properties.zig");
    const events = @import("events.zig");

    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    // Declared before the mount table so its `deinit` runs LAST: the table's
    // build-effects unsubscribe from this signal on teardown, and freeing it first
    // would dangle them (the same ordering `runApp` documents for the theme signal).
    var is_open = signals.Signal(bool).init(a, false);
    defer is_open.deinit();

    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    var b = component.UIBuilder.init(&registry, &store);
    var ctx = component.BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(OverlayWindow, .{ .open = &is_open });
    b.close();

    const anchor = registry.getNode(0).?.first_child;
    const ov: *OverlayWindow = @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));

    // Closed signal → nothing wanted, nothing open. (No engine here, so `apply`
    // never runs; what this pins is that the widget reads the signal and adds no
    // nodes of its own to the parent's tree.)
    try testing.expect(!ov.desired);
    try testing.expect(!ov.isOpen());

    const before = registry.nodes.items.len;
    is_open.set(true);
    try testing.expect(ov.desired);
    // The parent's tree is untouched by the window state changing — the promise
    // the whole feature rests on.
    try testing.expectEqual(before, registry.nodes.items.len);
}
