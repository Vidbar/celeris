using System;
using System.Runtime.InteropServices;
using Celeris.Interop;
using Celeris.App;
using Celeris.Core;

var app = new CelerisApp("Celeris.NET Code-First");

var clicks = 0;
string[] palette = [
    "rgb(49, 50, 68)",   // base
    "rgb(40, 90, 120)",  // teal
    "rgb(60, 110, 60)",  // green
    "rgb(140, 70, 70)",  // red
    "rgb(90, 70, 130)",  // purple
];
int colorIndex = 0;
const string hoverColor = "rgb(69, 71, 90)";
const string closeHoverColor = "rgb(243, 139, 168)"; // Catppuccin red
bool blockDrag = false;

var root = new Column
{
    Layout = { Width = "100%", Height = "100%" },
    Style = { Background = new Color(30, 30, 46) },
    Children =
    {
        // AppBar
        new Row
        {
            ActionId = "appbar",
            Layout = { FlexDirection = "row", Width = "100%", Height = "32px", JustifyContent = "space-between", AlignItems = "center", PaddingLeft = "16px", PaddingRight = "8px" },
            Style = { Background = new Color(24, 24, 37) }, // Darker crust
            Children =
            {
                new TextElement("Celeris.NET C# App")
                {
                    Style = { Color = new Color(205, 214, 244), FontSize = 16 }
                },
                new Row
                {
                    Layout = { FlexDirection = "row", Width = "104px", Height = "32px", Gap = "4px", AlignItems = "center" },
                    Children =
                    {
                        new Box
                        {
                            ActionId = "appbar_min",
                            Layout = { Width = "32px", Height = "24px", JustifyContent = "center", AlignItems = "center" },
                            Style = { Radius = 4 },
                            Children = { new TextElement("-") { Style = { Color = new Color(255, 255, 255), FontSize = 16 } } }
                        },
                        new Box
                        {
                            ActionId = "appbar_max",
                            Layout = { Width = "32px", Height = "24px", JustifyContent = "center", AlignItems = "center" },
                            Style = { Radius = 4 },
                            Children = { new TextElement("[ ]") { Style = { Color = new Color(255, 255, 255), FontSize = 14 } } }
                        },
                        new Box
                        {
                            ActionId = "appbar_close",
                            Layout = { Width = "32px", Height = "24px", JustifyContent = "center", AlignItems = "center" },
                            Style = { Radius = 4 },
                            Children = { new TextElement("X") { Style = { Color = new Color(255, 255, 255), FontSize = 16 } } }
                        }
                    }
                }
            }
        },
        // Main Content
        new Column
        {
            Layout = { Width = "100%", FlexGrow = "1", JustifyContent = "center", AlignItems = "center", Gap = "16px" },
            Children =
            {
                new Box
                {
                    ActionId = "btn",
                    Layout = { Width = "260px", Height = "80px", JustifyContent = "center", AlignItems = "center" },
                    Style = { Background = new Color(49, 50, 68), Radius = 14, BorderWidth = 2, BorderColor = new Color(137, 180, 250) },
                    Children =
                    {
                        new TextElement("Click me")
                        {
                            Style = { Color = new Color(205, 214, 244), FontSize = 24 }
                        }
                    }
                },
                new Box
                {
                    ActionId = "open_btn",
                    Layout = { Width = "260px", Height = "56px", JustifyContent = "center", AlignItems = "center" },
                    Style = { Background = new Color(40, 90, 120), Radius = 10 },
                    Children =
                    {
                        new TextElement("Open file...")
                        {
                            Style = { Color = new Color(205, 214, 244), FontSize = 18 }
                        }
                    }
                }
            }
        }
    }
};

app.Render(root);

app.OnEvent = (ev) =>
{
    var action = Marshal.PtrToStringUTF8(ev.ActionId) ?? "";
    var type = (CelerisEventType)ev.EventType;

    if (type is not (CelerisEventType.Tick or CelerisEventType.MouseMove))
        Console.WriteLine($"[C# Event] Action: '{action}', Type: {type}, Node: {ev.NodeId}");

    // AppBar Events
    if (action == "appbar_min" || action == "appbar_max" || action == "appbar_close")
    {
        if (type == CelerisEventType.MouseDown) blockDrag = true;
    }

    if (action == "appbar")
    {
        if (type == CelerisEventType.MouseDown)
        {
            if (!blockDrag) app.StartDrag();
            blockDrag = false;
        }
        return;
    }

    if (action == "appbar_min")
    {
        if (type == CelerisEventType.MouseEnter) app.SetStyle(ev.NodeId, "background", hoverColor);
        if (type == CelerisEventType.MouseLeave) app.SetStyle(ev.NodeId, "background", "rgba(0,0,0,0)");
        if (type == CelerisEventType.Click) app.MinimizeWindow();
        return;
    }

    if (action == "appbar_max")
    {
        if (type == CelerisEventType.MouseEnter) app.SetStyle(ev.NodeId, "background", hoverColor);
        if (type == CelerisEventType.MouseLeave) app.SetStyle(ev.NodeId, "background", "rgba(0,0,0,0)");
        if (type == CelerisEventType.Click) app.MaximizeWindow();
        return;
    }

    if (action == "appbar_close")
    {
        if (type == CelerisEventType.MouseEnter) app.SetStyle(ev.NodeId, "background", closeHoverColor);
        if (type == CelerisEventType.MouseLeave) app.SetStyle(ev.NodeId, "background", "rgba(0,0,0,0)");
        if (type == CelerisEventType.Click) app.CloseWindow();
        return;
    }

    // Content Events
    if (action == "open_btn")
    {
        if (type == CelerisEventType.MouseEnter) app.SetStyle(ev.NodeId, "background", hoverColor);
        if (type == CelerisEventType.MouseLeave) app.SetStyle(ev.NodeId, "background", "rgb(40, 90, 120)");
        if (type == CelerisEventType.Click)
        {
            Console.WriteLine("Opening file dialog...");
            var path = app.OpenFileDialog("Select a file", "*");
            Console.WriteLine($"Selected path: {path ?? "none"}");
        }
        return;
    }

    if (action == "btn")
    {
        switch (type)
        {
            case CelerisEventType.MouseEnter:
                app.SetStyle(ev.NodeId, "background", hoverColor);
                break;
            case CelerisEventType.MouseLeave:
                app.SetStyle(ev.NodeId, "background", palette[colorIndex]);
                break;
            case CelerisEventType.Click:
                clicks++;
                colorIndex = clicks % palette.Length;
                app.SetStyle(ev.NodeId, "background", palette[colorIndex]);
                Console.WriteLine($"Clicked {clicks} time(s) — node {ev.NodeId}");
                break;
        }
    }
};

app.Run();
