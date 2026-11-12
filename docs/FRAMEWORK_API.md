# Celeris Framework API

Celeris is a lightweight, cross-platform UI framework written in Zig. It provides a declarative, component-based API inspired by Flutter, Jetpack Compose, and SolidJS, built on top of WebGPU.

This document is the reference for developers and AI assistants. The code snippets below are copied from **compiled examples** (`examples/counter.zig`, compiled by `zig build examples` and compared against this page by `zig build test`), so the Quick Start cannot drift from the real API. When in doubt, the example file is the source of truth.

## Core Concepts

A Celeris app is a plain struct with a `build` method. `runApp` mounts it **reactively**: state lives in `Signal`s, and reading a signal during `build` (or binding one via `dynText`/`bindStyle`/`bindList`) subscribes the affected part of the UI to it. When the signal changes, the framework updates *just that part* in place — it does not diff or rebuild the whole tree. There is no `triggerRebuild`, no manual `register`, and no string action-ids in the modern path.

The three primitives you compose with:

1. **Signals** (`fw.signals.Signal(T)`) — your state.
2. **Framework-owned widgets** (`ctx.mountOwned(Widget, .{ ...props })`) — the framework allocates, reuses, and frees the widget instance for you; you pass props (including typed event handlers) declaratively.
3. **Reactive bindings** (`ctx.dynText`, `fw.signals.bindStyle`, `fw.signals.bindList`) — glue a signal to a node so it updates in place.

## Package layout

`@import("celeris")` has three namespaces: **`framework`** — everything on this page (alias it `fw`); **`c_api`** — the functions of `include/celeris.h`, callable from Zig; **`internal`** — the engine's registry, property store, layout solver and renderer, exposed for tooling with no stability promise.

## Quick Start — the canonical counter

This is `examples/counter.zig` verbatim, minus its header comment (build & run it with `zig build counter`; `zig build test` fails if the two diverge). A developer who copies it gets code that compiles.

```zig
const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

const CounterApp = struct {
    /// The only state: a reactive integer. `dynText` below tracks it.
    count: fw.signals.Signal(i64),
    /// Owns the `dynText` binding effect for the app's lifetime.
    scope: fw.signals.Scope,

    /// Typed `on_click` handler: bump the signal. The bound label repaints itself;
    /// we never touch the UI tree here.
    fn onIncrement(self: *CounterApp, ev: fw.events.Event) void {
        _ = ev;
        self.count.set(self.count.get() + 1);
    }

    pub fn build(self: *CounterApp, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;

        const col = try b.openBox();
        try b.flexColumn(col);
        try b.alignItems(col, .center);
        try b.justifyContent(col, .center);
        try b.gap(col, 16);
        try b.width(col, 100, .percent);
        try b.height(col, 100, .percent);

        // Reactive label — bound once; updates in place when `count` changes.
        const label = try ctx.dynText(i64, &self.scope, &self.count, "Count: {d}");
        try b.fontSize(label, 32);

        // Framework-owned button with a typed handler. A row wrapper lets it hug.
        const wrap = try b.openBox();
        try b.flexRow(wrap);
        try ctx.mountOwned(fw.button.Button, .{
            .hug = true,
            .key = "increment",
            .label = "Increment",
            .on_click = ctx.handler(self, onIncrement),
        });
        b.close(); // wrap

        b.close(); // col
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var router = fw.events.EventRouter.init(allocator);
    defer router.deinit();

    var app = CounterApp{
        .count = fw.signals.Signal(i64).init(allocator, 0),
        .scope = fw.signals.Scope.init(allocator),
    };
    defer app.count.deinit();
    defer app.scope.deinit();

    try fw.runApp(&app, &router, .{
        .title = "Celeris Counter",
        .width = 400,
        .height = 300,
        .theme = fw.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
```

### `runApp` and `AppOptions`

`fw.runApp(app_instance, router, options)` creates the window/engine and mounts `app_instance` reactively (via `mountReactiveFill`, so the app root fills the window). `AppOptions` fields: `.title`, `.width`, `.height`, `.theme` (a `Theme`, e.g. `Theme.fromSeed(color, .dark)`), `.fonts` (see below), `.hide_app_bar` (drop the default title bar), `.app_bar_style` / `.app_bar` / `.app_bar_height` / `.app_bar_divider` / `.app_bar_fill` / `.app_bar_background` / `.app_bar_foreground` / `.app_bar_divider_color` (a custom caption: put your own content in the window chrome, as `examples/titlebar_proto.zig` does), `.window_control_labels` (accessible names of the caption buttons, for localization), `.window_corners`, `.window_outline` and `.is_headless`.


**Typography (`.fonts`).** An app can set the face its UI is drawn in, instead of
inheriting whatever the host's font scan turns up first:

```zig
try fw.runApp(&app, &router, .{
    .title = "My App",
    .fonts = .{
        .primary = @embedFile("assets/Inter-Regular.ttf"),
        .bold = @embedFile("assets/Inter-SemiBold.ttf"), // optional
        .mono = @embedFile("assets/JetBrainsMono-Regular.ttf"), // optional
    },
});
```

Bytes, not paths — the app stays asset-free the way the bundled Codicons icon font
is. Only `.primary` is required; the role faces (`bold`/`mono`/`mono_bold`) are the
ones `b.fontBold()` / `b.fontMono()` select, and an absent role degrades to the
primary rather than mixing in an unrelated host face — one family carrying every
role, as Material's type system reads it. Leaving `.fonts` unset keeps the OS
discovery that has always run, so nothing changes for apps that don't set it.

The faces are process-wide and apply to every window the app opens, including
secondary ones: one app, one type system. They must be registered before the first
window (`runApp` does this for you), because the font atlas is built at engine init
and glyphs are cached by font index. C hosts call `celeris_set_app_fonts`
(`CelerisFontConfig`, bytes copied on the call); C# hosts call
`CelerisFonts.Set(primary, bold, mono, monoBold)` before constructing `CelerisApp`.
**Custom window caption.** Celeris windows are borderless, so the title bar is drawn by
the framework, not the OS. `.app_bar_style = .custom` mounts `WindowChrome`, which
supplies only the draggable region and the min/max/close controls; the caption's
contents come from `.app_bar` — a `component.Child`, so either `component.slot(&.{…})`
or `component.childOf(T, &instance)` (`T` needs `pub fn build(self, ctx) !void` and
`pub fn deinit(self) void`). Setting `.app_bar` implies `.custom`. Use
`.app_bar_height` for a taller bar (default 32px), and `.app_bar_divider = false`
to drop the bottom hairline. `.app_bar_background`, `.app_bar_foreground` and
`.app_bar_divider_color` (`?theme.Color`) tint this bar alone — null keeps the theme
roles (`surface_low`, `text_secondary` glyphs, `border_color`), and the control hover
layer is mixed from background + foreground the way it is from `surface_low` + `text`.
The tokens' alpha is honored, so a translucent background lets what is behind show
through. The close button's hover stays the theme's `danger` red whatever
`foreground` is, so pick a foreground that still reads on red. These colors apply only
to `.custom`; the classic bar ignores them (set `.app_bar_style = .custom` or
`.app_bar`). `.app_bar_fill = true` drops the drag spacer and wraps the content in a
box that takes the whole drag area. The wrapper centers vertically only: to center a
title across the caption, make the content center itself (e.g. a box with
`flexGrow(1)` and `justifyContent(.center)`). The wrapper sits inside the drag region,
so the bar still drags. `WindowOptions` takes the same fields for secondary windows. The framework draws no wordmark, logo or badge of its own —
that is app content. Full example: `examples/titlebar_proto.zig`.

```zig
var caption = MyCaption{};                     // caller-owned; must outlive runApp
try fw.runApp(&app, &router, .{
    .app_bar = fw.component.childOf(MyCaption, &caption),
    .app_bar_height = 44,
    .app_bar_fill = true,                      // content spans the drag area
    .app_bar_background = .{ .r = 0x1f, .g = 0x1f, .b = 0x1f },
});
```

**Window frame.** A borderless window has no edge and square outer corners by
default, which reads as unfinished against a dark desktop. Two options cover it,
and they are meant to be used together:

- `.window_corners` — `.default` / `.square` / `.round` / `.round_small`. Asked of
  the compositor when the window is created (Windows 11 DWM; a no-op elsewhere).
- `.window_outline: ?Color` — a 1px hairline around the *whole* frame, caption
  included. It lives on the framework's root box, which is the only node spanning
  the caption and the body, so an app-level border cannot reach the top corners.
  Like any border it insets the content by 1px, and it follows `.window_corners`'
  curve so the line meets the rounded corners instead of poking past them. It also
  repaints the border the compositor draws *outside* the client area in the same
  color — rounding a window turns that border on, and left at its system color the
  window ends up with two hairlines in different colors.

```zig
try fw.runApp(&app, &router, .{
    .window_corners = .round,
    .window_outline = theme.border_color,
});
```

### Components (`build` method)

Both the **root** app and every **nested** component implement the same signature — `build(self, ctx: *fw.component.BuildContext)`. The builder is `ctx.builder`; the `ctx` also carries the MountTable and router that `ctx.mountOwned` needs, so always thread the same `ctx` down into child builds.

```zig
pub const MyWidget = struct {
    pub fn build(_: *MyWidget, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        _ = b;
    }
};
```

> Legacy note: a root whose `build` takes `*fw.builder.UIBuilder` (or `anytype`) is still accepted and built directly for one release, but it is **not reactive**. New code takes `*BuildContext`.

### Reading a node's resolved size in `build` (`ctx.measuredSize`)

During `build` you declare layout (`width: 100%`, `flex: 1`, …); you do **not** yet know the pixel rect that layout will resolve to — that is computed by the solve that runs *after* the build. When a component needs its own resolved size to keep its work proportional to what's visible — an infinite pan/zoom canvas sizing a background grid, a custom virtualizer culling to the window, a minimap — use:

```zig
pub fn build(self: *Canvas, ctx: *fw.component.BuildContext) !void {
    const root = try ctx.boxNode(.{ .width = fw.component.pct(100), .height = fw.component.pct(100) }, .{});

    if (ctx.measuredSize(root)) |size| {
        // size.w / size.h are logical px from the PREVIOUS solve.
        self.drawGridPoints(size.w, size.h); // O(visible), not a fixed guess
    } else {
        // First build, before any solve — use a one-frame fallback.
        self.drawGridPoints(self.last_w, self.last_h);
    }
}
```

