/*
 * celeris.h — C-ABI for the Celeris UI engine.
 *
 * This is the boundary that host languages (C# via bindings/csharp, or any FFI)
 * consume. The Zig framework (src/framework/) is the source of truth; this header
 * mirrors the `pub export fn` surface of src/c_api.zig, and `zig build test`
 * compiles a C program against it (examples/c_smoke.c) to keep the two in sync.
 *
 * STATUS: pre-1.0. Struct layouts are pinned by static asserts on both sides;
 * additive changes bump CELERIS_ABI_VERSION, and breaking changes are called out
 * in CHANGELOG.md until 1.0, after which they require a new major. Check
 * celeris_abi_version() at load time. Events are delivered solely through the
 * structured callback (CelerisEvent / celeris_register_event_callback).
 * Window control + clipboard + file dialogs are implemented on both Win32 and
 * Wayland (the latter via libdecor / wl_data_device / XDG portal).
 *
 * Conventions: engine_id is 1-based; 0/negative is invalid. Functions returning
 * int return 0 on success and -1 on failure unless noted; on failure call
 * celeris_last_error() for a human-readable reason. Strings are null-terminated
 * UTF-8. Pointers returned by the engine (get_dom_json, get_devtools_snapshot) are
 * engine-owned — do not free with the C allocator; use celeris_free_string where
 * documented.
 *
 * THREADING: the engine is single-threaded. Call all functions for a given engine
 * from the one thread that drives its loop (the thread that called
 * celeris_start_loop). There is no internal locking; concurrent calls are UB.
 */
#ifndef CELERIS_H
#define CELERIS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* C-ABI version of this header / build. Compare against celeris_abi_version() at
 * load time; a mismatch means the .dll/.so doesn't match this header. */
#define CELERIS_ABI_VERSION 6u
uint32_t celeris_abi_version(void);

/* ── Diagnostics: zone profiler ───────────────────────────────────────────────
 * No-ops unless the library was built with `-Dprofiling`; exempt from the ABI
 * version contract above (a non-profiling build still exports them as no-ops, so
 * calling them is always link-safe). They record timed zones across the engine
 * and dump them as a Chrome Trace JSON file (open in https://ui.perfetto.dev or
 * chrome://tracing) for a flame chart / hot-path view. The CELERIS_TRACE=<path>
 * env var auto-enables recording at loop start and dumps on exit; these let a
 * host enable mid-run and dump on demand (e.g. bound to a key) without exiting.
 * In a -Dprofiling build, pressing F12 in the window also dumps the trace to
 * celeris_trace.json (and arms recording on first press) — no host code needed. */

/* Start recording (idempotent). Inert until called, unless CELERIS_TRACE is set. */
void celeris_profiler_enable(void);
/* Write the trace so far to `path`. Returns 0 on success (a non-profiling or
 * never-enabled build writes nothing and still returns 0), -1 on a NULL path or
 * a write failure.
 * Cumulative — safe to call repeatedly. */
int32_t celeris_profiler_flush(const char *path);

/* ── Engine lifecycle ─────────────────────────────────────────────────────── */

typedef struct CelerisConfig {
    bool is_headless;
} CelerisConfig;

/* Human-readable reason for the most recent failed call (engine-owned, do NOT free;
 * valid until the next failing call). Empty string if nothing has failed. */
const char *celeris_last_error(void);

/* Routine diagnostics on stderr (font discovery, engine init, …). Off by default;
 * the CELERIS_LOG environment variable also enables them. Warnings about real
 * problems are always printed. */
void celeris_set_verbose_logging(bool on);

/* Creates an engine; returns its 1-based id, or -1 if no slot is free (max 16).
 * On -1 see celeris_last_error(). */
int32_t celeris_create_engine(const CelerisConfig *config);

/* A window's creation parameters. parent_engine_id (1-based, 0 = none)
 * makes this window an owned child of another; modal additionally disables the
 * parent's input until this window closes. title is NUL-terminated UTF-8 (NULL →
 * "Celeris"); width/height of 0 fall back to 800x600. */
