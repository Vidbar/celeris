# Celeris Architecture

**What is this document:** the rationale of the design — *why* the engine has the shape
it has. The decisions here are durable. For the practical "how do I use it" reference see
**[FRAMEWORK_API.md](FRAMEWORK_API.md)** (its snippets are compiled in CI). For current
status, verification commands and deferred work, see the sections at the end of this file
and the README.

---

## Vision

The long-term aim is a lightweight, native alternative to Electron-class stacks for
desktop UI (Windows and Linux first), **consumable from other languages** (C# today,
anything with a C FFI) through a **C-ABI**: no browser engine, and no reimplementing
the framework in every host language.

Central architectural consequence: **the declarative framework in Zig (`src/framework/`)
is the product, and the C-ABI is the definitive public interface**. Everything designed must
be able to cross that boundary without reimplementing framework logic in the host. The source
of truth is always the Zig code.

---

## Philosophy: declarative *and* reactive — two axes, joined deliberately

These are different properties, and Celeris implements both:

- **Declarative** is about *how you describe* the UI: `build()` states *what* should exist
  given the current state; the keyed reconciler computes the diff against the retained tree.
  The opposite is imperative widget mutation (`setItem()`-style APIs, removed from the
  framework).
- **Reactive** is about *how changes propagate*: signals track which consumers read which
  data, and a write re-runs only the affected consumers. The opposite is manual invalidation
  (`triggerRebuild()`, removed from the user-facing path).

The engine's core model (the "Track R" work, completed 2026-07) is the **junction of the
two**: every component's `build()` runs inside an effect, so *describing* the UI *is*
subscribing to it. Reading a signal with `.get()` during a build subscribes that component;
a later write re-executes only that build, and the keyed reconciler absorbs the diff with
node reuse. This is the SolidJS model, without a VDOM.

## Strategic Decision: NO virtual DOM

There is no virtual DOM or shadow tree. The `UIRegistry` tree is the **only**
representation of the UI in memory. Justification, based on what the core does:

1. `UIBuilder.openNode()` (`src/framework/builder.zig`) **reconciles** against the retained
   tree: reuses nodes by position+type (or by key) and deletes leftovers in `close()`.
2. `PropertyStore.setLayout/setStyle` (`src/core/properties.zig`) **compares values** and
   only marks `layout_dirty`/`render_dirty` when there is a real change, cutting propagation
   if the ancestor is already dirty.

A VDOM would duplicate the tree and re-diff everything to arrive at the same result that the
granular dirty-tracking already produces.

## Reconciliation in Three Levels

| Level | When | Mechanism | Cost |
|---|---|---|---|
| **Fine (bindings)** | A value maps 1:1 to a node property (color, text, dimension) | `bindStyle`/`bindLayout`/`bindText`/`dynText`: the signal's effect writes directly to `PropertyStore` → existing dirty-tracking. **No `build()` re-runs.** | O(1), no rebuild, no diff |
| **Component (build-effect)** — *the default* | Any signal read with `.get()` inside a component's `build()` changes | `mountReactive`/`mountOwned` run the build inside an effect. On change, **only that component's build** re-executes; the keyed reconciler reuses its subtree's nodes. | O(component subtree), heavy node reuse |
| **Structural (manual partial rebuild)** | Escape hatch: a container reconstructs arbitrary children outside the reactive path | `UIBuilder.rootAt(subroot)` + rebuild + `markLayoutDirty(subroot)` (the pattern inside `tabs.zig`/`tree_view.zig` internals) | O(subtree) |

Ordering guarantees of the build-effect level (the delicate part, encoded in
`src/framework/component.zig` + `src/core/signals.zig`):

- Build-effects get a **height floor above every `Computed`** plus the anchor's tree depth,
  so within one propagation all derived values recompute first, then ancestor builds, then
  descendant builds.
- **Parent→child subsumption:** if a parent's build re-runs, it re-mounts its children; a
  child's queued build-effect detects (via `propagation_gen`/`built_gen` stamps on the
  anchor node) that its subtree was already rebuilt and skips. One `set()` → each affected
  build runs exactly once.
- `batch()` coalesces N writes into one propagation → one rebuild per affected component.
- Writes from background threads are safe *for repaint scheduling*: `signals.on_propagation_end`
  wakes the render loop through the same thread-safe path as `celeris_request_redraw`.
  (Running the drain itself must happen on the UI thread; heavy work marshals results via
  `postTask` or writes signals from callbacks on the UI thread.)

