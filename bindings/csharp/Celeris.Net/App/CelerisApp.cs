using System;
using System.Runtime.InteropServices;
using Celeris.Interop;
using Celeris.Core;

namespace Celeris.App;

public class CelerisApp
{
    private readonly int _engineId;
    private readonly CelerisStructuredEventCallback _eventCallback;
    private GCHandle _callbackHandle;
    private Element? _rootElement;

    public Action<CelerisEvent>? OnEvent { get; set; }

    public CelerisApp(string title = "Celeris")
    {
        var config = new CelerisWindowConfig
        {
            IsHeadless = false,
            Title = title,
            Width = 800,
            Height = 600,
            ParentEngineId = 0,
            Modal = false
        };

        _engineId = CelerisInterop.celeris_create_window(ref config);
        if (_engineId <= 0) throw new CelerisException($"Failed to create the Celeris window: {Native.LastError()}");

        _eventCallback = HandleNativeEvent;
        _callbackHandle = GCHandle.Alloc(_eventCallback);
        CelerisInterop.celeris_register_event_callback(_engineId, _eventCallback);
    }

    public void Render(Element root)
    {
        _rootElement = root;
        _rootElement.Mount(_engineId, uint.MaxValue);
    }

    public void Run()
    {
        CelerisInterop.celeris_start_loop();
        _callbackHandle.Free();
        CelerisInterop.celeris_deinit(_engineId);
    }

    private void HandleNativeEvent(ref CelerisEvent ev)
    {
        OnEvent?.Invoke(ev);
    }

    public void SetStyle(uint nodeId, string key, string value)
    {
        Native.Check(CelerisInterop.celeris_node_add_style(_engineId, nodeId, key, value), $"style {key}={value}");
    }

    public void StartDrag()
    {
        CelerisInterop.celeris_window_start_drag(_engineId);
    }

    public void CloseWindow()
    {
        CelerisInterop.celeris_window_close(_engineId);
    }

    public void MinimizeWindow()
    {
        CelerisInterop.celeris_window_minimize(_engineId);
    }

    public void MaximizeWindow()
    {
        CelerisInterop.celeris_window_maximize(_engineId);
    }

    /// <summary>Animates a numeric style property (opacity, radius, …).</summary>
    public void AnimateStyle(uint nodeId, string key, float from, float to, float durationMs, uint easing = 0)
    {
        Native.Check(CelerisInterop.celeris_animate_style(_engineId, nodeId, key, from, to, durationMs, easing), $"animate_style {key}");
    }

    /// <summary>Returns the chosen path, or null if the user cancelled.</summary>
    public string? OpenFileDialog(string title = "Open File", string filter = "*")
    {
        var ptr = CelerisInterop.celeris_open_file_dialog(_engineId, title, filter);
        if (ptr == IntPtr.Zero) return null;
        try { return Marshal.PtrToStringUTF8(ptr); }
        finally { CelerisInterop.celeris_free_string(_engineId, ptr); }
    }
}
