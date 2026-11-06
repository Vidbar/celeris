const std = @import("std");
const windows = std.os.windows;
const platform = @import("platform.zig");

pub const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const UINT = windows.UINT;
// WPARAM/LRESULT/WINAPI were removed from std.os.windows in Zig 0.16.
const WPARAM = usize;
const LPARAM = windows.LONG_PTR;
const LRESULT = windows.LONG_PTR;
const WINAPI: std.builtin.CallingConvention = .winapi;

extern "user32" fn DefWindowProcA(h: HWND, m: UINT, w: WPARAM, l: LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn PostQuitMessage(n: i32) callconv(WINAPI) void;
extern "user32" fn RegisterClassExA(p: *const anyopaque) callconv(WINAPI) u16;
extern "user32" fn GetKeyState(nVirtKey: i32) callconv(WINAPI) i16;

/// Shift/Ctrl/Alt state as of the message being processed (GetKeyState is
/// synchronized with the message queue). Shared by key, pointer and wheel input.
fn keyMods() struct { shift: bool, ctrl: bool, alt: bool } {
    const hi: i16 = @bitCast(@as(u16, 0x8000));
    return .{
        .shift = (GetKeyState(0x10) & hi) != 0, // VK_SHIFT
        .ctrl = (GetKeyState(0x11) & hi) != 0, // VK_CONTROL
        .alt = (GetKeyState(0x12) & hi) != 0, // VK_MENU
    };
}
extern "user32" fn CreateWindowExA(
    ex: u32,
    cls: ?[*:0]const u8,
    title: ?[*:0]const u8,
    style: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    parent: ?HWND,
    menu: ?*anyopaque,
    inst: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(WINAPI) ?HWND;
extern "user32" fn ShowWindow(hwnd: HWND, cmd: i32) callconv(WINAPI) i32;
extern "user32" fn PeekMessageA(msg: *anyopaque, hwnd: ?HWND, min: UINT, max: UINT, remove: UINT) callconv(WINAPI) i32;
extern "user32" fn TranslateMessage(msg: *const anyopaque) callconv(WINAPI) i32;
extern "user32" fn DispatchMessageA(msg: *const anyopaque) callconv(WINAPI) LRESULT;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(WINAPI) windows.BOOL;
extern "user32" fn ReleaseCapture() callconv(WINAPI) windows.BOOL;
extern "user32" fn SetCapture(hwnd: HWND) callconv(WINAPI) ?HWND;
extern "user32" fn SendMessageA(hwnd: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn PostMessageA(hwnd: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(WINAPI) windows.BOOL;
extern "user32" fn EnableWindow(hwnd: HWND, enable: windows.BOOL) callconv(WINAPI) windows.BOOL;
extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(WINAPI) windows.BOOL;
extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(WINAPI) windows.BOOL;
extern "user32" fn PostThreadMessageA(idThread: u32, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) windows.BOOL;
extern "user32" fn MsgWaitForMultipleObjectsEx(nCount: u32, pHandles: ?*const anyopaque, dwMilliseconds: u32, dwWakeMask: u32, dwFlags: u32) callconv(WINAPI) u32;
extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(WINAPI) windows.BOOL;
extern "user32" fn SystemParametersInfoA(uiAction: u32, uiParam: u32, pvParam: ?*anyopaque, fWinIni: u32) callconv(WINAPI) windows.BOOL;

// SetWindowPos z-order sentinels and flags used by the window controls.
const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
const SWP_NOSIZE: u32 = 0x0001;
const SWP_NOMOVE: u32 = 0x0002;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;

extern "dwmapi" fn DwmSetWindowAttribute(hwnd: HWND, attr: u32, pv: *const anyopaque, cb: u32) callconv(WINAPI) i32;

/// DWMWA_WINDOW_CORNER_PREFERENCE. Unknown to pre-Win11 DWM, which fails the call
/// (E_INVALIDARG) and leaves the window square — the same result as `.default`.
const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;

/// DWMWA_BORDER_COLOR — the frame border DWM draws outside the client area. Write-
/// only: reading it back fails with E_INVALIDARG, so the HRESULT is the only signal.
/// It also takes the sentinels 0xFFFFFFFF (system default) and 0xFFFFFFFE (no
/// border); `null` here means "don't touch it", which leaves the system default.
const DWMWA_BORDER_COLOR: u32 = 34;

/// Asks DWM to round (or square) the window's outer corners. Silently does nothing
/// for `.default` and on Windows versions that don't know the attribute.
fn applyCornerPreference(hwnd: HWND, corners: platform.CornerPreference) void {
    if (corners == .default) return;
    // DWM_WINDOW_CORNER_PREFERENCE: DEFAULT=0, DONOTROUND=1, ROUND=2, ROUNDSMALL=3 —
    // the same order as platform.CornerPreference, so the tag value maps directly.
    const pref: u32 = @intFromEnum(corners);
    _ = DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &pref, @sizeOf(u32));
}

/// Repaints DWM's own frame border in `argb` (0xAARRGGBB). Rounding a window turns
/// this border on, and it defaults to a system color — left alone it doubles up with
/// whatever hairline the app draws inside the client area. Returns false when DWM
/// rejects the call (pre-Win11), which is indistinguishable from "no border drawn".
fn applyBorderColor(hwnd: HWND, argb: ?u32) bool {
    const c = argb orelse return true; // null → leave the system default alone
    const colorref = colorRefFromArgb(c);
    return DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, &colorref, @sizeOf(u32)) >= 0;
}

/// 0xAARRGGBB → COLORREF (0x00BBGGRR). Alpha is dropped; DWM has no use for it here.
fn colorRefFromArgb(c: u32) u32 {
    return ((c & 0x0000FF) << 16) | (c & 0x00FF00) | ((c & 0xFF0000) >> 16);
}

// Window mouse-leave tracking (TrackMouseEvent / WM_MOUSELEAVE).
const TRACKMOUSEEVENT = extern struct {
    cbSize: u32,
    dwFlags: u32,
    hwndTrack: ?HWND,
    dwHoverTime: u32,
};
const TME_LEAVE: u32 = 0x0002;
const WM_MOUSELEAVE: UINT = 0x02A3;
/// One-shot arm state: TrackMouseEvent auto-disarms after posting WM_MOUSELEAVE,
/// so we re-arm on the next WM_MOUSEMOVE. Single flag — one tracked window at a
/// time is enough (the pointer is only ever inside one of our windows).
var g_mouse_leave_armed: bool = false;
extern "kernel32" fn GetCurrentThreadId() callconv(WINAPI) u32;

/// UI-thread id, captured on the first `pollSystemEvents`. `wake()` posts a
/// thread message to it to break an idle `waitEvents` from another thread.
var g_ui_thread_id: u32 = 0;

/// Blocks until a window message arrives, `wake()` is called, or `timeout_ms`
/// elapses — replaces a busy sleep so an idle window costs ~0 CPU while staying
/// instantly responsive to cross-thread `wake()`. `pollSystemEvents` drains the
/// messages right after.
pub fn waitEvents(timeout_ms: u32) void {
    const QS_ALLINPUT: u32 = 0x04FF;
    const MWMO_INPUTAVAILABLE: u32 = 0x0004;
    _ = MsgWaitForMultipleObjectsEx(0, null, timeout_ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
}

/// Wakes the UI thread's `waitEvents` from any thread (thread-safe). Posts a
/// benign WM_NULL the message pump discards. No-op before the loop starts.
pub fn wake() void {
    const tid = @atomicLoad(u32, &g_ui_thread_id, .acquire);
    if (tid != 0) _ = PostThreadMessageA(tid, 0x0000, 0, 0); // WM_NULL
}

// ── IME (imm32) ───────────────────────────────────────────────────────────────
const HIMC = ?*anyopaque;
extern "imm32" fn ImmGetContext(hwnd: HWND) callconv(WINAPI) HIMC;
extern "imm32" fn ImmReleaseContext(hwnd: HWND, himc: HIMC) callconv(WINAPI) windows.BOOL;
extern "imm32" fn ImmGetCompositionStringW(himc: HIMC, dwIndex: u32, lpBuf: ?*anyopaque, dwBufLen: u32) callconv(WINAPI) i32;
const GCS_COMPSTR: u32 = 0x0008;

/// Reads the in-progress composition (preedit) string as UTF-8 into `out`.
/// Returns the slice, or null if there's none / it doesn't fit.
fn imeCompositionStr(himc: HIMC, out: []u8) ?[]const u8 {
    const bytes = ImmGetCompositionStringW(himc, GCS_COMPSTR, null, 0);
    if (bytes <= 0) return null;
    const n_u16: usize = @intCast(@divFloor(bytes, 2));
    var u16buf: [256]u16 = undefined;
    if (n_u16 == 0 or n_u16 > u16buf.len) return null;
    _ = ImmGetCompositionStringW(himc, GCS_COMPSTR, @ptrCast(&u16buf), @intCast(bytes));
    const n = std.unicode.utf16LeToUtf8(out, u16buf[0..n_u16]) catch return null;
    return out[0..n];
}

// ── Clipboard ───────────────────────────────────────────────────────────────
const HANDLE = ?*anyopaque;
extern "user32" fn OpenClipboard(hwnd: ?HWND) callconv(WINAPI) windows.BOOL;
extern "user32" fn CloseClipboard() callconv(WINAPI) windows.BOOL;
extern "user32" fn EmptyClipboard() callconv(WINAPI) windows.BOOL;
extern "user32" fn SetClipboardData(format: UINT, mem: HANDLE) callconv(WINAPI) HANDLE;
extern "user32" fn GetClipboardData(format: UINT) callconv(WINAPI) HANDLE;
extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(WINAPI) HANDLE;
extern "kernel32" fn GlobalFree(mem: HANDLE) callconv(WINAPI) HANDLE;
extern "kernel32" fn GlobalLock(mem: HANDLE) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(mem: HANDLE) callconv(WINAPI) windows.BOOL;
const CF_UNICODETEXT: UINT = 13;
const GMEM_MOVEABLE: UINT = 0x0002;

/// Copies `text` (UTF-8) to the system clipboard as CF_UNICODETEXT. Returns false
/// on any failure (clipboard busy, OOM, bad UTF-8).
pub fn clipboardSetText(text: []const u8) bool {
    const a = std.heap.page_allocator;
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(a, text) catch return false;
    defer a.free(utf16);

    const bytes = (utf16.len + 1) * 2; // include the NUL terminator
    const mem = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return false;
    {
        const dst: [*]u16 = @ptrCast(@alignCast(GlobalLock(mem) orelse {
            _ = GlobalFree(mem);
            return false;
        }));
        @memcpy(dst[0..utf16.len], utf16[0..utf16.len]);
        dst[utf16.len] = 0;
        _ = GlobalUnlock(mem);
    }

    if (@intFromEnum(OpenClipboard(null)) == 0) {
        _ = GlobalFree(mem);
        return false;
    }
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    if (SetClipboardData(CF_UNICODETEXT, mem) == null) {
        // Ownership only transfers to the OS on success; free on failure.
        _ = GlobalFree(mem);
        return false;
    }
    return true;
}

/// Reads CF_UNICODETEXT from the clipboard as UTF-8 (caller owns the slice), or
/// null if the clipboard has no text / is unavailable.
pub fn clipboardGetText(allocator: std.mem.Allocator) ?[]u8 {
    if (@intFromEnum(OpenClipboard(null)) == 0) return null;
    defer _ = CloseClipboard();

    const mem = GetClipboardData(CF_UNICODETEXT) orelse return null;
    const ptr: [*:0]const u16 = @ptrCast(@alignCast(GlobalLock(mem) orelse return null));
    defer _ = GlobalUnlock(mem);

    const utf16 = std.mem.span(ptr);
    return std.unicode.utf16LeToUtf8Alloc(allocator, utf16) catch null;
}

// ── File dialogs (comdlg32) ─────────────────────────────────────────────────
const OPENFILENAMEW = extern struct {
    lStructSize: u32,
    hwndOwner: ?HWND,
    hInstance: ?HINSTANCE,
    lpstrFilter: ?[*:0]const u16,
    lpstrCustomFilter: ?[*:0]u16,
    nMaxCustFilter: u32,
    nFilterIndex: u32,
    lpstrFile: ?[*:0]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*:0]u16,
    nMaxFileTitle: u32,
    lpstrInitialDir: ?[*:0]const u16,
    lpstrTitle: ?[*:0]const u16,
    Flags: u32,
    nFileOffset: u16,
    nFileExtension: u16,
    lpstrDefExt: ?[*:0]const u16,
    lCustData: LPARAM,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?[*:0]const u16,
    pvReserved: ?*anyopaque,
    dwReserved: u32,
    FlagsEx: u32,
};
extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(WINAPI) windows.BOOL;
extern "comdlg32" fn GetSaveFileNameW(ofn: *OPENFILENAMEW) callconv(WINAPI) windows.BOOL;
const OFN_OVERWRITEPROMPT: u32 = 0x00000002;
const OFN_NOCHANGEDIR: u32 = 0x00000008;
const OFN_PATHMUSTEXIST: u32 = 0x00000800;
const OFN_FILEMUSTEXIST: u32 = 0x00001000;
const OFN_EXPLORER: u32 = 0x00080000;

/// Builds the comdlg32 double-NUL-terminated UTF-16 filter from a UTF-8 pattern
/// like "*.txt" (null → all files). Caller frees.
fn buildFilterW(a: std.mem.Allocator, pattern: ?[]const u8) ?[]u16 {
    const utf8 = if (pattern) |p|
        std.fmt.allocPrint(a, "Files ({s})\x00{s}\x00All Files (*.*)\x00*.*\x00\x00", .{ p, p }) catch return null
    else
        a.dupe(u8, "All Files (*.*)\x00*.*\x00\x00") catch return null;
    defer a.free(utf8);
    return std.unicode.utf8ToUtf16LeAlloc(a, utf8) catch null;
}

fn runFileDialog(
    allocator: std.mem.Allocator,
    owner: ?*anyopaque,
    title: ?[]const u8,
    filter: ?[]const u8,
    default_name: ?[]const u8,
    save: bool,
) ?[]u8 {
    // GetOpenFileNameW/GetSaveFileNameW under OFN_EXPLORER host shell controls
    // (the places bar, the folder-tree view) that need an initialized COM
    // apartment on the calling thread. The folder picker (pickDirectory) does
    // this; the file dialogs did not, so on a fresh worker thread the dialog
    // could come up without its shell chrome or fail outright. S_FALSE (>= 0)
    // means COM was already up — only balance our own successful init.
    const hr_init = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    defer if (hr_init >= 0) CoUninitialize();

    const a = std.heap.page_allocator;
    var file_buf: [4096]u16 = std.mem.zeroes([4096]u16);
    if (default_name) |dn| {
        if (std.unicode.utf8ToUtf16Le(file_buf[0 .. file_buf.len - 1], dn)) |n| {
            file_buf[n] = 0;
        } else |_| {}
    }

    const filter_w = buildFilterW(a, filter);
    defer if (filter_w) |fw| a.free(fw);
    const title_w: ?[:0]u16 = if (title) |t| (std.unicode.utf8ToUtf16LeAllocZ(a, t) catch null) else null;
    defer if (title_w) |tw| a.free(tw);

    var ofn = std.mem.zeroes(OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.hwndOwner = @ptrCast(owner);
    ofn.lpstrFilter = if (filter_w) |fw| @ptrCast(fw.ptr) else null;
    ofn.lpstrFile = @ptrCast(&file_buf);
    ofn.nMaxFile = @intCast(file_buf.len);
    ofn.lpstrTitle = if (title_w) |tw| tw.ptr else null;
    ofn.Flags = OFN_NOCHANGEDIR | OFN_EXPLORER | OFN_PATHMUSTEXIST |
        (if (save) OFN_OVERWRITEPROMPT else OFN_FILEMUSTEXIST);

    const ok = if (save) GetSaveFileNameW(&ofn) else GetOpenFileNameW(&ofn);
    if (@intFromEnum(ok) == 0) return null; // cancelled or error

    const path16 = std.mem.span(@as([*:0]const u16, @ptrCast(&file_buf)));
    return std.unicode.utf16LeToUtf8Alloc(allocator, path16) catch null;
}

pub fn openFileDialog(allocator: std.mem.Allocator, owner: ?*anyopaque, title: ?[]const u8, filter: ?[]const u8) ?[]u8 {
    return runFileDialog(allocator, owner, title, filter, null, false);
}

pub fn saveFileDialog(allocator: std.mem.Allocator, owner: ?*anyopaque, title: ?[]const u8, filter: ?[]const u8, default_name: ?[]const u8) ?[]u8 {
    return runFileDialog(allocator, owner, title, filter, default_name, true);
}

// ── Folder picker (IFileOpenDialog / ole32) ─────────────────────────────────
// comdlg32's GetOpenFileNameW can't pick a *folder*, so the directory picker uses
// the modern Common Item Dialog (IFileOpenDialog with FOS_PICKFOLDERS) — the same
// Explorer chrome as the file dialog. Driven through hand-laid COM vtables since
// Zig has no COM bindings; only the methods we call carry real signatures, the
// rest are opaque slots that keep the vtable offsets correct.
const GUID = extern struct { Data1: u32, Data2: u16, Data3: u16, Data4: [8]u8 };

// CLSID_FileOpenDialog {DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7}
const CLSID_FileOpenDialog = GUID{ .Data1 = 0xDC1C5A9C, .Data2 = 0xE88A, .Data3 = 0x4DDE, .Data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 } };
// IID_IFileOpenDialog {D57C7288-D4AD-4768-BE02-9D969532D960}
const IID_IFileOpenDialog = GUID{ .Data1 = 0xD57C7288, .Data2 = 0xD4AD, .Data3 = 0x4768, .Data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 } };

const FOS_PICKFOLDERS: u32 = 0x00000020;
const FOS_FORCEFILESYSTEM: u32 = 0x00000040;
const SIGDN_FILESYSPATH: u32 = 0x80058000;
const COINIT_APARTMENTTHREADED: u32 = 0x2;
const CLSCTX_INPROC_SERVER: u32 = 0x1;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(WINAPI) i32;
extern "ole32" fn CoUninitialize() callconv(WINAPI) void;
extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*anyopaque, dwClsContext: u32, riid: *const GUID, ppv: *?*anyopaque) callconv(WINAPI) i32;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(WINAPI) void;