typedef struct CelerisWindowConfig {
    bool        is_headless;
    uint32_t    width;
    uint32_t    height;
    int32_t     parent_engine_id;
    bool        modal;
    const char *title;
    /* Outer-corner rounding: 0 default, 1 square, 2 round, 3 round-small.
     * Honoured on Windows 11 (DWM); ignored elsewhere. */
    uint8_t     corner_preference;
    /* Compositor-drawn frame border as 0xAARRGGBB, or 0 for the system default.
     * Alpha only selects "set" from "unset". */
    uint32_t    border_color;
    /* Top-left in logical screen px; read only when has_position is true (0,0 is
     * a legitimate position, so no sentinel would do). */
    int32_t     x;
    int32_t     y;
    bool        has_position;
    /* Float above other windows, and create without stealing focus. */
    bool        always_on_top;
    /* The next three are negated on purpose: a host compiled against the older,
     * shorter struct leaves them zeroed, and zero must mean the previous
     * behaviour. */
    bool        fixed_size;        /* no resize border */
    bool        start_hidden;      /* create hidden, to be positioned first */
    bool        no_quit_on_close;  /* closing must not end the event loop */
} CelerisWindowConfig;

/* Creates a window (engine) with full configuration (title, size, owner/modal).
 * Returns the 1-based id, or -1. celeris_create_engine is the simple form. */
int32_t celeris_create_window(const CelerisWindowConfig *config);

/* Tears an engine down and frees everything it owns. Safe on an invalid id.
 * Closing a parent cascades to its child/modal windows. */
void celeris_deinit(int32_t engine_id);

/* Runs the platform event/render loop until the window closes. */
int32_t celeris_start_loop(void);

/* Enqueues a function to be executed safely on the main thread during the next
 * loop, and wakes an idle loop so it runs this frame. This is the thread-safe way
 * to mutate UI state from a worker thread: post a task, mutate signals inside it
 * (on the UI thread), and dirty-tracking schedules the repaint. */
void celeris_post_task(void (*callback)(void*), void* ctx);

/* Requests a repaint of engine_id from any thread (thread-safe), waking an idle
 * loop. For forcing a frame when state changed outside the signal system; for
 * normal state changes prefer celeris_post_task (signals are not thread-safe). */
void celeris_request_redraw(int32_t engine_id);

/* ── Events ───────────────────────────────────────────────────────────────── */
void celeris_stop_propagation(int32_t engine_id);

/* Structured event channel — the engine's only event channel. Keep in
 * sync with EventType in src/core/events.zig. text_composition is reserved for
 * IME composed text. */
typedef enum CelerisEventType {
    CELERIS_EVENT_MOUSE_MOVE = 0,
    CELERIS_EVENT_MOUSE_DOWN,
    CELERIS_EVENT_MOUSE_UP,
    CELERIS_EVENT_RIGHT_MOUSE_DOWN,
    CELERIS_EVENT_RIGHT_MOUSE_UP,
    CELERIS_EVENT_MOUSE_ENTER,
    CELERIS_EVENT_MOUSE_LEAVE,
    CELERIS_EVENT_GLOBAL_MOUSE_DOWN,
    CELERIS_EVENT_CLICK,
    CELERIS_EVENT_FOCUS,
    CELERIS_EVENT_BLUR,
    CELERIS_EVENT_KEY_DOWN,
    CELERIS_EVENT_KEY_UP,
    CELERIS_EVENT_CHAR_INPUT,
    CELERIS_EVENT_SCROLL,
    CELERIS_EVENT_TICK,
    CELERIS_EVENT_TEXT_COMPOSITION, /* IME preedit (text = composition string) */
    CELERIS_EVENT_TEXT_COMMIT,      /* IME commit (text = finalized string) */
    CELERIS_EVENT_DROP,             /* drag-and-drop (text = uri-list / path / text) */
    CELERIS_EVENT_DOUBLE_CLICK,     /* double/triple click; key_code = click count (2|3) */
    CELERIS_EVENT_SCROLL_H,         /* horizontal scroll; scroll_delta = notches (+ = right) */
    CELERIS_EVENT_RESIZE            /* observed node's solved size changed; x = width, y = height */
} CelerisEventType;

