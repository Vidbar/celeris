# Celeris.Net — C# bindings

Drive a native Celeris window entirely from C#, over the C-ABI in
[`include/celeris.h`](../../include/celeris.h). No Zig in the application.

- `Celeris.Net/` — the binding library:
  - `Interop/CelerisInterop.cs` — the P/Invoke surface (mirrors `celeris.h`).
  - `Interop/Native.cs` — `Native.Check`, which turns a native `-1` into a
    `CelerisException` carrying `celeris_last_error()`.
  - `Core/` — a small element tree (`Box`, `Row`, `Column`, `TextElement`) with
    `Style` and `Layout` objects.
  - `App/CelerisApp.cs` — window, event loop, and event callback.
- `HelloCeleris/` — a sample app: a custom title bar (drag, minimize, maximize,
  close) and a button that reacts to hover and cycles its colour on click.

## Prerequisites

- Windows x64 (the bindings are not packaged for Linux yet, although the same
  C-ABI is exported there as `libceleris.so`).
- .NET SDK 9 or newer.
- Zig 0.16.0, to build the native library.

## Run the sample

```bash
zig build
```

```bash
cd bindings/csharp/HelloCeleris
dotnet run
```

`zig build` (from the repo root) produces `zig-out/bin/celeris.dll` and
`wgpu_native.dll`. `Celeris.Net.csproj` copies both next to your executable.

## Using it in your own project

Celeris.Net is not on NuGet yet; reference it from a checkout in which you have run
`zig build` (its `.csproj` copies `celeris.dll` and `wgpu_native.dll` from that
checkout's `zig-out/bin`). The native library is x64, so target x64:

```bash
dotnet new console -o MyApp
```

```bash
dotnet add MyApp reference path/to/celeris/bindings/csharp/Celeris.Net/Celeris.Net.csproj
```

and in `MyApp.csproj` add `<PlatformTarget>x64</PlatformTarget>` to the
`<PropertyGroup>`. Then `Program.cs`:

```csharp
using Celeris.App;
using Celeris.Core;

var app = new CelerisApp("My App");
app.Render(new Column
{
    Layout = { Width = "100%", Height = "100%", JustifyContent = "center", AlignItems = "center" },
    Style = { Background = new Color(30, 30, 46) },
    Children = { new TextElement("Hello") { Style = { Color = Color.White, FontSize = 18 } } },
});
app.OnEvent = ev => { /* ev.EventType is a CelerisEventType */ };
app.Run();
```

- **The first element rendered is the window's root.**
- Style and layout values use the C-ABI syntax: colors `#rrggbb` / `rgb()` /
  `rgba()`; lengths `12px` (plus `50%` where it resolves, and `auto` / `fill` for
  width and height); keywords such as `row` or `space-between`. See the comment above `celeris_node_add_style` in the header.
- Any call the engine rejects (unknown key, or a value the key cannot use) throws
  `CelerisException` with the engine's reason.
- Keep the event callback delegate alive for as long as the loop runs.
  `CelerisApp` does this for you; if you call `celeris_register_event_callback`
  yourself, hold a reference (or a `GCHandle`) or the GC will free it while
  native code still calls into it.

## Publish

```bash
dotnet publish -c Release --self-contained
```

This produces a folder under `bin/Release/<target framework>/win-x64/publish/` with the
executable, `celeris.dll` and `wgpu_native.dll`, runnable without a .NET install.
Drop `--self-contained` for a smaller, framework-dependent build.
