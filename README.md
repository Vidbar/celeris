# Celeris Engine

[![CI](https://github.com/Vidbar/celeris/actions/workflows/ci.yml/badge.svg)](https://github.com/Vidbar/celeris/actions/workflows/ci.yml)

Celeris is a native, GPU-rendered UI engine for desktop apps, written in Zig, for
Windows and Linux (Wayland). Apps are built with its Zig framework or, from other
languages, through a C-ABI — no browser engine involved. The long-term goal is a
lightweight alternative to Electron-class stacks; today it is an early 0.x release.
Host bindings: **C# (.NET)** via `Celeris.Net` ([`bindings/csharp/`](bindings/csharp/)).
Any other language can use the C header directly.

## Status

**0.1.1 — early, usable, pre-1.0.** The retained-mode core (**no virtual DOM**:
granular dirty-tracking, keyed reconciliation, fine-grained signals) and the
reactive framework on top of it are feature-complete for desktop apps and covered
by a ~470-test suite. Windows is the primary platform; Linux (Wayland) is
supported and built in CI. The Zig API and the C-ABI may still change before 1.0;
breaking changes are listed in [CHANGELOG.md](CHANGELOG.md).

Writing UI, in short (full compiled example in
[docs/FRAMEWORK_API.md](docs/FRAMEWORK_API.md)):

- State lives in `Signal`s. A component's `build()` re-runs automatically — only
  that component, with node reuse — when a signal it read changes. No
  `triggerRebuild`, no manual `register`, no string action-ids.
- Widgets are framework-owned:
  `ctx.mountOwned(Button, .{ .label = "OK", .on_click = ctx.handler(self, onOk) })`
  — the framework allocates, reuses and frees the instance; handlers are typed.
- Background threads publish by writing signals; the loop wakes and repaints the
  bound nodes.

Implemented today, natively in Zig:

- **Reactive declarative framework:** `UI = f(state)` with three reconciliation
  levels (fine signal bindings, per-component build-effects with glitch-free
  height-ordered propagation, manual partial rebuild as escape hatch);
  comptime-resolved components; keyed reconciliation; automatic mount/unmount.
- **Widget suite (20+):** Button, IconButton, Checkbox, Radio, RadioGroup,
  Slider, Dropdown, TextInput, TextArea (selection, undo/redo, password, IME),
  Tabs, SplitPane, ScrollView, TreeView, VirtualList (10k+ items, dozens of live
  nodes), Menu/MenuBar, Dialog, Tooltip, Toast, ProgressBar,
  AppBar/StatusBar/BottomBar.
- **Focus & keyboard:** every widget focusable and keyboard-operable (Tab order,
  Enter/Space/arrows), rendered focus ring, focus scopes that trap and restore
  (modals/menus), engine-level accelerator table.
- **Theming:** semantic tokens with dark/light presets, switched at runtime via a
  reactive `Signal(Theme)`.
- **WebGPU rendering (SDF):** rounded corners, gradients, opacity, box-shadows;
  buffers grow on demand; event-driven loop: no frames are rendered while the UI
  is idle (check with `CELERIS_PROFILE=1`, which prints renders/s); scroll as a
  render offset, no re-layout.
- **Text stack:** HarfBuzz shaping with per-node glyph cache, font-stack fallback
  (CJK), fontconfig discovery on Linux, pixel-exact caret, UAX#14 line breaking
  (subset), IME (Win32 + Wayland `zwp_text_input_v3`).
- **Flexbox layout:** CSS-correct grow/shrink (weighted freeze + redistribute),
  `flex-basis`, min sizes, wrap, per-axis gaps, `align-self`, `space-evenly`.
- **Desktop platform:** Win32 + Wayland windowing (parity; X11 out by design),
  clipboard, file dialogs, cursors, runtime DPI, drag & drop, mouse capture.
- **Secondary windows:** each gets its own component tree, layout pass, render
  loop and event router; opening/closing one never unmounts another. Per-window
  always-on-top, caption-less chrome, anchored placement, runtime
  move/resize/hide, and `OverlayWindow` to bind a window to a signal. (Placement
  and always-on-top are Win32 only; on Wayland the compositor owns both.)
- **Accessibility (Windows):** a real UI Automation provider. Inspect.exe,
  NVDA/Narrator and UIA drivers see a native control tree with correct roles,
  names and bounds — and can drive it: Invoke, Toggle, Value, ExpandCollapse and
  SelectionItem are derived from a node's semantic role with no per-widget
  wiring, each executing the real user input path. Focus- and property-changed
  events are raised from a single funnel. The semantic tree also crosses the
  C-ABI (`celeris_get_accessibility_json`); Linux AT-SPI is the remaining bridge.
- **DevTools / Inspector:** a separate app that inspects a running engine's live tree over the C-API (`zig build devtools`).

## Documentation

1. **[docs/FRAMEWORK_API.md](docs/FRAMEWORK_API.md)** — how to build apps: the
   canonical counter (compiled in CI so it cannot drift), widgets, typed
   handlers, signals/bindings, theming.
2. **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — why the engine is shaped
   this way: declarative *vs* reactive and their junction, the no-VDOM decision,
   the three-level reconciliation model, component/lifecycle/event design, C-ABI
   strategy, verification commands, deferred work.

## Using Celeris from another Zig project

Requirements: Zig 0.16.0, x86_64 Windows 10+ or Linux (Wayland). On Linux you
also need `wayland-client`, `wayland-cursor`, `xkbcommon`, `libdecor-0`,
`wayland-protocols` and `wayland-scanner` from your distro. macOS is not
supported yet. The API is pre-1.0 and may change between minor versions.

Add the dependency to `build.zig.zon`:

```bash
zig fetch --save=celeris https://github.com/Vidbar/celeris/archive/refs/tags/v0.1.1.tar.gz
```

A complete `build.zig`:

```zig
const std = @import("std");
const celeris_build = @import("celeris"); // Celeris' build.zig

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const celeris = b.dependency("celeris", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("celeris", celeris.module("celeris"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the app").dependOn(&run.step);
    // Installs wgpu_native.dll / libwgpu_native.so next to your exe and puts it
    // on the run step's PATH.
    celeris_build.addRuntimeDeps(b, celeris, exe, run);
}
```

Without this call, Windows builds fail at startup with a missing
`wgpu_native.dll`. `addRuntimeDeps` owns the vendored paths, so consumers never
reference `vendor/wgpu-native/...` directly.

In your code, `@import("celeris").framework` is the API (`const fw = @import("celeris").framework;`).
`@import("celeris").c_api` exposes the C-ABI functions to Zig, and
`@import("celeris").internal` the engine's own modules — unstable, for tooling.

The engine is silent on stderr by default. Set `CELERIS_LOG=1` (or call
`fw.setVerboseLogging(true)`) to see font discovery and engine init diagnostics;
warnings about real problems are always printed.

## Using Celeris from C, C# or another language

`zig build` produces the shared library (`zig-out/bin/celeris.dll` on Windows,
`libceleris.so` on Linux) plus [`include/celeris.h`](include/celeris.h). The
header documents every call; in short, a host creates a window, builds a node
tree, styles it with string keys and values, and receives typed events:

```c
static void on_event(const CelerisEvent *ev) {      // your event handler
    (void)ev;                                           // ev->event_type, ev->node_id, …
}

// in main():
CelerisWindowConfig cfg = { .width = 800, .height = 600, .title = "Hello" };
int32_t e = celeris_create_window(&cfg);
uint32_t root = (uint32_t)celeris_node_create(e, 0);          // first node = root
uint32_t text = (uint32_t)celeris_node_create(e, 1);
celeris_node_append_child(e, root, text);
celeris_node_set_text_content(e, text, "Hello from C");
celeris_node_add_style(e, root, "background", "#1e1e1e");
celeris_node_add_style(e, text, "color", "#ffffff");
celeris_node_add_layout(e, root, "justify-content", "center");
celeris_register_event_callback(e, on_event);
celeris_start_loop();
```

Link against `zig-out/lib/celeris.lib` (Windows) or `libceleris.so` (Linux), and ship
`celeris.dll` and `wgpu_native.dll` (or the `.so` files) next to your executable.
[`examples/c_smoke.c`](examples/c_smoke.c) is a complete C host (built and run by
`zig build test`). For .NET, see [`bindings/csharp/`](bindings/csharp/).

## Examples

```bash
zig build dashboard      # component-model showcase (all widgets, reactive)
zig build counter        # the docs' Quick Start, verbatim
zig build devtools       # DevTools inspector, inspecting another engine
zig build overlay_bar    # always-on-top 460x56 bar with its own tree
zig build headless       # C-API smoke test, no GPU window (CI-runnable)
zig build test           # unit tests
```

## License

Celeris is released under the [MIT License](LICENSE). It vendors HarfBuzz,
wgpu-native, stb and the Codicons font under their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for what apps built with
Celeris need to include when they ship.