/* A structured UI event. action_id/text are engine-owned, NUL-terminated, and
 * valid only for the duration of the callback — copy what you need. node_id is
 * the numeric registry id (0 = none/global). */
typedef struct CelerisEvent {
    int32_t  event_type;   /* CelerisEventType */
    uint32_t node_id;      /* registry node id (matches celeris_node_* ids); 0 = none */
    const char *action_id; /* modifier action id ("" if none) */
    float    x;
    float    y;
    uint32_t key_code;
    float    scroll_delta;
    const char *text;      /* char_input / IME composed text, UTF-8 ("" if none) */
    uint32_t modifiers;    /* bit0=Shift, bit1=Ctrl, bit2=Alt */
} CelerisEvent;

/* Layout is frozen at 48 bytes on 64-bit (LP64/Win64); the Zig side asserts the
 * same offsets at compile time. Keep both in sync if a field is added. */
#if UINTPTR_MAX == 0xFFFFFFFFFFFFFFFFu
#  if defined(__cplusplus)
    static_assert(sizeof(CelerisEvent) == 48, "CelerisEvent layout drifted from the Zig ABI");
#  elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
    _Static_assert(sizeof(CelerisEvent) == 48, "CelerisEvent layout drifted from the Zig ABI");
#  endif
#endif

#define CELERIS_MOD_SHIFT 1u
#define CELERIS_MOD_CTRL  2u
#define CELERIS_MOD_ALT   4u

typedef void (*CelerisStructuredEventCallback)(const CelerisEvent *event);

/* The sole event-delivery channel. The action_id/text pointers in CelerisEvent
 * point at engine stack buffers valid ONLY for the duration of the callback —
 * copy them out before returning. (Lengths are bounded; see c_api.zig emitEvent.) */
void celeris_register_event_callback(int32_t engine_id, CelerisStructuredEventCallback callback);

/* Synthetic input injection (testing / automation). event_type for keyboard:
 * see src/platform; for char_input pass the codepoint as key_code. */
int32_t celeris_dispatch_mouse_click(int32_t engine_id, float x, float y);
int32_t celeris_dispatch_keyboard_event(int32_t engine_id, uint32_t event_type, uint32_t key_code);
int32_t celeris_dispatch_scroll_event(int32_t engine_id, float x, float y, float delta);
/* Delivers a drag-and-drop drop at (x, y); text is the payload (a newline-separated
 * path/URI list, or plain text). Routed to the node under the pointer as a `drop`
 * event. Called by the platform DnD handler or directly by a host. */
int32_t celeris_dispatch_drop(int32_t engine_id, float x, float y, const char *text);
/* Replaces the editable text of a TextInput/TextArea node through the real edit
 * path (focus, select-all, commit), exactly as typing would. `text` is UTF-8 of
 * `len` bytes and need not be null-terminated. */
int32_t celeris_dispatch_set_text(int32_t engine_id, uint32_t node_id, const char *text, size_t len);

/* ── Reactive signals by handle ──────────────────────────────────── */
/* The host manipulates state, not nodes: create a signal, bind it once to a
 * node property, then only set values — the engine reconciles and re-renders. */

/* Returns a signal handle (>= 0), or -1 on failure. Initial value is number 0. */
int32_t celeris_signal_create(int32_t engine_id);

int32_t celeris_signal_set_f32(int32_t engine_id, int32_t handle, float value);
/* Setters return -1 for NaN/Inf (and alpha outside 0..1). unit: 0 = px,
 * 1 = pt, 2 = percent; pt is accepted for compatibility but no property reads it. */
int32_t celeris_signal_set_dimension(int32_t engine_id, int32_t handle, float value, uint32_t unit);
/* r,g,b are 0–255; a is 0.0–1.0. */
int32_t celeris_signal_set_color(int32_t engine_id, int32_t handle, uint8_t r, uint8_t g, uint8_t b, float a);
float   celeris_signal_get_f32(int32_t engine_id, int32_t handle);