**Rule of thumb:** the component level is the default; `bindStyle`/`bindText` are the
opt-in optimization for hot paths where a rebuild-per-change would be wasteful (e.g. a
widget's hover background is an effect write, preserving the "hover → 1 `render_dirty`
node / 0 `layout_dirty`" invariant enforced by `verification_test.zig`).

---

## Component Model (comptime, no vtables)

A component is any Zig struct with `build(self, ctx: *BuildContext)`. There are no
interfaces or `*anyopaque` in the hot path. The canonical widget pattern
(`src/framework/button.zig` is the reference):

- **Framework-owned instances:** users mount widgets with
  `ctx.mountOwned(Widget, .{ ...props })`. The framework allocates the instance on first
  mount, **reuses it across rebuilds** while its keyed anchor survives (props re-applied,
  state preserved), and destroys it on unmount. No `init`/`register`/`deinit` in user code.
  The manual path (user-owned struct + `ctx.mount`/`ctx.mountReactive`) remains as an
  escape hatch.
- **State is signals**, auto-initialized in `onMount(self)` / `onMount(self, allocator)`
  (arity detected at comptime). Visual-only state (hover, press) is written by fine effects
  (render-only); structural state is read in the build (reactive).
- **Typed events:** `on_click`/`on_change`/... props take an `events.Handler` built with
  `ctx.handler(payload, comptime f)` — allocation-free comptime trampoline, zero strings.
- **Slots:** a widget exposing composed content declares `content: ?Child`; callers pass
  `component.childOf(T, ptr)` or `component.slot(&.{ ... })`.
- **Reserved mount props:** `.key` (sibling disambiguation), `.fill` (anchor fills parent),
  `.hug` (anchor shrink-wraps content).

What is exploited from Zig:

- **Props as struct literals + `inline for`**: `BuildContext.box` iterates fields at
  comptime and generates the exact calls to `PropertyStore`. Ergonomics of named
  parameters with **zero runtime cost** (no tables, no strings, no branches).
- **Children as comptime tuples**, resolved by `@hasDecl`/`@typeInfo` at compilation.
- **Type-erased children at runtime** (`component.Child` / `childOf`): the minimal handle
  (`build` + `deinit`, no `handleEvent`) used by containers (`ScrollView`/`Tabs`/`SplitPane`).

## Lifecycle

Mounted components are tracked in a `MountTable` (anchor `NodeId` → record). The table
subscribes to the registry's `node_removed` hook: when reconciliation deletes a mounted
anchor, the framework runs the component's `onUnmount`, destroys its build-effect (safe
mid-drain), and frees framework-owned instances.