const IShellItem = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IShellItem) callconv(WINAPI) u32,
        BindToHandler: *const anyopaque,
        GetParent: *const anyopaque,
        GetDisplayName: *const fn (*IShellItem, u32, *?[*:0]u16) callconv(WINAPI) i32,
        // GetAttributes / Compare omitted — never called.
    };
};

const IFileOpenDialog = extern struct {
    vtbl: *const Vtbl,
    // Layout matches IFileOpenDialog : IFileDialog : IModalWindow : IUnknown.
    // Slots through GetResult (index 20) must stay in order; later methods are
    // dropped because we don't call them.
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IFileOpenDialog) callconv(WINAPI) u32,
        Show: *const fn (*IFileOpenDialog, ?HWND) callconv(WINAPI) i32,
        SetFileTypes: *const anyopaque,
        SetFileTypeIndex: *const anyopaque,
        GetFileTypeIndex: *const anyopaque,
        Advise: *const anyopaque,
        Unadvise: *const anyopaque,
        SetOptions: *const fn (*IFileOpenDialog, u32) callconv(WINAPI) i32,
        GetOptions: *const fn (*IFileOpenDialog, *u32) callconv(WINAPI) i32,
        SetDefaultFolder: *const anyopaque,
        SetFolder: *const anyopaque,
        GetFolder: *const anyopaque,
        GetCurrentSelection: *const anyopaque,
        SetFileName: *const anyopaque,
        GetFileName: *const anyopaque,
        SetTitle: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(WINAPI) i32,
        SetOkButtonLabel: *const anyopaque,
        SetFileNameLabel: *const anyopaque,
        GetResult: *const fn (*IFileOpenDialog, *?*IShellItem) callconv(WINAPI) i32,
    };
};

