# Changelog

Notable changes to Celeris, newest first. Celeris follows semantic versioning for the
package; before 1.0, minor releases (0.x) may contain breaking changes, and every one
is listed here under **BREAKING** together with its replacement.

The C-ABI has its own counter, `CELERIS_ABI_VERSION` in `include/celeris.h`
(compare it with `celeris_abi_version()` at load time). It goes up whenever the
exported surface changes; until 1.0 that can include breaking changes, which are
listed here as well.

## Unreleased

No C-ABI change.

- **`Dropdown`: lifted selection, index in `on_change`, configurable size.**
  `.selected: ?*Signal(usize)` follows the lifted-state convention (`Tabs.active`):
  the app can write it at any time and the trigger follows without a rebuild; a
  user pick writes it back. Without it, the internal state is seeded from
  `.initial_selected`. The shown index is clamped to the options. New `.width`
  (default 150; `null` = fit the widest option, so the menu rows fit and the
  trigger keeps one width), `.height` (default 32, also sizes the
  option rows, min 24) and `.font_size` (default: the theme's `body_medium`); the menu docks under the
  trigger at any height.
- **BREAKING: `Dropdown.on_change` event.** It now fires only when a user pick
  changes the selection (re-picking the current option no longer fires), with
  `ev.name = "change"`, `ev.item_id` = the new index and `ev.node_id` = the
  trigger. Before, it forwarded the raw click/key event with no index. The
  internal `selected` field is now `selected_state`; read the selection through
  your own `.selected` signal.
- **`Menu`: radio items, headers, anchored popup.** `addRadio(label, id, &group,
  value)` binds a row to a caller-owned `Signal(usize)` (bullet shown live,
  choosing writes the group, then `on_select`). `addHeader(label)` adds a
  non-selectable group title (`MenuItemKind.header`). `popupBelow(node, gap,
  origin)` opens the menu under a node's resolved geometry.
- **Docs and example:** recipe "Selector with actions" (Button + Menu with radio
  items, a separator and command rows) in `docs/FRAMEWORK_API.md`, for pickers
  that also run commands such as "Edit Configurations…". Runnable as
  `zig build selector_actions` (`examples/selector_actions.zig`).

## 0.11.1 — 2026-11-24

No C-ABI change.

- **Fix: `100%` children of a box held at its `min_width`/`min_height`.** When a
  flex item's size came from its minimum (a `SplitPane` pane whose ratio share is
  below `min`), its percentage-sized children — including a `mountReactiveFill`
  anchor — resolved to 0 instead of the clamped size. Layout now re-measures the
  children of a box its minimum enlarged.

## 0.11.0 — 2026-11-24

No C-ABI change.

- **Hinted text on Windows (DirectWrite).** Glyphs are now rasterized by
  DirectWrite with grid fitting (`gdi_natural` mode, grayscale antialiasing)
  instead of stb_truetype, so 12–13 px UI text has vertical stems on whole pixels,
  as in VS Code and other native Windows apps. Only each glyph's pixels change:
  HarfBuzz shaping, advances, measurement and layout are untouched, so no widths
  move. The `dwrite` library is now linked on Windows. `CELERIS_TEXT_RASTERIZER`
  (`stb`, `gdi_natural`, `gdi_classic`, `natural_symmetric`) selects the rasterizer
  at startup, and `FontAtlas.setRasterizer` / `.rasterizer()` change and query it
  at runtime. A font DirectWrite rejects, or any DirectWrite error, falls back to
  stb for that glyph. Linux keeps stb_truetype.

- Small text reads fuller: the text shader lifts antialiased glyph edges with
  DirectWrite's "enhanced contrast" curve, `c(k+1)/(ck+1)`, with `k` scaled by
  the text color's luminance (`text.TEXT_CONTRAST_DARK`/`_LIGHT`, mirrored by
  `text.textCoverage`). Light text on dark backgrounds, which the gamma-space blend
  made thin and washed out, gains the most; full and zero coverage are unchanged.
- **BREAKING (Zig, minor):** `text.REF_PX` is removed. It was a leftover from an earlier
  renderer: glyphs have long been rasterized at their exact device-pixel size
  (font size × DPI scale), cached per size, and placed on whole pixels with a 1:1 atlas
  sample — not a 64 px bitmap minified per draw. Nothing read it. The stale comments
  that described the old path are corrected.