/* Bind a signal to a node property once (e.g. "opacity"/"background" for style,
 * "width"/"left" for layout). The current value applies immediately and on every
 * later set. Signals are untyped, so each value is converted to the key's type:
 * numbers and px lengths convert into each other; a value with no meaning for
 * the key (a number for "background", a color for "radius") is skipped and the
 * property keeps its last value. */
int32_t celeris_signal_bind_style(int32_t engine_id, int32_t handle, uint32_t node_id, const char *key);
int32_t celeris_signal_bind_layout(int32_t engine_id, int32_t handle, uint32_t node_id, const char *key);

/* ── Imperative node tree (used by the framework/runtime; bindings prefer signals) ─ */

/* node_type: 0 = Box, 1 = Text, 2 = Image, 3 = Path (unknown → Box). Returns the
 * new node id, or -1. The first node created in an engine is its window's root;
 * attach everything else under it with append_child / insert_before. */
int32_t celeris_node_create(int32_t engine_id, uint32_t node_type);
int32_t celeris_node_append_child(int32_t engine_id, uint32_t parent, uint32_t child);
int32_t celeris_node_insert_before(int32_t engine_id, uint32_t parent, uint32_t child, uint32_t ref_child);
int32_t celeris_node_remove(int32_t engine_id, uint32_t node_id);
/* String-keyed properties. Keys are the property names (`-` or `_` both work):
 *   style:    background, color, radius, opacity, font_size, text_align,
 *             letter_spacing, line_height (unitless multiplier, e.g. "1.4"),
 *             border_width, border_color, shadow_color, shadow_blur, …
 *   layout:   width, height, padding_*, margin_*, flex_direction, flex_grow,
 *             justify_content, align_items, gap, position, left, top, …
 *   modifier: clickable, hoverable, focusable, role, cursor, label, tooltip, …
 * Values: colors `#rgb` `#rrggbb` `#rrggbbaa` `rgb(r,g,b)` `rgba(r,g,b,a)`;
 * lengths `12` / `12px`, plus `50%` where it resolves (width, height,
 * flex_basis, min/max sizes; margins and padding are px only) and `auto` /
 * `fill` for width and height only;
 * numbers; keywords such as `row`, `center`, `space-between`; booleans
 * `true`/`false`/`1`/`0` (for flags like pointer_events_none, `0` is off);
 * anything else verbatim. The key decides the type (`"1"` is a number for
 * opacity, 1px for radius). Unknown keys and values the key cannot use (a
 * keyword for radius, `%` for gap) return -1; see celeris_last_error(). */
int32_t celeris_node_add_style(int32_t engine_id, uint32_t node_id, const char *key, const char *val);
int32_t celeris_node_add_layout(int32_t engine_id, uint32_t node_id, const char *key, const char *val);
int32_t celeris_node_add_modifier(int32_t engine_id, uint32_t node_id, const char *key, const char *val);
/* text must be non-NULL (pass "" to clear); returns -1 otherwise. */
int32_t celeris_node_set_text_content(int32_t engine_id, uint32_t node_id, const char *text);
/* Set a Path node's geometry. `verts` is a flat float array, `float_count` a
 * multiple of celeris_path_vertex_stride() (8): [x, y, c1x, c1y, c2x, c2y,
 * move, close] per vertex. c1==prev point & c2==(x,y) (or all-zero) → straight
 * line, else cubic. move!=0 starts a subpath; close!=0 shuts it. The engine
 * copies `verts`. float_count 0 clears. Stroke uses the node's border_color /
 * border_width / opacity. Returns -1 on bad id / stride mismatch / OOM. */
int32_t celeris_node_set_path(int32_t engine_id, uint32_t node_id, const float *verts, uint32_t float_count);
uint32_t celeris_path_vertex_stride(void);
/* Any out-pointer may be NULL. */
int32_t celeris_node_get_bounds(int32_t engine_id, int32_t node_id,
                                float *out_x, float *out_y, float *out_w, float *out_h);

/* ── Animation ────────────────────────────────────────────────────────────── */
/* Numeric properties only (sizes, opacity, radius, shadow_blur, …). easing_val:
 * 0 linear, 1 ease-in, 2 ease-out, 3 ease-in-out, 4 spring. A new animation on the
 * same property replaces the running one. */