/// Shows a native folder-selection dialog (IFileOpenDialog + FOS_PICKFOLDERS).
/// Returns the chosen absolute path (UTF-8, caller owns) or null on cancel /
/// failure. `initial_dir` is not wired yet (would need SHCreateItemFromParsingName).
pub fn pickDirectory(allocator: std.mem.Allocator, owner: ?*anyopaque, title: ?[]const u8, initial_dir: ?[]const u8) ?[]u8 {
    _ = initial_dir;
    // COM may already be initialized on this thread (S_FALSE, >= 0); only balance
    // CoUninitialize when our init actually succeeded.
    const hr_init = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    defer if (hr_init >= 0) CoUninitialize();

    var dlg_ptr: ?*anyopaque = null;
    if (CoCreateInstance(&CLSID_FileOpenDialog, null, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, &dlg_ptr) < 0) return null;
    const dlg: *IFileOpenDialog = @ptrCast(@alignCast(dlg_ptr orelse return null));
    defer _ = dlg.vtbl.Release(dlg);

    var opts: u32 = 0;
    if (dlg.vtbl.GetOptions(dlg, &opts) >= 0) {
        _ = dlg.vtbl.SetOptions(dlg, opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
    }

    const a = std.heap.page_allocator;
    if (title) |t| {
        if (std.unicode.utf8ToUtf16LeAllocZ(a, t) catch null) |tw| {
            defer a.free(tw);
            _ = dlg.vtbl.SetTitle(dlg, tw.ptr);
        }
    }

    // HRESULT_FROM_WIN32(ERROR_CANCELLED) is negative → covers user cancel.
    if (dlg.vtbl.Show(dlg, @ptrCast(owner)) < 0) return null;

    var item_ptr: ?*IShellItem = null;
    if (dlg.vtbl.GetResult(dlg, &item_ptr) < 0) return null;
    const item = item_ptr orelse return null;
    defer _ = item.vtbl.Release(item);

    var wpath: ?[*:0]u16 = null;
    if (item.vtbl.GetDisplayName(item, SIGDN_FILESYSPATH, &wpath) < 0) return null;
    const wp = wpath orelse return null;
    defer CoTaskMemFree(@ptrCast(wp));

    return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(wp)) catch null;
}

