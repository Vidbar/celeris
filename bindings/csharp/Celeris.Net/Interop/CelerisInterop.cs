using System.Runtime.InteropServices;

namespace Celeris.Interop;

[StructLayout(LayoutKind.Sequential)]
public struct CelerisConfig
{
    [MarshalAs(UnmanagedType.I1)] public bool IsHeadless;
}

public enum CelerisEventType
{
    // Must match CelerisEventType in include/celeris.h, value for value.
    MouseMove = 0, MouseDown, MouseUp, RightMouseDown, RightMouseUp,
    MouseEnter, MouseLeave, GlobalMouseDown, Click, Focus, Blur,
    KeyDown, KeyUp, CharInput, Scroll, Tick, TextComposition, TextCommit,
    Drop, DoubleClick, ScrollH, Resize,
}

[StructLayout(LayoutKind.Sequential)]
public struct CelerisWindowConfig
{
    [MarshalAs(UnmanagedType.I1)] public bool IsHeadless;
    public uint Width;
    public uint Height;
    public int ParentEngineId;
    [MarshalAs(UnmanagedType.I1)] public bool Modal;
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string? Title;
    /// <summary>0 default, 1 square, 2 round, 3 round-small. Windows 11 only.</summary>
    public byte CornerPreference;
    /// <summary>Frame border as 0xAARRGGBB, or 0 for the system default.</summary>
    public uint BorderColor;
    /// <summary>Top-left in logical screen px; read only when HasPosition is set.</summary>
    public int X;
    public int Y;
    [MarshalAs(UnmanagedType.I1)] public bool HasPosition;
    /// <summary>Float above other windows, and create without stealing focus.</summary>
    [MarshalAs(UnmanagedType.I1)] public bool AlwaysOnTop;
    // Negated on purpose: default(CelerisWindowConfig) must mean the behaviour
    // Celeris had before these fields existed.
    [MarshalAs(UnmanagedType.I1)] public bool FixedSize;
    [MarshalAs(UnmanagedType.I1)] public bool StartHidden;
    [MarshalAs(UnmanagedType.I1)] public bool NoQuitOnClose;
}

[StructLayout(LayoutKind.Sequential)]
public struct CelerisEvent
{
    public int EventType;
    public uint NodeId;
    public IntPtr ActionId;
    public float X;
    public float Y;
    public uint KeyCode;
    public float ScrollDelta;
    public IntPtr Text;
    public uint Modifiers;
}

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void CelerisStructuredEventCallback(ref CelerisEvent ev);

internal static class CelerisInterop
{
    private const string Lib = "celeris";

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern uint celeris_abi_version();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_create_engine(ref CelerisConfig config);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_create_window(ref CelerisWindowConfig config);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_deinit(int engineId);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_start_loop();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr celeris_last_error();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_free_string(int engineId, IntPtr str);

    /// <summary>Routine engine diagnostics on stderr. Off by default; CELERIS_LOG also enables them.</summary>
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_set_verbose_logging([MarshalAs(UnmanagedType.I1)] bool on);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_register_event_callback(int engineId, CelerisStructuredEventCallback callback);

    // Imperative node tree
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_node_create(int engineId, uint nodeType);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_node_append_child(int engineId, uint parent, uint child);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_node_remove(int engineId, uint nodeId);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_node_add_layout(int engineId, uint nodeId, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string val);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_node_add_style(int engineId, uint nodeId, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string val);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_node_add_modifier(int engineId, uint nodeId, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string val);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_node_set_text_content(int engineId, uint nodeId, [MarshalAs(UnmanagedType.LPUTF8Str)] string text);

    // Animation (numeric properties only). easing: 0 linear, 1 ease-in, 2 ease-out, 3 ease-in-out, 4 spring.
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_animate_style(int engineId, uint nodeId, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, float from, float to, float durationMs, uint easing);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_animate_layout(int engineId, uint nodeId, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, float from, float to, float durationMs, uint easing);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_cancel_animations(int engineId, uint nodeId);

    // Signals
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_signal_create(int engineId);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_signal_set_f32(int engineId, int handle, float value);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_signal_set_dimension(int engineId, int handle, float value, uint unit);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_signal_set_color(int engineId, int handle, byte r, byte g, byte b, float a);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_signal_bind_style(int engineId, int handle, uint nodeId, [MarshalAs(UnmanagedType.LPUTF8Str)] string key);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_signal_bind_layout(int engineId, int handle, uint nodeId, [MarshalAs(UnmanagedType.LPUTF8Str)] string key);

    // Dialogs
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr celeris_open_file_dialog(int engineId, [MarshalAs(UnmanagedType.LPUTF8Str)] string title, [MarshalAs(UnmanagedType.LPUTF8Str)] string filter);

    // Window Management
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_window_start_drag(int engineId);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_window_close(int engineId);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_window_minimize(int engineId);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_window_maximize(int engineId);

    // Secondary windows. All geometry is logical (DPI-independent) px.
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_window_set_bounds(int engineId, int x, int y, uint w, uint h);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_window_get_bounds(int engineId, out int x, out int y, out uint w, out uint h);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_window_set_always_on_top(int engineId, [MarshalAs(UnmanagedType.I1)] bool on);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_window_set_visible(int engineId, [MarshalAs(UnmanagedType.I1)] bool visible);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr celeris_window_native_handle(int engineId);

    /// <summary>Closes a window from inside an event handler: the engine is freed at
    /// the top of the next loop iteration, not underneath the frame in flight.</summary>
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_window_destroy_deferred(int engineId);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_display_work_area(out int x, out int y, out uint w, out uint h);

    /// <summary>Focus-ring color (RGBA, 0..1) for this window, normally from its
    /// theme. Per window, so two windows on different themes each draw their own.</summary>
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void celeris_set_focus_ring_color(int engineId, float r, float g, float b, float a);

    /// <summary>Registers the app's typefaces for every engine created afterwards,
    /// so the app's typography is identical on every machine instead of whatever the
    /// host font scan turns up. Call BEFORE celeris_create_window — the atlas is
    /// built at engine init and is not re-based. The native side copies the bytes;
    /// pass null to clear back to OS discovery. Returns 0, or -1 on OOM.</summary>
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int celeris_set_app_fonts(ref CelerisFontConfig config);
}

/// <summary>One face: bytes + length, or {IntPtr.Zero, 0} for "not supplied".</summary>
[StructLayout(LayoutKind.Sequential)]
public struct CelerisFontFace
{
    public IntPtr Data;
    public nuint Len;
}

/// <summary>The app's typefaces. A zeroed struct means "discover as before".
/// Only Primary is really needed: the role faces degrade to it when absent.</summary>
[StructLayout(LayoutKind.Sequential)]
public struct CelerisFontConfig
{
    public CelerisFontFace Primary;
    public CelerisFontFace Bold;
    public CelerisFontFace Mono;
    public CelerisFontFace MonoBold;
}
