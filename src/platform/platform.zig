const std = @import("std");
const builtin = @import("builtin");

pub const NativeWindowHandle = union(enum) {
    win32: struct {
        hwnd: ?*anyopaque,
        hinst: ?*anyopaque,
    },
    macos: struct {
        ns_window: ?*anyopaque,
        ns_view: ?*anyopaque,
    },
    linux: struct {
        // Wayland: wl_display* and wl_surface* (both opaque pointers).
        display: ?*anyopaque,
        surface: ?*anyopaque,
    },
};

pub const InputEventType = enum { mouse_down, mouse_up, right_mouse_down, right_mouse_up, mouse_move, mouse_leave, key_down, key_up, char_input, scroll, resize, ime_preedit, ime_commit, drop };

pub const InputEvent = struct {
    /// The window the event came from. Optional: synthetic/injected input (the
    /// `celeris_dispatch_*` C-API) omits it and targets the engine directly.
    native_handle: ?NativeWindowHandle = null,
    event_type: InputEventType,
    x: f32 = 0,
    y: f32 = 0,
    key_code: u32 = 0,
    scroll_delta: f32 = 0,
    /// Horizontal scroll notches, positive = right. Internal struct — NOT
    /// the C-ABI CelerisEvent (horizontal reaches hosts as CELERIS_EVENT_SCROLL_H
    /// with the delta in scroll_delta).
    scroll_dx: f32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    shift_held: bool = false,
    ctrl_held: bool = false,
    alt_held: bool = false,
    /// UTF-8 payload for IME events (ime_preedit / ime_commit). Borrowed — valid
    /// only for the duration of the input callback.
    text: []const u8 = "",
};

/// Mouse cursor shapes the engine can request based on what's hovered.
pub const CursorType = enum { default, pointer, text, resize_ew, resize_ns };

/// Parameters for creating a top-level (or child) window. Replaces the old
/// width/height-only signature so a host can title windows and establish a
/// parent/modal relationship. `parent` is the owner window's native
/// handle (null = top-level). `modal` disables the parent while this window is
/// alive (owner-modal dialog).
/// Rounding of the window's own outer corners, asked of the compositor at
/// creation. Celeris windows are borderless, so without this they come out square
/// while everything drawn inside is rounded. `.default` leaves the platform's own
/// policy alone. Honoured on Windows 11 (DWM); a no-op where the compositor owns
/// the decision (X11/Wayland, macOS).
pub const CornerPreference = enum(u8) { default = 0, square = 1, round = 2, round_small = 3 };

/// A window rectangle in logical (DPI-independent) pixels, screen coordinates.
pub const Rect = struct { x: i32, y: i32, w: u32, h: u32 };

pub const WindowConfig = struct {
    width: u32,
    height: u32,
    title: []const u8 = "Celeris",
    parent: ?NativeWindowHandle = null,
    modal: bool = false,
    resizable: bool = true,
    corners: CornerPreference = .default,
    /// Top-left position in logical screen pixels. Null lets the platform place the
    /// window (Win32 uses its historical 200,150; Wayland lets the compositor decide).
    x: ?i32 = null,
    y: ?i32 = null,
    /// Keep the window above non-topmost windows of every process. The whole
    /// point of a floating overlay bar — a HUD that survives the user clicking into
    /// the app it is recording. Honoured on Windows; a no-op on Wayland (the
    /// compositor owns stacking).
    always_on_top: bool = false,
    /// Show the window at creation. `false` creates it hidden, for an overlay that
    /// should be positioned before it is ever seen (no flash at the default spot).
    visible: bool = true,
    /// Destroying this window ends the application event loop. True for the primary
    /// window; secondary windows must set it false, or closing the overlay
    /// would take the whole app down with it.
    quit_on_close: bool = true,
    /// Color of the border the compositor draws *outside* the client area, as
    /// 0xAARRGGBB (alpha ignored; null = leave the system default). Rounding a
    /// window makes Windows 11 draw this border, so an app that paints its own
    /// hairline ends up with two lines in different colors — matching it here
    /// collapses them into one. Honoured on Windows 11; ignored elsewhere.
    border_color: ?u32 = null,
};

pub const InputCallback = *const fn (ctx: ?*anyopaque, event: InputEvent) void;

// Resize callback type: handles generic resizes without exposing hwnd. `scale`
// is the current DPI scale (logical→physical), so a runtime DPI change (Win32
// WM_DPICHANGED / Wayland output rescale) updates the engine's scale, not just
// its size.
pub const ResizeCallback = *const fn (handle: NativeWindowHandle, w: u32, h: u32, scale: f32) void;

