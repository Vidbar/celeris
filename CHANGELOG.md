# Changelog

Notable changes to Celeris, newest first. Celeris follows semantic versioning for the
package; before 1.0, minor releases (0.x) may contain breaking changes, and every one
is listed here under **BREAKING** together with its replacement.

The C-ABI has its own counter, `CELERIS_ABI_VERSION` in `include/celeris.h`
(compare it with `celeris_abi_version()` at load time). It goes up whenever the
exported surface changes; until 1.0 that can include breaking changes, which are
listed here as well.

## Unreleased

### BREAKING

- Box model: one content box for both axes. A `%` **height** now resolves against
  the parent's content box (height minus vertical padding and borders), the same as
  `%` width already did. Before, a `height(100, .percent)` child of a padded or
  bordered box got the full border-box height and overflowed by padding + border
  (a `SplitPane` with `fill = true` in a box with `padding 6` overflowed 12px).
  If you compensated by hand (subtracting padding from a height), remove it.
- Per-side borders (`borderTop` / `borderRight` / `borderBottom` / `borderLeft`)
  now take layout space like `borderWidth`: the content is inset by that edge
  instead of painting over the line. A box that relied on a child covering its
  border loses that much space on that side. A per-side value overrides
  `borderWidth` for its edge in layout, as it already did when painting.
- Absolute children resolve `%` sizes and `left` / `top` against the parent's
  padding box (inside the border), as in CSS; before, they used the border box.

- Flex grow now honors `min-*` / `max-*` (CSS 9.7): an item that hits a limit
  freezes there and the rest of the free space goes to the other items. Before,
  a growing item ignored its `min-width`/`max-width` (only shrink clamped).

- `overflowHidden` clips to the **padding box** (inside the border), as in CSS;
  it used to clip to the border box, so children could paint over the border.

### Added

- Rounded clipping: `overflowHidden` on a box with `radius` clips its whole
  subtree — backgrounds, text, images, paths — to the rounded padding box
  (radius minus border), antialiased; nested clips intersect (the two innermost
  rounded ones both apply). Hit-testing follows the rounded shape. See
  `overflowHidden` in FRAMEWORK_API.md and `examples/rounded_clip.zig`
  (`scripts/sample_rounded_clip.ps1` checks the corner pixels).
- `SplitPane`: per-pane `PaneCfg` (`.left` / `.right`) with a px `min`,
  VS Code-style snap-collapse (`collapsible`, `collapse_threshold`,
  `collapsed_size`) and a lifted two-way `collapsed: ?*Signal(bool)`. The drag
  policy is the pure, public `split_pane.resolveDrag`. See *SplitPane sizing* in
  FRAMEWORK_API.md.
- `SplitPane`: a `sash_color` with alpha 0 stays invisible on hover (no state
  layer) while still taking hover and drags.
- `examples/dashboard.zig`: collapsible side bar plus a "Side Bar" toolbar toggle.

### Fixed

- Changing a border (`borderWidth` or a side) at runtime now relayouts; it was
  paint-only, so the content box stayed stale until something else relayouted
  (e.g. a text input whose focus border toggles).
- `WindowChrome`: with `divider` on, the caption buttons' hover fill and the drag
  area stop above the 1px divider instead of covering it.

## 0.1.15 — 2026-11-12

### Fixed