`measuredSize(id: NodeId) ?MeasuredSize` returns `{ w: f32, h: f32 }` (the border box, padding included, margin excluded — the same numbers as the node's resolved `geometry`), or `null` if the node has never been through a solve or its id is dead. `ctx.measuredRect(id)` returns the same box with its position; see [Pointer coordinates local to a node](#pointer-coordinates-local-to-a-node).

Two properties to design around:

- **One frame stale.** It reports the *last* solve's result, so on the first frame and on the frame a window resize lands you read the previous size. For culling this is harmless if you keep a small overdraw margin (same trade-off `VirtualList` and `ScrollView` make internally).
- **Not reactive on its own.** A window resize re-runs the solve but does **not** re-run `build`, so a bare `measuredSize` read won't refresh when only the window changed size. If your component must track a live resize, own a signal and refresh it after the solve:

  ```zig
  size_sig: fw.signals.Signal(fw.component.MeasuredSize),   // created in onMount
  layout: fw.component.LayoutReader,                         // self.layout = ctx.layoutReader() in build

  fn refreshSize(self: *Canvas) void {                       // runs on the UI thread
      if (self.layout.rect(self.root)) |r| {
          const now: fw.component.MeasuredSize = .{ .w = r.w, .h = r.h };
          const cur = self.size_sig.peek();
          if (now.w != cur.w or now.h != cur.h) self.size_sig.set(now);
      }
      fw.application.postTask(refreshSizeTramp, self);        // check again next frame
  }
  ```

  Reading `size_sig.get()` in `build` then re-windows the canvas through the normal fine-grained path — the subtree rebuild stays O(visible). (This is the pattern `ScrollView` uses for its post-solve content-height read.)

There is deliberately **no** `viewportSize()` for "the window content area": in Celeris the title bar, split panes, sidebars and dialogs are all nodes, so a component is rarely the whole window. `measuredSize(your_root)` gives the number that actually matters and composes regardless of where the component is mounted. If you genuinely need the OS window size, that is `AppOptions` / the window API (see [Windows](#windows)), not `BuildContext`.

### Pointer coordinates local to a node

Pointer events (`mouse_down`, `mouse_up`, `mouse_move`, `click`, `double_click`) carry `ev.x` / `ev.y` in **window coordinates** (logical px). A widget that hit-tests its own content — click → line and column in a text editor, a point on a chart, a cell in a custom grid — needs them relative to its node. Keep a `LayoutReader` from `build` and convert in the handler:

```zig
const Editor = struct {
    layout: ?fw.component.LayoutReader = null,
    text_node: fw.component.NodeId = 0,

    pub fn build(self: *Editor, ctx: *fw.component.BuildContext) !void {
        self.layout = ctx.layoutReader(); // a BuildContext only lives for this build
        self.text_node = try ctx.boxNode(.{
            .grow = 1,
            .on_mouse_down = ctx.handler(self, onDown),
        }, .{});
    }

    fn onDown(self: *Editor, ev: fw.events.Event) void {
        const p = self.layout.?.toLocal(self.text_node, ev.x, ev.y) orelse return;
        // p.x / p.y: 0,0 is the node's top-left corner. Map them to your
        // content, e.g. line = p.y / line_height, then
        // fw.component.columnAtX(measure, that_line, font_size, p.x).
        self.caretTo(p.x, p.y);
    }
};
```

- `ctx.layoutReader() LayoutReader` — a plain value you can store. It stays valid for as long as the window the widget is mounted in.
- `reader.rect(id) ?MeasuredRect` — `{ x, y, w, h }`, the node's **border box** (padding included, margin excluded) in window coordinates. `null` if the node was never solved or is gone.
- `reader.toLocal(id, x, y) ?Point` — the same as `rect(id).?.toLocal(x, y)`. `MeasuredRect` also has `toLocal(x, y)` and `contains(x, y)`.
- `ctx.measuredRect(id)` — the same read during `build`, with the caveats of `measuredSize` above (one frame stale, not reactive: a node that moves does not re-run `build`).

What the rect means:

- **It is where the node is painted.** Scroll offsets of scrolling ancestors are already applied, so the conversion is correct inside a `ScrollView`.
- **It is fresh in a handler.** Input is dispatched after the solve of the frame the user acted on.
- **It is not clamped.** During a drag (`router.onGlobal` delivers `mouse_move` with `ev.node_id == 0`) the pointer can leave the node. Convert against the node id you stored, and the local coordinates come out negative or larger than `w`/`h`, which is what a drag-select needs.

There is no `ev.local_x`: `ev.node_id` is the node whose handler fires, not always the node you want coordinates for (often an inner text node), and a global handler has no node at all. Naming the reference node, as above, works the same in both cases.

In tests, `fw.testkit.Query.mouseDownAt(node, lx, ly)` / `pointerAt(name, node, lx, ly)` place an event at node-local coordinates, and `globalPointerAt(name, ref_node, lx, ly)` sends an untargeted one, as during a drag. They derive `ev.x/y` from the solved rect (call `h.solve(...)` first), so the handler's conversion runs exactly as in production.

## Framework-Owned Widgets

Celeris ships a suite of pre-built widgets in `src/framework`. In the modern model you **do not** `init`/`register`/`deinit` them yourself. Instead you `ctx.mountOwned(Widget, .{ ...props })`: the framework allocates the instance on first mount, reuses it across rebuilds (preserving its internal state — hover, caret, value), and frees it on unmount.

```zig
pub fn build(self: *MyForm, ctx: *fw.component.BuildContext) !void {
    const b = ctx.builder;

    const col = try b.openBox();
    try b.flexColumn(col);
    try b.gap(col, 16);

    try ctx.mountOwned(fw.checkbox.Checkbox, .{
        .key = "agree",
        .label = "I Agree",
        .on_change = ctx.handler(self, onAgreeChanged),
    });
    try ctx.mountOwned(fw.button.Button, .{
        .hug = true,
        .key = "submit",
        .label = "Submit",
        .on_click = ctx.handler(self, onSubmit),
    });

    b.close();
}
```

**Reserved props** understood by `mountOwned` for every widget:
- `.key` — disambiguates sibling instances of the same widget type under one parent. Give each its own key.
- `.fill` — sizes the mount anchor to fill its parent (100% × 100%); use for container widgets whose root is full-size (e.g. a `SplitPane` body, a full-pane `TreeView`).
- `.hug` — makes the anchor a row so a hug-shaped widget (like `Button`) shrink-wraps its content instead of stretching to the anchor width.

**Available widgets:**

1. **Buttons & Inputs:** `fw.button.Button`, `fw.icon_button.IconButton`, `fw.checkbox.Checkbox`, `fw.radio.Radio`, `fw.slider.Slider`, `fw.dropdown.Dropdown`, `fw.text_input.TextInput`, `fw.text_area.TextArea`.
2. **Layout & Containers:** `fw.tabs.Tabs`, `fw.split_pane.SplitPane`, `fw.stack.Stack`, `fw.grid.Grid`, `fw.scroll_view.ScrollView`, `fw.scrollbar.Scrollbar`, `fw.tree_view.TreeView`.

Widgets that host children (Tabs, SplitPane, ScrollView) take a `Child` via `fw.component.childOf(ChildType, &instance)`; `ChildType` needs both `pub fn build(self, ctx) !void` and `pub fn deinit(self) void` (an empty `deinit` is fine; it runs when the child unmounts); some (e.g. a `Button` with composed content) take a slot via `fw.component.slot(&.{ ... })`. See `examples/dashboard.zig` for the full showcase.

### Observing and driving a widget's state (lifted state)

`mountOwned` returns `void` on purpose: the framework **owns** the instance (it may reuse or free it across rebuilds), so you must never hold a `*Widget` pointer to poke at its internal fields — that pointer can dangle after an unmount. When you need to *read* a widget's state (which node is selected, where the split is) or *drive* it from app state (an element picker that selects a node, a detail pane that animates a split open), **lift that state into a caller-owned `Signal` and pass it as a prop**. The signal is the shared, two-way channel: the widget reads it to render and writes it on user interaction; you read it to react and write it to command.

This is the same mechanism across the widget suite:

| Widget | Lifted prop | Type | Use |
|--------|-------------|------|-----|
| `Tabs` | `.active` | `*Signal(usize)` | switch tabs from app code / know the active tab |
| `TreeView` | `.selected`, `.hovered` | `*Signal(?usize)` | react to / drive selection & hover by node id |
| `SplitPane` | `.ratio` | `*Signal(f32)` | set or animate the split (collapse/expand a pane) |
| `ScrollView` | `.offset` | `*Signal(f32)` | read/drive the scroll position (px, `<= 0`; 0 = top) |
| `Scrollbar` | `.offset`, `.content_size`, `.viewport_size` | `*Signal(f32)` | standalone bar for a view that draws only its visible slice; same offset convention as `ScrollView` |

```zig
// App owns the state. Declare the signal BEFORE the mount table so teardown
// order is correct (the widget's effect unsubscribes before the signal frees).
selected: fw.signals.Signal(?usize),   // in your app struct; init in setup

// In build(): pass it in. Omit the prop entirely and the widget falls back to an
// equivalent internal signal — it still works standalone.
try ctx.mountOwned(fw.tree_view.TreeView, .{
    .roots = &self.tree_roots,
    .data_rev = &self.tree_rev,
    .selected = &self.selected,   // two-way
});

// React to the user selecting a node — a plain effect on your own signal.
_ = try self.scope.createEffect(self, showDetailFor);   // reads self.selected.get()

// Drive it: an element picker in the target app selects the matching node.
self.selected.set(picked_node_id);   // the tree repaints the highlight
```

> ⚠️ **Effects run synchronously inside `set()`**, on the thread that wrote the
> signal (normally the UI thread). Never do blocking work in an effect — file/pipe
> I/O, network calls, native dialogs — or every `set()` that triggers it freezes
> the UI for that long. Same rule as `fw.dialogs`: run the blocking work on a
> worker thread and marshal back with `application.postTask`, writing signals from
> the posted task (writes from a posted task run on the UI thread and are safe).

### Native file dialogs (`fw.dialogs`)

`fw.dialogs.openFile` / `saveFile` / `pickFolder` wrap the OS open/save/select-folder
dialogs. Each blocks the calling thread until the user chooses or cancels and
returns an engine-owned path (`fw.dialogs.freeString` it) or `null`.

Run them on a worker (`std.Thread.spawn`) and post the path back with
`application.postTask` — while the blocking call is on the UI thread the frame
loop is stalled and the window stops repainting. The call is worker-safe by
design: the engine's per-window string table is mutex-guarded and Win32 COM is
initialised on whatever thread invokes the dialog. `examples/dashboard.zig` shows
the full worker + `postTask` round trip.

`Options.window` scopes the modal to a specific `WindowHandle` (defaults to the
primary window); pass the **same** `window` to `freeString`. Platform matrix:
Win32 full; Linux via the XDG portal (`filter` ignored for now); macOS returns
`null` (no native dialog — out of scope per `ARCHITECTURE.md`).

For `TreeView` specifically, because selection lives in a caller-owned signal keyed by the stable `TreeNode.id`, it **survives live data refreshes** (`data_rev` bumps): the widget keeps the selection when the id still exists in the new `roots` and clears it only if that node disappeared. No manual JSON de-duplication is needed to protect the user's selection.

**TreeView keyboard navigation.** The tree root is focusable; once focused (Tab into it, or click a row) it responds to:

| Key | Action |
|-----|--------|
| ↑ / ↓ | Move the selection up/down across the visible rows (clamped at the ends; from no selection, ↓/↑ pick the first row). |
| → | Expand a collapsed branch; if already expanded, step into its first child. |
| ← | Collapse an expanded branch; otherwise step out to the parent. |
| Enter | On a branch, toggle it. On a leaf, fire `on_activate` (see below). |

Navigation drives the `.selected` signal, so it composes with the lifted-state recipe above: the caller observes selection changes identically whether they came from the mouse, the keyboard, or the caller's own `.set`.

**TreeView click gestures.** A branch row has two hit-targets:

- The **caret** (the ▸/▾ disclosure triangle) always toggles expand/collapse and never touches the selection. The glyphs are overridable via `.caret_collapsed` / `.caret_expanded`, for a different look or a font that lacks them.
- The **row body** always selects. By default it *also* toggles a branch (the classic file-tree gesture). Pass `.toggle_on_row_click = false` for the DevTools/IDE pattern where clicking a container only selects it — expanding stays available via the caret, ←/→, and Enter. This is the right setting for inspectors, where the most-inspected nodes are branches and collapsing on select is disruptive.

**TreeView expansion and activation events.** Three optional `events.Handler` props (build them with `ctx.handler`). Each receives a synthesized event whose `ev.name` is `"expand"`, `"collapse"` or `"activate"` and whose `ev.item_id` is the `TreeNode.id`:

- `.on_expand` / `.on_collapse` fire for every expand/collapse gesture: caret click, row click (when `toggle_on_row_click`), ←/→, and Enter on a branch.
- `.on_activate` fires on a double click on a row and on Enter on a leaf. An IDE opens the file here. A single click only selects.

**Controlled expansion (model owns `expanded`, lazy children).** Set `.controlled_expansion = true` when an app model decides which folders are open. The widget then never writes `TreeNode.expanded`; it only fires `on_expand`/`on_collapse`. The handler updates `roots` (e.g. loads a folder's children the first time it opens) and bumps `data_rev`, which is required in this mode (asserted). Selection, hover and scroll survive that rebuild like any data refresh.

```zig
fn onExpand(self: *App, ev: fw.events.Event) void {
    const node = self.model.find(ev.item_id.?);
    if (!node.loaded) self.model.loadChildren(node); // fill roots lazily
    node.expanded = true;
    self.tree_rev.set(self.tree_rev.peek() + 1);
}

try ctx.mountOwned(fw.tree_view.TreeView, .{
    .roots = &self.tree_roots,
    .data_rev = &self.tree_rev,
    .controlled_expansion = true,
    .on_expand = ctx.handler(self, onExpand),
    .on_collapse = ctx.handler(self, onCollapse),
    .on_activate = ctx.handler(self, onOpenFile),
});
```

**Recipe — scroll a tree to reveal the selected node (element picker + keyboard).** A `TreeView` doesn't know its container `ScrollView`; the bridge is a *shared* offset signal. Pass the same `Signal(f32)` as the ScrollView's `.offset` and the TreeView's `.scroll_offset`, and give the TreeView the viewport height. Whenever the selection changes — by keyboard nav, or by the caller's own `.selected.set(picked)` (the element-picker path) — the tree nudges the shared offset so the selected row stays inside the viewport (offsets are `<= 0`; a row above the window aligns its top, one below aligns its bottom; a row already visible doesn't move). A selection whose row isn't currently visible (an ancestor is collapsed) is left alone.

```zig
// One shared signal owned by the app (declare before the mount table).
tree_scroll: fw.signals.Signal(f32),   // init to 0 in setup
selected:    fw.signals.Signal(?usize),

// In build():
try ctx.mountOwned(fw.scroll_view.ScrollView, .{
    .fill = true,
    .offset = &self.tree_scroll,
    .viewport_height = 400,
    .content = fw.component.childOf(fw.tree_view.TreeView, &self.tree),
});
// The hosted TreeView shares the same offset + viewport height:
//   .roots = &self.tree_roots, .data_rev = &self.tree_rev,
//   .selected = &self.selected,
//   .scroll_offset = &self.tree_scroll, .viewport_height = 400,

// Element picker: select a node from app code — the tree scrolls to it.
self.selected.set(picked_node_id);
```

**Virtualization (automatic).** Wiring that same scroll bridge (`.scroll_offset` + a positive `.viewport_height`) also makes `TreeView` *windowed*: it materializes only the rows in view (plus a small overdraw) instead of one DOM node per visible tree node, so a fully-expanded tree of thousands of rows stays fluid — scrolling, hover and selection all cost O(window), not O(rows). This is transparent: the props, the `.selected`/`.hovered` signals, keyboard nav and ensure-visible all behave the same (they index the full tree internally). Requirement: rows are a fixed height, so the window math is exact. Omit the scroll bridge and the tree renders every visible row as before (fine for small trees).

### `VirtualGrid` — 2D windowed grid over a pull source

`fw.VirtualGrid(Datum)` is `VirtualList`'s 2D sibling. It materializes only the
visible `~rows × cols` cell nodes of an arbitrarily large grid, over a **pull
source** — not a materialized cell array:

```zig
const VG = fw.VirtualGrid(MyCell);
try ctx.mountOwned(VG, .{
    .row_count = 100_000,
    .col_count = 40,
    .cell_at = &myCellAt,          // fn (?*anyopaque, row, col) MyCell  (or VG.sourceFn(*T, f))
    .col_width_at = &myColWidth,   // fn (?*anyopaque, col) f32          (or VG.colWidthFn(*T, f))
    .render = VG.cellFn(*Self, drawCell), // fn (*Self, *BuildContext, MyCell, row, col) !void
    .payload = self,
    .row_height = 26,             // uniform in v1
    .viewport_width = 980,
    .viewport_height = 560,
    .selected = &self.selected,   // ?*Signal(fw.CellRange), lifted (see below)
    .col_scroll = &self.col_scroll, // ?*Signal(f32), optional — sync a frozen header
    .data_rev = &self.rev,        // ?*Signal(u32) — bump after mutating the source / widths
});
```

- **Vertical axis is O(1)** (`floor(top / row_height)`); the **horizontal axis is
  O(log col_count)** — a prefix sum of column widths + binary search, rebuilt on
  a `data_rev` bump. Sub-cell scrolling on either axis is render-only (no layout
  solve); a boundary crossing repopulates only the visible window.
- **Owned behaviour is keyboard cell navigation only**: arrows, Tab / Shift+Tab,
  Home / End, Ctrl+Home / Ctrl+End, PageUp / PageDown move the focused cell,
  scroll it into view, and write a *collapsed* `CellRange` to `.selected`. The
  viewport captures Tab (`capturesTab`); Ctrl+Tab or Escape then Tab leave it. The
  grid does not paint the active cell — your `render` callback reads `.selected` and
  highlights it. The focused viewport shows the focus ring by default; once your cells
  paint the active cell, pass `.focus_ring = false` so that highlight is the only
  focus indicator. The
  grid defines no selection-change events and never *extends* a range — an app
  that wants Shift+Arrow range-select does that in its own key handler.
- **Everything else composes**:
  a **frozen header/column** is nodes you build outside the grid and translate by
  `-col_scroll` / `-row_scroll` (pass the same `Signal(f32)` as the grid's
  `.col_scroll` / `.row_scroll`); **column resize** is `on_mouse_down` on a
  divider + `EventRouter.onGlobal`, writing your own width array (which the grid
  reads via `col_width_at`); **sort** re-points `cell_at` and bumps `data_rev`;
  **in-cell editing** is a `TextInput` you mount into the focused cell (safe under
  recycling — focus is cleared when a cell node is removed). Not built in: an
  editor, a selection model with semantics, merged cells, variable row heights.
- `examples/virtual_grid.zig` (`zig build virtual_grid`) is the reference.

### `ScrollView` viewport height

`ScrollView` clamps scrolling (and sizes its thumb) against the height the viewport
**actually solved to** whenever it is mounted with `.fill = true` or `viewport_height`
is left at its default (600) — the same way `content_height` is read back from
geometry. A `.fill` ScrollView in a 400px slot over 1000px of content scrolls to
`-600`, so the last rows are reachable. An explicit `viewport_height` without `.fill`
is still honoured as-is. Before the first layout solve both fall back to the props.

### `Dialog` (`fw.dialog.Dialog`) mount point and content refresh

```zig
const Greeting = struct {
    pub fn build(_: *@This(), ctx: *fw.component.BuildContext) !void {
        _ = try ctx.builder.addText("Hello from a dialog");
    }
    pub fn deinit(_: *@This()) void {}
};
var greeting = Greeting{};
var open = fw.signals.Signal(bool).init(allocator, false); // app-owned; outlives the mount

// In the app root's build():
try ctx.mountOwned(fw.dialog.Dialog, .{
    .open = &open,
    .title = "Greeting",
    .content = fw.component.childOf(Greeting, &greeting), // a Child, not a string
});

// Later, e.g. from a button handler:
open.set(true);
```

Props: `open` (`?*Signal(bool)`, caller-owned), `title`, `content` (`?component.Child` — build it with `childOf`), `dismissable` (Escape / backdrop click close it; default `true`) and `on_close`.

**Mount it as a direct child of the app's window root** — the same rule `Menu` already has, and for the same reason: `ctx.mountOwned(fw.dialog.Dialog, .{ .open = &sig, ... })` sizes its scrim to `100%`/`100%` of its **immediate mounting parent**, not of the true window. As a sibling among other top-level children (a header, a status bar) it correctly covers the whole window regardless of those siblings' sizes, because it takes its own mount anchor out of their flex flow first. Mounted deeper — say, inline inside a 40px custom caption row, with no full-window wrapper between it and that row — its scrim resolves against that row's own size (40px tall) instead. If a dialog needs to open from code that lives deep in the tree, keep the `Dialog` itself mounted at the root and control it with a signal owned further up (the same `open`/lifted-state shape you'd use for any cross-tree dialog).

**`title`/`content` refresh on the closed→open transition.** These are plain `mountOwned` props, not signals, so they only get their current value two ways: whenever the component that mounts the `Dialog` rebuilds (ordinary prop re-application), or — because many apps set them from an event handler right before opening, with no rebuild in between (`title_buf` fields written, then `open.set(true)`, the `MessageDialog.show()` shape) — via a refresh `Dialog` itself triggers on every `open` transition from `false` to `true`. Calling your open-with-new-content routine again while the dialog is **already** open does not refresh it (`Signal.set` no-ops on an unchanged value, so there's no transition to catch) — close and reopen it, or lift `title`/`content` to signals you own if you need that.

### Context menus (`fw.menu.Menu`)

A `Menu` is a host-owned controller: create it **once** (`Menu.init`, keep the
pointer in your app state), add items, and `ctx.mount(menu)` it in every build — the
build is idempotent and keeps `is_open`/position across rebuilds. Creating a new
`Menu` per frame discards the open state, so the panel never shows.

Open it from a handler with **`menu.popupWindow(ev.x, ev.y, .pointer)`** — window
coordinates, exactly what pointer events carry. (`popup(x, y, ...)` takes
coordinates relative to the node the menu is mounted into; `popupWindow` converts
by subtracting that container's resolved origin, including a custom caption above
it and any `scroll_offset_x/y` pan.)

**Where to mount it:** the backdrop fills, and the panel is positioned and
**clipped** within, the node the Menu is mounted into. Mount it in a full-window
container — typically as the **last child of your app root**, after the canvas —
not inside a clipped (`overflowHidden`) or panned canvas: a clip also cuts the
panel (z-index does not escape an ancestor's clip), and a pan translates it.
Opening it from a press that also triggers a rebuild is fine.

```zig
// setup (once):  self.ctx_menu = try fw.menu.Menu.init(gpa, "node_ctx");
//                try self.ctx_menu.addItem("Delete", "delete");
//                self.ctx_menu.on_select = onMenuSelect;
pub fn build(self: *App, ctx: *fw.component.BuildContext) !void {
    try ctx.box(.{ .width = fw.component.pct(100), .height = fw.component.pct(100), .direction = .column }, .{
        Caption{},                  // 40px custom caption
        Canvas{ .app = self },      // overflowHidden + clickable; nodes carry on_right_click
    });
    try ctx.mount(self.ctx_menu);   // full-window overlay, sibling after the canvas
}
fn onNodeRightClick(self: *App, ev: fw.events.Event) void {
    self.ctx_menu.popupWindow(ev.x, ev.y, .pointer);
}
```

## Event Handlers

Widget events are typed props. `ctx.handler(payload, comptime f)` builds a `Handler` (allocation-free) where `f` is `fn(*Payload, fw.events.Event) void`. Wire it to the widget's declarative `on_*` prop:

```zig
try ctx.mountOwned(fw.button.Button, .{
    .key = "run",
    .label = "Run",
    .on_click = ctx.handler(self, onRun),
});

// ...
fn onRun(self: *MyApp, ev: fw.events.Event) void {
    _ = ev;
    self.busy.set(true);
}
```

No string action-id, no `router.on`.

**Common widget handlers:** `on_click` (Button/IconButton), `on_change` (Checkbox/Radio/Slider/Dropdown, and **TextInput/TextArea**), `on_submit` (TextInput/TextArea, on Enter), `on_expand`/`on_collapse`/`on_activate` (TreeView; the node id is in `ev.item_id`, see "TreeView expansion and activation events" under lifted state above). For the text widgets `on_change` fires on **real text mutations only** — insert, delete, paste, cut, IME commit, undo and redo — with the new buffer contents in `ev.text` and the widget's root node id in `ev.node_id`; caret and selection moves never fire it. It's the hook for reactive text, e.g. a live search filter:

```zig
try ctx.mountOwned(fw.text_input.TextInput, .{
    .key = "filter",
    .placeholder = "Filter…",
    .on_change = ctx.handler(self, onFilterChanged),
});

fn onFilterChanged(self: *MyApp, ev: fw.events.Event) void {
    self.applyFilter(ev.text); // e.g. rebuild the visible node list now
}
```

> `ev.text` is **borrowed** — it aliases the widget's internal buffer and is only valid for the duration of the call. Use it immediately; if you need to retain it (store it in a field or a `Signal`), copy it into memory you own first.

### Size changes (`on_resize`)

`.on_resize = ctx.handler(self, onResize)` on a box (or `ctx.onResize(id, h)` for a node opened with the raw builder) reports the node's **solved border-box size** in `ev.width` / `ev.height` (logical px). The equivalent of the web's `ResizeObserver`.

- **When.** After every rendered frame whose layout solve changed the node's size by ≥ 0.5px, and **once after the first solve** — so a widget that needs its real size (a virtualizer, a canvas) gets it without polling and without `measuredSize`'s first-build `null`.
- **Never inside the solve.** The engine collects changes after the frame is on screen; whatever the handler writes lands in the next frame. A node reports at most once per solve.
- **Observe a node whose size is imposed** (`pct`, `fill`, `grow`), not one that hugs content the handler itself changes — that loop would advance one frame per round trip. Observing a hug-sized node is fine when the handler doesn't affect its size (`ScrollView` observes its content wrapper only to update the thumb).
- **Rebuilds.** Re-applying the same handler reports nothing new; binding a different receiver to the same node re-reports the current size to it. A removed node stops reporting.
- `VirtualList(.fill = true)`, `VirtualGrid(.fill = true)` and `ScrollView` use it: growing the window materializes the rows that now fit and re-clamps the scroll, with no wheel event. `viewport_height`/`viewport_width` remain as the frame-0 estimate.
- C hosts receive `CELERIS_EVENT_RESIZE` with the size in `x` / `y`.

### Wheel on raw-builder nodes (`ctx.onScroll` / `ctx.onScrollH`)

The `on_scroll` / `on_scroll_h` box props have raw-builder forms, the same way
`on_resize` has `ctx.onResize`. Use them for a node opened with `b.openNodeKeyed`
(or any id you already hold) instead of switching to `boxNode` just to get the prop:

```zig
const view = try b.openNodeKeyed(.box, null);
try ctx.onScroll(view, ctx.handler(self, onWheel));   // vertical wheel: ev.scroll_delta
try ctx.onScrollH(view, ctx.handler(self, onWheelH)); // horizontal: ev.scroll_delta
b.close();
```

Same semantics as the props: the node is marked scrollable (so the wheel reaches it
under the rules below) and `.scroll` / `.scroll_h` events go to the handler.

### Pointer event delivery rules

These are load-bearing behaviours; downstream apps (node editors, canvases) rely on them.

- **Modifiers on every pointer event.** `ev.shift` / `ev.ctrl` / `ev.alt` are filled on `mouse_down`, `mouse_up`/`click`, `mouse_move`, `right_click`, `mouse_enter`/`mouse_leave`, `double_click` and `scroll`/`scroll_h` — not just on keys. They reflect the key state at the moment the OS delivered the pointer message (Win32 `GetKeyState`, Wayland xkb state), so shift-click multi-select and shift-drag marquee work: `if (ev.shift) self.toggleSelect(id) else self.selectOnly(id);`. (C hosts read the same bits in `CelerisEvent.modifiers`.)
- **Presses bubble through clickable ancestors.** A `mouse_down` (and the `click` on release) is dispatched capture → target → bubble along the hit node's ancestor chain: the child's handler runs first, then the handler of **every clickable ancestor**, e.g. a clickable canvas root behind a clickable node. `right_click` bubbles the same way through right-clickable ancestors. An ancestor that must ignore presses already handled by a child has to check `ev.node_id` (or keep a "handled this press" flag); `.no_drag` stops the bubble at that node.
- **Wheel only reaches scrollable nodes.** `scroll`/`scroll_h` go to the **nearest ancestor-or-self of the hit node marked scrollable** (`on_scroll` / `.scrollable`) and stop there — exactly one node receives each wheel event, and a plain clickable box never sees one. Give a zoomable canvas an `on_scroll` handler to receive the wheel (or `ctx.onScroll(id, h)` for a raw-builder node — see [Wheel on raw-builder nodes](#wheel-on-raw-builder-nodes-ctxonscroll--ctxonscrollh)).
- **Release goes where the press went (implicit pointer capture).** On release the engine emits the global `mouse_up` (no node, for drag-follow handlers), then a node-targeted `mouse_up` to every clickable node that received the `mouse_down` — even if the pointer is now elsewhere — and only then the `click` to the node under the pointer. A node removed by a rebuild between press and release gets its `mouse_up` at removal time. So `on_press` / `on_mouse_up` state (`Button.pressed`) can't get stuck, including when the click handler re-mounts the button. `Button`/`IconButton` also drop `pressed` on `mouse_leave`.
- **Hover survives rebuilds.** If a rebuild removes the hovered node (e.g. a `Button` whose click rebuilds its parent is re-created), that node receives its `mouse_leave` **at removal time** — a removed node is never hovered — so hover-driven state (`Button.hovered`) resets even if the pointer leaves before the next frame or the re-mounted widget is no longer under it. After the next frame is baked, hover is re-evaluated at the last pointer position: a replacement still under the pointer gets `mouse_enter`, and its own `mouse_leave` later. Note that such a `mouse_leave` handler can run *during* a rebuild; keep hover handlers to state writes (the `on_hover` signal-setter pattern).

### Keys (`fw.events.Key`, `ev.key()`)

Keyboard events carry their key in `ev.key_code`, using the Windows virtual-key numbering on every platform (Linux translates xkb keysyms to it). Don't compare against numbers: `ev.key()` returns a named `fw.events.Key`, or `null` when the event isn't a `key_down`/`key_up` or the platform reported no key.

```zig
fn onKey(self: *Editor, ev: fw.events.Event) void {
    const key = ev.key() orelse return;
    switch (key) {
        .left => self.moveCaret(-1, ev.shift),
        .right => self.moveCaret(1, ev.shift),
        .home, .end => self.toLineEdge(key == .end, ev.shift),
        .z => if (ev.ctrl) self.undo(),
        .f5 => self.run(),
        else => {},
    }
}
```

- **Named keys:** `left right up down home end page_up page_down`, `backspace delete enter tab escape space insert`, `a`–`z`, `@"0"`–`@"9"`, `f1`–`f12`. Letters are named once, without case; read Shift from `ev.shift`.
- **Modifiers are unchanged:** `ev.shift` / `ev.ctrl` / `ev.alt`.
- **The enum is non-exhaustive:** a code without a name still comes back as a `Key` (`key.code()` gives the number), so a `switch` needs an `else` arm. `Key.fromCode(u32)` converts a raw code (`0` → `null`), and `Key.x.code()` goes the other way (e.g. to build an `Accelerator` or a synthetic test event).
- **Not for text.** Typed text arrives as `char_input` with the UTF-8 in `ev.text`. On `char_input` `key_code` holds a codepoint, and on clicks it holds the click count, which is why `ev.key()` returns `null` there.
- C hosts keep using the raw `key_code`; the numbering and `CELERIS_ABI_VERSION` are unchanged.

### Escape hatch: raw action-ids + EventRouter

For a bare interactive `Box` built directly with the `UIBuilder` (no widget), you can assign a string `action_id` and respond through the `EventRouter`. Prefer typed handlers above; this exists for low-level/interop cases. The context pointer comes **before** the handler.

```zig
const btn = try b.openBox();
try b.clickable(btn, "my_custom_button");
b.close();

try router.on("my_custom_button", &app, MyApp.onCustomButtonClick);

pub fn onCustomButtonClick(_: *MyApp, ev: fw.events.Event) void {
    _ = ev;
    std.debug.print("Clicked!\n", .{});
}
```

## Fine-Grained Reactivity (Signals)

Celeris is **retained mode** and intentionally avoids diffing the whole tree. Never call `runApp` again or destroy the `UIRegistry` to refresh — that loses widget state (caret position, scroll offset). Instead bind a signal to the exact node(s) that depend on it.

### Reactive text (`dynText`)
Creates a text leaf and binds its content to a signal formatted with a comptime `std.fmt` spec (`"{d}"`, `"{s}"`, …). Call it **once** at build time; the owned effect updates the node in place afterward. Accepts a `*Signal(T)` or `*Computed(T)`.

```zig
const label = try ctx.dynText(i64, &self.scope, &self.count, "Count: {d}");
```

### Style & layout bindings (`bindStyle` / `bindLayout`)
Bind a color or dimension to a `Signal(PropValue)`; on change, the new value is injected into the `UIRegistry` without rebuilding. Color channels in a `PropValue` are 0–1 floats; `PropValue.rgbA(r, g, b, a)` takes 0–255 bytes. The signal must outlive the scope that binds it (deinit the scope first).


```zig
var color = fw.signals.Signal(fw.PropValue).init(allocator, fw.PropValue.rgbA(255, 0, 0, 1));

const box_id = try b.openNodeKeyed(.box, null);
try fw.signals.bindStyle(&app.scope, b.store, box_id, .background, &color);
b.close();
```

### Structural lists (`bindList`)
For dynamic lists (chat histories, tables), `bindList` incrementally appends/removes children of a container without destroying siblings.

```zig
self.list_signal = fw.signals.Signal([]const MyItem).init(allocator, items.items);

const list_container = try b.openNodeKeyed(.box, null);
try fw.signals.bindList(
    MyItem,             // Item type
    &app.scope,         // Scope managing effect lifecycles
    b,                  // UIBuilder
    list_container,     // parent node id
    &app.list_signal,   // pointer to the signal
    buildMyItem,        // fn(b: *UIBuilder, item: MyItem) !void
);
b.close();
```

Mutate with `list_signal.set(new_items)`; the rebuild is isolated to `list_container` (with a `markLayoutDirty`), preserving app-wide focus and performance.

## Recipes

### Key/value property panel

A DevTools-style property/inspector pane is a **composition, not a widget**. The framework rule is not to ship a widget until at least two real consumers need it — until then the panel is a tiny reusable row component plus a build-loop over the data. The runnable reference is [`examples/property_panel.zig`](../examples/property_panel.zig) (`zig build property_panel`).

The reusable piece is a two-cell row. Every key cell shares the same column basis, so keys line up across rows with no table/grid:

```zig
const KvRow = struct {
    key: []const u8,
    value: []const u8,

    pub fn build(self: *KvRow, ctx: *fw.component.BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;
        const row = try b.openBox();
        try b.flexRow(row);
        try b.width(row, 100, .percent);
        try b.padding(row, 4, 8, 4, 8);
        try b.alignItems(row, .center);
        try b.gap(row, 8);

        // A11y: name the row "key: value" as a "listitem" so a screen reader / UIA
        // client reads it as one unit. A bare box has no role and never reaches the
        // a11y tree — the rows are stamped inside a `role(list, "list")` container.
        try b.role(row, "listitem");
        var name_buf: [128]u8 = undefined;
        try b.ariaLabel(row, std.fmt.bufPrint(&name_buf, "{s}: {s}", .{ self.key, self.value }) catch self.key);

        const key = try b.addText(self.key);          // dimmed, fixed 40% column
        try b.width(key, 40, .percent);
        try b.textColor(key, t.text_disabled.r, t.text_disabled.g, t.text_disabled.b);

        const val = try b.addText(self.value);         // grows to fill the rest
        try b.flexGrow(val, 1);
        try b.textColor(val, t.text.r, t.text.g, t.text.b);
        b.close();
    }
    pub fn deinit(_: *KvRow) void {}
};
```

Stamp one per data pair in the parent's `build`, inside a `list`-role container so the rows form an enumerable list for UIA, and use `dynText` for any value that must react to a signal:

```zig
const list = try b.openBox();
try b.flexColumn(list);
try b.role(list, "list");                 // rows below are its "listitem" children
var rows = [_]KvRow{ .{ .key = "id", .value = "n_42" }, .{ .key = "type", .value = "Box" } };
for (&rows) |*r| try r.build(ctx);
// A reactive value: bind it to a Signal so only that text node repaints.
const v = try ctx.dynText(i64, &self.scope, &self.renders, "{d}");
try b.flexGrow(v, 1);
b.close(); // list
```

**Promotion criterion.** When a *second* real consumer needs this, move `KvRow` into `src/framework/` as a proper widget with lifted props (`values: []const Kv`, a `data_rev` for live updates), following the same patterns as the rest of the suite (caller-owned signals, no raw fn pointers, `mountOwned`). Until then, keep it as this recipe — a local component is cheaper than a premature widget.

## Multithreading and Background Tasks

Rendering and UI state updates are single-threaded (no locking overhead). For heavy or blocking work (network, LLM inference), spawn a `std.Thread`. To surface results, write a `Signal` from the worker thread — the reactive layer repaints the bound nodes. (`fw.application.postTask` hops a callback onto the UI thread for the next tick if you need to run code there; the C-ABI equivalent for host code is `celeris_post_task(callback, ctx)`.)

```zig
fn backgroundTask(app: *MyApp) void {
    const result = heavyComputation();
    app.result_signal.set(result); // repaint happens automatically
}
```

## Windows

`runApp` creates the **main window**. `fw.window` drives it, and opens further ones.

### Controlling the main window

Celeris windows are borderless (no native caption), so these are what an app that sets
`hide_app_bar` uses to do what the framework bar would have done:

```zig
fw.window.startDrag();          // move the window (wire to a mouse_down)
fw.window.minimize();
fw.window.toggleMaximize();     // and fw.window.isMaximized()
fw.window.close();
```

Geometry and visibility, all in **logical px** (the same units layout uses — never
convert for DPI yourself):

```zig
const saved = fw.window.bounds();          // ?fw.Rect — save before you move it
fw.window.setBounds(x, y, w, h);
fw.window.hide();                          // the tree stays mounted; nothing is lost
fw.window.show();
fw.window.setAlwaysOnTop(true);
const area = fw.window.workArea();         // ?Rect — screen minus taskbar
const hwnd = fw.window.nativeHandle();     // ?*anyopaque (HWND) — escape hatch only
```

`hide()` is not a teardown: scroll positions, panel state and every mounted component
survive it. An app that wants to step aside for a compact bar hides itself and restores
the saved rect afterwards — no window enumeration, nothing to persist to disk.

The caption is per-window state, changeable at runtime (it used to be frozen at `runApp`):

```zig
fw.window.setAppBarHeight(44);
fw.window.setAppBarVisible(false);
```

### Secondary windows

`fw.window.open` creates a window with **its own component tree, layout pass, render
loop, event router and mount table**. Opening or closing it does not touch the main
window's tree — nothing is unmounted and no state is lost. That is the difference from
returning a different root out of the app's `build`, which throws the whole tree away.

```zig
const overlay = try fw.window.open(.{
    .content = fw.component.childOf(RecorderBar, &app.recorder_bar),
    .title = "Recording",
    .width = 460,
    .height = 56,
    .placement = .{ .anchored = .{ .at = .top_right, .margin = 16 } },
    .always_on_top = true,
    .resizable = false,       // no resize border eating clicks along a 56px bar
    .hide_app_bar = true,     // no caption: the full height is the content's
    .window_corners = .round_small,
    .window_outline = t.border_color,
    .theme = .inherit,        // or .{ .own = fw.theme.Theme.light() }
});
```

- **`content`** is caller-owned (`childOf(T, &instance)`), so its state lives in the app
  struct and survives the window closing and reopening.
- **`placement`** is `.platform_default`, an absolute `.position = .{ .x, .y }`, or
  `.anchored` to a corner of the work area (`.top_left`/`.top_right`/`.bottom_left`/
  `.bottom_right`/`.center`) with a margin — a HUD lands clear of the taskbar without the
  app doing screen arithmetic. Anchoring falls back to the platform default where there
  is no work-area query (Wayland).
- **`theme: .inherit`** shares the parent's theme signal, so one `set` restyles every
  window at once; `.own` gives this window an independent theme.

The handle mirrors the main-window controls, and closing frees the window's tree:

```zig
overlay.setBounds(x, y, w, h);
overlay.setAlwaysOnTop(false);
overlay.hide();  overlay.show();
overlay.setAppBarHeight(0);
const still_open = overlay.isOpen(); // false once closed
overlay.close();
```

`close()` is safe from an event handler, including a handler of the window being closed —
a "Stop" button that closes its own overlay is the ordinary case. The window stops taking
input and rendering immediately, but everything it owns (engine, component tree, event
router) is released at the top of the next loop iteration, not underneath the frame
currently dispatching. The same holds for a user-initiated close (close button, Alt+F4).
A handle kept past its
window's close is **inert** — every call is a no-op and `isOpen()` is false, so a stale
handle left in app state cannot crash the app.

**Lifecycle.** Closing the main window closes every secondary one. Closing a secondary
window (its close button, Alt+F4, or `close()`) frees only its tree. Content that
declares `onUnmount` is told when its window goes away — see below.

**Input is per window.** Clicks and hovers in a secondary window reach only its own
handlers; the two windows never see each other's events.

### `ctx.dragRegion` — moving a window with no caption

A window opened with `hide_app_bar` has no title bar, so nothing moves it. `dragRegion`
turns any box into the grab handle, and it drags **the window whose tree it was built
into** — you pass nothing:

```zig
const bar = try b.openBox();
// …styling…
try ctx.dragRegion(bar);   // the whole bar drags, except the buttons built after it
```

Children built after it win the hit test, which is how a "drag anywhere except the Stop
button" bar falls out naturally.

### `OverlayWindow` — the declarative form

When a window's existence just tracks a piece of state, bind it to a signal instead of
calling `open`/`close` by hand. This is Flutter's `Overlay` / Compose's `Popup` shape,
and it is a thin layer over `fw.window.open` — not a separate mechanism:

```zig
try ctx.mountOwned(fw.OverlayWindow, .{
    .open = &self.is_recording,          // ?*Signal(bool), caller-owned (lifted state)
    .options = fw.WindowOptions{
        .content = fw.component.childOf(RecorderBar, &self.bar),
        .width = 460, .height = 56,
        .placement = .{ .anchored = .{ .at = .top_right, .margin = 16 } },
        .always_on_top = true,
        .hide_app_bar = true,
    },
});
```

`is_recording.set(true)` opens the window, `set(false)` closes it. The widget only reads
the signal — it never writes back, so the app stays in charge of the flag. The window is
opened on the next loop tick rather than mid-build (creating an engine and a GPU surface
inside a build, with a builder in flight, is not safe).

Use the imperative `open`/handle when you need to move or resize the window; use
`OverlayWindow` when you only need it to exist while some state holds. Both are fine to
mix — `overlay_widget.window()` returns the live handle.

> Working example: `examples/overlay_bar.zig` (`zig build overlay_bar`) — a main window
> that hides itself while an always-on-top 460x56 bar floats over the desktop, with a
> counter proving the main tree is never unmounted.

### Content reused across windows: `onUnmount`

A `childOf` content instance is **caller-owned**: it outlives the window and gets built
again if the window reopens. Anything in it that refers to *nodes* — a `Scope` holding
`dynText`/`bindStyle` bindings, a cached `NodeId` — belongs to that window's registry and
must be dropped when the window closes, or the next signal write reaches a freed store.
The framework tells you:

```zig
pub fn onUnmount(self: *RecorderBar) void {
    self.scope.deinit();
    self.scope = fw.signals.Scope.init(self.allocator);
}
```

The rule of thumb: state that refers to nodes is per-mount and is reset here; state that
is genuinely the app's (a counter, a flag) lives outside the component and is exactly
what survives.

## Text line height and metrics (`line_height`, `fw.text`)

Every text node lays out its lines in **slots** of `font_size × line_height`. The
same number drives measurement (the node's height), wrapping, the renderer's
baselines, the caret and click-to-character hit-testing, so they cannot disagree.
The cap band is centered in each slot: a taller line height adds leading evenly
above and below the glyphs, like CSS.

**The multiplier.** Unitless, like CSS `line-height: 1.4` or Flutter's
`TextStyle.height`. Unset, it is `fw.text.default_line_height` (**1.55**). A value
≤ 0, NaN or ∞ means "default", so a bad value never collapses text to zero height.
Set it any of these ways:

| Where | How |
|---|---|
| Raw builder | `try b.lineHeight(text_id, 1.2);` |
| `Text` component | `fw.component.Text{ .content = "…", .size = 14, .line_height = 1.2 }` |
| Theme style | `Text{ .content = "…", .style = t.typography.body_medium }` applies that style's `line_height` (1.42) |
| C ABI / C# | style key `"line_height"` with a number on the **text node**, e.g. `celeris_node_add_style(e, text_id, "line_height", "1.2")` |

`Text.line_height` wins over the style's. Changing it re-lays out the node, the
same as changing `font_size`. Styles are **not inherited**: the multiplier goes on
the text node itself. There is no `.line_height` box prop, because a box is not
measured as text (the same holds for `font_size` on a box).

Built-in widgets label with theme styles (`Button` → `label_large`, overridable with
its `text_style`; `Checkbox`, `Radio`, `RadioGroup`, `Dropdown` → `body_medium`), so
their labels use that style's line height. Both are 1.42, so a 14px label is 19.9px
tall, not 21.7px. To change it app-wide, set the style's `line_height` in your theme's
`typography`.

**Sizing rows to text (virtualized lists, code views).** Don't hardcode a row
height: a 16px font has a 24.8px slot at the default, so a 20px row overlaps its
neighbours. Ask `fw.text` for the number the text nodes will measure:

```zig
const fw = @import("celeris").framework;

const font_size: f32 = 16;
const row_h = fw.text.lineHeight(font_size); // 24.8 — default multiplier
// If your rows' text nodes set `.line_height = 1.25`, use the same factor:
const tight_row_h = fw.text.lineHeightWith(font_size, 1.25); // 20.0
// Rows built from a theme style: use the style's own factor.
const st = ctx.theme().typography.body_medium;
const styled_row_h = fw.text.lineHeightWith(st.size, st.line_height orelse fw.text.default_line_height); // 19.88
```

Use the **same factor the text node has**. `lineHeight(size)` is only right for
text that leaves `line_height` unset.

These are pure functions of the font size and factor (no engine, no font), so they
are exact in `build`, in tests and headless. `TextMeasure.lineHeight(size)` /
`TextMeasure.lineHeightWith(size, f)` give the same values from a measure handle.

**Baseline and caret band inside a box.** A widget that draws a caret, selection
band or underline over text asks for the geometry instead of hardcoding px:

- `TextMeasure.vertical(size, box_h, lines)` — default line height, engine-exact.
- `TextMeasure.verticalWith(size, box_h, lines, f)` — for text with a
  `line_height`; pass the node's factor, or the band drifts from the glyphs line by
  line.
- `fw.builder.verticalFallback` / `verticalFallbackWith` — the same computation
  without a measure handle.
- `TextMeasure.verticalStyled(size, box_h, lines, f, role)` — the geometry of a
  role's own face (a `fontMono` / `fontBold` node).

**Measuring text drawn with a role or letter spacing.** `TextMeasure.width` measures
the default face with no tracking. For text a node draws with `b.fontMono`,
`b.fontBold`, `b.fontRole` or `b.letterSpacing`, measure with the same style, or the
caret, the clicked column and the selection band drift further with every character:

```zig
const m = ctx.builder.measure orelse return;
const style: fw.builder.TextMeasure.MeasureStyle = .{ .role = .mono, .letter_spacing = 0 };
const caret_x = m.widthStyled(line[0..cursor], font_size, style); // == the next glyph's x
const mono_w  = m.widthRole(line, font_size, .mono);               // role only
const col = fw.component.columnAtXStyled(m, line, font_size, style, click_x);
```

- `widthStyled(prefix, size, style)` equals the renderer's pen x for the next
  glyph: same face (`fontIndexForRole`, with its fallbacks) and same tracking. The
  glyph itself is drawn snapped to the physical pixel, so on screen it can sit up
  to half a physical pixel from that x.
- `columnAtXStyled` takes one line (no newlines). It measures whole prefixes, so
  kerning and tracking never add up to drift, and it always returns a UTF-8
  codepoint boundary. It binary-searches the prefix widths (O(log n) measurements
  per hit-test), assuming they grow with each character; a letter spacing negative
  enough to cancel a glyph's advance breaks that, and the column is then a boundary
  but not necessarily the nearest. `columnAtX` is unchanged (default face, per-byte
  sum) and is what `TextInput`/`TextArea` still use.
- A `TextMeasure` built without `measureStyledFn` (a custom stub) falls back to
  `measureFn` and **ignores the style**. The engine's handle always has it.

**Testing without a window.** `fw.testkit.measureStub()` returns a deterministic,
role-aware `TextMeasure`: 10px per character for `.default`, 11 for `.bold`, 12 for
`.mono`/`.mono_bold`, plus `letter_spacing` per character, measured per codepoint, and
a −3px kern on the pair "AV" in the proportional roles so code that sums single
characters instead of measuring prefixes fails here as it would on a real font.
Install it with `b.measure = fw.testkit.measureStub();`. The advances are exposed as
`fw.testkit.MeasureStub.default_advance` etc.

**C hosts.** `celeris_get_caret_metrics` and `celeris_get_char_index_at` measure at
the default line height. For text whose node has a `line_height` style, call
`celeris_get_caret_metrics_ex` / `celeris_get_char_index_at_ex` with the same
factor (ABI 6). Otherwise the caret and the clicked line come out at 1.55 slots
while the engine draws at yours.

**Limits.** The slot is a multiplier of the font size. It is not computed from the
face's own ascent/descent/line gap (CSS `line-height: normal`), and there is no
per-node font family: faces are the app-wide roles from `setAppFonts`. Both are
listed under *Deferred work* in `ARCHITECTURE.md`. The built-in `TextInput` and
`TextArea` keep their own fixed metrics and do not read `line_height`. Layout
without a font atlas (some headless setups) sizes a text node as
`font_size + padding`, ignoring line count and `line_height`. With an atlas, which
real windows always have, the height is `lines × font_size × line_height`.

## Theming

The active theme is `b.theme`. Tokens are defined in `src/framework/theme.zig` — e.g. `bg_base`, `bg_surface`, `bg_input`, `accent`, `accent_hover`, `accent_pressed`, `text`, `text_secondary`, `text_disabled`, `text_on_accent`, `focus_ring`, `overlay_scrim`, `success`/`warning`/`danger`. Use the curated presets `Theme.dark()` (default) or `Theme.light()`, and read `b.theme.<token>` for custom boxes. (There is no `primary`/`text_normal` token — use `accent`/`text`.) Apply a token with the `…Of` helpers, which take a theme `Color`:

```zig
const t = ctx.theme();
const card = try b.openBox();
try b.backgroundOf(card, t.bg_surface);
const label = try b.addText("Themed");
try b.textColorOf(label, t.text_secondary);
b.close();
```

(`b.background(id, r, g, b)` takes raw 0–255 channels; `backgroundOf` / `textColorOf` / `borderColorOf` take a `Color`.)

**Typography.** `t.typography` holds Material-style `TextStyle`s (`display_large` …
`label_small`), each with a `size`, `weight` and `line_height`. Passing one to
`fw.component.Text{ .style = … }` (or `Button.text_style`) applies its size
**and its line height**. A hand-written `TextStyle{ .size = 13 }` leaves
`line_height = null` and keeps the engine default (1.55). See
[Text line height and metrics](#text-line-height-and-metrics-line_height-fwtext).

Read it reactively with `ctx.theme()` instead of `b.theme` when you want a runtime theme
swap to re-run your component: `ctx.themeSignal().?.set(Theme.light())` restyles every
build that read it, with no global rebuild.

**Themes are per window.** Each window has its own theme signal, shared by pointer with
its parent under `theme: .inherit` (one `set` restyles all of them) or independent under
`.own`. Window-scoped rendering follows: the `focus_ring` token is routed into that
window's engine on every build, so two windows on different themes draw their own focus
ring and a runtime swap is picked up — it is not a process-wide setting.

## Internal layer / escape hatch: `UIBuilder`

Underneath the widgets and bindings, `UIBuilder` (`ctx.builder`, aka `b`) provides the primitive drawing and layout instructions. In the modern model you use it mostly for **layout scaffolding** (boxes, flex, spacing) while widgets and bindings own the interactive/stateful parts. Reach for the raw primitives directly only when no widget fits.

- `const node = try b.openBox()` — open a container node.
- `b.close()` — close the last opened container.
- `const text = try b.addText("Text")` — add a static text node (use `ctx.dynText` for reactive text).
- `const img = try b.image("assets/logo.png")` — add an image node. Self-closing (no
  `close()`). The source is a **local file path** (relative paths resolve against the
  process's working directory), decoded with stb_image (PNG, JPEG, BMP, GIF's first
  frame, TGA and more). URLs are not supported. The image stretches to the
  node's box, so give it a `width` / `height`; `b.opacity` fades it. A file that fails
  to load draws nothing, with no error.
- `try b.rootAt(node)` … `b.close()` — rebuilds only `node`'s children: the `open*` calls
  that follow are matched against its current children (reused or deleted) instead of
  building a whole tree. This is what re-running one component's `build` uses; widgets
  call it to refresh a panel without touching the rest of the window (`Dialog` does
  this for its body). Most code never needs it.
- `const id = try b.openNode(.box)` — the general form behind `openBox` (also `.text`,
  `.image`, `.path`); `openNodeKeyed(type, key)` adds a reconciliation key so the node
  keeps its identity when siblings are reordered or inserted.
- `const p = try b.path(verts)` — add a stroked vector-path node (`verts: []const fw.PathVertex`).
  Self-closing. Each `PathVertex` is `{ x, y, c1x, c1y, c2x, c2y, move, close }`:
  `c1 == previous point` and `c2 == (x, y)` (or all four zero) → straight line,
  otherwise a cubic Bézier; `move != 0` starts a subpath, `close != 0` shuts it.
  Style the returned id with `b.borderColor` / `b.borderWidth` (stroke) and
  `b.opacity`. The node's intrinsic size is the vertex bounding box; author paths
  in local coords starting near the origin. **v1 is stroke-only, opaque, round
  caps/joins** — no fill, dashes, miter joins, or translucent strokes (see
  ARCHITECTURE.md's deferred list). C-ABI: `celeris_node_create(e, 3)` +
  `celeris_node_set_path`.

**Layout & Flexbox:**
- `try b.flexColumn(node)` / `try b.flexRow(node)`
- `try b.justifyContent(node, .center)` / `try b.alignItems(node, .center)`
- `try b.width(node, 100, .percent)` / `try b.height(node, 50, .px)`
- `try b.flexGrow(node, 1)` / `try b.gap(node, 16)`
- `try b.flexShrink(node, 1)` — lets the node give up space when the row/column
  overflows. **The default is 0 (Yoga-style), not CSS's 1:** nothing shrinks unless you
  ask, which is what lets scroll containers and virtualized lists overflow on purpose.
  Set it on a child that should get narrower, e.g. a text label next to fixed icons. `try b.flexBasis(node, 200, .px)` — its
  starting main-axis size before grow/shrink (`.px` or `.percent`).
- `try b.flexWrap(node, true)` — lets a row or column break onto more lines, but only
  once its children no longer fit; while they fit it stays one line.
- `try b.minWidth(node, 120, .px)` / `maxWidth` / `minHeight` / `maxHeight` — clamp the
  node's size; grow and shrink never take it past them (`.px` or `.percent` of the
  parent).
- `try b.positionAbsolute(node, left, top)` — takes the node out of the flex flow and
  places it at `left` / `top` px from its parent's origin. The parent keeps no room for
  it; combine with `zIndex` to draw it above siblings.
- `try b.scrollOffsetY(node, -150)` / `scrollOffsetX` — shifts all of the node's
  children by that many px (negative moves them up / left, i.e. scrolls down / right).
  Render-only: no layout solve, so it is cheap to animate. Pair it with
  `overflowHidden(node)` to clip what moves out. `ScrollView`, `VirtualList` and
  `VirtualGrid` drive it for you.

**Styling:**
- `try b.background(node, r, g, b)`
- `try b.radius(node, 8)`
- `try b.boxShadow(node, .{ .blur = 40, .dy = 18, .spread = -4, .color = t.shadow })` —
  CSS `box-shadow` semantics: `blur` is the blur *radius* in px (the shadow fades out
  over that distance, half inside its edge and half outside), `spread` inflates the
  shadow before the blur. A design token translates field for field. `blur = 0` with
  an offset gives a hard-edged shadow. The loose form is `b.shadow(node, blur, dx, dy,
  r, g, b, a)`.
- `try b.padding(node, top, right, bottom, left)` / `try b.margin(node, top, right, bottom, left)`
- per side: `try b.paddingLeft(node, 14)` (also `paddingTop`/`paddingRight`/`paddingBottom`,
  and `marginTop`/`marginRight`/`marginBottom`/`marginLeft`) — for the one-edge case,
  where the four-value form reads as noise. Margins and padding are px only.
- `try b.backgroundAlpha(node, r, g, b, 0.5)` — background with an opacity (0–1); the
  plain `background` is opaque. `borderColorAlpha` and `textColorAlpha` are the same for
  the border and text color.
- `try b.shadowSpread(node, -4)` — sets only the shadow's spread, for a shadow set with
  the loose `b.shadow(…)` form; `boxShadow` already takes `.spread`.
- `try b.linearGradient(node, r1, g1, b1, a1, r2, g2, b2, a2, vertical)` — fills the
  background from the first color to the second: left → right, or top → bottom when
  `vertical` is true. It replaces the node's background (the first color *is* the
  background), so call it instead of `background`, not with it.
- `try b.radialGradient(node, r1, g1, b1, a1, r2, g2, b2, a2)` — first color at the
  center, second at the edge; the edge is the longer half-side, so on a non-square box
  the shorter sides never reach the second color.
- `try b.borderTop(node, 2)` / `borderRight` / `borderBottom` / `borderLeft` — border width
  for one edge (px), overriding the uniform `borderWidth` on that edge, so a single
  bottom rule is `borderBottom(node, 1)` plus a `borderColor`. **Paint only:** unlike
  `borderWidth`, they don't push the content inward; add padding if text would touch
  the line.
- `try b.borderStyle(node, .dashed)` — dashed border (`.solid` is the default). Dashes
  only render on boxes without `radius`; a rounded box always draws a solid border.

**Text styling:**
- `try b.textColor(text_node, 255, 255, 255)`
- `try b.fontSize(text_node, 14)`
- `try b.letterSpacing(text_node, 0.5)` — extra px between glyphs (negative tightens)
- `try b.lineHeight(text_node, 1.4)` — line-height multiplier; see
  [Text line height and metrics](#text-line-height-and-metrics-line_height-fwtext)
- `try b.fontBold(text_node, true)` / `try b.fontMono(text_node, true)` — face role
- `try b.textAlign(text_node, .center)` — `.left` (default), `.center` or `.right` within
  the text node's own box. The box must be wider than the text for this to show, so
  give it a `width` (or let it stretch in a column).

**Pointer input and stacking:**

These attach raw string action ids that you handle through the `EventRouter` (see
[Escape hatch: raw action-ids + EventRouter](#escape-hatch-raw-action-ids--eventrouter)).
Typed handlers on `boxNode` (`on_click`, `on_right_click`, `on_hover`, …) set the same
modifiers for you; prefer them. Delivery follows the
[Pointer event delivery rules](#pointer-event-delivery-rules).

- `try b.rightClickable(node, "action")` — the node receives `right_click`. It fires when
  the right button goes **down**, not on release, and bubbles through right-clickable
  ancestors like `click` does.
- `try b.hoverable(node, "action")` — the node receives `mouse_enter` / `mouse_leave`. Hover
  goes to the **nearest hoverable ancestor-or-self** of the node under the pointer, so
  moving between children of one hoverable box sends nothing; only one node is hovered at
  a time.
- `try b.tooltip(node, "text")` — a tooltip shown after a hover dwell, rendered by the
  app's `TooltipHost`. Same as the `.tooltip` box prop, but usable on a node that already
  exists. It also makes the node hoverable with an id of its own, **replacing** any
  `hoverable` action id set before it; to keep your own hover handler, call `hoverable`
  after `tooltip`.
- `try b.pointerEventsNone(node)` — hit-testing skips this node, so a click, hover or
  wheel over it goes to whatever is below it (a sibling underneath, or its parent). It
  is still drawn and still focusable. **Unlike CSS `pointer-events: none`, it is not
  inherited:** its children stay hittable; set it on each child that should let events
  through.
- `try b.noDrag(node)` — stops a press from bubbling past this node, so an ancestor's
  handler (typically a custom title bar's drag region) never sees it. The node itself
  and anything inside it still get the event. The CSS equivalent is `app-region: no-drag`.
- `try b.zIndex(node, z)` — draw and hit-test order. Higher `z` is drawn on top and gets
  the pointer first; equal `z` keeps tree order (later siblings on top). **Children
  inherit their parent's `z`** unless they set their own, and the comparison is global
  across the window, not per parent (there are no CSS stacking contexts): a child with
  `z = 5` inside a `z = 100` panel is drawn *below* an unrelated `z = 10` node.
- `const panel = try b.openOverlay(z)` … `b.close()` — opens a box that floats above the
  app at `z`, positioned with `left` / `top` in the coordinates of the container the
  overlay host was mounted into (window coordinates for a `runApp` singleton). It also
  takes its parent (the host's anchor box) out of the layout flow, so use it only in a
  component that renders nothing but overlays, like `TooltipHost` and `ToastHost` do;
  any other content in that component would leave the layout with it.

**Accessibility (a11y / UIA):**

Celeris derives a semantic accessibility tree (`src/core/accessibility.zig`) from the
node store and exposes it to platform UIA clients and screen readers. On Windows the
bridge is a real UIA provider (`src/platform/uia.zig`), grafted onto the HWND via
`WM_GETOBJECT` — Inspect.exe, NVDA/Narrator and UI-automation test drivers see the app
as a native control tree, not as one opaque window. **Only nodes that carry a `role` —
either set explicitly or inferred — are serialized into that tree**, so a custom widget
that wants to be seen by a screen reader (or by a UIA automation/test tool) must
annotate its nodes. The framework-owned widgets already do this; you only reach for
these primitives when building your own widget or an escape-hatch layout.

- `try b.role(node, "treeitem")` — sets the ARIA-ish role. Explicit roles win over
  inference. `button`/`checkbox`/`radio`/`slider` pass through as-is; `icon_button` maps
  to `button`. Un-annotated nodes get a role inferred from their modifiers (e.g. a
  `clickable` box → `button`, an I-beam `cursor` → `textbox`), which is why standalone
  layout boxes without a role stay invisible to UIA.
- `try b.ariaLabel(node, "Name")` — an explicit accessible name. Use it when the visible
  text isn't the right name — e.g. a row whose leading chevron/icon glyphs would
  otherwise be mistaken for the name. Roles that are "named by contents" (`button`,
  `treeitem`, `tab`, `option`, `menuitem`, `heading`, …) otherwise take their name from
  the first text found in the subtree.
- `try b.focusable(node, action_id)` — makes the node keyboard-focusable and routes
  focus actions through `action_id`.
- `try b.capturesTab(node)` — while the node is focused, plain Tab / Shift+Tab reach
  its `key_down` handler instead of moving focus (code editors, grids). Ctrl+Tab, or
  Escape then Tab, still move focus (within the active focus scope), so keyboard
  users are never trapped. Handle Tab on `key_down`: Linux sends no `char_input` for it.
- **Focus ring.** The focused node gets a 2px ring in the theme's `focus_ring` color,
  drawn just outside its bounds and following its `radius` — only when focus came from
  the keyboard, UIA or code (CSS `:focus-visible`); a mouse click focuses without a ring.
  `try b.noFocusRing(node)` turns the ring off for that node (CSS `outline: none`, WPF
  `FocusVisualStyle="{x:Null}"`) for widgets that show focus their own way, like an
  editor's caret or a grid's active cell. Focus, Tab order, key routing and UIA focus
  events are unchanged. It is not inherited: a focusable child still gets its ring. A
  widget that turns the ring off must draw its own visible focus indicator (WCAG 2.4.7).
- **Roving highlight (`virtual_focus_target`).** A list-like widget that moves a
  highlight with the arrow keys can keep real focus on its container (so it keeps
  receiving keys) and point the ring and screen readers at the highlighted row instead
  — ARIA's `aria-activedescendant`. There is no builder helper; write the modifier on
  the focusable container whenever the highlight moves:
  `try b.store.setModifier(container, .virtual_focus_target, .{ .number = @floatFromInt(row) })`.
  The ring then paints around `row`, and UIA raises its focus-changed event for `row`.
  Use `.{ .number = -1 }` for "nothing highlighted" (there is no way to remove a single
  modifier); the ring then falls back to the container. A target that no longer exists
  or has zero size also falls back. `Menu` works this way.
- **Focus scopes (`b.focus_scope`).** An overlay that should trap Tab — a dialog, a
  popup menu — copies `b.focus_scope` (a `?FocusScopeHooks`; `null` in tests and
  headless runs) during `build`. When it opens it calls `fs.push(panel, origin)`: Tab
  then cycles only inside `panel`, and focus moves to its first focusable node. Pass
  `.keyboard` as `origin` when a key opened it and `.pointer` for a click, so the
  ring shows only when it should. On close, `fs.pop()` restores the focus held before
  the push, if that node still exists and can take focus. Scopes nest up to 8 deep;
  `push` returns `false` past that or when `panel` no longer exists, and a push must
  be matched by exactly one pop, including when the widget unmounts while open.
  `Dialog` and `Menu` already do this.
- `try b.nodeId(node, "name")` — attaches a string tag to the node. It is **not** the UIA
  `AutomationId` (UIA reports the numeric node id) and the engine does not look nodes
  up by it, except for the reserved `"debug_text"`: a text node tagged with it when the
  run loop starts gets its content overwritten every frame with the window size, so
  don't use that name for anything else. It is what the `.id` box prop sets.
- State flags surfaced to the a11y tree (a screen reader hears "checked"/"expanded"/
  "disabled"): `try b.setChecked(node, bool)`, `try b.setExpanded(node, bool)`,
  `try b.setDisabled(node, bool)`. Selection is reflected through `.checked`, which the
  UIA `SelectionItem` provider reads as `IsSelected`.

**Action patterns — a UIA client can *drive* the app, not just read it.** Annotating a
node with a role is all it takes: the provider derives which UIA control patterns to
expose from the semantic role, with no per-widget wiring. This is automatic and always
on; there is no build flag and no opt-in.

| Role | Pattern exposed | What the client can do |
|------|-----------------|------------------------|
| `button`, `link`, `menuitem` | **Invoke** | `Invoke()` presses it |
| `checkbox`, `switch` | **Toggle** | `Toggle()`, and `ToggleState` reads back |
| `textbox` (and an editable combobox) | **Value** | `SetValue()` replaces the text; `get_Value` reads it |
| `combobox`, `treeitem`, `menuitem` | **ExpandCollapse** | `Expand()` / `Collapse()`, plus the current state |
| `radio`, `option`, `tab`, `tabitem`, `treeitem`, `cell` | **SelectionItem** | `Select()`, and `IsSelected` reads back |

Two rules the implementation holds to, and that you can rely on:

- **Every pattern runs the same code path as real user input.** `Invoke()` on a button
  dispatches the same click a mouse would; `SetValue()` focuses the field and goes
  through the ordinary edit/commit path (the one IME uses). There is no parallel
  "programmatic" channel that can drift from what a user experiences — so a handler
  cannot be reached by automation without also being reachable by a person.
- **Patterns are non-blocking and thread-safe.** UIA calls them from its own RPC thread;
  each one marshals the work onto the UI thread and returns immediately. Intent is
  re-checked against fresh state there, so `Expand()` on an already-expanded node is a
  no-op rather than a collapse.

Per UIA, a role exposes one *primary* action: a selection item (`tab`/`treeitem`/
`option`) gets SelectionItem rather than Invoke, and a `radio` gets SelectionItem rather
than Toggle — exposing both confuses clients about what the element does.

**Accessibility events are raised for you.** A screen reader is told about changes
instead of having to re-poll, and no app or widget code participates:

- **Focus changes** — every focus move (Tab, click, focus scopes, a client's own
  `SetFocus`) funnels through one place in the engine, which raises the UIA
  focus-changed event.
- **Property changes** — the `PropertyStore` fires only on *real* value changes (a
  write of the same value is not an event), and the engine maps them to the right
  pattern property by role: `.checked` → Toggle or SelectionItem, `.expanded` →
  ExpandCollapse, `.text` → Value.

Both are skipped entirely when `UiaClientsAreListening()` is false, so an app with no
assistive tech attached pays nothing.

> Not exposed yet: a tri-state `ToggleState` (`.checked` is a bool, so `Indeterminate`
> is unreachable), and Linux AT-SPI — the semantic tree is platform-agnostic, but only
> the Win32 bridge is built.

**Widget shortcut — `aria_label`.** For an icon-only `Button` the visible label is a
glyph, which would become the accessible name. Pass `.aria_label` and that wins:

```zig
try ctx.mountOwned(fw.button.Button, .{
    .key = "explorer",
    .label = "\u{eb0f}",          // a Codicon glyph
    .aria_label = "Explorer",     // what a screen reader announces
    .on_click = ctx.handler(self, onExplorer),
});
```

**Worked example — `TreeView` (`src/framework/tree_view.zig`).** The root gets
`role(root, "tree")` plus `focusable` (keyboard nav lives on the root, not per row), and
each row gets `role(row, "treeitem")`, an `ariaLabel` of the node text, `setExpanded` on
branches, and selected state via the `.checked` flag. Because `treeitem` is in the table
above, every row automatically carries **ExpandCollapse** and **SelectionItem**: a UIA
client can navigate the rows, read their names, hear expanded/selected state, and expand
or select a row programmatically — all through the same click path the mouse uses.
(Still not exposed: an explicit depth `level` / parent-child relationship — hierarchy is
conveyed only by visual indentation.) Follow the same pattern for any custom container
that should be navigable.

**Worked example — a key/value list.** See the property-panel recipe above: a bare box
has no role and never reaches the a11y tree, so detail rows are stamped as
`role(row, "listitem")` inside a `role(container, "list")`, with an `ariaLabel` of
`"key: value"` so the pair is announced as one unit instead of two stray text runs.
