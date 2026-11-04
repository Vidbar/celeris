using System.Globalization;
using Celeris.Interop;

namespace Celeris.Core;

public struct Color
{
    public byte R { get; }
    public byte G { get; }
    public byte B { get; }
    public byte A { get; }

    public Color(byte r, byte g, byte b, byte a = 255)
    {
        R = r;
        G = g;
        B = b;
        A = a;
    }

    // Invariant culture: a comma decimal separator (es-ES, de-DE, …) would make
    // the alpha unparsable on the native side.
    public override string ToString() =>
        A == 255 ? $"rgb({R}, {G}, {B})" : string.Create(CultureInfo.InvariantCulture, $"rgba({R}, {G}, {B}, {A / 255f:0.###})");

    public static Color White => new(255, 255, 255);
    public static Color Black => new(0, 0, 0);
}

public class Style
{
    public Color? Background { get; set; }
    public Color? Color { get; set; }
    public float? FontSize { get; set; }
    public float? Radius { get; set; }
    public float? BorderWidth { get; set; }
    public Color? BorderColor { get; set; }

    private static string Px(float v) => string.Create(CultureInfo.InvariantCulture, $"{v}px");

    private static void Set(int engineId, uint nodeId, string key, string value) =>
        Native.Check(CelerisInterop.celeris_node_add_style(engineId, nodeId, key, value), $"style {key}={value}");

    internal void Apply(int engineId, uint nodeId)
    {
        if (Background.HasValue) Set(engineId, nodeId, "background", Background.Value.ToString());
        if (Color.HasValue) Set(engineId, nodeId, "color", Color.Value.ToString());
        if (FontSize.HasValue) Set(engineId, nodeId, "font_size", Px(FontSize.Value));
        if (Radius.HasValue) Set(engineId, nodeId, "radius", Px(Radius.Value));
        if (BorderWidth.HasValue) Set(engineId, nodeId, "border_width", Px(BorderWidth.Value));
        if (BorderColor.HasValue) Set(engineId, nodeId, "border_color", BorderColor.Value.ToString());
    }
}

public class Layout
{
    public string? Width { get; set; }
    public string? Height { get; set; }
    public string? FlexDirection { get; set; }
    public string? JustifyContent { get; set; }
    public string? AlignItems { get; set; }
    public string? Gap { get; set; }
    public string? PaddingLeft { get; set; }
    public string? PaddingRight { get; set; }
    public string? FlexGrow { get; set; }

    private static void Set(int engineId, uint nodeId, string key, string value) =>
        Native.Check(CelerisInterop.celeris_node_add_layout(engineId, nodeId, key, value), $"layout {key}={value}");

    internal void Apply(int engineId, uint nodeId)
    {
        if (Width != null) Set(engineId, nodeId, "width", Width);
        if (Height != null) Set(engineId, nodeId, "height", Height);
        if (FlexDirection != null) Set(engineId, nodeId, "flex_direction", FlexDirection);
        if (JustifyContent != null) Set(engineId, nodeId, "justify_content", JustifyContent);
        if (AlignItems != null) Set(engineId, nodeId, "align_items", AlignItems);
        if (Gap != null) Set(engineId, nodeId, "gap", Gap);
        if (PaddingLeft != null) Set(engineId, nodeId, "padding_left", PaddingLeft);
        if (PaddingRight != null) Set(engineId, nodeId, "padding_right", PaddingRight);
        if (FlexGrow != null) Set(engineId, nodeId, "flex_grow", FlexGrow);
    }
}