pub const PlatformWindow = struct {
    // Logical size (DPI-independent).
    width: u32,
    height: u32,
    /// DPI scale factor (1.0 = 96 DPI / 100%). The framebuffer is logical × scale.
    scale: f32 = 1.0,

    // Abstracted handle
    handle: NativeWindowHandle,

    // Platform-specific struct instance
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        startDrag: *const fn (ptr: *anyopaque) void,
        close: *const fn (ptr: *anyopaque) void,
        maximize: *const fn (ptr: *anyopaque) void,
        minimize: *const fn (ptr: *anyopaque) void,
        /// Optional: reports whether the window is currently maximized. Backends
        /// that don't implement it leave it null (treated as "not maximized").
        isMaximized: ?*const fn (ptr: *anyopaque) bool = null,
        /// Optional: true while the compositor itself draws the window's left,
        /// right and bottom edge in the outline color (Win32: DWM's frame border on
        /// a resizable, restored window). The app's outline must then skip those
        /// sides, or the edge reads 2px there and 1px on top. Null → false.
        nativeSideEdges: ?*const fn (ptr: *anyopaque) bool = null,
        /// Sets the root UIA provider for this window. Win32 only.
        setUiaProvider: ?*const fn (ptr: *anyopaque, provider: *anyopaque) void = null,
        /// Moves and resizes the window in logical screen pixels. Backends that
        /// can't position themselves (Wayland) leave it null.
        setBounds: ?*const fn (ptr: *anyopaque, x: i32, y: i32, w: u32, h: u32) void = null,
        /// Current outer bounds in logical screen pixels — the counterpart of
        /// `setBounds`, so an app can save a rect and restore it later.
        getBounds: ?*const fn (ptr: *anyopaque) Rect = null,
        /// Toggles the always-on-top band at runtime.
        setAlwaysOnTop: ?*const fn (ptr: *anyopaque, on: bool) void = null,
        /// Shows/hides the window without destroying it. Hiding the primary
        /// window is how an app swaps itself for a compact overlay.
        setVisible: ?*const fn (ptr: *anyopaque, visible: bool) void = null,
        /// Sets the OS window title (taskbar, Alt+Tab, decoration). UTF-8; the
        /// backend truncates to its own limit on a character boundary.
        setTitle: ?*const fn (ptr: *anyopaque, title: []const u8) void = null,
    };

    pub fn deinit(self: *PlatformWindow) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn startDrag(self: *PlatformWindow) void {
        self.vtable.startDrag(self.ptr);
    }

    pub fn setUiaProvider(self: *PlatformWindow, provider: *anyopaque) void {
        if (self.vtable.setUiaProvider) |func| {
            func(self.ptr, provider);
        }
    }

    pub fn close(self: *PlatformWindow) void {
        self.vtable.close(self.ptr);
    }

    pub fn maximize(self: *PlatformWindow) void {
        self.vtable.maximize(self.ptr);
    }

    pub fn minimize(self: *PlatformWindow) void {
        self.vtable.minimize(self.ptr);
    }

    pub fn isMaximized(self: *PlatformWindow) bool {
        return if (self.vtable.isMaximized) |f| f(self.ptr) else false;
    }

    pub fn nativeSideEdges(self: *PlatformWindow) bool {
        return if (self.vtable.nativeSideEdges) |f| f(self.ptr) else false;
    }

    /// Moves/resizes the window (logical px). Also updates the cached logical size so
    /// the engine's next frame matches, even before the platform's resize event lands.
    pub fn setBounds(self: *PlatformWindow, x: i32, y: i32, w: u32, h: u32) void {
        if (self.vtable.setBounds) |f| {
            f(self.ptr, x, y, w, h);
            self.width = w;
            self.height = h;
        }
    }

    pub fn getBounds(self: *PlatformWindow) Rect {
        if (self.vtable.getBounds) |f| return f(self.ptr);
        return .{ .x = 0, .y = 0, .w = self.width, .h = self.height };
    }

    pub fn setAlwaysOnTop(self: *PlatformWindow, on: bool) void {
        if (self.vtable.setAlwaysOnTop) |f| f(self.ptr, on);
    }

    pub fn setVisible(self: *PlatformWindow, visible: bool) void {
        if (self.vtable.setVisible) |f| f(self.ptr, visible);
    }

    pub fn setTitle(self: *PlatformWindow, title: []const u8) void {
        if (self.vtable.setTitle) |f| f(self.ptr, title);
    }
};

pub const Impl = switch (builtin.os.tag) {
    .windows => @import("win32.zig"),
    .linux => @import("linux.zig"),
    else => @compileError("Celeris supports Windows and Linux (Wayland); " ++ @tagName(builtin.os.tag) ++ " is not supported yet."),
};

// Polls events for all windows. Returns false if application should quit.
pub fn pollSystemEvents(ctx: ?*anyopaque, input_cb: ?InputCallback) bool {
    return Impl.pollSystemEvents(ctx, input_cb);
}

pub fn setResizeCallback(cb: ResizeCallback) void {
    Impl.setResizeCallback(cb);
}

/// Notified when the user closes a window that does NOT own the event loop — an
/// overlay's Alt+F4 or its own close button. The platform swallows the close so
/// the engine can tear the window down in order instead of the OS destroying
/// the HWND out from under a live component tree.
pub const CloseRequestCallback = *const fn (handle: NativeWindowHandle) void;