`EventRouter` subscribes to the same hook (`nodeRemovedListener` → `removeNodeHandlers`),
which prunes *every* owner-keyed channel — `node_handlers`, but also `tick_handlers`,
`global_handlers`, and `observers`. A widget that registers a tick/global/observer handler
(caret blink, drag-follow, the tooltip host's dwell tracking) passes its own node id as the
owner and calls unconditionally from `build()` every time — replace-in-place (same
invariant as `onNode`) makes the re-registration on rebuild a no-op, and removal on unmount
is automatic. No `onUnmount` bookkeeping, no `removeGlobalHandlers`/`removeTickHandlers` to
remember: those don't exist anymore. (Whatever registry the router is attached to must
subscribe it via `addNodeRemovedListener` — every production host does; a test harness that
builds its own registry/router pair needs to as well, or pruning silently doesn't happen.)

Tearing a whole tree down (a window closing) runs the same hook: `MountTable.deinit`
fires every record's `onUnmount` before freeing anything. A type-erased `Child`
(`component.childOf`) forwards it through `Child.unmount()`, so **caller-owned** content
built into a window — which outlives that window and may be built into the next one —
gets told its nodes are gone and can drop bindings that pointed at them. Without that,
the first signal write after a window closes reaches a freed store.

## Windows

The engine has always been multi-window: a pool of 16 independent `EngineState`s, each
with its own registry, store, renderer and atlas; a loop that walks all of them with
per-engine dirty flags; input routed by native handle; and cascading close through
`parent_engine_id`. What was single-window was the **framework**: `runApp` kept every
window's state — mount table, theme signal, app scope, caption config — in a comptime
`Runner` struct behind two globals.

That state is a `WindowHost` now, one instance per window (`src/framework/application.zig`).
The consequences are the point of the design:

- **A second window is a second host.** Opening or closing it never touches another
  window's tree — no unmount, no lost scroll or panel state.
- **Nothing is frozen at startup.** `app_bar_height` and friends are host fields, so they
  are changeable at runtime.
- **Window-scoped rendering.** The focus-ring color moved from a mutable renderer global
  onto `EngineState` (carried through `BakeContext` next to `focused_node`) and is written
  on every build from that window's theme. Two windows on different themes no longer
  overwrite each other, and a runtime theme swap is picked up.

`rebuildUI` takes a bare `fn (*UIBuilder)` with no context parameter, so each window slot
gets its **own comptime-generated trampoline** that looks up `g_hosts[slot]` — the same
technique the per-engine event trampolines already used, and the reason none of this
needed a C-ABI change.

Two ordering rules the implementation depends on:

- **Closing is deferred.** `close()` typically runs from a click, i.e. from inside the
  loop's own walk over the engines; freeing the engine there would pull the registry out
  from under the frame in flight. `celeris_window_destroy_deferred` queues it, and the
  queue drains at the top of the next iteration, before anything reads an engine.
- **An event that names a window matches strictly.** The handle-less fallback (synthetic
  input) stays, but an event naming a window that matches no engine is dropped rather than
  sent to the first one. Windows fires `WM_SIZE` from inside `CreateWindowExA`, before the
  new window is recorded on its engine — guessing there resized the *main* window to the
  new window's dimensions.

`WindowHandle` carries a monotonic generation stamp, so a handle kept past its window's
close is inert even if the engine slot and the heap address are both recycled.

The public API (`window.open`, `WindowHandle`, `OverlayWindow`, `ctx.dragRegion`) is in
`docs/FRAMEWORK_API.md`; `examples/overlay_bar.zig` is the compiled reference.

## Events

Two channels, by design:

1. **Typed per-node handlers (the user-facing path):** `EventRouter.onNode(node, kind, handler)`,
   auto-wired by the declarative `on_*` props. Dispatch is by `CelerisEvent.node_id`.
   Entries are replaced in place on rebuild and pruned when the node is removed.
2. **String action-ids (the C-ABI / interop channel):** hit-testing still carries an
   action-id string (autogenerated `"n{id}"` for framework widgets, or user-set for raw
   boxes) because the C host consumes events by id. `router.on(id, ctx, handler)` remains
   for low-level Zig interop.

Plus three broadcast channels, each keyed by the registering widget's own node id (see
Lifecycle for the pruning contract this shares with `onNode`):
- `onTick` (per-frame, no id) — caret blink, dwell timers.
- `onGlobal` (mouse_move/up without id) — drag-follow (sash/thumb).
- `onObserver` — sees *every* routed event regardless of node/id, as a side channel that
  never consumes it. For code that needs to watch everything without being anyone's
  handler (the tooltip host's hover/press/scroll dwell tracking, an app-level focus
  counter) — not "prefix matching on all-ids-start-with-empty-string" dressed up as
  something else, which is what this used to be built from.

Channel 2 is **interop, not the framework's own plumbing**. Widgets that once leaned on
it have been migrated off: `tree_list` used to register a *prefix* handler and parse ids
out of the string, and now routes by node id like everything else — a new widget
reaching for `router.on`/`onPrefix` was a design smell, so `onPrefix` (and the wildcard
`onPrefix("", ...)` idiom it enabled) is gone; genuine "watch everything" needs go
through `onObserver` instead.

Accelerators (`EventRouter.setAccelerators`) bind a keyboard chord straight to a
`Handler`, called directly on match — no detour through an id string and a list scan.

**Dispatch is re-entrant by construction.** `route()` snapshots the matching handler
lists before it calls any of them. A handler routinely does something that mutates the
router — a click that navigates, unmounts a subtree, and drops the very entries being
iterated — and walking the live list there is a use-after-free waiting for the right
click order. Snapshot-then-dispatch makes "this handler tore down the tree it was
dispatched from" ordinary instead of fatal, which is the same reason `close()` on a
window is deferred.

## Accessibility

`src/core/accessibility.zig` derives a semantic tree (roles + states) from the node store;
`src/platform/uia.zig` bridges it to Win32 UI Automation, grafted onto the HWND through
`WM_GETOBJECT`. The core stays platform-agnostic — it knows about ARIA-ish roles, not
about COM — so AT-SPI can later be a second consumer of the same model.