- New `text.glyphQuadPhys`: the pixel-snapped glyph quad placement, factored out of the
  backend, plus a test pinning that 12–13 px text at 100% and 150% is rasterized at
  `round(size × scale)` and lands on whole pixels.

## 0.10.0 — 2026-11-23

No C-ABI change.

### Added

- **TreeView columns.** `TreeView.columns` (`[]const fw.Column`) draws rows as
  Name | Value | Type: column 0 holds the indent, caret, icon and name, and
  `TreeNode.cells` fills the others (one line each, clipped, with an optional
  per-cell `color`). Without `columns` a tree is unchanged.
- **`fw.ColumnHeader`**: the column titles, with a drag grip at each right edge
  that resizes the column (resize cursor, clamped to `min_width`). Widths are
  caller-owned `Signal(f32)`s shared with the tree, applied render-only while
  dragging. `on_column_resize` fires on release. A `stretch` column fills the
  rest of the view.
- **Two-axis `ScrollView`**: `offset_x` + `content_width` turn on horizontal
  scrolling (horizontal wheel, Shift+wheel, and a bottom scrollbar while the
  content is wider than the view). `TreeView.content_width` publishes the column
  total for it, and `ColumnHeader.scroll_x` keeps the header aligned.
- Header colors in `theme.list`: `header_bg`, `header_text`, `header_separator`.
- `TreeView.findNode` is public, for controlled-expansion handlers.
- `examples/debugger_variables.zig`: a Variables view with lazy branches.

### Docs

- Lazy branches are documented: a childless `.branch` shows its caret and fires
  "expand"; set it to `.leaf` if loading finds nothing.

## 0.9.3 — 2026-11-23

No C-ABI change.

### Fixed

- **A handler a rebuild no longer passes is really gone.** A reused node kept its
  old router entries (`on_click`, `on_hover*`, `on_press`, `on_mouse_*`, `on_key`,
  …) when the rebuild passed `null` or dropped the prop. The node lost its hit
  modifier, so a plain disabled button stayed inert, but any other prop that made
  the node hit-testable again (a `.tooltip` makes it hoverable) brought the stale
  handler back. Reuse now drops the node's handlers along with its props, and a
  null `on_resize` stops reporting to the old receiver.

## 0.9.2 — 2026-11-21

No C-ABI change.

### Added

- **Debugger icons in `fw.icons`:** `debug_continue`, `debug_step_over`,
  `debug_step_into`, `debug_step_out` and `debug_restart` (codicons EACF, EAD6,
  EAD4, EAD5, EAD2), for an IDE's debug toolbar.

## 0.9.1 — 2026-11-19

No C-ABI change.

### Added