int32_t celeris_animate_layout(int32_t engine_id, uint32_t node_id, const char *key,
                               float from, float to, float duration_ms, uint32_t easing_val);
int32_t celeris_animate_style(int32_t engine_id, uint32_t node_id, const char *key,
                              float from, float to, float duration_ms, uint32_t easing_val);
int32_t celeris_cancel_animations(int32_t engine_id, uint32_t node_id);

/* ── Text measurement (font atlas) ────────────────────────────────────────── */
float   celeris_measure_text(int32_t engine_id, const char *text, size_t len, float font_size);
/* Any out-pointer may be NULL. */
int32_t celeris_get_caret_metrics(int32_t engine_id, const char *text, size_t len,
                                  float font_size, float max_width, size_t char_index,
                                  float *out_x, float *out_y, float *out_line_height);
int32_t celeris_get_char_index_at(int32_t engine_id, const char *text, size_t len,
                                  float font_size, float max_width, float local_x, float local_y);
/* The _lh variants take the text node's line_height multiplier (the "line_height"
 * style; <= 0 or non-finite = default 1.55) so the caret line, its y and the
 * hit-tested line match what the engine renders. The plain forms use the default. */
int32_t celeris_get_caret_metrics_lh(int32_t engine_id, const char *text, size_t len,
                                     float font_size, float max_width, float line_height,
                                     size_t char_index,
                                     float *out_x, float *out_y, float *out_line_height);
int32_t celeris_get_char_index_at_lh(int32_t engine_id, const char *text, size_t len,
                                     float font_size, float max_width, float line_height,
                                     float local_x, float local_y);

/* ── Application typefaces ───────────────────────────────────────────── */
/* One face: bytes + length, or {NULL, 0} for "not supplied". */
typedef struct CelerisFontFace {
    const uint8_t *data;
    size_t         len;
} CelerisFontFace;

/* The app's typefaces. A zeroed struct means "discover as before" — which is also
 * what a host built against an older, shorter struct leaves behind. Only primary is
 * really needed: the role faces degrade to it when absent. */
typedef struct CelerisFontConfig {
    CelerisFontFace primary;
    CelerisFontFace bold;
    CelerisFontFace mono;
    CelerisFontFace mono_bold;
} CelerisFontConfig;

/* Registers the faces every engine created afterwards uses, so an app's typography
 * is the same on every machine instead of whatever the host font scan turns up.
 * Call BEFORE celeris_create_window: the atlas is built at engine init and is not
 * re-based afterwards. The bytes are copied, so the caller may free them on return;
 * NULL clears back to OS discovery. Returns 0, or -1 on allocation failure. */
int32_t celeris_set_app_fonts(const CelerisFontConfig *config);

/* ── DevTools / introspection ─────────────────────────────────────────────── */
/* Returned buffers are engine-owned (arena-backed); see celeris_free_string. */
const char *celeris_get_dom_json(int32_t engine_id);
const char *celeris_get_devtools_snapshot(int32_t engine_id);
void        celeris_free_string(int32_t engine_id, const char *str);

/* Accessibility tree as JSON (role / accessible name / focused / bounds, nested)
 * for a screen-reader provider. Engine-owned; free with celeris_free_string. */
const char *celeris_get_accessibility_json(int32_t engine_id);

/* ── Focus scopes ───────────────────────────────────────────────────────── */
/* Traps Tab traversal within node_id's subtree (focus trap for overlays and
 * dialogs) until the matching pop; push moves the focus to the scope's first
 * focusable node, pop restores the focus held before the push. Stack depth 8.
 * Return 0 on success, -1 on error (bad engine/node, stack full/empty). */
int32_t celeris_push_focus_scope(int32_t engine_id, uint32_t node_id);
int32_t celeris_pop_focus_scope(int32_t engine_id);

/* ── Clipboard ────────────────────────────────────────────────────────────── */
/* set returns 0 on success, -1 on failure / unsupported platform. Implemented on
 * both Win32 (CF_UNICODETEXT) and Wayland (wl_data_device). get returns engine-owned
 * UTF-8 (free with celeris_free_string) or NULL when empty/unsupported. */
