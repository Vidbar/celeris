# Changelog

Notable changes to Celeris, newest first. Celeris follows semantic versioning for the
package; before 1.0, minor releases (0.x) may contain breaking changes, and every one
is listed here under **BREAKING** together with its replacement.

The C-ABI has its own counter, `CELERIS_ABI_VERSION` in `include/celeris.h`
(compare it with `celeris_abi_version()` at load time). It goes up whenever the
exported surface changes; until 1.0 that can include breaking changes, which are
listed here as well.

## Unreleased

### Added

- **`line_height` per text node** — a unitless multiplier (CSS `line-height`,
  Flutter `TextStyle.height`): each line slot is `font_size × line_height`.
  Measurement, the renderer, the caret and hit-testing all use it. Set it with
  `b.lineHeight(id, f)`, `Text{ .line_height = f }`, the box prop `.line_height`,
  or the style key `"line_height"` from C / C#. Unset keeps the old 1.55.
- **`fw.text`** — public text metrics: `lineHeight(size)`,
  `lineHeightWith(size, factor)`, `default_line_height`. Size virtualized rows
  from these instead of `celeris.internal.text`. Also
  `TextMeasure.lineHeight(size)`.
- **`ctx.onScroll(id, h)` / `ctx.onScrollH(id, h)`** — the raw-builder forms of the
  `on_scroll` / `on_scroll_h` props, matching `ctx.onResize`.

### Changed

- **Theme typography's `line_height` is now applied.** `Text{ .style = … }` and
  widgets that take a `text_style` (e.g. `Button`, whose label defaults to
  `label_large`, 1.42) now lay out text at that style's line height instead of
  ignoring it. Single-line labels stay centered; a multi-line label is a little
  shorter. `TextStyle.line_height` is now `?f32` (default `null` = engine default),
  so an ad-hoc `.{ .size = 13 }` style keeps 1.55.
- `FontAtlas.measureTextMultilinePref` (internal) takes the line-height factor.

## 0.1.2 — 2026-11-05

`CELERIS_ABI_VERSION` 5 (additive).

### Added

- **`on_resize`** — a node is told its solved size (`ev.width` / `ev.height`) after
  every frame whose layout changed it, and once after the first solve; the
  equivalent of the web's `ResizeObserver`. Use it as a box prop
  (`.on_resize = ctx.handler(self, f)`) or `ctx.onResize(id, h)` for raw-builder
  nodes. It never runs inside the layout solve. C hosts get
  `CELERIS_EVENT_RESIZE` with the size in `x` / `y`.
- **`VirtualList` / `VirtualGrid` `.fill = true`** — the viewport takes its parent's
  size and tracks it: a bigger window materializes the rows/columns that now fit
  without a scroll. `viewport_height` / `viewport_width` become the frame-0
  estimate.
- `examples/resize_list.zig`.

### Fixed

- `ScrollView` now reacts to resizes: the offset is re-clamped, the thumb resized,
  and the scrollbar appears/disappears when the content stops/starts fitting —
  previously all of that waited for the next wheel event.
- Layout: flex grow/shrink started from a clean sibling's previous post-flex size
  instead of its measured size, so a `grow` item kept its old width when a sibling
  got wider and the line overflowed.

## 0.1.1 — 2026-11-04

### Fixed

- Linux: 0.1.0 did not build on Linux at all, so it was Windows-only in practice;
  use 0.1.1 there. `src/platform/linux.zig` and two examples used std APIs removed
  in Zig 0.16 (`std.Thread.sleep`, `std.posix.write`, `std.os.linux.E.init`), and
  the Windows UI Automation code was linked into `libceleris.so`. Linux is now
  built and tested in CI (Ubuntu 24.04).

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