pub const POINT = extern struct {
    x: i32,
    y: i32,
};
pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};
extern "user32" fn GetWindowRect(hwnd: HWND, lpRect: *RECT) callconv(WINAPI) windows.BOOL;
extern "user32" fn GetWindowLongA(hwnd: HWND, nIndex: i32) callconv(WINAPI) i32;
extern "user32" fn SetWindowLongPtrA(hwnd: HWND, nIndex: i32, dwNewLong: LPARAM) callconv(WINAPI) LPARAM;
extern "user32" fn GetWindowLongPtrA(hwnd: HWND, nIndex: i32) callconv(WINAPI) LPARAM;
extern "uiautomationcore" fn UiaReturnRawElementProvider(hwnd: HWND, wParam: WPARAM, lParam: LPARAM, el: ?*anyopaque) callconv(WINAPI) LRESULT;
extern "user32" fn IsZoomed(hwnd: HWND) callconv(WINAPI) i32;
extern "user32" fn GetSystemMetricsForDpi(index: i32, dpi: UINT) callconv(WINAPI) i32;
extern "user32" fn GetClientRect(hwnd: HWND, lpRect: *RECT) callconv(WINAPI) windows.BOOL;
const SIZE = extern struct { cx: i32, cy: i32 };

/// Physical thickness of the sizing frame at the window's DPI (SM_CXSIZEFRAME +
/// SM_CXPADDEDBORDER) — the invisible border a native window resizes from.
fn resizeFrame(hwnd: HWND) i32 {
    const dpi = GetDpiForWindow(hwnd);
    const d: UINT = if (dpi > 0) dpi else 96;
    return GetSystemMetricsForDpi(32, d) + GetSystemMetricsForDpi(92, d);
}

/// The sizing frame WM_NCCALCSIZE keeps outside the client (left/right/bottom),
/// or 0 when there is none (fixed-size or maximized window).
fn invisibleFrame(hwnd: HWND) i32 {
    const style = GetWindowLongA(hwnd, -16); // GWL_STYLE
    if ((style & 0x00040000) == 0 or IsZoomed(hwnd) != 0) return 0;
    return resizeFrame(hwnd);
}
extern "user32" fn MonitorFromWindow(hwnd: HWND, flags: u32) callconv(WINAPI) HANDLE;
extern "user32" fn GetMonitorInfoA(hmon: HANDLE, lpmi: *MONITORINFO) callconv(WINAPI) i32;

const GWLP_USERDATA: i32 = -21;
const UiaRootObjectId: LPARAM = -25;
const WM_GETOBJECT: UINT = 0x003D;

const MONITORINFO = extern struct {
    cbSize: u32,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: u32,
};
const POINTL = extern struct { x: i32, y: i32 };
/// WM_GETMINMAXINFO payload — we override the maximized size/position so a
/// borderless (WS_POPUP + WM_NCCALCSIZE-stripped) window respects the taskbar.
const MINMAXINFO = extern struct {
    ptReserved: POINTL,
    ptMaxSize: POINTL,
    ptMaxPosition: POINTL,
    ptMinTrackSize: POINTL,
    ptMaxTrackSize: POINTL,
};
extern "user32" fn ScreenToClient(hwnd: HWND, lpPoint: *POINT) callconv(WINAPI) windows.BOOL;
extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(WINAPI) windows.BOOL;
extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(WINAPI) ?HINSTANCE;
extern "user32" fn SetProcessDpiAwarenessContext(value: ?*anyopaque) callconv(WINAPI) windows.BOOL;
extern "user32" fn GetDpiForSystem() callconv(WINAPI) UINT;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(WINAPI) UINT;
extern "user32" fn LoadCursorW(inst: ?HINSTANCE, name: ?*const anyopaque) callconv(WINAPI) ?*anyopaque;
extern "user32" fn SetCursor(cursor: ?*anyopaque) callconv(WINAPI) ?*anyopaque;

/// The cursor the engine wants shown; applied on WM_SETCURSOR so Windows doesn't
/// reset it to the (null) class cursor on every pointer move.
var g_cursor: ?*anyopaque = null;

/// Win32 IME is always available and gated by the focused control; preedit is
/// driven by WM_IME_COMPOSITION. No explicit enable/disable needed here.
pub fn setImeActive(active: bool) void {
    _ = active;
}

pub fn setCursor(cursor: platform.CursorType) void {
    const idc: usize = switch (cursor) {
        .default => 32512, // IDC_ARROW
        .pointer => 32649, // IDC_HAND
        .text => 32513, // IDC_IBEAM
        .resize_ew => 32644, // IDC_SIZEWE
        .resize_ns => 32645, // IDC_SIZENS
    };
    const h = LoadCursorW(null, @ptrFromInt(idc));
    g_cursor = h;
    _ = SetCursor(h);
}

/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4. With this set,
/// Windows reports physical pixels and stops bitmap-stretching the window, so we
/// render crisp at native resolution.
fn perMonitorV2() ?*anyopaque {
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));
}

pub fn getScale(ptr: *anyopaque) f32 {
    const self: *Win32Window = @ptrCast(@alignCast(ptr));
    if (self.hwnd) |hwnd| {
        const dpi = GetDpiForWindow(hwnd);
        if (dpi > 0) return @as(f32, @floatFromInt(dpi)) / 96.0;
    }
    return 1.0;
}

const WNDCLASSEXA = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u8,
    lpszClassName: [*:0]const u8,
    hIconSm: ?*anyopaque,
};
const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: extern struct { x: i32, y: i32 },
    lPrivate: u32,
};

var g_resize_pending: bool = false;
var g_resize_w: u32 = 0;
var g_resize_h: u32 = 0;
var g_resize_hwnd: ?HWND = null;

var g_resize_cb: ?platform.ResizeCallback = null;

pub fn setResizeCallback(cb: platform.ResizeCallback) void {
    g_resize_cb = cb;
}

var g_close_req_cb: ?platform.CloseRequestCallback = null;