int32_t     celeris_clipboard_set_text(int32_t engine_id, const char *text);
const char *celeris_clipboard_get_text(int32_t engine_id);

/* ── File dialogs ─────────────────────────────────────────────────────────── */
/* Native open/save dialogs. Return the chosen path (engine-owned UTF-8, free with
 * celeris_free_string) or NULL if cancelled / unsupported. Implemented on Win32
 * (comdlg32) and Wayland (XDG Desktop Portal via libdbus; needs a running portal).
 * title/filter ("*.txt")/default_name may be NULL. */
const char *celeris_open_file_dialog(int32_t engine_id, const char *title, const char *filter);
const char *celeris_save_file_dialog(int32_t engine_id, const char *title, const char *filter, const char *default_name);
/* Native folder picker (Win32 IFileOpenDialog / Wayland XDG portal directory mode).
 * Returns the chosen absolute path (engine-owned UTF-8, free with
 * celeris_free_string) or NULL if cancelled / unsupported. title/initial_dir may
 * be NULL (initial_dir is a hint, not yet honored on all backends). */
const char *celeris_pick_directory(int32_t engine_id, const char *title, const char *initial_dir);
void        celeris_set_overlay_rect(int32_t engine_id, bool visible,
                                     float x, float y, float w, float h,
                                     float r, float g, float b, float a);

/* ── Window control (Win32 + Wayland/libdecor) ────────────────────────────── */
void celeris_window_start_drag(int32_t engine_id);
void celeris_window_close(int32_t engine_id);
void celeris_window_maximize(int32_t engine_id);
void celeris_window_minimize(int32_t engine_id);
/* Returns 1 if the window is currently maximized, 0 otherwise. */
int32_t celeris_window_is_maximized(int32_t engine_id);
/* Registers a callback fired when the OS changes a window's maximized state
 * without a button click (e.g. dragging a maximized window restores it). */
void celeris_set_maximize_change_callback(void (*cb)(int32_t engine_id));

/* ── Secondary windows ─────────────────────────────────────────── */
/* All geometry below is in logical (DPI-independent) px — the same units layout
 * uses — so a host never converts for DPI itself. */

/* Moves and resizes a window. */
void celeris_window_set_bounds(int32_t engine_id, int32_t x, int32_t y,
                               uint32_t w, uint32_t h);
/* Reads a window's outer bounds into the out-params (any may be NULL).
 * Returns 0 on success, -1 if the engine or its window is gone. */
int32_t celeris_window_get_bounds(int32_t engine_id, int32_t *x, int32_t *y,
                                  uint32_t *w, uint32_t *h);
/* Toggles the always-on-top band at runtime. */
void celeris_window_set_always_on_top(int32_t engine_id, bool on);
/* Shows/hides a window without destroying it — its component tree survives. */
void celeris_window_set_visible(int32_t engine_id, bool visible);
/* The platform handle (HWND on Windows), or NULL when headless. Escape hatch. */
void *celeris_window_native_handle(int32_t engine_id);
/* Schedules celeris_deinit for the top of the next loop iteration. This is what
 * an event handler must call: closing from inside a handler runs during the
 * loop's own walk over the engines, where freeing one immediately would pull the
 * registry out from under the frame in flight. */
void celeris_window_destroy_deferred(int32_t engine_id);
/* Fired when the user closes a window that does not own the event loop (its own
 * close button, Alt+F4), so the host can unwind that window's state before the
 * engine goes away. Without a callback the engine is simply destroyed. */
void celeris_set_close_request_callback(void (*cb)(int32_t engine_id));

/* Sets this window's focus-ring color (RGBA, 0..1), normally from its theme.
 * Per window: two windows on different themes each draw their own ring. */
void celeris_set_focus_ring_color(int32_t engine_id, float r, float g, float b, float a);

/* The primary display's work area (screen minus taskbar). Returns 0 on success,
 * -1 where the platform does not expose it (Wayland). Any out-param may be NULL. */
int32_t celeris_display_work_area(int32_t *x, int32_t *y, uint32_t *w, uint32_t *h);

#ifdef __cplusplus
}
#endif

#endif /* CELERIS_H */