- Win32: a resizable window with `window_corners` rounded and a `window_outline`
  showed a 1px white column between DWM's border and the content on the left, right
  and bottom (the non-client carve was 1px wider than DWM's invisible frame). The
  edge is now one continuous 1px line in the outline color on all four sides. While
  DWM draws that border (resizable, restored window), the framework skips its own
  outline and corner radius instead of doubling it; maximized windows get the
  framework outline back. The resize grip still sits entirely outside the content.

### Added

- `celeris_window_native_side_edges(engine_id)` (and the optional
  `PlatformWindow.nativeSideEdges` backend query): 1 while the platform draws the
  window's left/right/bottom edge itself.
- `examples/window_edge.zig` + `scripts/sample_window_edge.ps1`: manual check that
  samples the four window edges and fails on any white pixel.

No BREAKING changes. `CELERIS_ABI_VERSION` 7 (additive).

## 0.1.14 — 2026-11-11

### Added

- `WindowChrome.background` / `foreground` / `divider_color` (`?theme.Color`, null =
  theme roles) and `AppOptions`/`WindowOptions.app_bar_background` /
  `app_bar_foreground` / `app_bar_divider_color`: tint the custom caption without
  overriding theme roles app-wide. The control hover layer mixes from them.
- `WindowChrome.content_fill` / `app_bar_fill`: the caption content gets the whole
  drag area (no spacer) and can center itself across the bar.

### Changed

- The custom caption (`WindowChrome`) now honors the alpha of the theme tokens it
  paints with (`surface_low`, `text_secondary`, and the hover layer), where it used to
  force them opaque. Built-in themes are opaque, so nothing changes for them; a custom
  theme with translucent tokens there now renders the caption translucent.

## 0.1.13 — 2026-11-11

### Added

- `icons.files` (Codicon U+EAF0, the Explorer icon from the VS Code activity bar).

## 0.1.12 — 2026-11-10

### Added

- **`TreeView.on_expand` / `.on_collapse`** (`?events.Handler`) — fired for every
  expand/collapse gesture (caret click, row click with `toggle_on_row_click`, ←/→,
  Enter on a branch) as an event named `"expand"` / `"collapse"` carrying the node
  id in `ev.item_id`.
- **`TreeView.controlled_expansion`** (default `false`) — the widget no longer writes
  `TreeNode.expanded`; it only fires the handlers, and the caller updates `roots`
  (e.g. loading a folder's children lazily) and bumps `data_rev`, which this mode
  requires (asserted in Debug builds). Selection, hover and scroll survive the
  rebuild.
- **`TreeView.on_activate`** (`?events.Handler`) — an `"activate"` event with the
  node id in `ev.item_id`, fired on a double click on a row and on Enter on a leaf
  (where Enter used to do nothing). Enter on a branch still toggles it.
- **`events.Event.item_id: ?usize`** — the item a widget-level event refers to.
  Framework-only; the C-ABI event and `CELERIS_ABI_VERSION` are unchanged.

## 0.1.11 — 2026-11-09

### Added

- **`UIBuilder.noWrap(id)` / `UIBuilder.textWrap(id, bool)`** (style `text_wrap`,
  also `text-wrap` through the style parser) — single-line text, the equivalent of
  CSS `white-space: nowrap`, Compose `Text(softWrap = false)` and Flutter
  `Text(softWrap: false)`. The node is shaped at its natural width whatever width
  it is offered; hard `\n` breaks still apply. It is never shrunk by `flex-shrink`
  nor narrowed by cross-axis stretch below that width (a no-wrap text's automatic
  minimum size is its line), so it overflows a narrower parent instead of
  wrapping. A declared `min-width` (e.g. `0`) replaces that minimum, as in CSS.
- `text.NO_WRAP` — the explicit "no soft wrap" `max_width` for
  `FontAtlas.measureTextMultiline` (0 keeps meaning the same for C-ABI callers).

### Fixed

- Center/right-aligned text whose line is wider than its box now overflows
  towards the end (as in CSS), instead of starting left of the box.

- `Scrollbar` module doc: `.fill = true` is `mountOwned`'s reserved prop, not a
  `Scrollbar` field; the doc now says so and shows the call.

## 0.1.10 — 2026-11-08

### Added

- **`UIBuilder.noFocusRing(id)`** (modifier `no_focus_ring`, also settable through the
  C-ABI as `celeris_node_add_modifier(…, "no_focus_ring", "1")`) — the equivalent of
  CSS `outline: none` / WPF `FocusVisualStyle="{x:Null}"`: the node never paints the
  keyboard focus ring, while focus, Tab order, key routing and UIA focus events stay
  exactly the same. Not inherited. With `virtual_focus_target`, setting it on the
  focused container also hides the ring on the redirected target. Widgets that use it
  must draw their own focus indicator (caret, active cell). `"0"` turns it back off.
- **`VirtualGrid.focus_ring`** (default `true`) — set it to `false` when your cell
  `render` callback paints the active cell, so the focus ring no longer outlines the
  whole viewport. The grid itself never paints the active cell, so the default keeps
  the ring.

### Fixed

- `VirtualGrid`: moving the active cell with the keyboard now re-runs `render` for the
  visible cells. Before, a highlight painted from `.selected` stayed on the first cell
  and only moved when the grid scrolled to a new range.

No BREAKING changes. `CELERIS_ABI_VERSION` unchanged (6).

## 0.1.9 — 2026-11-08

### Added

- **`UIBuilder.capturesTab(id)`** (modifier `captures_tab`, also settable through the
  C-ABI as `celeris_node_add_modifier(…, "captures_tab", "1")`) — while that node is
  focused, plain Tab / Shift+Tab are delivered to its `key_down` handler instead of
  moving focus, so editors and grids can use Tab. Ctrl+Tab, or Escape then Tab, still
  move focus (within the active focus scope); a bare modifier press between Escape
  and Tab keeps that exit open, any other key closes it. Without the modifier, Tab
  behaves exactly as before.
- **`Key.shift` / `ctrl` / `alt` / `meta`** — names for the key codes of a modifier
  pressed on its own (0x10 / 0x11 / 0x12 / 0x5B).

### Changed

- `VirtualGrid` captures Tab: Tab / Shift+Tab now move the focused cell (the handling
  existed but the engine consumed Tab first). Use Ctrl+Tab or Escape then Tab to
  leave the grid.
- Linux: a `key_down` for Shift, Control, Alt or Super pressed alone now carries the
  same code as on Windows (0x10 / 0x11 / 0x12 / 0x5B) instead of 0. Code 0 now means
  only "unmapped key".

No BREAKING changes. `CELERIS_ABI_VERSION` unchanged (6).

## 0.1.8 — 2026-11-06

### Added

- **`ctx.layoutReader()` → `fw.component.LayoutReader`** — read a node's resolved
  geometry from an event handler without touching `celeris.internal`.
  `reader.rect(id)` returns a `MeasuredRect { x, y, w, h }`: the border box in
  window coordinates (the space of `ev.x/y`), with ancestor scroll already applied.
  `reader.toLocal(id, ev.x, ev.y)` converts a pointer to node-local coordinates. They
  are not clamped, so a drag outside the node gives negative or larger-than-size values.
- **`ctx.measuredRect(id)`** — the same rect during `build`, with the same caveats
  as `measuredSize` (one frame stale, not reactive).
- **`MeasuredRect.toLocal` / `contains`.**
- **`fw.testkit.Query.mouseDownAt` / `pointerAt` / `globalPointerAt`** — route
  pointer events at node-local coordinates. `ev.x/y` comes from the solved rect,
  the same way as in production.

### Changed

- `TextInput` and `TextArea` hit-test clicks through `LayoutReader` instead of
  reading the registry directly.
- Docs: `MeasuredSize` is the border box; one code comment wrongly said content box.
  The `FRAMEWORK_API.md` resize example no longer keeps a `BuildContext` past
  `build`, which was invalid. It keeps a `LayoutReader` instead.

No BREAKING changes. `ev.x/y` keep their meaning. `CELERIS_ABI_VERSION` unchanged (6).

## 0.1.7 — 2026-11-06

### Added

- **`TextMeasure.widthStyled` / `widthRole`** — measure text with a font role
  (`.mono`, `.bold`, `.mono_bold`) and letter spacing, using the same face and
  tracking the renderer draws that node with. For a prefix of a line the width is
  the x of the next glyph, so carets and selection bands over `fontMono`/`fontBold`
  or letter-spaced text no longer drift. `TextMeasure.MeasureStyle` carries the
  role and spacing. `width` is unchanged (default face).
- **`TextMeasure.verticalStyled`** — vertical caret/band geometry from a role's
  own face.
- **`fw.component.columnAtXStyled`** — click-to-column for styled text. Measures
  whole prefixes (no accumulated kerning/tracking drift), returns UTF-8 codepoint
  boundaries, and binary-searches (O(log n) measurements). `columnAtX` is unchanged.
- **`fw.testkit.measureStub()`** — a public, role-aware `TextMeasure` for testing
  text widgets without a window: distinct advances per role, per-codepoint
  counting, letter spacing and an "AV" kern.
- `TextMeasure` gains two optional fields, `measureStyledFn` and
  `verticalStyledFn` (default `null`). A handle without them falls back to the
  default face and ignores the style; existing struct literals keep compiling.

No BREAKING changes; `CELERIS_ABI_VERSION` unchanged (6). `TextInput` and
`TextArea` still use `columnAtX`.

## 0.1.6 — 2026-11-06

### Added

- **`fw.events.Key` and `ev.key()`** — named keys for `key_down`/`key_up`
  (`if (ev.key() == .left)`), so widgets don't need key-code numbers. It names
  the virtual-key codes `key_code` already carried: navigation, editing keys,
  `a`–`z`, `0`–`9` and `f1`–`f12`. The enum is non-exhaustive, `Key.fromCode` /
  `key.code()` convert both ways, and `ev.key()` is `null` on non-key events
  (on clicks `key_code` is the click count, on `char_input` a codepoint).
  Modifiers stay in `ev.shift` / `ev.ctrl` / `ev.alt`. Every built-in widget now
  uses it; no widget compares `key_code` against a literal any more.

### Fixed

- **Linux: most keys arrived as `key_code` 0** — only Backspace, Tab, Enter,
  Escape, the arrows and Delete were translated. Home, End, Page Up/Down,
  Insert, Space, letters, digits, F1–F12 and the keypad navigation keys now map
  to the same codes as on Windows. That fixes Home/End in `TextInput`/`TextArea`,
  Home/End/Page Up/Page Down in `VirtualGrid`, Ctrl+A/C/V/X/Z/Y in the text
  widgets, accelerators, and Shift+Tab (`ISO_Left_Tab`) on Linux.

No BREAKING changes; `key_code` numbering and `CELERIS_ABI_VERSION` unchanged (6).

## 0.1.5 — 2026-11-06

### Fixed

- **Scrollbar cursor** — the track and thumb showed the hand cursor (implied by
  `clickable`); they now pin the arrow, as the docs said.
- **Windows: resize border no longer eats edge clicks** — resizable windows keep
  their left/right/bottom sizing frame outside the visible window (invisible, as
  in native Windows 11 windows) instead of an 8 px strip inside the content, so a
  scrollbar flush with the edge gets every click. The top grip stays inside, over
  the caption. The client is now exactly the requested size and position, and `getBounds` /
  `setBounds` describe the visible window, not the invisible frame. Moving
  between monitors of different DPI keeps the client exact (the frame isn't
  linear in DPI, so the window answers `WM_GETDPISCALEDSIZE` itself), and the
  first frame no longer starts a few px off before the first resize.

## 0.1.4 — 2026-11-05

### Added

- **`fw.scrollbar.Scrollbar`** — a standalone scrollbar for views that draw only
  their visible slice (where `ScrollView` can't help). Driven by caller-owned
  `offset` / `content_size` / `viewport_size` signals (`offset` uses the same
  `<= 0` px convention as `ScrollView.offset`, so one signal can be shared).
  Proportional thumb with a minimum length, drag with global follow, track click
  pages one viewport, wheel over the bar, hover/pressed colours, vertical and
  horizontal. Exposed to UI Automation as a ScrollBar with a Thumb child.
  Known limitation: holding the mouse on the track pages once, it does not
  auto-repeat (native scrollbars keep paging until the thumb reaches the pointer).
- **Theme:** `scrollbar_thumb_hover` and `scrollbar_thumb_active` (set in the dark,
  light and seed themes; a theme that leaves them unset falls back to
  `scrollbar_thumb`).

### Changed

- **`ScrollView` uses `Scrollbar`** instead of its private bar. Same API and
  channel width; the bar now also pages on a track click, scrolls on the wheel
  over the bar, and shows hover/pressed colours. With a very long content (20px
  minimum thumb) the thumb now ends flush with the track instead of overrunning
  it. The thumb uses the default arrow cursor (was a pointer hand), as native
  scrollbars do.

## 0.1.3 — 2026-11-05

`CELERIS_ABI_VERSION` 6 (additive).

### BREAKING

- **`TextStyle.line_height` is now `?f32`** (was `f32 = 1.2`, which nothing
  applied). Default `null` = the engine default (1.55). Replacement: code reading it
  as a number writes `style.line_height orelse fw.text.default_line_height`.
- **Theme typography's line height is now applied, so widget labels get shorter.**
  `Text{ .style = … }` and every built-in widget that uses a theme style
  (`Button` → `label_large`, `Checkbox` / `Radio` / `RadioGroup` / `Dropdown` →
  `body_medium`, all 1.42) lay text out at that style's line height. A 14px label
  goes from 21.7px to 19.9px tall. Fixed-height controls stay centered, but
  hug-height rows (dropdown options, radio-group rows, a button without `.height`)
  shrink by about 1.8px. Replacement, to keep the old spacing: for `Button`, pass
  `.text_style = .{ .size = 14, .weight = .medium }` (no `line_height` = default);
  for the others, set `line_height = null` (or 1.55) on `typography.body_medium` /
  `label_large` of the **app theme** (`b.theme`, or `ctx.themeSignal().?.set(...)`),
  not on a widget's own `theme` field, which `build` overwrites; for your own
  `Text`, `.line_height = 1.55`.
- `FontAtlas.measureTextMultilinePref` (reachable through `celeris.internal`)
  takes a `lh_factor` argument before the allocator. Pass
  `text.LINE_HEIGHT_FACTOR` for the old behaviour.
- `TextMeasure.verticalFn` (for hosts that inject their own measure) takes a
  trailing `line_height_factor: f32`.

### Added

- **`line_height` per text node** — a unitless multiplier (CSS `line-height`,
  Flutter `TextStyle.height`): each line slot is `font_size × line_height`.
  Measurement, the renderer, the atlas caret and hit-testing all use it. Set it on
  the text node with `b.lineHeight(id, f)`, `Text{ .line_height = f }`, or the style
  key `"line_height"` from C / C#. Unset keeps 1.55; ≤ 0, NaN or ∞ means default.
- **`fw.text`** — public text metrics: `lineHeight(size)`,
  `lineHeightWith(size, factor)`, `default_line_height`. Size virtualized rows
  from these instead of `celeris.internal.text`.
- **`TextMeasure.lineHeight` / `lineHeightWith` / `verticalWith`** and
  `fw.builder.verticalFallbackWith`, so a widget drawing a caret or a selection
  band over text with a `line_height` gets matching geometry.
- **C ABI:** `celeris_get_caret_metrics_ex` / `celeris_get_char_index_at_ex` take
  the node's line-height factor. The existing functions keep the default.
- **`ctx.onScroll(id, h)` / `ctx.onScrollH(id, h)`** — the raw-builder forms of the
  `on_scroll` / `on_scroll_h` props, matching `ctx.onResize`.

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
