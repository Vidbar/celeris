# Changelog

Notable changes to Celeris, newest first. Celeris follows semantic versioning for the
package; before 1.0, minor releases (0.x) may contain breaking changes, and every one
is listed here under **BREAKING** together with its replacement.

The C-ABI has its own counter, `CELERIS_ABI_VERSION` in `include/celeris.h`
(compare it with `celeris_abi_version()` at load time). It goes up whenever the
exported surface changes; until 1.0 that can include breaking changes, which are
listed here as well.

## 0.1.1 — 2026-11-04

### Fixed

- Linux: the engine did not compile with Zig 0.16 (`src/platform/linux.zig` used
  `std.Thread.sleep` and `std.posix.write`, both removed in 0.16). 0.1.0 was
  Windows-only in practice; use 0.1.1 on Linux.

## 0.1.0 — 2026-11-03

First public release. Platforms: Windows 10+ (x64) and Linux (x64, Wayland).
Zig 0.16.0. `CELERIS_ABI_VERSION` 4.

### What's in it

- **Zig framework** (`@import("celeris").framework`): retained-mode UI with no
  virtual DOM — fine-grained `Signal`s, components whose `build()` re-runs only when
  a signal they read changes, keyed reconciliation, framework-owned widgets with
  typed handlers, `runApp` for the window and event loop.
- **Widgets:** Button, IconButton, Checkbox, Radio/RadioGroup, Slider, Dropdown,
  TextInput, TextArea (selection, undo/redo, password mode, IME), Tabs, SplitPane,
  ScrollView, TreeView, VirtualList, VirtualGrid, Menu/MenuBar, Dialog, Tooltip,
  Toast, ProgressBar, AppBar/StatusBar/BottomBar, custom window chrome.
- **Layout:** flexbox (grow/shrink with redistribution, basis, min/max, wrap,
  per-axis gaps, align-self, absolute positioning).
- **Rendering:** WebGPU (wgpu-native) with SDF rounded rects, borders (per side,
  dashed), gradients, blurred shadows, vector paths; HarfBuzz text shaping with font
  fallback, UAX#14 line breaking (subset), app-supplied fonts (`AppOptions.fonts`).
- **Platform:** Win32 and Wayland windowing, multiple windows, clipboard, file
  dialogs, drag and drop, cursors, DPI changes, IME.
- **Accessibility (Windows):** a UI Automation provider with roles, names, bounds
  and Invoke / Toggle / Value / ExpandCollapse / SelectionItem patterns, plus focus
  and property-changed events. The accessibility tree is also available as JSON.
- **C-ABI** (`include/celeris.h`, `celeris.dll` / `libceleris.so`): windows, a node
  tree styled with string keys and values (each value is checked against the type
  its key is read as), host-owned signals, animations, typed events, text
  measurement, clipboard and dialogs. `zig build test` compiles and links a C host
  against the header, so the two cannot drift apart.
- **C# binding** (`bindings/csharp`): P/Invoke surface, a small element tree and a
  sample app.
- **Tooling:** DevTools inspector (`zig build devtools`), an opt-in zone profiler
  (`-Dprofiling`, Chrome-trace output), `framework.testkit` for headless widget tests.
- The engine is silent on stderr unless `CELERIS_LOG` is set (or
  `setVerboseLogging(true)` / `celeris_set_verbose_logging(true)`); warnings are
  always printed.

### Known limitations

- No macOS support yet; building for it fails with one explicit error.
- On Linux, accessibility (AT-SPI) is not implemented, and secondary-window
  placement / always-on-top are left to the compositor.
- Margins and paddings are px only (a `%` value is refused by the C-ABI and
  ignored by the solver).
- No transforms (rotate/scale), no subtree opacity, no color emoji, no bidi/RTL.
- The Zig API and the C-ABI may still change before 1.0.