pub fn setCloseRequestCallback(cb: platform.CloseRequestCallback) void {
    g_close_req_cb = cb;
}

fn wndProc(hwnd: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT {
    if (msg == WM_GETOBJECT) {
        const ulParam = @as(usize, @bitCast(lp));
        const obj_id = @as(i32, @bitCast(@as(u32, @truncate(ulParam))));
        if (obj_id == @as(i32, @bitCast(@as(u32, @truncate(@as(usize, @bitCast(UiaRootObjectId))))))) {
            const ptr = GetWindowLongPtrA(hwnd, GWLP_USERDATA);
            if (ptr != 0) {
                const win32_win: *Win32Window = @ptrFromInt(@as(usize, @bitCast(ptr)));
                if (win32_win.uia_provider) |provider| {
                    return UiaReturnRawElementProvider(hwnd, wp, lp, provider);
                }
            }
        }
        return DefWindowProcA(hwnd, msg, wp, lp);
    } else if (msg == 0x0010) { // WM_CLOSE
        // A secondary window (overlay) hands the close back to the engine and
        // swallows the message: the engine tears down its component tree and only
        // then destroys the HWND. Without this, Alt+F4 on an overlay would free the
        // window under a live tree. The primary window falls through to
        // DefWindowProc → WM_DESTROY → PostQuitMessage, as before.
        const ptr = GetWindowLongPtrA(hwnd, GWLP_USERDATA);
        if (ptr != 0) {
            const win32_win: *Win32Window = @ptrFromInt(@as(usize, @bitCast(ptr)));
            if (!win32_win.quit_on_close and !win32_win.closing) {
                if (g_close_req_cb) |cb| {
                    cb(.{ .win32 = .{ .hwnd = hwnd, .hinst = null } });
                    return 0;
                }
            }
        }
    } else if (msg == 0x0002) { // WM_DESTROY
        // Only the primary window ends the loop. A secondary window — an
        // overlay bar, a tool palette — is destroyed while the app keeps running,
        // so posting WM_QUIT here would take the whole process down with it.
        var quits = true;
        const ptr = GetWindowLongPtrA(hwnd, GWLP_USERDATA);
        if (ptr != 0) {
            const win32_win: *Win32Window = @ptrFromInt(@as(usize, @bitCast(ptr)));
            quits = win32_win.quit_on_close;
        }
        if (quits) PostQuitMessage(0);
        return 0;
    } else if (msg == 0x0005) { // WM_SIZE
        const ulLParam = @as(usize, @bitCast(lp));
        g_resize_w = @as(u32, @as(u16, @truncate(ulLParam)));
        g_resize_h = @as(u32, @as(u16, @truncate(ulLParam >> 16)));
        g_resize_pending = true;
        g_resize_hwnd = hwnd;
        if (g_resize_cb) |cb| {
            const dpi = GetDpiForWindow(hwnd);
            const scale: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96.0 else 1.0;
            cb(.{ .win32 = .{ .hwnd = hwnd, .hinst = null } }, g_resize_w, g_resize_h, scale);
        }
    } else if (msg == 0x02E4) { // WM_GETDPISCALEDSIZE
        // Sent before WM_DPICHANGED, still at the old DPI. Windows' default scales
        // the whole outer rect linearly, but the sizing frame isn't linear in DPI
        // (8 px at 96, 11 at 144), so the client would drift by a few px. Scale
        // the client instead and re-add the frame at the new DPI.
        const f_old = invisibleFrame(hwnd);
        if (f_old == 0) return 0; // no frame: the linear default is exact
        const old_dpi = GetDpiForWindow(hwnd);
        if (old_dpi == 0) return 0;
        const new_dpi: UINT = @truncate(wp);
        var cr: RECT = undefined;
        if (GetClientRect(hwnd, &cr) == .FALSE) return 0;
        const ratio = @as(f32, @floatFromInt(new_dpi)) / @as(f32, @floatFromInt(old_dpi));
        const f_new = GetSystemMetricsForDpi(32, new_dpi) + GetSystemMetricsForDpi(92, new_dpi);
        const size: *SIZE = @ptrFromInt(@as(usize, @bitCast(lp)));
        size.cx = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(cr.right - cr.left)) * ratio))) + 2 * f_new;
        size.cy = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(cr.bottom - cr.top)) * ratio))) + f_new;
        return 1;
    } else if (msg == 0x02E0) { // WM_DPICHANGED
        // Windows hands us a suggested rect for the new DPI; moving the window to
        // it fires a WM_SIZE that carries the new scale to the resize callback.
        const rect: *const RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, 0x0004 | 0x0010); // SWP_NOZORDER | SWP_NOACTIVATE
        return 0;
    } else if (msg == 0x0024) { // WM_GETMINMAXINFO
        // Borderless windows (WS_POPUP + WM_NCCALCSIZE) otherwise maximize to the
        // full monitor, covering the taskbar. Clamp to the monitor work area.
        if (MonitorFromWindow(hwnd, 0x2)) |hmon| { // MONITOR_DEFAULTTONEAREST
            var mi: MONITORINFO = undefined;
            mi.cbSize = @sizeOf(MONITORINFO);
            if (GetMonitorInfoA(hmon, &mi) != 0) {
                const mmi: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
                mmi.ptMaxPosition.x = mi.rcWork.left - mi.rcMonitor.left;
                mmi.ptMaxPosition.y = mi.rcWork.top - mi.rcMonitor.top;
                mmi.ptMaxSize.x = mi.rcWork.right - mi.rcWork.left;
                mmi.ptMaxSize.y = mi.rcWork.bottom - mi.rcWork.top;
                mmi.ptMaxTrackSize.x = mi.rcWork.right - mi.rcWork.left;
                mmi.ptMaxTrackSize.y = mi.rcWork.bottom - mi.rcWork.top;
                return 0;
            }
        }
    } else if (msg == 0x0083) { // WM_NCCALCSIZE
        // wParam 0 (the first calc, inside CreateWindowEx) passes a bare RECT,
        // wParam 1 a NCCALCSIZE_PARAMS whose first field is that same RECT: handle
        // both, or DefWindowProc frames the first frame (client 2px wide/6px short).
        {
            // No caption: the client starts at the window's top edge. A resizable,
            // restored window keeps its left/right/bottom sizing frame as non-client
            // — DWM draws it invisible (Win10+), so the resize grip sits *outside*
            // the visible window, as in native Windows 11 windows, and content
            // flush with the edge (a scrollbar) never loses clicks to it. Maximized
            // windows have nothing to resize: the client takes the whole rect.
            const f = invisibleFrame(hwnd);
            if (f > 0) {
                const params: *RECT = @ptrFromInt(@as(usize, @bitCast(lp))); // RECT or NCCALCSIZE_PARAMS.rgrc[0]
                params.left += f;
                params.right -= f;
                params.bottom -= f;
            }
            return 0;
        }
    } else if (msg == 0x0084) { // WM_NCHITTEST
        const style = GetWindowLongA(hwnd, -16); // GWL_STYLE
        if ((style & 0x00040000) != 0 and IsZoomed(hwnd) == 0) { // WS_THICKFRAME, restored
            const ulLParam = @as(usize, @bitCast(lp));
            const x: i16 = @bitCast(@as(u16, @truncate(ulLParam)));
            const y: i16 = @bitCast(@as(u16, @truncate(ulLParam >> 16)));

            var rect: RECT = undefined;
            _ = GetWindowRect(hwnd, &rect);

            // Left/right/bottom: exactly the invisible non-client frame (see
            // WM_NCCALCSIZE). Top has no frame outside the client, so the grip
            // there is inside the content — it overlaps the app bar's drag area,
            // not interactive content.
            const border = resizeFrame(hwnd);
            var hit: LRESULT = 1; // HTCLIENT

            const on_left = x < rect.left + border;
            const on_right = x >= rect.right - border;
            const on_top = y < rect.top + border;
            const on_bottom = y >= rect.bottom - border;

            if (on_top and on_left) {
                hit = 13;
            } // HTTOPLEFT
            else if (on_top and on_right) {
                hit = 14;
            } // HTTOPRIGHT
            else if (on_bottom and on_left) {
                hit = 16;
            } // HTBOTTOMLEFT
            else if (on_bottom and on_right) {
                hit = 17;
            } // HTBOTTOMRIGHT
            else if (on_left) {
                hit = 10;
            } // HTLEFT
            else if (on_right) {
                hit = 11;
            } // HTRIGHT
            else if (on_top) {
                hit = 12;
            } // HTTOP
            else if (on_bottom) {
                hit = 15;
            } // HTBOTTOM

            if (hit != 1) return hit;
        }
    } else if (msg == 0x0020) { // WM_SETCURSOR
        const hit: u16 = @truncate(@as(usize, @bitCast(lp)));
        if (hit == 1) { // HTCLIENT — our content area
            if (g_cursor) |c| {
                _ = SetCursor(c);
                return 1; // handled; don't let DefWindowProc reset to the class cursor
            }
        }
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

pub const Win32Window = struct {
    hwnd: ?HWND,
    hinst: ?HINSTANCE,
    /// Owner window (for modal dialogs). Re-enabled on close so input returns to it.
    parent_hwnd: ?HWND = null,
    modal: bool = false,
    uia_provider: ?*anyopaque = null,
    /// See `WindowConfig.quit_on_close` — read by wndProc on WM_DESTROY.
    quit_on_close: bool = true,
    /// Set once the engine has begun tearing this window down, so a WM_CLOSE
    /// arriving mid-teardown isn't handed back to the engine a second time.
    closing: bool = false,

    fn deinit(ptr: *anyopaque) void {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        self.closing = true;
        // Re-enable the owner BEFORE destroying this modal child, so focus returns
        // to it instead of to some unrelated window.
        if (self.modal) {
            if (self.parent_hwnd) |p| {
                _ = EnableWindow(p, @enumFromInt(1));
                _ = SetForegroundWindow(p);
            }
        }
        if (self.hwnd) |hwnd| {
            _ = DestroyWindow(hwnd);
        }
        // The window struct was heap-allocated in initWindow; free it.
        std.heap.page_allocator.destroy(self);
    }

    fn startDrag(ptr: *anyopaque) void {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        if (self.hwnd) |hwnd| {
            var pt: POINT = undefined;
            _ = GetCursorPos(&pt);

            const x16: u16 = @bitCast(@as(i16, @truncate(pt.x)));
            const y16: u16 = @bitCast(@as(i16, @truncate(pt.y)));
            const lparam: LPARAM = @bitCast(@as(usize, @as(u32, x16) | (@as(u32, y16) << 16)));

            _ = ReleaseCapture();
            _ = SendMessageA(hwnd, 0x00A1, 2, lparam); // WM_NCLBUTTONDOWN, HTCAPTION
        }
    }

    fn close(ptr: *anyopaque) void {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        if (self.hwnd) |hwnd| {
            _ = PostMessageA(hwnd, 0x0010, 0, 0); // WM_CLOSE
        }
    }

    fn maximize(ptr: *anyopaque) void {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        if (self.hwnd) |hwnd| {
            // Toggle: restore if already maximized, else maximize.
            if (IsZoomed(hwnd) != 0) {
                _ = ShowWindow(hwnd, 9); // SW_RESTORE
            } else {
                _ = ShowWindow(hwnd, 3); // SW_MAXIMIZE
            }
        }
    }

    fn isMaximized(ptr: *anyopaque) bool {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        if (self.hwnd) |hwnd| return IsZoomed(hwnd) != 0;
        return false;
    }

    fn minimize(ptr: *anyopaque) void {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        if (self.hwnd) |hwnd| {
            _ = ShowWindow(hwnd, 6); // SW_MINIMIZE
        }
    }

    fn setUiaProvider(ptr: *anyopaque, provider: *anyopaque) void {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        self.uia_provider = provider;
    }

    /// Logical px in, physical px out: the caller thinks in the same units as
    /// layout, and this is the one place that knows the window's DPI.
    fn setBounds(ptr: *anyopaque, x: i32, y: i32, w: u32, h: u32) void {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        const hwnd = self.hwnd orelse return;
        const scale = getScale(ptr);
        const px: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(x)) * scale));
        const py: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(y)) * scale));
        const pw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(w)) * scale));
        const ph: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(h)) * scale));
        // NOACTIVATE: repositioning an overlay must not steal focus from whatever
        // the user is actually working in — that's the whole point of a HUD.
        // Bounds are the visible window; the invisible sizing frame goes around it.
        const f = invisibleFrame(hwnd);
        _ = SetWindowPos(hwnd, null, px - f, py, pw + 2 * f, ph + f, SWP_NOZORDER | SWP_NOACTIVATE);
    }

    fn getBounds(ptr: *anyopaque) platform.Rect {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        const hwnd = self.hwnd orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        var rect: RECT = undefined;
        if (GetWindowRect(hwnd, &rect) == .FALSE) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const f = invisibleFrame(hwnd);
        rect.left += f;
        rect.right -= f;
        rect.bottom -= f;
        const scale = getScale(ptr);
        return .{
            .x = @intFromFloat(@round(@as(f32, @floatFromInt(rect.left)) / scale)),
            .y = @intFromFloat(@round(@as(f32, @floatFromInt(rect.top)) / scale)),
            .w = @intFromFloat(@round(@as(f32, @floatFromInt(rect.right - rect.left)) / scale)),
            .h = @intFromFloat(@round(@as(f32, @floatFromInt(rect.bottom - rect.top)) / scale)),
        };
    }

    fn setAlwaysOnTop(ptr: *anyopaque, on: bool) void {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        const hwnd = self.hwnd orelse return;
        _ = SetWindowPos(hwnd, if (on) HWND_TOPMOST else HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    fn setVisible(ptr: *anyopaque, visible: bool) void {
        const self: *Win32Window = @ptrCast(@alignCast(ptr));
        const hwnd = self.hwnd orelse return;
        // SW_SHOWNOACTIVATE (4), not SW_SHOW: same reasoning as setBounds.
        _ = ShowWindow(hwnd, if (visible) 4 else 0); // 0 = SW_HIDE
    }
};

const vtable = platform.PlatformWindow.VTable{
    .deinit = Win32Window.deinit,
    .startDrag = Win32Window.startDrag,
    .close = Win32Window.close,
    .maximize = Win32Window.maximize,
    .minimize = Win32Window.minimize,
    .isMaximized = Win32Window.isMaximized,
    .setUiaProvider = Win32Window.setUiaProvider,
    .setBounds = Win32Window.setBounds,
    .getBounds = Win32Window.getBounds,
    .setAlwaysOnTop = Win32Window.setAlwaysOnTop,
    .setVisible = Win32Window.setVisible,
};

/// SPI_GETWORKAREA — the primary monitor minus the taskbar, in logical px.
pub fn workArea() ?platform.Rect {
    var rect: RECT = undefined;
    if (SystemParametersInfoA(0x0030, 0, @ptrCast(&rect), 0) == .FALSE) return null;
    const dpi = GetDpiForSystem();
    const scale: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96.0 else 1.0;
    return .{
        .x = @intFromFloat(@round(@as(f32, @floatFromInt(rect.left)) / scale)),
        .y = @intFromFloat(@round(@as(f32, @floatFromInt(rect.top)) / scale)),
        .w = @intFromFloat(@round(@as(f32, @floatFromInt(rect.right - rect.left)) / scale)),
        .h = @intFromFloat(@round(@as(f32, @floatFromInt(rect.bottom - rect.top)) / scale)),
    };
}

pub fn initWindow(config: platform.WindowConfig) !platform.PlatformWindow {
    const width = config.width;
    const height = config.height;
    // Per-monitor DPI awareness so Windows reports physical pixels and renders
    // crisp instead of bitmap-stretching. Harmless/ignored if already set.
    _ = SetProcessDpiAwarenessContext(perMonitorV2());
    const sys_dpi = GetDpiForSystem();
    const scale: f32 = if (sys_dpi > 0) @as(f32, @floatFromInt(sys_dpi)) / 96.0 else 1.0;

    const hInst = GetModuleHandleA(null);
    const cls = "CelerisWindow";

    // The owner HWND, if this is a child/modal window.
    const parent_hwnd: ?HWND = if (config.parent) |p| switch (p) {
        .win32 => |w| @ptrCast(w.hwnd),
        else => null,
    } else null;

    // CreateWindowExA needs a NUL-terminated title; copy into a stack buffer
    // (titles are short — truncate rather than allocate).
    var title_buf: [256]u8 = undefined;
    const tn = @min(config.title.len, title_buf.len - 1);
    @memcpy(title_buf[0..tn], config.title[0..tn]);
    title_buf[tn] = 0;
    const title_z: [*:0]const u8 = @ptrCast(&title_buf);

    _ = RegisterClassExA(&WNDCLASSEXA{
        .cbSize = @sizeOf(WNDCLASSEXA),
        .style = 0x0003,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInst,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = cls,
        .hIconSm = null,
    });

    // Create the window at physical size (logical × scale) so the logical content
    // area is width×height regardless of DPI.
    const phys_w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) * scale));
    const phys_h: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * scale));
    const style_flags: u32 = 0x80000000 | (if (config.resizable) @as(u32, 0x00040000) else 0);
    // WM_NCCALCSIZE keeps a sizing frame on the left, right and bottom only (none
    // on top), so the window is the client plus that frame on three sides.
    const frame: i32 = if (config.resizable) blk: {
        const dpi: UINT = @intFromFloat(@round(scale * 96.0));
        break :blk GetSystemMetricsForDpi(32, dpi) + GetSystemMetricsForDpi(92, dpi);
    } else 0;

    const win_w = phys_w + 2 * frame;
    const win_h = phys_h + frame;

    // Requested position is logical; CreateWindowExA wants physical. Null keeps the
    // historical default spot.
    // The outer rect includes the invisible left frame; shift it so the *visible*
    // window lands at x (matching setBounds).
    const pos_x: i32 = (if (config.x) |lx| @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(lx)) * scale))) else 200) - frame;
    const pos_y: i32 = if (config.y) |ly| @intFromFloat(@round(@as(f32, @floatFromInt(ly)) * scale)) else 150;
    // WS_EX_TOPMOST (0x8) at creation rather than a post-hoc SetWindowPos, so an
    // overlay is never painted once below the window it is supposed to float over.
    // WS_EX_NOACTIVATE (0x08000000) keeps a floating bar from stealing focus from
    // the app the user is actually driving.
    const ex_style: u32 = if (config.always_on_top) 0x00000008 | 0x08000000 else 0;

    const hwnd = CreateWindowExA(ex_style, cls, title_z, style_flags, pos_x, pos_y, win_w, win_h, parent_hwnd, null, hInst, null) orelse return error.CreateWindowFailed;

    // Corner rounding and frame border before the first paint, so the window never
    // flashes square or with a mismatched edge.
    applyCornerPreference(hwnd, config.corners);
    _ = applyBorderColor(hwnd, config.border_color);

    if (config.visible) {
        // A topmost overlay shows without activating; the primary window activates
        // as usual (SW_SHOW), or it would come up behind whatever had focus.
        _ = ShowWindow(hwnd, if (config.always_on_top) 4 else 5); // SW_SHOWNOACTIVATE / SW_SHOW
    }

    // Owner-modal: disable the parent so input can't reach it until this closes.
    if (config.modal) {
        if (parent_hwnd) |p| _ = EnableWindow(p, @enumFromInt(0));
    }

    const win32_win = try std.heap.page_allocator.create(Win32Window);
    win32_win.* = Win32Window{
        .hwnd = hwnd,
        .hinst = hInst,
        .parent_hwnd = parent_hwnd,
        .modal = config.modal,
        .quit_on_close = config.quit_on_close,
    };

    _ = SetWindowLongPtrA(hwnd, GWLP_USERDATA, @bitCast(@as(usize, @intFromPtr(win32_win))));

    // Re-query for the window's actual monitor (may differ from the system DPI).
    const win_scale = getScale(win32_win);

    return platform.PlatformWindow{
        .width = width,
        .height = height,
        .scale = win_scale,
        .handle = .{ .win32 = .{ .hwnd = hwnd, .hinst = hInst } },
        .ptr = win32_win,
        .vtable = &vtable,
    };
}