- **Punctuation keys in `events.Key`:** `backquote minus equal bracket_left
  bracket_right backslash semicolon quote comma period slash`, with the Windows
  `VK_OEM_*` codes, so accelerators like Ctrl+` / Ctrl+/ / Ctrl+= no longer need
  hand-written VK numbers. Linux maps the US keysyms onto the same codes,
  naming each key by its unshifted keysym: German Shift+7 stays `7`, the AZERTY
  `-`/`6` key is `6`. On Windows the code follows the
  layout's VK, so Spanish Ctrl+Ñ (`VK_OEM_3`) matches `backquote`.

## 0.9.0 — 2026-11-18

No C-ABI change.

### Added

- **Alt chords on Windows**, `b.capturesAltKeys(id)` (`ModifierKey.captures_alt`):
  while that node holds focus, Alt+key arrives as `key_down` with `ev.alt` instead
  of going to the system, so terminals get Alt+B / Alt+F / Alt+Backspace. Alt+F4,
  Alt+Space and a bare Alt tap stay with the system. Linux already delivered them.
- **Programmatic focus**, `ctx.requestFocus(id)` and `ctx.focusRequester()`
  (`FocusRequester.focus`): the DOM's `element.focus()`. Refused for nodes that
  are not focusable, disabled or outside an open modal scope; a node built in the
  same pass is focused after the next layout.
- **UIA `document` role**: `b.role(id, "document")` now maps to UIA's Document
  control type (it was reported as Group), for read-only text surfaces such as
  terminals and log views.

## 0.8.0 — 2026-11-18

C-ABI v10: adds `celeris_set_app_italic_fonts` and the `text_decoration`,
`text_decoration_color` and `text_faint` style keys; `font_role` takes 0..7. No
BREAKING changes: the `font_role` ordinals 0..3 keep their meaning and
`CelerisFontConfig` keeps its layout.

### Added

- **Text styles for terminals, code views and rich text** (see *Text styles* in
  `docs/FRAMEWORK_API.md`; `zig build text_styles` shows them all):
  - **Italic**, `b.fontItalic(id, on)`: a third face bit (`FontRole.ITALIC`) that
    composes with bold and mono. A role uses its italic cut when one is registered;
    otherwise it keeps its family and weight and slants the upright face 14°, as CSS
    does. Measurement follows the face that is drawn.
  - **Decorations**, `b.textDecoration(id, .{ … })`: underline in `single`, `double`,
    `wavy`, `dotted` and `dashed` styles, plus `strikethrough` and `overline`. Lines
    are positioned and sized from the font's `post` / `OS/2` tables, pixel-snapped,
    and never change measurement or layout.
  - **Decoration color**, `b.decorationColor` / `decorationColorOf`. Without one,
    lines use the text color.
  - **Faint**, `b.textFaint(id, on)`: text and lines at 0.5 alpha (Ghostty's model).
  - All of it can be driven after the build with `bindStyle` on `.font_role`,
    `.text_decoration`, `.text_decoration_color` and `.text_faint`. All of it can be
    read back with `fw.testkit.textStyle` / `Query.textStyle`.
- Italic faces: `AppOptions.fonts.italic` / `.bold_italic` / `.mono_italic` /
  `.mono_bold_italic`, `celeris_set_app_italic_fonts` (C) and
  `CelerisFonts.SetItalic` (C#). Host discovery adds Segoe UI / Consolas italics on
  Windows and DejaVu / Liberation obliques on Linux. A host italic is never paired
  with an app-supplied upright face.
- `fw.text` now exports `FontRole`, `TextDecoration`, `UnderlineStyle`,
  `faint_opacity` and `synthetic_italic_shear`.
- `MeasureStub` gives italic its own advance (`italic_advance`, 9px). Mono italic
  keeps the mono cell.

### Changed

- `FontAtlas.fontIndexForRole` now resolves through `resolveRole`, which also
  reports whether the slant is synthetic. The per-role `bold_font_index` /
  `mono_font_index` / `mono_bold_font_index` fields are now `role_font_index[8]`.

## 0.7.1 — 2026-11-18

No C-ABI surface change.

### Fixed

- **Tearing down a window or `testkit.Harness` no longer crashes when a widget frees
  a signal its build read.** `MountTable.deinit` freed framework-owned instances
  before destroying their build-effects, so a widget that created a `Signal` in
  `onMount`, `.get()`-ed it in `build` (or let its children read it) and freed it in
  `deinit` segfaulted in `Signal.unsubscribe`. Teardown now unmounts like
  reconciliation: `onUnmount` → destroy build-effects → `deinit`. `Signal.deinit`
  (and `Computed` teardown) also detach subscribers that are still alive. See
  *Unmount order* in `docs/FRAMEWORK_API.md`.
- **`mountReactive` and table teardown, in either order.** The build-effect lives
  in the caller's `Scope`, but the table freed the record it points at, so a
  `set()` between closing a window and deinit-ing that scope ran the build on freed
  memory; and a write from a widget's `deinit` could re-run a build mid-teardown.
  The effect now has an `on_destroy` hook (new `Effect.on_destroy`): whichever of
  the scope and the mount goes first cleans up the other.
- **Debug guard: destroying a running effect panics.** A `build()` that deinits the
  `Scope` holding its own build-effect used to free the effect mid-run; debug builds
  now panic with a pointer to *Writing signals during build*.

## 0.7.0 — 2026-11-18

No C-ABI surface change.

### BREAKING

- **Celeris now requires Zig 0.17.1** (`minimum_zig_version`); Zig 0.16 is no
  longer supported. Upgrade your toolchain and your own code with the Zig 0.17
  release notes.
- Zig 0.17's `@hasDecl` only sees `pub` declarations. Celeris detects a
  component's `build`, `onMount`, `onUnmount` and `deinit` that way, so they
  must be `pub fn`. A non-`pub` `onMount`/`onUnmount`/`deinit` is now silently
  skipped instead of called.

### Changed

- `addRuntimeDeps` works the same for consumers. Internally it now puts the
  wgpu runtime directory on the run step's `PATH` itself, because Zig 0.17
  removed `Run.addPathDir`.
- The C headers (wgpu, stb, HarfBuzz, Wayland) are translated in `build.zig`
  with `addTranslateC`, replacing `@cImport`, which Zig 0.17 removed.

## 0.6.4 — 2026-11-17

No BREAKING changes. No C-ABI surface change.

### Added

- `IconButton.size` (default 32) and `IconButton.icon_size` (default 16): button
  side and glyph size, independently. Defaults keep today's look. Also exported:
  `fw.icon_button.DEFAULT_SIZE` / `DEFAULT_ICON_SIZE`.
- `MenuBar.item_radius` and `MenuBar.item_gap` (both default 0): rounded
  highlights and spacing for the top-level buttons, e.g. a menu bar embedded in a
  custom caption.
- `Theme.StateLayer.opacity()` is now public.

### Changed

- `MenuBar` buttons now show a highlight: the theme's `text` color at the M3
  hover opacity under the pointer, and at the pressed opacity while the button's
  menu is open. Before, a hover painted nothing and an open menu left its button
  unmarked. It is a render-only effect over each menu's `is_open`, so every close
  path clears it. `MenuBar.deinit` must run before its menus' `deinit` (the
  natural `defer` order).

## 0.6.3 — 2026-11-17

No BREAKING changes. No C-ABI surface change.

### Documentation

- README and `docs/FRAMEWORK_API.md` now list the whole widget suite (VirtualList,
  VirtualGrid, Grid, Stack, Dialog, Menu/MenuBar, TooltipHost, ToastHost,
  ProgressBar, AppBar, WindowChrome, StatusBar, BottomBar, OverlayWindow), and
  `FRAMEWORK_API.md` has a section on `fw.icons`, including how to draw an icon
  that has no named constant.
- `ARCHITECTURE.md`: the deferred data-grid item says that the windowing it
  needs already exists as `VirtualGrid`.

### Tests

- The icon tests cover every constant in `fw.icons`, with no list to maintain.
  They check each glyph with the same stb lookup the font atlas uses.

## 0.6.2 — 2026-11-17

No BREAKING changes. No C-ABI surface change.

### Added

- Run and debug icons in `icons`: `debug`, `debug_start`, `debug_stop`,
  `debug_alt` and `debug_alt_small` (codicons EAD8, EAD3, EAD7, EB91, EBA8), for
  Run / Stop / Debug buttons in a title bar. A test checks that each glyph is in
  the embedded `codicon.ttf`.

## 0.6.1 — 2026-11-17

No BREAKING changes. No C-ABI surface change.

### Changed

- Pointer motion updates hover (`mouse_enter` / `mouse_leave`, `hoverWithin`
  included) before emitting the global `mouse_move`, the same order a press
  already uses. An `onGlobal` handler reading hover state now sees it for the
  current position instead of the previous one. Before, the global
  `mouse_move` came first. C hosts see the same new order in the event
  callback (`CELERIS_EVENT_MOUSE_ENTER` / `_LEAVE` before the target-less
  `CELERIS_EVENT_MOUSE_MOVE`).

## 0.6.0 — 2026-11-17

No BREAKING changes. No C-ABI surface change (new modifier key strings only).

### Added

- `b.noFocusOnClick(node)` / modifier `no_focus_on_click`: a press on the node
  or its subtree leaves keyboard focus where it is; hit-testing, `mouse_down`
  and `click` are unchanged, and a `focusable` inside it still takes focus.
  For floating boxes shown beside a focused widget.
- `b.hoverWithin(node)` / modifier `hover_within`: a `hoverable` node stays
  hovered while the pointer is over any visible part of its subtree, hoverable
  descendants included. Decided by the routing hit-test, so the part of the
  subtree an `overflow_hidden` ancestor clips away does not count.
- FRAMEWORK_API.md recipe "Floating box beside a focused widget": the two
  modifiers plus a `global_mouse_down` handler, with no coordinate checks.

### Changed

- A left press re-evaluates hover at the press point before
  `global_mouse_down`, so a press with no motion before it (touch, or a node
  that appeared under a still pointer) sends `mouse_enter` first and sees the
  same hover state the press is routed by.

## 0.5.0 — 2026-11-17

No BREAKING changes. `CELERIS_ABI_VERSION` is now 9 (additive).

### Added

- `pointer_left_window` event (`CELERIS_EVENT_POINTER_LEFT_WINDOW`, appended
  last to the C enum): when the OS reports the pointer leaving the window, the
  engine sends it target-less (`node_id == 0`) to every `router.onGlobal`
  handler, once per leave, whether or not a node was hovered. It follows the
  hovered node's own `mouse_leave`, which also fires on node-to-node moves and
  so could not tell the two apart. `x`/`y` hold the last known in-window
  position on every platform.
- `Scrollbar.on_change` (`events.Handler`): fires `value_changed` after a thumb
  drag, track click or wheel over the bar changed `offset`. Programmatic
  `offset.set(...)` and writes that clamp to the same value stay silent. Same
  contract as `Slider.on_change`.
- Documented the rule for writing signals during `build` (FRAMEWORK_API.md,
  "Writing signals during build"). Debug builds now panic when a build writes a
  signal it already read with `get()`: that write's re-run was silently dropped
  (stale UI) or re-entered the build. Writing `peek()`-ed or unread signals, or
  another component's, is unaffected. Release builds are unchanged.
- Window-coordinate input in the test harness: `Harness.bakeHits()` plus
  `testkit.Query.clickAtWindow` / `mouseDownAtWindow` / `mouseUpAtWindow` /
  `wheelAtWindow` / `moveToWindow` / `leaveWindow`. They route through the
  engine's real hit-test, z-order and `clickable`/`scrollable` bubbling, so a
  test can check that an overlay blocks the nodes beneath it.

### Changed

- Pointer routing (hit-test, hover, press capture, click, wheel) moved out of
  `c_api.zig` into `core/input_routing.zig`, shared by the engine and the test
  harness. Event order and targets are unchanged. Internally, `EventContext`
  gained an optional `sink` (a callback with context) next to `event_callback`.

## 0.4.3 — 2026-11-16

No BREAKING changes. `CELERIS_ABI_VERSION` unchanged (8).

### Fixed

- Text batching regressed in 0.4.2: every node emitted a body rect even when it
  painted nothing, so each text node split the text batch ("empty rect, text")
  and a row of N text nodes cost about 2N draw calls. A body rect is now emitted
  only when it paints (a visible fill, a gradient with a visible second stop, or
  a border with width and alpha) and has non-zero area. Paint order and
  hit-testing are unchanged.
- If planning a frame's draw calls fails (out of memory), the frame is now
  skipped with a warning instead of being drawn partially and out of order.

## 0.4.2 — 2026-11-16

No BREAKING changes. `CELERIS_ABI_VERSION` unchanged (8).

### Fixed

- At equal `z`, boxes, text, images and paths now paint in tree order. Before,
  every path and image painted over every box at the same `z`, and text over
  both, whatever their place in the tree (a `b.path` underline drew over a caret
  box placed after it). An image's texture now always paints above its own
  background. See "Paint order at equal `z`" under `b.zIndex` in
  FRAMEWORK_API.md.

## 0.4.1 — 2026-11-15

No BREAKING changes. `CELERIS_ABI_VERSION` unchanged (8).

### Fixed

- A box with no width inside a row now takes the width of its content. Before, it
  could take the whole row when a box inside it took its parent's width (a
  column, or a `mountOwned` anchor without `.hug`). Such children now count with
  their content width while the outer box is being measured. After that they
  stretch to its width, as an auto-width child of a CSS `fit-content` box does.
  `.hug` and row wrappers are no longer needed for this. See "Content-sized
  boxes" in FRAMEWORK_API.md.

## 0.4.0 — 2026-11-13

### Added

- `TreeView` for file explorers: one-line rows that clip instead of wrapping;
  metrics props `row_height`, `indent`, `row_padding`, `icon_gap`, `font_size`,
  `text_style`; colors through the new `fw.theme.ListColors` (`theme.list`, or
  the tree's `.colors`) plus `TreeNode.icon_color`; a focused row separate from
  the selection, with a 1 px focus outline and an inactive selection color while
  the tree lacks keyboard focus; `activate_on_click` (single-click "preview");
  `reveal: ?*Signal(?usize)` to scroll a row into view; `on_context_menu` (right
  click, Shift+F10, menu key) and `context_menu_selects`. See FRAMEWORK_API.md.
- `Button.radius` overrides the theme corner radius (`0` for square corners).
- `Button.justify` places the label/content on the main axis (`.start` for a
  left-aligned full-width button).
- `fw.events.Key.apps` (the context-menu key; `XK_Menu` on Linux). Shift+F10
  now reaches the app on Windows (it arrives as a system key).

### Changed

- The engine's `click` event carries the click count in `key_code` (1, 2, ...),
  like `double_click` already did, so a single-click handler can skip the click
  that completes a double click.
- A right click now focuses the nearest focusable ancestor of the hit node
  before dispatching, like a left click (a miss leaves the focus alone).
- `TreeView` look: rows have a 4 px gap between icon and label and 1 px of
  vertical padding (it holds the focus outline) instead of 2 px at the top, and
  an unfocused tree paints its selection with the dimmer `inactive_selected_bg`.
- `TreeView` with a scroll bridge scrolls to the selected row only when the
  selection changes; a hover or focus change no longer scrolls it back.

No BREAKING changes. `CELERIS_ABI_VERSION` unchanged (8): `click` now fills
`key_code` (it was always 0), and the event layout is the same.

## 0.3.0 — 2026-11-13

### BREAKING

- `fw.menu.Menu.on_select` is now `?events.Handler` (was
  `?*const fn (*Menu, []const u8) void`), so a selection reaches the host's own
  state without globals. The handler receives a synthesized `select` event with
  `ev.id` = the chosen item's `action_id`, identical for mouse and keyboard (Enter).
  As before, only the root menu's handler fires, including for submenu items.
  Migration: `menu.on_select = onSel;` with `fn onSel(_: *Menu, id: []const u8)`
  becomes `menu.on_select = fw.events.makeHandler(self, onSel);` with
  `fn onSel(self: *App, ev: fw.events.Event)`, reading `ev.id`.

### Added

- `fw.events.makeHandler(payload, f)`: builds an `events.Handler` outside
  `build()` (`ctx.handler` is the same function).
- Runtime window title: `fw.window.setTitle` / `fw.window.title()` and
  `WindowHandle.setTitle` / `.title()`. Each updates the OS title and the classic
  bar. The title is copied and cut to 255 bytes on a UTF-8 boundary. C ABI:
  `celeris_window_set_title(engine_id, title, len)`; `CELERIS_ABI_VERSION` is now 8.

### Fixed

- Windows: the window class, window, and message loop now use the wide (W) Win32
  API. Titles outside the system code page (e.g. `日本語`, emoji) were mangled
  before. Typed characters outside it were too: `WM_CHAR` arrived as code-page
  bytes, and IME results in non-Latin scripts as DBCS bytes. Characters outside
  the BMP now arrive as one `char_input` (the surrogate pair is combined).
- Window titles longer than 255 bytes were cut mid-character, handing the OS
  invalid UTF-8; they are now cut on a character boundary (Win32 and Wayland).
- `TextInput` / `TextArea`: clicking inside non-ASCII text could put the caret in
  the middle of a multibyte character (`component.columnAtX` stepped byte by
  byte), so the next keystroke split it into invalid UTF-8. Clicks now always
  land on a character boundary.

## 0.2.1 — 2026-11-12

### Fixed

- Borders at fractional positions (e.g. the cards in a `SplitPane` at ratio 0.25)
  were missing, smeared over two faint pixels, or — on rounded boxes — up to twice
  as bright as their color. Boxes now paint with their edges snapped to device
  pixels (layout itself stays fractional; see *Pixel snapping* in
  `docs/FRAMEWORK_API.md`), the border composites over the fill instead of fading
  twice, and the framebuffer's alpha accumulates instead of being replaced by each
  antialiased edge.
- `internal.renderer.bakeRegistry` takes the window's DPI scale as a new last
  argument (internal API, not covered by semver).

## 0.2.0 — 2026-11-12

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