pub fn setCloseRequestCallback(cb: CloseRequestCallback) void {
    Impl.setCloseRequestCallback(cb);
}

pub fn initWindow(config: WindowConfig) !PlatformWindow {
    return Impl.initWindow(config);
}

/// Writes UTF-8 text to the system clipboard. Returns false if unsupported on
/// this platform or the operation failed.
pub fn clipboardSetText(text: []const u8) bool {
    return Impl.clipboardSetText(text);
}

/// Reads the clipboard as UTF-8 (caller owns the slice), or null if empty /
/// unsupported.
pub fn clipboardGetText(allocator: std.mem.Allocator) ?[]u8 {
    return Impl.clipboardGetText(allocator);
}

/// Shows a native "open file" dialog. Returns the chosen path (UTF-8, caller
/// owns) or null if cancelled / unsupported. `owner` is the native window handle
/// for modality (may be null). `filter` is a pattern like "*.txt" (null = all).
pub fn openFileDialog(allocator: std.mem.Allocator, owner: ?*anyopaque, title: ?[]const u8, filter: ?[]const u8) ?[]u8 {
    return Impl.openFileDialog(allocator, owner, title, filter);
}

/// Shows a native "save file" dialog. `default_name` pre-fills the filename.
pub fn saveFileDialog(allocator: std.mem.Allocator, owner: ?*anyopaque, title: ?[]const u8, filter: ?[]const u8, default_name: ?[]const u8) ?[]u8 {
    return Impl.saveFileDialog(allocator, owner, title, filter, default_name);
}

/// Shows a native "select folder" dialog. Returns the chosen directory path
/// (UTF-8, caller owns) or null if cancelled / unsupported. `owner` is the native
/// window handle for modality (may be null); `initial_dir` is a hint (may be null).
pub fn pickDirectory(allocator: std.mem.Allocator, owner: ?*anyopaque, title: ?[]const u8, initial_dir: ?[]const u8) ?[]u8 {
    return Impl.pickDirectory(allocator, owner, title, initial_dir);
}

/// Wakes the UI event loop from any thread (thread-safe). Used after queuing a
/// task or requesting a redraw so an idle `waitEvents` returns immediately
/// instead of waiting out its timeout.
pub fn wake() void {
    Impl.wake();
}

/// Blocks the UI thread until an OS event arrives, `wake()` is called, or
/// `timeout_ms` elapses. Lets an idle window drop to ~0 CPU without busy-spinning.
pub fn waitEvents(timeout_ms: u32) void {
    Impl.waitEvents(timeout_ms);
}

/// The primary display's work area (screen minus taskbar/panels) in logical px, or
/// null where the platform doesn't expose it. Anchored overlay placement
/// (`.top_right`, …) is resolved against this.
pub fn workArea() ?Rect {
    return Impl.workArea();
}

/// Sets the mouse cursor shape for the window under the pointer.
pub fn setCursor(cursor: CursorType) void {
    Impl.setCursor(cursor);
}

/// Enables/disables IME text input — called by the engine when focus moves to (or
/// away from) an editable widget, so the compositor/IME only composes inside text
/// fields. On Wayland this enables/disables `zwp_text_input_v3`; on Win32 it's a
/// no-op (the IME is always available and gated by which control has focus).
pub fn setImeActive(active: bool) void {
    Impl.setImeActive(active);
}

/// Longest prefix of `s` that is at most `max_bytes` long and does not end in
/// the middle of a UTF-8 sequence. Backends copy titles into fixed buffers; a
/// plain byte cut could split a multibyte character and hand the OS invalid
/// UTF-8. Only the cut point is adjusted — the rest of `s` is not validated.
pub fn utf8Truncate(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var n = max_bytes;
    // Back off while the byte at the cut is a continuation byte (10xxxxxx): the
    // cut would land inside the sequence that byte belongs to.
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

test "utf8Truncate keeps short strings and never splits a multibyte character" {
    const t = std.testing;
    try t.expectEqualStrings("abc", utf8Truncate("abc", 10));
    try t.expectEqualStrings("ab", utf8Truncate("abc", 2));
    // "ñ" is 2 bytes (C3 B1): a cut after its first byte backs off before it.
    try t.expectEqualStrings("a", utf8Truncate("añ", 2));
    try t.expectEqualStrings("añ", utf8Truncate("añb", 3));
    // A 4-byte emoji straddling the limit is dropped whole.
    try t.expectEqualStrings("x", utf8Truncate("x\u{1F600}", 3));
    // At the real title limit (255): 254 ASCII + "é" (2 bytes) → the é is dropped.
    var buf: [256]u8 = undefined;
    @memset(buf[0..254], 'a');
    buf[254] = 0xC3;
    buf[255] = 0xA9;
    const out = utf8Truncate(&buf, 255);
    try t.expectEqual(@as(usize, 254), out.len);
    try t.expect(std.unicode.utf8ValidateSlice(out));
}