pub fn pollSystemEvents(ctx: ?*anyopaque, input_cb: ?platform.InputCallback) bool {
    // Cheap and idempotent: lets wake() target this thread from workers.
    @atomicStore(u32, &g_ui_thread_id, GetCurrentThreadId(), .release);
    if (g_resize_pending) {
        if (input_cb) |cb| {
            cb(ctx, .{
                .native_handle = .{ .win32 = .{ .hwnd = g_resize_hwnd, .hinst = null } },
                .event_type = .resize,
                .width = g_resize_w,
                .height = g_resize_h,
            });
        }
        g_resize_pending = false;
    }

    var msg: MSG = undefined;
    while (PeekMessageA(&msg, null, 0, 0, 1) != 0) {
        if (msg.message == 0x0012) return false; // WM_QUIT

        if (input_cb) |cb| {
            if (msg.message == 0x0200 or msg.message == 0x0201 or msg.message == 0x0202 or msg.message == 0x0204 or msg.message == 0x0205) {
                const ulParam = @as(usize, @bitCast(msg.lParam));
                const x: f32 = @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(ulParam)))));
                const y: f32 = @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(ulParam >> 16)))));

                const ev_type: platform.InputEventType = switch (msg.message) {
                    0x0201 => .mouse_down,
                    0x0202 => .mouse_up,
                    0x0204 => .right_mouse_down,
                    0x0205 => .right_mouse_up,
                    else => .mouse_move,
                };
                // Mouse capture: capture on button-down so a drag that leaves the
                // window keeps delivering move/up here (slider/sash/scrollbar thumbs);
                // release on button-up. Without this the pointer stops sending
                // WM_MOUSEMOVE once it exits the client area and drags stick.
                if (msg.hwnd) |hwnd| {
                    switch (msg.message) {
                        0x0201, 0x0204 => _ = SetCapture(hwnd),
                        0x0202, 0x0205 => _ = ReleaseCapture(),
                        // Arm leave-tracking on the first move after (re)entry so
                        // the OS posts WM_MOUSELEAVE when the pointer exits the window.
                        0x0200 => if (!g_mouse_leave_armed) {
                            var tme = TRACKMOUSEEVENT{
                                .cbSize = @sizeOf(TRACKMOUSEEVENT),
                                .dwFlags = TME_LEAVE,
                                .hwndTrack = hwnd,
                                .dwHoverTime = 0,
                            };
                            if (@intFromEnum(TrackMouseEvent(&tme)) != 0) g_mouse_leave_armed = true;
                        },
                        else => {},
                    }
                }
                // Pointer events carry the modifier state too (shift-click
                // multi-select, shift-drag marquee), read the same way as for keys.
                const km = keyMods();
                cb(ctx, .{ .native_handle = .{ .win32 = .{ .hwnd = msg.hwnd, .hinst = null } }, .event_type = ev_type, .x = x, .y = y, .shift_held = km.shift, .ctrl_held = km.ctrl, .alt_held = km.alt });
                // NOTE: WM_CAPTURECHANGED (capture stolen by another window/menu) is a
                // SENT message, so PeekMessage never returns it here — synthesizing a
                // drag-ending mouse_up for that rare case needs wndProc plumbing (and
                // care not to double-fire on our own ReleaseCapture). Deferred; the
                // SetCapture/ReleaseCapture pair above already fixes the common
                // pointer-left-the-window stuck-drag.
            } else if (msg.message == 0x0100 or msg.message == 0x0101 or msg.message == 0x0102) {
                const ev_type: platform.InputEventType = switch (msg.message) {
                    0x0100 => .key_down,
                    0x0101 => .key_up,
                    else => .char_input,
                };
                const key_code: u32 = @intCast(msg.wParam);
                const km = keyMods();
                cb(ctx, .{ .native_handle = .{ .win32 = .{ .hwnd = msg.hwnd, .hinst = null } }, .event_type = ev_type, .key_code = key_code, .shift_held = km.shift, .ctrl_held = km.ctrl, .alt_held = km.alt });
            } else if (msg.message == 0x020A or msg.message == 0x020E) { // WM_MOUSEWHEEL / WM_MOUSEHWHEEL
                const ulWParam = @as(usize, @bitCast(msg.wParam));
                const delta: i16 = @bitCast(@as(u16, @truncate(ulWParam >> 16)));
                const notches = @as(f32, @floatFromInt(delta)) / 120.0;

                const ulLParam = @as(usize, @bitCast(msg.lParam));
                var pt = POINT{
                    .x = @as(i32, @as(i16, @bitCast(@as(u16, @truncate(ulLParam))))),
                    .y = @as(i32, @as(i16, @bitCast(@as(u16, @truncate(ulLParam >> 16))))),
                };
                if (msg.hwnd) |hwnd| {
                    _ = ScreenToClient(hwnd, &pt);
                }

                const x: f32 = @floatFromInt(pt.x);
                const y: f32 = @floatFromInt(pt.y);

                // WM_MOUSEHWHEEL tilts carry the delta in the same word but on
                // the horizontal axis (positive = right — matches the engine's dx
                // convention). shift_held lets the engine apply the Shift+wheel →
                // horizontal convention for mice without a tilt wheel.
                const is_horizontal = msg.message == 0x020E;
                const km = keyMods();
                cb(ctx, .{
                    .native_handle = .{ .win32 = .{ .hwnd = msg.hwnd, .hinst = null } },
                    .event_type = .scroll,
                    .x = x,
                    .y = y,
                    .scroll_delta = if (is_horizontal) 0 else notches,
                    .scroll_dx = if (is_horizontal) notches else 0,
                    .shift_held = km.shift,
                    .ctrl_held = km.ctrl,
                    .alt_held = km.alt,
                });
            } else if (msg.message == WM_MOUSELEAVE) {
                // The pointer left the window — tell the engine so it clears
                // hover state (TrackMouseEvent disarmed itself; re-armed on next move).
                g_mouse_leave_armed = false;
                cb(ctx, .{ .native_handle = .{ .win32 = .{ .hwnd = msg.hwnd, .hinst = null } }, .event_type = .mouse_leave });
            } else if (msg.message == 0x010F) { // WM_IME_COMPOSITION
                // Preedit only: the committed result still arrives as WM_CHAR
                // (→ char_input, which inserts UTF-8), so we don't read GCS_RESULTSTR
                // here and avoid double-inserting. We still DispatchMessage below so
                // DefWindowProc produces those WM_CHARs.
                if (msg.hwnd) |hwnd| {
                    const himc = ImmGetContext(hwnd);
                    if (himc != null) {
                        defer _ = ImmReleaseContext(hwnd, himc);
                        var u8buf: [512]u8 = undefined;
                        const lp: usize = @bitCast(msg.lParam);
                        const txt: []const u8 = if (lp & GCS_COMPSTR != 0)
                            (imeCompositionStr(himc, &u8buf) orelse "")
                        else
                            "";
                        cb(ctx, .{ .native_handle = .{ .win32 = .{ .hwnd = hwnd, .hinst = null } }, .event_type = .ime_preedit, .text = txt });
                    }
                }
            } else if (msg.message == 0x010E) { // WM_IME_ENDCOMPOSITION
                cb(ctx, .{ .native_handle = .{ .win32 = .{ .hwnd = msg.hwnd, .hinst = null } }, .event_type = .ime_preedit, .text = "" });
            }
        }
        _ = TranslateMessage(&msg);
        _ = DispatchMessageA(&msg);
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "The DWM border color is byte-swapped into a COLORREF, alpha dropped" {
    // DWMWA_BORDER_COLOR is write-only (reading it returns E_INVALIDARG), so the
    // swizzle is the only part testable without a live window — and it's the part
    // that silently paints the wrong color when it's wrong.
    try std.testing.expectEqual(@as(u32, 0x00563412), colorRefFromArgb(0xFF123456));
    try std.testing.expectEqual(@as(u32, 0x00000000), colorRefFromArgb(0xFF000000));
    try std.testing.expectEqual(@as(u32, 0x00FFFFFF), colorRefFromArgb(0x00FFFFFF));
}