Four decisions carry the design:

- **Roles drive patterns, not widgets.** Which UIA control patterns a node exposes
  (Invoke / Toggle / Value / ExpandCollapse / SelectionItem) is a pure function of its
  semantic role. No widget registers anything, and a custom widget that sets a role gets
  the patterns for free. The role→pattern predicates are pure functions, so they are
  tested headless with no COM involved.
- **A pattern executes the real input path.** `Invoke()` dispatches the same click a
  mouse would; `SetValue()` goes through the focus → select-all → `text_commit` path
  that IME and the keyboard use. The alternative — a parallel "programmatic" channel —
  drifts silently from what a user experiences, and turns automation into a second
  behaviour to maintain. The one genuinely new code path this needed was a single
  additive export, `celeris_dispatch_set_text`.
- **Everything crosses to the UI thread, and re-checks there.** UIA calls pattern methods
  from its RPC thread, so each one enqueues through the task queue and returns `S_OK`
  immediately (patterns are fire-and-forget and must not block). Intent is evaluated
  *after* the hop, against fresh state — `Expand()` on an already-expanded node is a
  no-op rather than a collapse — which closes the time-of-check/time-of-use gap that
  reading state on the COM thread would open.
- **Events come from one funnel per datum, not from handlers.** Focus events are raised
  from `moveFocus`, the single point every focus change passes through (Tab, click, focus
  scopes, a client's `SetFocus`); property events come from a `PropertyStore` listener
  that fires only on real changes, with the role→pattern-property mapping living in the
  engine so the store stays platform-agnostic. Raising from individual click handlers
  would mean every new handler is a chance to forget. Both raises are skipped when
  `UiaClientsAreListening()` is false, so an app with no AT attached pays nothing.

Pattern objects are **embedded in the provider struct** (`@fieldParentPtr`, one refcount
per node) rather than separately allocated COM objects — fewer lifetimes to get wrong in
the part of the system with the least type safety.

## Reactivity (signals)

`src/core/signals.zig`: `Signal(T)` with automatic dependency tracking, memoized
`Computed(T)` (recomputes once per change, re-notifies only if the value changed),
`Effect`, `Scope` (batch disposal), `batch()`. Propagation is **glitch-free**: `set()`
opens a propagation and the outermost close drains the queue in ascending `height`
(dependency order) with dedup — each effect runs once per propagation and never observes
stale derived values. Fine bindings: `bindStyle`/`bindLayout`/`bindText`/`bindList`.

Known limitation (by design, author error): dependency cycles are not supported; a build
that writes a signal it reads is the same class of error.

## C-ABI Boundary

`src/c_api.zig` is a thin layer with no framework logic; `include/celeris.h` is the
compile-verified C contract: `zig build test` builds `examples/c_smoke.c` against it
and links it to the library, so a declaration without an export fails the build.
Struct layouts are pinned by `_Static_assert` of size/offsets on both sides. Additive
exports bump `CELERIS_ABI_VERSION` (currently 4); until 1.0, breaking changes are
allowed but must be listed in `CHANGELOG.md`.

- **Signals by handle** (`celeris_signal_*`): the host creates a signal, binds it once to a
  node property, and only does `set`. **The host manages state, not nodes.**
- **Structured events** (`CelerisEvent` + `celeris_register_event_callback`): only channel.
  **Contract:** `action_id`/`text` point to emitter stack buffers, valid only during the
  callback — the consumer must copy them.
- **Multi-window:** events route per engine via a comptime array of C-ABI trampolines
  (`src/framework/window.zig`, and `application.zig` for `runApp`-owned windows) — no
  broadcast. Secondary windows add only additive exports: `celeris_window_set_bounds` /
  `get_bounds` / `set_always_on_top` / `set_visible` / `native_handle` /
  `destroy_deferred`, `celeris_set_close_request_callback`,
  `celeris_set_focus_ring_color`, `celeris_display_work_area`. `CelerisWindowConfig`
  grew fields at the end, negated where needed (`fixed_size`, `start_hidden`,
  `no_quit_on_close`) so a host compiled against the shorter struct leaves them zeroed
  and keeps the previous behaviour.
- `celeris_last_error()` is the error channel; single-thread contract documented in the
  header (UI thread owns the drain; `celeris_post_task` marshals work in).

---

## How to verify (Zig 0.16)

- `zig build test` — unit tests, the adversarial C-API fuzz gate, the C host smoke
  test (`examples/c_smoke.c`) and a `zig fmt` check. Headless: no window needed.
- `zig build examples` — compiles every example without running it.
- `zig build` — the shared library and `include/celeris.h` in `zig-out/`.
- **Linux prerequisites** (Debian/Ubuntu names): `libwayland-dev libwayland-bin
  libxkbcommon-dev libdecor-0-dev wayland-protocols`, plus a font such as
  `fonts-dejavu-core`. CI runs the same commands on Windows and Ubuntu
  (`.github/workflows/ci.yml`).

## Deferred work (identified, deliberately out of scope so far)

Large follow-ups needing dedicated design, real hardware, or OS services to verify:

- **Linux AT-SPI (DBus)** — the semantic tree is platform-agnostic and the Win32 UIA
  bridge is done (see *Accessibility* above), so this is a second consumer of an
  existing model rather than new design. Needs a real Linux desktop to verify.
- **Tri-state toggles** — `.checked` is a bool, so UIA's `ToggleState.Indeterminate` is
  unreachable. Widen to an enum when a control actually needs it.
- **Transforms (rotate/scale) and subtree opacity** — require render-to-texture.
- **Stroke path fill / joins-caps enum / dashes / per-path opacity** — `NodeType.path`
  ships stroke-only, opaque, round caps+joins (from the capsule SDF), reusing
  `border_color`/`border_width`/`opacity`. Each of the four is a real cost, not a
  taboo: fill needs a tessellator and has no consumer yet; a joins/caps enum
  waits for a control that needs miter (same gate as the tri-state); per-path
  opacity needs an offscreen coverage pass (overlapping capsules double-blend at
  joints otherwise); dashes are a fast-follow once AA is proven on hardware.
- **data-grid** widget; **grid layout** algorithm; intrinsic `min-width: auto`
  (text min-content).
- **Text:** color emoji (COLR/CPAL), bidi/RTL (UAX#9), rich text runs, full UAX#14
  pair table.
- **Text line height from font metrics** (CSS `line-height: normal`). The line slot
  is `font_size × multiplier` (default 1.55, overridable per node with
  `line_height`), not ascent + descent + line gap of the face. Switching the default
  would move every text box in every app; the per-node multiplier already gives
  control.
- **Font family per node/component** (Monaco's `fontFamily`). Faces are process-wide
  roles (`primary`/`bold`/`mono`/`mono_bold`, `setAppFonts` before the first window)
  because the atlas is built at engine init and caches glyphs by font index. A
  per-node family needs runtime face registration in the atlas — its own design.
- **Platform:** system tray, OS notifications, global shortcuts, fractional scaling
  (`wp_fractional_scale_v1`), deep links, auto-update, Win32 native `IDropTarget`,
  scissor-rect clipping (today fragment `discard`, correct but over-shading).
- **Live-hardware verification:** multi-window/IME/menus confirmed headless and on Windows;
  Wayland pixel-level confirmation needs a real Linux desktop with GPU (WSLg is not enough).
- **Secondary-window controls on Wayland.** `setBounds`/`setAlwaysOnTop`/`setVisible`/
  `getBounds` and `workArea` are Win32 only; the Wayland vtable entries are null (a
  no-op) because the compositor owns placement and stacking there, and there is no
  work-area query. So `window.open` works, but `.placement = .anchored` falls back to
  the platform default and an overlay cannot be told to float on top. Doing this
  properly needs `xdg-positioner` for child surfaces and `wlr-layer-shell` (or the
  desktop's portal) for a real always-on-top HUD — a design job, not a port of the Win32
  calls. The close-request callback is likewise unwired there (libdecor already routes
  close through its frame handler).

## What is NOT done (by decision)

- **Virtual DOM / shadow tree** — see strategic decision above.
- **X11 support** — Wayland only on Linux, by design.
- **macOS** — out of the current scope (Linux + Windows primary).
- **Bindings other than C# (.NET)** — Node.js/N-API definitively discarded; TypeScript,
  Python, Rust, etc. postponed indefinitely to focus on the Zig engine + `Celeris.Net`
  (`bindings/csharp/`) reaching production quality.
- **Changes in core/layout/render unless additive.**
