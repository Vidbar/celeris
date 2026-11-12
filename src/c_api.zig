const std = @import("std");
const reg = @import("core/registry.zig");
const props = @import("core/properties.zig");
const layout_mod = @import("layout/flexbox.zig");
const renderer_mod = @import("render/renderer.zig");
const events_mod = @import("core/events.zig");
const fw_events = @import("framework/events.zig");
const platform_mod = @import("platform/platform.zig");
const wgpu_mod = @import("render/wgpu_backend.zig");
const text_mod = @import("render/text.zig");
const font_discovery = @import("platform/font_discovery.zig");
const keysym_mod = @import("platform/keysym.zig");
const animation_mod = @import("core/animation.zig");
const signals_mod = @import("core/signals.zig");
const a11y = @import("core/accessibility.zig");
const dispatch_mod = @import("core/dispatch.zig");
const prof = @import("core/profiler.zig");
const log = @import("core/log.zig");
const path_mod = @import("core/path.zig");
const prop_parse = @import("core/prop_parse.zig");
const uia = @import("platform/uia.zig");
const builtin = @import("builtin");

/// Null-terminated allocPrint (std.fmt.allocPrintZ was removed in Zig 0.16).
fn allocPrintZ(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    return std.fmt.allocPrintSentinel(a, fmt, args, 0);
}

// ─── std.Io shim (Zig 0.16) ───────────────────────────────────────────────────
// 0.16 moved file I/O and clocks behind the `std.Io` interface, which threads an
// `io` instance through every call. We use one process-wide blocking Io.
var g_threaded: ?std.Io.Threaded = null;
fn engineIo() std.Io {
    if (g_threaded == null) g_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    return g_threaded.?.io();
}
/// Monotonic milliseconds (replaces std.time.milliTimestamp, removed in 0.16).
fn nowMs() i64 {
    const ts = std.Io.Clock.now(.awake, engineIo());
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
}
/// Monotonic nanoseconds — fine-grained timing for the frame profiler.
fn nowNs() i64 {
    const ts = std.Io.Clock.now(.awake, engineIo());
    return @intCast(ts.nanoseconds);
}
/// Reads a whole file via the 0.16 std.Io.Dir API.
fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(engineIo(), path, gpa, .unlimited);
}

// ── Application-supplied typefaces ───────────────────────────────────────
//
// Without these the primary face is whatever the OS scan below turns up first, so
// the same app has a different typographic voice on every machine. Type is half of
// a product's identity — Material's type system starts by naming the family, and
// only then the scale — and it was the half an app could not choose. These are
// process-wide on purpose: one app, one type system, so every window (secondary
// ones included) speaks with the same voice.

/// Faces an app hands the engine, as TTF/OTF bytes (typically `@embedFile`).
/// `primary` replaces the discovered default; the role faces override the system
/// scan for their role. Any field left null keeps today's discovery behaviour, so
/// an app that sets none of them is unaffected.
pub const AppFonts = struct {
    primary: ?[]const u8 = null,
    bold: ?[]const u8 = null,
    mono: ?[]const u8 = null,
    mono_bold: ?[]const u8 = null,
};

/// Borrowed: the bytes must outlive every engine created afterwards. Trivially
/// true for `@embedFile` (static) — `celeris_set_app_fonts` copies for C hosts,
/// which cannot make that promise about a malloc'd buffer.
var g_app_fonts: AppFonts = .{};

/// Owned copies made for the C-ABI path, freed when replaced.
var g_app_fonts_owned: AppFonts = .{};

/// Registers the faces used by every engine created from here on. Call before
/// `celeris_create_window` — an atlas is built at engine init and never re-based
/// (cached glyphs are keyed by font index), so this does not restyle a live window.
pub fn setAppFonts(fonts: AppFonts) void {
    g_app_fonts = fonts;
}

/// The faces registered by `setAppFonts` (for tests and the framework layer).
pub fn appFonts() AppFonts {
    return g_app_fonts;
}

/// One face across the C-ABI: pointer + length, or `{null, 0}` for "not supplied".
pub const CelerisFontFace = extern struct {
    data: [*c]const u8 = null,
    len: usize = 0,
};

/// The app's typefaces. Every field is optional; a zeroed struct means "discover
/// as before", which is also what a host compiled against an older, shorter struct
/// leaves behind.
pub const CelerisFontConfig = extern struct {
    primary: CelerisFontFace = .{},
    bold: CelerisFontFace = .{},
    mono: CelerisFontFace = .{},
    mono_bold: CelerisFontFace = .{},
};

fn faceSlice(f: CelerisFontFace) ?[]const u8 {
    if (f.data == null or f.len == 0) return null;
    return f.data[0..f.len];
}

fn freeAppFontsCopy(f: AppFonts) void {
    const a = std.heap.page_allocator;
    inline for (.{ "primary", "bold", "mono", "mono_bold" }) |field| {
        if (@field(f, field)) |bytes| a.free(bytes);
    }
}

fn freeOwnedAppFonts() void {
    freeAppFontsCopy(g_app_fonts_owned);
    g_app_fonts_owned = .{};
}

/// Sets the app's typefaces from a C host. The bytes are copied, so the caller may
/// free its buffers on return. Passing null clears back to OS discovery. Returns 0
/// on success, -1 if a copy could not be allocated (the previous set is kept).
pub export fn celeris_set_app_fonts(config: ?*const CelerisFontConfig) i32 {
    const a = std.heap.page_allocator;
    const c = config orelse {
        freeOwnedAppFonts();
        g_app_fonts = .{};
        return 0;
    };
    var copy: AppFonts = .{};
    inline for (.{ "primary", "bold", "mono", "mono_bold" }) |field| {
        if (faceSlice(@field(c.*, field))) |bytes| {
            @field(copy, field) = a.dupe(u8, bytes) catch {
                freeAppFontsCopy(copy);
                setLastError("celeris_set_app_fonts: out of memory copying {s}", .{field});
                return -1;
            };
        }
    }
    freeOwnedAppFonts();
    g_app_fonts_owned = copy;
    g_app_fonts = copy;
    return 0;
}

/// Loads a font atlas from the first available system font for the OS.
/// Returns null if none load — text won't render but the engine still runs.
fn loadFontAtlas(allocator: std.mem.Allocator) ?text_mod.FontAtlas {
    const candidates: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{
            "C:/Windows/Fonts/segoeui.ttf",
            "C:/Windows/Fonts/arial.ttf",
            "C:/Windows/Fonts/tahoma.ttf",
        },
        else => &.{
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
        },
    };
    // Fallback fonts for glyphs the primary lacks (CJK, symbols). Color emoji
    // (COLR/CPAL) won't rasterize through stb_truetype, but CJK/symbol outlines do.
    // Each is best-effort: a missing file is simply skipped.
    const fallbacks: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{
            "C:/Windows/Fonts/msgothic.ttc", // Japanese
            "C:/Windows/Fonts/malgun.ttf", // Korean
            "C:/Windows/Fonts/simsun.ttc", // Simplified Chinese
            "C:/Windows/Fonts/seguisym.ttf", // symbols
        },
        else => &.{
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
        },
    };
    // OS-native discovery (fontconfig on Linux): a system primary + a
    // coverage-ordered fallback chain. Null on Windows / when unavailable.
    const discovered: ?[][]u8 = font_discovery.discover(allocator);
    defer if (discovered) |d| {
        for (d) |p| allocator.free(p);
        allocator.free(d);
    };

    // 1. Primary font: the app's own face if it supplied one, else the
    //    candidate system paths, then the discovered default.
    var atlas: text_mod.FontAtlas = undefined;
    var have_primary = false;
    var primary_path: []const u8 = "";
    if (g_app_fonts.primary) |ttf| {
        if (text_mod.FontAtlas.init(allocator, ttf, 72.0)) |a| {
            atlas = a;
            have_primary = true;
            log.info("font (app-supplied primary): {d} bytes\n", .{ttf.len});
        } else |err| {
            // A corrupt blob must not leave the app textless: warn and fall through
            // to discovery, the same degradation every other face here follows.
            log.info("app-supplied primary font rejected ({s}); falling back to discovery\n", .{@errorName(err)});
        }
    }
    if (!have_primary) for (candidates) |path| {
        const data = readFileAlloc(allocator, path) catch continue;
        defer allocator.free(data);
        if (text_mod.FontAtlas.init(allocator, data, 72.0)) |a| {
            atlas = a;
            have_primary = true;
            primary_path = path;
            log.info("font loaded: {s}\n", .{path});
            break;
        } else |_| {}
    };
    if (!have_primary) {
        if (discovered) |d| for (d) |path| {
            const data = readFileAlloc(allocator, path) catch continue;
            defer allocator.free(data);
            if (text_mod.FontAtlas.init(allocator, data, 72.0)) |a| {
                atlas = a;
                have_primary = true;
                primary_path = path;
                log.info("font (discovered): {s}\n", .{path});
                break;
            } else |_| {}
        };
    }
    if (!have_primary) return null;

    // 2. Bundled Codicons icon font (framework/icons.zig): first fallback so
    //    icon PUA codepoints always resolve, on every OS, with no asset file.
    //    Tagged as the icon font so its glyphs are centered by bbox, not baseline.
    atlas.addIconFont(@embedFile("codicon_ttf")) catch {};

    // 3. Fallback chain: prefer fontconfig's coverage-ordered list; else the
    //    hardcoded per-OS list. Each entry is best-effort (skip on failure).
    if (discovered) |d| {
        for (d) |path| {
            if (std.mem.eql(u8, path, primary_path)) continue;
            const fb = readFileAlloc(allocator, path) catch continue;
            defer allocator.free(fb);
            atlas.addFallback(fb) catch continue;
            log.info("fallback (discovered): {s}\n", .{path});
        }
    } else {
        for (fallbacks) |path| {
            const fb = readFileAlloc(allocator, path) catch continue;
            defer allocator.free(fb);
            atlas.addFallback(fb) catch continue;
            log.info("fallback font: {s}\n", .{path});
        }
    }

    // 4. Role faces (bold / monospace) for per-node font selection. Each is
    //    best-effort: a missing file leaves that role unregistered, and text using
    //    it degrades to the primary face. First readable candidate per role wins.
    const RoleFonts = struct { role: text_mod.FontRole, paths: []const []const u8 };
    const role_faces: []const RoleFonts = switch (builtin.os.tag) {
        .windows => &.{
            .{ .role = .bold, .paths = &.{ "C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/arialbd.ttf" } },
            .{ .role = .mono, .paths = &.{ "C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/cour.ttf" } },
            .{ .role = .mono_bold, .paths = &.{ "C:/Windows/Fonts/consolab.ttf", "C:/Windows/Fonts/courbd.ttf" } },
        },
        else => &.{
            .{ .role = .bold, .paths = &.{
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
            } },
            .{ .role = .mono, .paths = &.{
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
            } },
            .{ .role = .mono_bold, .paths = &.{
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
            } },
        },
    };
    // 4a. App-supplied role faces win outright over the scan: an app that ships its
    //     own bold/mono means them, and pairing a chosen primary with the host's
    //     Consolas would break the family relationship the roles exist to express.
    inline for (.{
        .{ text_mod.FontRole.bold, "bold" },
        .{ text_mod.FontRole.mono, "mono" },
        .{ text_mod.FontRole.mono_bold, "mono_bold" },
    }) |entry| {
        if (@field(g_app_fonts, entry[1])) |ttf| {
            atlas.addRoleFont(entry[0], ttf) catch |err| {
                log.info("app-supplied {s} font rejected ({s})\n", .{ entry[1], @errorName(err) });
            };
        }
    }
    for (role_faces) |rf| {
        // Already satisfied by the app: don't load a second, unrelated face for it.
        if (atlas.hasRoleFont(rf.role)) continue;
        for (rf.paths) |path| {
            const data = readFileAlloc(allocator, path) catch continue;
            defer allocator.free(data);
            atlas.addRoleFont(rf.role, data) catch continue;
            log.info("role font ({s}): {s}\n", .{ @tagName(rf.role), path });
            break;
        }
    }
    return atlas;
}

/// A reactive signal exposed to the host by handle. The host manipulates state
/// (set), binds it to a node property once (bind_style/bind_layout), and the Zig
/// side reconciles: a set() writes the bound store property and the existing
/// dirty-tracking re-renders — the host never touches the node tree.
const HostSignal = signals_mod.Signal(props.PropValue);

pub const OverlayRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// In Debug builds the engine's backing allocator is the leak-checking
/// DebugAllocator; in release it's libc's malloc (fast, thread-safe, no
/// per-allocation bookkeeping). A thin wrapper gives release the same
/// `allocator()`/`deinit()` shape so EngineState stays allocator-agnostic.
const ReleaseGpa = struct {
    fn allocator(_: *ReleaseGpa) std.mem.Allocator {
        return std.heap.c_allocator;
    }
    fn deinit(_: *ReleaseGpa) std.heap.Check {
        return .ok;
    }
};
const EngineGpa = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else ReleaseGpa;

// ─── Global engine state (singleton) ─────────────────────────────────────────
/// A pointer position in logical px.
const PointerPos = struct { x: f32, y: f32 };

pub const EngineState = struct {
    gpa: EngineGpa,
    registry: reg.UIRegistry,
    store: props.PropertyStore,
    /// Structured C-ABI event callback. Hosts/bindings route on typed
    /// `(node_id, event_type, payload)` fields — there is no JSON event channel.
    event_callback: ?events_mod.StructuredEventCallback,
    renderer: renderer_mod.RendererState,
    /// Backing store for the type-erased `TextMeasure` handed to the builder.
    /// It MUST outlive the build pass: widgets (TextInput, TextArea, Tabs,
    /// Tooltip, VirtualList) and `signals.forEach`'s effect context cache the
    /// handle and call through it on later reactive rebuilds. It used to be a
    /// local of `rebuildUI`, so every cached copy pointed into a dead stack
    /// frame — usually survivable, until a UIA SetValue arriving through the
    /// task queue re-entered the builder at a shallower stack and segfaulted.
    measure_ctx: MeasureContext,
    window: ?platform_mod.PlatformWindow,
    atlas: ?text_mod.FontAtlas,
    backend: ?wgpu_mod.WgpuBackend,
    is_headless: bool,
    is_initialized: bool,
    /// This engine's own id (1-based), so pool-wide queries (modal gating, cascade
    /// close) can find relatives without pointer arithmetic.
    id: i32,
    /// Owner engine id (1-based) for a child/modal window; 0 = top-level.
    parent_engine_id: i32,
    /// Owner-modal: while alive, the parent engine ignores input.
    is_modal: bool,
    /// DPI scale factor (logical→physical). 1.0 = 96 DPI.
    scale: f32,
    /// The cursor shape currently shown (so we only call the OS when it changes).
    current_cursor: platform_mod.CursorType,
    focused_node: ?reg.NodeId,
    hovered_node: ?reg.NodeId,
    debug_node_id: ?reg.NodeId,
    overlay_rect: ?OverlayRect,
    dev_arena: std.heap.ArenaAllocator,
    animator: animation_mod.AnimationEngine,
    last_frame_time: i64,
    hit_list: std.array_list.Managed(renderer_mod.HitNode),
    propagation_stopped: bool,
    /// MOD_* bitmask of the input event being handled by handleOSInput (0
    /// outside it); stamped on every node-routed pointer event.
    input_mods: u32 = 0,
    /// Last pointer position inside the window (logical px); null after the
    /// pointer leaves. Used by `recheckHover`.
    last_pointer: ?PointerPos = null,
    /// Set when the hovered node is removed; consumed after the next bake.
    hover_recheck: bool = false,
    /// Clickable nodes on the path that received the current mouse_down
    /// (target first). The release goes to them — implicit pointer capture —
    /// not to whatever is under the pointer at mouse_up. See `releasePressed`.
    pressed_nodes: [MAX_PRESSED]reg.NodeId = undefined,
    pressed_len: usize = 0,
    /// Double/triple-click detection: time and position of the previous
    /// mouse-down, plus the running consecutive-click count.
    last_click_ms: i64 = 0,
    last_click_x: f32 = 0,
    last_click_y: f32 = 0,
    click_count: u32 = 0,
    /// Host-owned signals (by handle) and the scope owning their node bindings.
    signal_scope: signals_mod.Scope,
    host_signals: std.array_list.Managed(*HostSignal),
    /// The `node_id` of every host signal binding (owned by `signal_scope`). When a
    /// node is removed its entries are set to NULL_NODE, so a binding can never
    /// write into whatever node later reuses the slot.
    host_binding_nodes: std.array_list.Managed(*reg.NodeId),
    /// Addresses of every gpa-owned string this engine has ever handed across
    /// the C-ABI for the host to free (`celeris_get_dom_json`,
    /// `celeris_get_accessibility_json`, the clipboard/file-dialog getters).
    /// `celeris_free_string` is documented as "do not pass the devtools
    /// snapshot pointer here — that one is arena-owned and freeing it corrupts
    /// the heap", but nothing enforced it: any pointer at all, host garbage
    /// included, went straight to `gpa.free`. This turns that footgun into a
    /// checked operation — free only removes and frees an address actually in
    /// this set, so a double free, a foreign pointer, or the devtools buffer
    /// is a logged no-op instead of heap corruption.
    owned_strings: std.AutoHashMap(usize, void),
    /// Guards `owned_strings` alone. The native file dialogs are documented as
    /// "run the blocking call on a worker thread, marshal the result back with
    /// `celeris_post_task`" (FRAMEWORK_API.md), so `trackOwnedString` (worker)
    /// and `celeris_free_string` (worker cancel path, or UI thread) can hit the
    /// map concurrently. The backing gpa is already thread-safe (libc malloc in
    /// release, DebugAllocator's default `thread_safe` in Debug); only the
    /// hashmap was not.
    owned_strings_mutex: std.atomic.Mutex = .unlocked,
    /// Focus-scope stack. While non-empty, Tab traverses only the top scope's
    /// subtree (focus trap for overlays/dialogs); pop restores the previous focus.
    focus_scopes: [MAX_FOCUS_SCOPES]FocusScope = undefined,
    focus_scope_len: usize = 0,
    /// Set by an Escape key_down while a `captures_tab` node is focused: the
    /// next Tab traverses focus instead of reaching the node. Cleared by any
    /// other key_down and by every focus move (`moveFocus`).
    tab_escape_armed: bool = false,
    /// Last-seen maximized state, to fire the maximize-change hook only on a
    /// transition (drag-to-restore un-maximizes via the OS, not through our button).
    last_maximized: bool = false,
    /// The root UIA provider handed to this engine's window (Win32), so `deinit`
    /// can drop the reference `create` gave us. Null when headless / not Windows.
    uia_provider: ?*uia.CelerisUiaProvider = null,
    /// This window's focus-ring color (RGBA 0..1), from its theme. Per engine so
    /// two windows on different themes each draw their own ring.
    focus_ring_color: [4]f32 = renderer_mod.default_focus_ring_color,
    /// focus-visible: whether the ring paints at all right now, recomputed
    /// by every `moveFocus` call from its `FocusOrigin` — see `events_mod.FocusOrigin`.
    /// Defaults to `.keyboard` (ring visible) so a window's very first, pre-input
    /// focus state shows it, matching the CSS `:focus-visible` default for
    /// initial/programmatic focus.
    focus_highlight_mode: events_mod.FocusHighlightMode = .keyboard,

    pub const MAX_FOCUS_SCOPES = 8;
    pub const FocusScope = struct { root: reg.NodeId, prev_focus: ?reg.NodeId };

    /// Window-creation parameters threaded from the C-ABI into platform.initWindow.
    /// `create_engine` uses defaults; `create_window` fills them from the host config.
    const WindowParams = struct {
        width: u32 = 800,
        height: u32 = 600,
        title: []const u8 = "Celeris",
        parent: ?platform_mod.NativeWindowHandle = null,
        modal: bool = false,
        corners: platform_mod.CornerPreference = .default,
        border_color: ?u32 = null,
        x: ?i32 = null,
        y: ?i32 = null,
        always_on_top: bool = false,
        resizable: bool = true,
        visible: bool = true,
        quit_on_close: bool = true,
    };

    fn init(self: *EngineState, headless: bool, win: WindowParams) void {
        self.gpa = .{};
        const allocator = self.gpa.allocator();
        self.id = 0; // assigned by createEngineInternal once the slot is known
        self.parent_engine_id = 0;
        self.is_modal = false;
        self.registry = reg.UIRegistry.init(allocator);
        self.store = props.PropertyStore.init(allocator);

        self.registry.addNodeRemovedListener(&self.store, struct {
            fn cb(ctx: ?*anyopaque, id: reg.NodeId) void {
                const s: *props.PropertyStore = @ptrCast(@alignCast(ctx.?));
                s.clearProperties(id, false); // node freed → release its text too
            }
        }.cb);

        // Focus must never dangle on a recycled id (`registry.free_list` reuses
        // slots): a virtualized surface that scrolls the focused row out drops
        // the node, and without this the next keystroke lands on whatever now
        // occupies that slot. Route through `moveFocus`, the single focus funnel
        // — a direct `focused_node = null` would skip the UIA focus-changed
        // raise and the focus-visible mode bookkeeping. Target is `null` on purpose: the
        // engine guarantees the mechanism (focus is not dangling); the widget
        // owning the surface owns the policy of where focus goes next, since
        // only it knows the logical row.
        self.registry.addNodeRemovedListener(self, struct {
            fn cb(ctx: ?*anyopaque, id: reg.NodeId) void {
                const e: *EngineState = @ptrCast(@alignCast(ctx.?));
                if (e.focused_node == id) moveFocus(e, null, .removed);
                for (e.host_binding_nodes.items) |slot| {
                    if (slot.* == id) slot.* = reg.NULL_NODE;
                }
                // Hover likewise: a removed node is no longer hovered,
                // so it gets its mouse_leave NOW. Safe here: removal is
                // post-order (children before the anchor that owns their
                // component) and this listener is registered before the mount
                // table's and router's, so the handler and its instance are
                // still alive. Waiting is not an option — the router drops the
                // node's handlers right after this, and a pointer that leaves
                // before the next frame would never reach the replacement.
                // Then re-evaluate after the next bake so a replacement under
                // a still pointer gets mouse_enter.
                if (e.hovered_node == id) {
                    e.hovered_node = null;
                    e.hover_recheck = true;
                    const p = e.last_pointer orelse PointerPos{ .x = 0, .y = 0 };
                    emitEvent(e, .mouse_leave, id, "", p.x, p.y, 0, 0, "", 0);
                }
                // Press likewise: a removed node that took the mouse_down gets
                // its mouse_up now (same safety argument), so press state it
                // drives (Button.pressed) can't outlive it.
                releasePressed(e, id);
                // A focus scope whose saved `prev_focus` was this node would
                // otherwise restore focus to a recycled id on pop.
                for (e.focus_scopes[0..e.focus_scope_len]) |*sc| {
                    if (sc.prev_focus == id) sc.prev_focus = null;
                }
            }
        }.cb);

        self.store.setRegistry(&self.registry);
        self.event_callback = null;
        self.renderer = renderer_mod.RendererState.init(win.width, win.height);
        self.is_headless = headless;
        self.window = null;
        self.uia_provider = null;
        self.focus_ring_color = renderer_mod.default_focus_ring_color;
        // Visible by default (matches :focus-visible's initial/programmatic-
        // focus default) until a mouse click first switches it to .pointer.
        self.focus_highlight_mode = .keyboard;
        self.atlas = null;
        self.backend = null;
        self.focused_node = null;
        self.hovered_node = null;
        self.debug_node_id = null;
        self.overlay_rect = null;
        self.dev_arena = std.heap.ArenaAllocator.init(allocator);
        self.animator = animation_mod.AnimationEngine.init(allocator);
        self.last_frame_time = nowMs();
        self.hit_list = std.array_list.Managed(renderer_mod.HitNode).init(allocator);
        self.propagation_stopped = false;
        self.last_click_ms = 0;
        self.last_click_x = 0;
        self.last_click_y = 0;
        self.click_count = 0;
        self.input_mods = 0;
        self.last_pointer = null;
        self.hover_recheck = false;
        self.pressed_len = 0;
        self.signal_scope = signals_mod.Scope.init(allocator);
        self.host_signals = std.array_list.Managed(*HostSignal).init(allocator);
        self.host_binding_nodes = std.array_list.Managed(*reg.NodeId).init(allocator);
        self.owned_strings = std.AutoHashMap(usize, void).init(allocator);
        self.owned_strings_mutex = .unlocked;
        self.focus_scope_len = 0;

        if (!headless) {
            self.window = platform_mod.initWindow(.{
                .width = win.width,
                .height = win.height,
                .title = win.title,
                .parent = win.parent,
                .modal = win.modal,
                .corners = win.corners,
                .border_color = win.border_color,
                .x = win.x,
                .y = win.y,
                .always_on_top = win.always_on_top,
                .resizable = win.resizable,
                .visible = win.visible,
                .quit_on_close = win.quit_on_close,
            }) catch null;
        }
        var native_handle: ?platform_mod.NativeWindowHandle = null;
        self.scale = 1.0;
        if (self.window) |*w| {
            native_handle = w.handle;
            self.scale = w.scale;
            if (builtin.os.tag == .windows and native_handle != null) {
                if (native_handle.?.win32.hwnd) |hwnd| {
                    if (uia.CelerisUiaProvider.create(allocator, 0, &self.registry, &self.store, @ptrCast(hwnd), true, self.scale)) |provider| {
                        provider.focused = &self.focused_node;
                        // Hand over the IRawElementProviderSimple interface, not
                        // the Zig struct: UiaReturnRawElementProvider expects a
                        // COM pointer, and relying on `simple` being field 0
                        // would break silently if the layout ever changed.
                        w.setUiaProvider(&provider.simple);
                        self.uia_provider = provider;
                        // Raise UIA property-changed events from the one place state
                        // is mutated, so click/keyboard/UIA/host all announce alike.
                        self.store.setPropertyChangedListener(self, uiaPropertyChanged);
                    } else |_| {}
                }
            }
        }
        self.current_cursor = .default;
        self.last_maximized = false;
        self.atlas = loadFontAtlas(allocator);
        // Armed here so the handle is never read uninitialized; `rebuildUI`
        // refreshes it each pass (the scale can change with the display).
        if (self.atlas) |*atlas| self.measure_ctx = .{ .atlas = atlas, .scale = self.scale };

        self.backend = wgpu_mod.WgpuBackend.init(allocator, native_handle, win.width, win.height, self.scale, headless, if (self.atlas) |*a| a else null) catch null;

        self.is_initialized = true;
    }

    fn deinit(self: *EngineState) void {
        // Tear bindings down first (unsubscribes effects from the signals), then
        // free the signals themselves.
        self.signal_scope.deinit();
        self.host_binding_nodes.deinit();
        for (self.host_signals.items) |sig| {
            sig.deinit();
            self.gpa.allocator().destroy(sig);
        }
        self.host_signals.deinit();
        // Reclaim any host-owned strings the host never called
        // celeris_free_string on — otherwise every one leaks at shutdown, and
        // in Debug that's exactly what the leak-detecting `deinit` above (see
        // `debug_leak_count`) would flag as a false-positive engine leak.
        {
            var it = self.owned_strings.keyIterator();
            while (it.next()) |addr| {
                const ptr: [*c]const u8 = @ptrFromInt(addr.*);
                self.gpa.allocator().free(std.mem.span(ptr));
            }
        }
        self.owned_strings.deinit();
        if (self.backend) |*be| {
            be.deinit();
            self.backend = null;
        }
        // Destroy the OS window only after the GPU backend has released the surface
        // drawn onto it. This used to be skipped entirely: with one window the
        // process exited right afterwards and nobody noticed, but a closed secondary
        // window left a live HWND behind — still pumping messages into a wndProc
        // whose engine was gone, and still owning a surface the next window had to
        // be created alongside.
        if (self.window) |*w| {
            w.deinit();
            self.window = null;
        }
        // Drop the reference `CelerisUiaProvider.create` handed us — after the
        // window is gone, so no UIA client can be handed this provider again. It is
        // refcounted, so it survives until any client references go too — which,
        // for a client that cached a fragment (tree navigation, focus events) and
        // never got around to releasing it, may be never. Force every in-process
        // client proxy to drop its cached references first so our own release
        // below is what actually brings the count to zero.
        if (uiaProvider(self)) |p| {
            uia.disconnectAllProviders();
            p.releaseRef();
            self.uia_provider = null;
        }
        if (self.atlas) |*atlas| {
            atlas.deinit();
            self.atlas = null;
        }
        self.animator.deinit();
        self.dev_arena.deinit();
        self.hit_list.deinit();
        self.store.deinit();
        self.registry.deinit();
        // Surface leaks instead of swallowing them: in Debug the gpa is a
        // DebugAllocator that already knows, and a silent `_ =` here is how a
        // per-call leak in an export (celeris_get_dom_json) went unnoticed. The
        // counter (not just the log line) is what lets a Zig-level harness like
        // fuzz_api turn "leaked" into a nonzero exit — printing to stderr alone
        // does not fail a build step, so `zig build test` stayed green through
        // a 779-block-per-run leak until someone read the scrollback by hand.
        if (self.gpa.deinit() == .leak) {
            log.warn("engine deinit: allocator reported leaked memory (see the DebugAllocator traces above)\n", .{});
            _ = debug_leak_count.fetchAdd(1, .monotonic);
        }
        self.is_initialized = false;
    }
};

/// Number of engine `deinit`s that reported a leaked allocation (Debug builds
/// only — see `EngineState.deinit`). Not part of the C ABI; a Zig-level test
/// harness that `@import`s this module directly (see `examples/fuzz_api.zig`)
/// reads it after a run and exits nonzero if it moved, so leaks fail the build
/// instead of only appearing in scrollback.
pub var debug_leak_count: std.atomic.Value(u32) = .init(0);

var g_engines: [16]EngineState = undefined;
var g_engines_active: [16]bool = [_]bool{false} ** 16;

/// Debug/ReleaseSafe cross-thread misuse detector for the "mutate engine state
/// only from the UI thread" contract documented on `celeris_request_redraw` and
/// `celeris_post_task` — a rule every other export relies on but nothing
/// checked. The first thread to touch an engine (typically the one that calls
/// `celeris_create_engine`) claims ownership; any other thread reaching
/// `getEngine` afterwards means a host is poking engine state directly from a
/// worker instead of routing through `celeris_post_task`, which is exactly the
/// class of bug that produced the dangling `TextMeasure` context crash (a task
/// re-entering the builder is fine — it still runs on the UI thread, inside
/// `TaskQueue.drain`; a raw cross-thread call is not). Panics loudly in
/// Debug/ReleaseSafe; compiles to nothing in ReleaseFast so the check costs
/// nothing in a shipped app.
var g_owner_claimed = std.atomic.Value(bool).init(false);
var g_owner_thread_id = std.atomic.Value(u64).init(0);

fn assertUiThread(comptime site: []const u8) void {
    if (!std.debug.runtime_safety) return;
    const tid: u64 = @intCast(std.Thread.getCurrentId());
    // cmpxchgStrong returns null on success (false -> true actually happened),
    // or the current value on failure — here that's always `true`, since this
    // is the only writer and it never goes back to `false`.
    if (g_owner_claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        g_owner_thread_id.store(tid, .release);
        return;
    }
    const owner = g_owner_thread_id.load(.acquire);
    if (owner != tid) {
        std.debug.panic(
            "celeris: {s} called from thread {d}, but engine state is owned by thread {d}. " ++
                "Engine/signal/node mutation is not thread-safe — call from the UI thread, or " ++
                "hand the work to celeris_post_task instead of touching the engine directly.",
            .{ site, tid, owner },
        );
    }
}

pub fn getEngine(id: i32) ?*EngineState {
    assertUiThread("getEngine");
    if (id <= 0 or id > 16) return null;
    const idx: usize = @intCast(id - 1);
    if (!g_engines_active[idx]) return null;
    return &g_engines[idx];
}

/// Registers `ptr` (a gpa-owned string) as host-freeable via `owned_strings` and
/// returns it unchanged. If the tracking entry can't be allocated, `ptr` is
/// freed here and null is returned: `celeris_free_string` refuses to free any
/// pointer not in `owned_strings`, so an untracked string would leak forever —
/// a null return (a normal OOM outcome for these getters) is the honest result.
/// `std.atomic.Mutex` has no blocking `lock()`; this spins, which is fine here —
/// the only contention is a worker running a file dialog vs. the UI thread
/// freeing its result, and the critical section is a single hashmap op.
fn lockOwnedStrings(engine: *EngineState) void {
    while (!engine.owned_strings_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn trackOwnedString(engine: *EngineState, ptr: [*c]const u8) [*c]const u8 {
    if (ptr == null) return ptr;
    lockOwnedStrings(engine);
    defer engine.owned_strings_mutex.unlock();
    engine.owned_strings.put(@intFromPtr(ptr), {}) catch {
        engine.gpa.allocator().free(std.mem.span(ptr));
        return null;
    };
    return ptr;
}

/// Like `getEngine`, minus the UI-thread assertion. ONLY for the native file
/// dialogs and `celeris_free_string`: their documented usage (FRAMEWORK_API.md)
/// runs the blocking dialog on a worker thread and marshals the path back with
/// `celeris_post_task`. Those exports read only the window handle (immutable
/// after window init), the thread-safe gpa, and `owned_strings` (guarded by
/// `owned_strings_mutex`) — no signal / node / tree state — so a worker call is
/// sound where `assertUiThread` would otherwise reject it.
fn getEngineForDialog(id: i32) ?*EngineState {
    if (id <= 0 or id > 16) return null;
    const idx: usize = @intCast(id - 1);
    if (!g_engines_active[idx]) return null;
    return &g_engines[idx];
}

/// Copies `slice` into an engine-gpa-owned NUL-terminated C string, frees the
/// (gpa-owned) source slice, and returns the pointer (null on OOM). For the
/// getters that hand a fresh string back across the C-ABI, freed by the host
/// with `celeris_free_string`.
fn returnOwnedZ(engine: *EngineState, slice: []const u8) [*c]const u8 {
    const a = engine.gpa.allocator();
    defer a.free(slice);
    const z = allocPrintZ(a, "{s}", .{slice}) catch return null;
    return trackOwnedString(engine, z.ptr);
}

/// The EventContext for this engine's current frame. Extracted because every
/// pointer-event handler builds the same struct verbatim.
fn makeEventCtx(engine: *EngineState) events_mod.EventContext {
    return .{
        .registry = &engine.registry,
        .store = &engine.store,
        .propagation_stopped = &engine.propagation_stopped,
        .event_callback = engine.event_callback,
        .allocator = engine.gpa.allocator(),
        .modifiers = engine.input_mods,
    };
}

/// Hit-tests (x,y) against the current frame and, on a hit, dispatches
/// `event_type` (capture→bubble via the given modifier keys) to that node.
/// No-op when nothing is under the pointer.
fn hitAndDispatch(
    engine: *EngineState,
    x: f32,
    y: f32,
    event_type: events_mod.EventType,
    modifier_capture: props.ModifierKey,
    modifier_bubble: props.ModifierKey,
) void {
    const hit_id = events_mod.hitTest(engine.hit_list.items, &engine.registry, &engine.store, x, y) orelse return;
    events_mod.dispatchEvent(makeEventCtx(engine), hit_id, event_type, modifier_capture, modifier_bubble, x, y) catch {};
}

// ── Error channel ─────────────────────────────────────────────────────────────
// The C-ABI signals failure with -1/0/null; this carries a human-readable reason so
// a host can tell apart, say, a semantic error from an exhausted engine pool or a
// cancelled dialog. Single-threaded contract (see celeris.h): one global slot,
// overwritten by the most recent failing call.
var g_last_error: [256]u8 = [_]u8{0} ** 256;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(g_last_error[0 .. g_last_error.len - 1], fmt, args) catch {
        const m = "error (message too long)";
        @memcpy(g_last_error[0..m.len], m);
        g_last_error[m.len] = 0;
        return;
    };
    g_last_error[s.len] = 0;
}

/// Turns the engine's routine diagnostics on stderr (font discovery, engine init,
/// …) on or off. Off by default; the `CELERIS_LOG` environment variable also turns
/// them on. Warnings about real problems are always printed.
pub export fn celeris_set_verbose_logging(on: bool) void {
    log.setVerbose(on);
}

/// Returns a NUL-terminated description of the most recent failed call (engine-owned,
/// do NOT free; valid until the next failing call). Empty string if none recorded.
pub export fn celeris_last_error() [*:0]const u8 {
    return @ptrCast(&g_last_error);
}

/// The C-ABI version of this build (see include/celeris.h). Additive surface
/// changes bump it; breaking changes are a new major. v3 adds the folder picker
/// (celeris_pick_directory) and thread-safe repaint (celeris_request_redraw);
/// v5 adds the CELERIS_EVENT_RESIZE event type; v6 adds the `line_height` style
/// key and celeris_get_caret_metrics_ex / celeris_get_char_index_at_ex.
pub export fn celeris_abi_version() u32 {
    return 6;
}

// ─── Diagnostics: zone profiler ────────────────────────────────────────────────
// No-ops unless the library was built with `-Dprofiling`. They let a host turn
// the profiler on mid-run and dump the accumulated trace (Chrome Trace JSON,
// open in https://ui.perfetto.dev) without exiting the loop — e.g. bound to a key
// to capture a stall as it happens. `flush` is cumulative; call it repeatedly.

/// Start recording zones (idempotent). Until called, zones are inert even in a
/// profiling build. The CELERIS_TRACE env var enables this automatically at loop
/// start, so a host using that doesn't need this.
pub export fn celeris_profiler_enable() void {
    prof.enable(engineIo());
}

/// Write the trace recorded so far to `path` (UTF-8, null-terminated). Returns 0
/// on success (a non-profiling/never-enabled build writes nothing and still
/// returns 0), -1 only if the file write itself failed.
pub export fn celeris_profiler_flush(path: [*c]const u8) i32 {
    if (path == null) return -1;
    prof.flush(std.mem.span(path)) catch return -1;
    return 0;
}

// ─── C-ABI Exports ──────────────────────────────────────────────────────────

/// The structured event delivered to `celeris_register_event_callback`.
pub const CelerisEvent = events_mod.CelerisEvent;
pub const CelerisEventType = events_mod.EventType;

pub const CelerisConfig = extern struct {
    is_headless: bool,
};

/// Tears down an engine, frees all memory it owns, and releases its slot so a
/// later celeris_create_engine can reuse it. Safe to call on an invalid or
/// already-freed engine_id (no-op).
pub export fn celeris_deinit(engine_id: i32) void {
    if (engine_id <= 0 or engine_id > 16) return;
    const idx: usize = @intCast(engine_id - 1);
    if (!g_engines_active[idx]) return;

    // Close child windows first so they don't outlive their owner (orphaned modal
    // dialogs). Bounded by the pool (16) and acyclic — a parent always predates its
    // children — so the recursion terminates.
    for (0..16) |i| {
        if (!g_engines_active[i]) continue;
        if (g_engines[i].parent_engine_id == engine_id) {
            celeris_deinit(@intCast(i + 1));
        }
    }

    g_engines[idx].deinit();
    g_engines_active[idx] = false;
    // Drop any queued deferred-destroy for this slot: it has just been freed, and
    // the slot may be reused by the next window before the queue is drained.
    g_pending_destroy[idx] = false;
}

pub export fn celeris_window_start_drag(engine_id: i32) void {
    if (getEngine(engine_id)) |engine| {
        if (engine.window) |*w| w.startDrag();
    }
}

pub export fn celeris_window_close(engine_id: i32) void {
    if (getEngine(engine_id)) |engine| {
        if (engine.window) |*w| w.close();
    }
}

pub export fn celeris_window_maximize(engine_id: i32) void {
    if (getEngine(engine_id)) |engine| {
        if (engine.window) |*w| w.maximize();
    }
}

pub export fn celeris_window_minimize(engine_id: i32) void {
    if (getEngine(engine_id)) |engine| {
        if (engine.window) |*w| w.minimize();
    }
}

/// Fired when a window's maximized state changes outside our own button — e.g.
/// dragging a maximized window restores it via the OS. The framework wires this
/// to a UI rebuild so the AppBar's maximize/restore glyph stays in sync.
var g_on_maximize_change: ?*const fn (engine_id: i32) callconv(.c) void = null;

pub export fn celeris_set_maximize_change_callback(cb: ?*const fn (engine_id: i32) callconv(.c) void) void {
    g_on_maximize_change = cb;
}

/// Returns 1 if the window is currently maximized, 0 otherwise (or on error).
pub export fn celeris_window_is_maximized(engine_id: i32) i32 {
    if (getEngine(engine_id)) |engine| {
        if (engine.window) |*w| return if (w.isMaximized()) 1 else 0;
    }
    return 0;
}

/// Returns 1 while the platform draws the window's left/right/bottom edge itself
/// (see `PlatformWindow.nativeSideEdges`), 0 otherwise (or on error).
pub export fn celeris_window_native_side_edges(engine_id: i32) i32 {
    if (getEngine(engine_id)) |engine| {
        if (engine.window) |*w| return if (w.nativeSideEdges()) 1 else 0;
    }
    return 0;
}

/// Sets this window's focus-ring color (RGBA, 0..1), normally from its theme's
/// `focus_ring` token. Per engine: two windows on different themes each draw their
/// own ring, instead of the last one to build deciding for both.
pub export fn celeris_set_focus_ring_color(engine_id: i32, r: f32, g: f32, b: f32, a: f32) void {
    const engine = getEngine(engine_id) orelse return;
    const next = [4]f32{ r, g, b, a };
    if (std.mem.eql(f32, &engine.focus_ring_color, &next)) return;
    engine.focus_ring_color = next;
    engine.registry.global_render_dirty = true;
}

/// Moves and resizes a window, in logical (DPI-independent) screen pixels — the
/// same units layout uses. The engine's surface follows through the platform's
/// normal resize event, so no extra plumbing is needed here.
pub export fn celeris_window_set_bounds(engine_id: i32, x: i32, y: i32, w: u32, h: u32) void {
    if (getEngine(engine_id)) |engine| {
        if (engine.window) |*win| win.setBounds(x, y, w, h);
    }
}

/// Reads a window's current outer bounds (logical px) into the out-params. Returns
/// 0 on success, -1 if the engine or its window is gone. Pass null for values you
/// don't need. Lets an app save a rect before shrinking to an overlay and put the
/// window back exactly where it was.
pub export fn celeris_window_get_bounds(engine_id: i32, x: ?*i32, y: ?*i32, w: ?*u32, h: ?*u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (engine.window) |*win| {
        const r = win.getBounds();
        if (x) |p| p.* = r.x;
        if (y) |p| p.* = r.y;
        if (w) |p| p.* = r.w;
        if (h) |p| p.* = r.h;
        return 0;
    }
    return -1;
}

/// Toggles a window's always-on-top band at runtime.
pub export fn celeris_window_set_always_on_top(engine_id: i32, on: bool) void {
    if (getEngine(engine_id)) |engine| {
        if (engine.window) |*win| win.setAlwaysOnTop(on);
    }
}

/// Shows or hides a window without destroying it. Hiding the primary window
/// is how an app replaces itself with a compact overlay and comes back later — no
/// HWND hunting, no teardown of its component tree.
pub export fn celeris_window_set_visible(engine_id: i32, visible: bool) void {
    if (getEngine(engine_id)) |engine| {
        if (engine.window) |*win| win.setVisible(visible);
    }
}

/// The platform handle backing this window (HWND on Windows), or null when the
/// engine is headless. The documented escape hatch for platform work Celeris does
/// not wrap — nothing in the framework requires an app to call it.
pub export fn celeris_window_native_handle(engine_id: i32) ?*anyopaque {
    const engine = getEngine(engine_id) orelse return null;
    if (engine.window) |*win| {
        return switch (win.handle) {
            .win32 => |h| h.hwnd,
            .macos => |h| h.ns_window,
            .linux => |h| h.surface,
        };
    }
    return null;
}

/// The primary display's work area (screen minus taskbar) in logical px. Returns 0
/// on success, -1 where the platform doesn't expose it (Wayland). Backs anchored
/// overlay placement (`.top_right`, …).
pub export fn celeris_display_work_area(x: ?*i32, y: ?*i32, w: ?*u32, h: ?*u32) i32 {
    const r = platform_mod.workArea() orelse return -1;
    if (x) |p| p.* = r.x;
    if (y) |p| p.* = r.y;
    if (w) |p| p.* = r.w;
    if (h) |p| p.* = r.h;
    return 0;
}

/// Engines queued for destruction by `celeris_window_destroy_deferred`, drained at
/// the top of the next loop iteration.
var g_pending_destroy = [_]bool{false} ** 16;

/// Schedules `celeris_deinit(engine_id)` for the start of the next loop iteration.
/// This is what a *handler* must call: `overlay.close()` typically runs from a
/// click, i.e. from inside the loop's own walk over `g_engines` — freeing the
/// engine there would pull the registry out from under the frame in flight.
pub export fn celeris_window_destroy_deferred(engine_id: i32) void {
    if (engine_id <= 0 or engine_id > 16) return;
    g_pending_destroy[@intCast(engine_id - 1)] = true;
    platform_mod.wake();
}

/// Set by the framework so a user-initiated close on a secondary window (its own
/// close button, Alt+F4) unwinds the window's host — component tree, scopes and
/// signals — before the engine is destroyed. Without a hook the engine is simply
/// destroyed, which is the right behaviour for a C host with no Zig-side state.
var g_on_close_request: ?*const fn (engine_id: i32) callconv(.c) void = null;

pub export fn celeris_set_close_request_callback(cb: ?*const fn (engine_id: i32) callconv(.c) void) void {
    g_on_close_request = cb;
}

/// Platform → engine bridge for a swallowed WM_CLOSE on a secondary window.
fn closeRequestCallback(handle: platform_mod.NativeWindowHandle) void {
    const engine = engineForHandle(handle) orelse return;
    if (g_on_close_request) |cb| cb(engine.id) else celeris_window_destroy_deferred(engine.id);
}

/// Drains the deferred-destroy queue. Called once per loop iteration, before any
/// engine is touched.
fn drainPendingDestroys() void {
    for (0..16) |i| {
        if (!g_pending_destroy[i]) continue;
        g_pending_destroy[i] = false;
        celeris_deinit(@intCast(i + 1));
    }
}

/// Shared engine/window construction: claims a pool slot, initializes the engine
/// with `win`, and stamps its id. Returns the 1-based id, or -1 if the pool is full.
fn createEngineInternal(headless: bool, win: EngineState.WindowParams) i32 {
    assertUiThread("celeris_create_engine/celeris_create_window");
    var found_idx: ?usize = null;
    for (0..16) |i| {
        if (!g_engines_active[i]) {
            found_idx = i;
            break;
        }
    }
    if (found_idx == null) {
        setLastError("cannot create engine: pool exhausted (max 16 live engines)", .{});
        return -1;
    }

    const idx = found_idx.?;
    const id: i32 = @intCast(idx + 1);

    g_engines[idx].is_initialized = false;
    g_engines[idx].init(headless, win);
    g_engines[idx].id = id;
    g_engines_active[idx] = true;

    // The UIA provider is created during init() before the slot id is known;
    // hand it the id + action channel now so Invoke/Toggle can reach this engine.
    if (uiaProvider(&g_engines[idx])) |prov| {
        prov.engine_id = id;
        prov.actions = &g_uia_action_channel;
    }

    if (headless) {
        log.info("Engine {} initialized in HEADLESS mode.\n", .{id});
    } else {
        log.info("Engine {} initialized.\n", .{id});
    }
    return id;
}

pub export fn celeris_create_engine(config: ?*const CelerisConfig) i32 {
    const headless = if (config) |c| c.is_headless else false;
    return createEngineInternal(headless, .{});
}

/// A window's creation parameters. `parent_engine_id` (1-based, 0 = none)
/// makes this an owned child of another window; `modal` additionally disables the
/// parent's input until this window closes. `title` is NUL-terminated UTF-8 (null →
/// "Celeris"); width/height of 0 fall back to the 800×600 default.
pub const CelerisWindowConfig = extern struct {
    is_headless: bool,
    width: u32,
    height: u32,
    parent_engine_id: i32,
    modal: bool,
    title: [*c]const u8,
    /// Outer-corner rounding, as `platform.CornerPreference` (0 default, 1 square,
    /// 2 round, 3 round-small). Honoured on Windows 11; ignored elsewhere.
    corner_preference: u8 = 0,
    /// Color of the compositor-drawn frame border as 0xAARRGGBB, or 0 to leave the
    /// system default. Alpha is ignored — it only selects "set" from "unset", so a
    /// fully transparent color is not expressible (use `corner_preference = .square`,
    /// which makes Windows draw no border at all).
    border_color: u32 = 0,
    // ── Secondary-window fields ───────────────────────────────────
    // Appended, never reordered: the C header and the C# bindings lay this struct
    // out positionally, and a host built against the old shape must keep working
    // (the added fields all default to the previous behaviour when zeroed).
    /// Top-left position in logical screen px, honoured only when `has_position`
    /// is true (0,0 is a legitimate position, so a sentinel won't do).
    x: i32 = 0,
    y: i32 = 0,
    has_position: bool = false,
    /// Keep this window above other windows. Also creates it without stealing
    /// focus, so a floating bar doesn't yank the user out of the app below.
    always_on_top: bool = false,
    // The next three are negated on purpose. Every field here is read through a
    // caller-supplied pointer, so a host compiled against the older, shorter struct
    // leaves them zeroed — and zero has to mean "what Celeris did before".
    /// Drop WS_THICKFRAME: no resize borders, and the 8px hit-test margin stops
    /// eating clicks along the edges of a 56px-tall bar.
    fixed_size: bool = false,
    /// Create the window hidden, to be positioned before its first appearance.
    start_hidden: bool = false,
    /// Closing this window must NOT end the app's event loop. Forced on for
    /// every window created with a `parent_engine_id`.
    no_quit_on_close: bool = false,
};

/// Creates a window (engine) with full configuration: title, size, and an optional
/// owner/modal relationship to an existing window. Returns the 1-based id or -1.
pub export fn celeris_create_window(config: ?*const CelerisWindowConfig) i32 {
    const c = config orelse return createEngineInternal(false, .{});

    var parent_handle: ?platform_mod.NativeWindowHandle = null;
    if (c.parent_engine_id != 0) {
        const pe = getEngine(c.parent_engine_id) orelse {
            setLastError("celeris_create_window: invalid parent_engine_id {d}", .{c.parent_engine_id});
            return -1;
        };
        if (pe.window) |w| parent_handle = w.handle; // null in headless — OK, relationship is still tracked
    }

    const title: []const u8 = if (c.title != null) std.mem.span(@as([*:0]const u8, c.title)) else "Celeris";
    const id = createEngineInternal(c.is_headless, .{
        .width = if (c.width == 0) 800 else c.width,
        .height = if (c.height == 0) 600 else c.height,
        .title = title,
        .parent = parent_handle,
        .modal = c.modal,
        .corners = if (c.corner_preference <= 3)
            @enumFromInt(c.corner_preference)
        else
            .default,
        .border_color = if (c.border_color == 0) null else c.border_color,
        .x = if (c.has_position) c.x else null,
        .y = if (c.has_position) c.y else null,
        .always_on_top = c.always_on_top,
        .resizable = !c.fixed_size,
        .visible = !c.start_hidden,
        // An owned window never ends the loop: closing an overlay bar must leave
        // the app it belongs to running.
        .quit_on_close = !c.no_quit_on_close and c.parent_engine_id == 0,
    });
    if (id < 0) return id;

    // Record the engine-level relationship (independent of the OS window) so input
    // gating + cascade-close work even in headless and on platforms where the
    // native owner relationship isn't wired yet (Wayland).
    if (getEngine(id)) |e| {
        e.parent_engine_id = c.parent_engine_id;
        e.is_modal = c.modal;
    }
    return id;
}

/// True if some active engine is a modal child of `engine_id`. The parent must
/// then ignore input until that child closes (owner-modal semantics).
fn hasAliveModalChild(engine_id: i32) bool {
    for (0..16) |i| {
        if (!g_engines_active[i]) continue;
        const e = &g_engines[i];
        if (e.is_modal and e.parent_engine_id == engine_id) return true;
    }
    return false;
}

const MeasureContext = struct {
    atlas: *text_mod.FontAtlas,
    scale: f32,
};

/// Wraps FontAtlas.measureWidthSnapped for the component layer's type-erased TextMeasure.
fn atlasMeasureWidth(ctx: *anyopaque, text: []const u8, font_size: f32) f32 {
    const m_ctx: *const MeasureContext = @ptrCast(@alignCast(ctx));
    return m_ctx.atlas.measureWidthSnapped(text, font_size, m_ctx.scale);
}

/// `atlasMeasureWidth` with a role and tracking: resolves the role to a face exactly
/// as layout does (`fontIndexForRole`), so the width matches what is drawn.
fn atlasMeasureWidthStyled(ctx: *anyopaque, text: []const u8, font_size: f32, style: @import("framework/builder.zig").TextMeasure.MeasureStyle) f32 {
    const m_ctx: *const MeasureContext = @ptrCast(@alignCast(ctx));
    const pref = m_ctx.atlas.fontIndexForRole(style.role);
    return m_ctx.atlas.measureWidthSnappedPref(text, font_size, m_ctx.scale, pref, style.letter_spacing);
}

fn atlasVerticalLayoutStyled(ctx: *anyopaque, font_size: f32, box_height: f32, num_lines: usize, line_height_factor: f32, role: text_mod.FontRole) text_mod.VerticalLayout {
    const m_ctx: *const MeasureContext = @ptrCast(@alignCast(ctx));
    return m_ctx.atlas.verticalLayoutWith(m_ctx.atlas.fontIndexForRole(role), font_size, box_height, num_lines, line_height_factor);
}

/// Wraps FontAtlas.verticalLayout for the component layer, so a widget drawing a
/// caret or a selection band gets the same geometry the renderer draws glyphs with.
fn atlasVerticalLayout(ctx: *anyopaque, font_size: f32, box_height: f32, num_lines: usize, line_height_factor: f32) text_mod.VerticalLayout {
    const m_ctx: *const MeasureContext = @ptrCast(@alignCast(ctx));
    return m_ctx.atlas.verticalLayoutWith(0, font_size, box_height, num_lines, line_height_factor);
}

// Platform clipboard wrappers for the component layer's type-erased Clipboard.
fn clipboardGetFn(_: *anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    return platform_mod.clipboardGetText(allocator);
}
fn clipboardSetFn(_: *anyopaque, text: []const u8) bool {
    return platform_mod.clipboardSetText(text);
}
var g_clipboard_ctx: u8 = 0; // unused ctx; clipboard is process-global

// Type-erased trampolines for `UIBuilder.focus_scope`: overlays in the
// framework layer push/pop focus scopes without importing the engine.
fn focusScopePushFn(ctx: *anyopaque, root: reg.NodeId, origin: events_mod.FocusOrigin) bool {
    const engine: *EngineState = @ptrCast(@alignCast(ctx));
    return pushFocusScope(engine, root, origin);
}
fn focusScopePopFn(ctx: *anyopaque) bool {
    const engine: *EngineState = @ptrCast(@alignCast(ctx));
    return popFocusScope(engine);
}

/// Zig-only API (not exported to C).
/// Clears the current UI, calls `build_fn(builder, ctx)` to populate the
/// registry via UIBuilder, then runs the layout pass.
///
/// This is the entry point for 100% Zig host apps (e.g. the inspector).
/// The build_fn signature: `fn (*framework_builder.UIBuilder) anyerror!void`
pub fn rebuildUI(engine_id: i32, build_fn: *const fn (*@import("framework/builder.zig").UIBuilder) anyerror!void) !void {
    const engine = getEngine(engine_id) orelse return error.EngineNotFound;
    if (!engine.is_initialized) return error.EngineNotInitialized;

    var b = @import("framework/builder.zig").UIBuilder.init(&engine.registry, &engine.store);
    // Inject exact text measurement so components position carets precisely.
    // The context lives on the engine, not on this frame: see `measure_ctx`.
    if (engine.atlas) |*atlas| {
        engine.measure_ctx = .{ .atlas = atlas, .scale = engine.scale };
        b.measure = .{ .ctx = @ptrCast(&engine.measure_ctx), .measureFn = atlasMeasureWidth, .verticalFn = atlasVerticalLayout, .measureStyledFn = atlasMeasureWidthStyled, .verticalStyledFn = atlasVerticalLayoutStyled };
    }
    // Inject the platform clipboard so text widgets can copy/paste.
    b.clipboard = .{ .ctx = @ptrCast(&g_clipboard_ctx), .getFn = clipboardGetFn, .setFn = clipboardSetFn };
    // Inject focus-scope control so overlays (Menu/Dialog) can trap Tab.
    b.focus_scope = .{ .ctx = @ptrCast(engine), .pushFn = focusScopePushFn, .popFn = focusScopePopFn };
    // Inject the per-frame animator so indeterminate indicators can animate smoothly
    // instead of stepping off the coarse ~500ms tick channel (see events.TICK_MS).
    b.animator = &engine.animator;
    {
        // Zoned so a -Dprofiling trace can separate tree construction from
        // measure+place below — the two were previously indistinguishable in
        // rebuildUI (the loop's incremental solve already had its own
        // "layout.solve" zone; the full-rebuild path perf_bench measures did
        // not). Needed to attribute perf_bench's superlinear us/node growth
        // (1.38 -> 2.33 us/node from 1.2k to 20k nodes) to a phase instead of
        // guessing.
        const z = prof.zoneNamed("rebuildUI.build");
        defer z.end();
        try build_fn(&b);
    }

    if (engine.registry.nodes.items.len == 0) return;
    const root_id = engine.registry.nodes.items[0].id;

    var flex = layout_mod.LayoutEngine.init(&engine.registry, &engine.store, if (engine.atlas) |*a| a else null);
    {
        // Text shaping happens inside solve (measure callbacks reach the font
        // atlas while placing), so this zone covers measure+place+shape as one
        // phase — deliberately not split further here; the atlas's own zones
        // (see render/shaper.zig) cover shaping cost within it if that split
        // is needed later.
        const z = prof.zoneNamed("layout.solve");
        defer z.end();
        flex.solve(
            root_id,
            0,
            0,
            @floatFromInt(engine.renderer.width),
            @floatFromInt(engine.renderer.height),
        );
    }

    bakeAndRender(engine, false) catch {};

    log.info("UI built. {} nodes registered.\n", .{
        engine.registry.nodes.items.len,
    });
}

/// Registers the structured event callback that receives UI events as typed
/// `CelerisEvent`s `(node_id, event_type, payload)`. The host routes on the
/// fields directly — there is no JSON event channel.
pub export fn celeris_register_event_callback(engine_id: i32, callback: events_mod.StructuredEventCallback) void {
    if (getEngine(engine_id)) |engine| {
        engine.event_callback = callback;
    }
}

pub export fn celeris_stop_propagation(engine_id: i32) void {
    if (getEngine(engine_id)) |engine| {
        engine.propagation_stopped = true;
    }
}

pub export fn celeris_set_overlay_rect(
    engine_id: i32,
    visible: bool,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
) void {
    if (getEngine(engine_id)) |engine| {
        if (visible) {
            engine.overlay_rect = .{ .x = x, .y = y, .w = w, .h = h, .r = r, .g = g, .b = b, .a = a };
        } else {
            engine.overlay_rect = null;
        }
    }
}

/// Moves keyboard focus, repainting the ring, updating IME activation and
/// emitting blur/focus — the shared tail of Tab traversal and focus scopes.
/// `origin` (focus-visible) recomputes `engine.focus_highlight_mode` — see
/// `events_mod.FocusOrigin` for what each value does. `.restore` leaves the
/// current mode untouched (a focus-scope pop is not a new navigation).
fn moveFocus(engine: *EngineState, new_focus: ?reg.NodeId, origin: events_mod.FocusOrigin) void {
    const old_mode = engine.focus_highlight_mode;
    switch (origin) {
        .pointer => engine.focus_highlight_mode = .pointer,
        .keyboard, .programmatic, .uia_external => engine.focus_highlight_mode = .keyboard,
        .restore, .removed => {},
    }
    const mode_changed = old_mode != engine.focus_highlight_mode;
    // Any focus move disarms the Escape→Tab exit (see `captures_tab`).
    engine.tab_escape_armed = false;

    const old_focus = engine.focused_node;
    if (old_focus == new_focus) {
        // The node didn't move, but the mode did (e.g. a keyboard action that
        // resolves back to the already-focused node) — still needs a repaint
        // so the ring appears/disappears on the node that's already focused.
        if (mode_changed) engine.registry.global_render_dirty = true;
        return;
    }
    engine.focused_node = new_focus;
    engine.registry.global_render_dirty = true; // focus ring moved → repaint
    platform_mod.setImeActive(imeActiveForNode(engine, new_focus)); // IME only in text fields

    // Announce the move to assistive tech. Single funnel: Tab, click, focus scopes
    // and UIA SetFocus all land here, so one call covers every origin.
    if (uiaProvider(engine)) |prov| {
        if (new_focus) |nf| prov.raiseFocusChanged(nf);
    }

    if (old_focus) |old| {
        if (engine.registry.getNode(old)) |node| node.render_dirty = true;
        if (engine.store.getModifier(old, .focusable)) |mod| {
            const id_str = switch (mod) {
                .string => |s| s,
                else => "unknown",
            };
            emitEvent(engine, .blur, old, id_str, 0, 0, 0, 0, "", 0);
        }
    }
    if (new_focus) |nf| {
        if (engine.registry.getNode(nf)) |node| node.render_dirty = true;
        if (engine.store.getModifier(nf, .focusable)) |mod| {
            const id_str = switch (mod) {
                .string => |s| s,
                else => "unknown",
            };
            emitEvent(engine, .focus, nf, id_str, 0, 0, 0, 0, "", 0);
        }
    }
}

/// Bridges a store value change to the matching UIA property-changed event. Runs
/// on the UI thread (every mutation path does), so it can touch the provider and
/// registry directly. The store stays platform-agnostic; the role→pattern mapping
/// (which UIA property a `.checked`/`.expanded`/`.text` change means) lives here.
fn uiaPropertyChanged(ctx: ?*anyopaque, node_id: reg.NodeId, changed: props.ChangedProp) void {
    const engine: *EngineState = @ptrCast(@alignCast(ctx orelse return));
    const prov = uiaProvider(engine) orelse return;
    switch (changed) {
        // The Value element is the nearest self/ancestor with a textbox role; the
        // node that actually holds the text is usually its child, so walk up.
        .text => {
            var id = node_id;
            while (true) {
                const node = engine.registry.getNode(id) orelse return;
                const role = a11y.accessibleRole(&engine.store, id, node.node_type);
                if (uia.roleSupportsValue(role)) {
                    const val = a11y.editableValue(&engine.registry, &engine.store, id);
                    prov.raisePropertyChanged(id, uia.UIA_ValueValuePropertyId, uia.variantBStr(val));
                    return;
                }
                if (node.parent == reg.NULL_NODE) return;
                id = node.parent;
            }
        },
        .modifier => |key| {
            const node = engine.registry.getNode(node_id) orelse return;
            const role = a11y.accessibleRole(&engine.store, node_id, node.node_type);
            switch (key) {
                .checked => {
                    const on = a11y.stateFlag(&engine.store, node_id, .checked);
                    // A control is a Toggle or a SelectionItem, never both (UIA rule).
                    if (uia.roleSupportsToggle(role)) {
                        const state: uia.ToggleState = if (on) .On else .Off;
                        prov.raisePropertyChanged(node_id, uia.UIA_ToggleToggleStatePropertyId, uia.variantI4(@intFromEnum(state)));
                    } else if (uia.roleSupportsSelectionItem(role)) {
                        prov.raisePropertyChanged(node_id, uia.UIA_SelectionItemIsSelectedPropertyId, uia.variantBool(on));
                    }
                },
                .expanded => {
                    if (uia.roleSupportsExpandCollapse(role)) {
                        const ex = a11y.stateFlag(&engine.store, node_id, .expanded);
                        const state: uia.ExpandCollapseState = if (ex) .Expanded else .Collapsed;
                        prov.raisePropertyChanged(node_id, uia.UIA_ExpandCollapseExpandCollapseStatePropertyId, uia.variantI4(@intFromEnum(state)));
                    }
                },
                // Roving focus: a container (a `Menu` panel) redirects the
                // ring to a "virtually" focused descendant (the highlighted
                // row) without moving real engine focus off itself — see
                // `ModifierKey.virtual_focus_target`. Screen readers need the
                // same redirect: `AutomationFocusChangedEventId` fires on the
                // row each time it changes, exactly as if real DOM/UIA focus
                // had moved there (the `aria-activedescendant` pattern — user
                // agents synthesize focus events on the logical target without
                // moving real focus). Only when `node_id` currently holds REAL
                // engine focus: a redirect set on a node that isn't focused
                // (e.g. cleared while closing, just before the pop restores
                // focus elsewhere) must not announce anything.
                .virtual_focus_target => {
                    if (engine.focused_node != node_id) return;
                    const target = engine.store.modifierNodeRef(node_id, .virtual_focus_target) orelse return;
                    if (engine.registry.getNode(target) == null) return;
                    prov.raiseFocusChanged(target);
                },
                else => {},
            }
        },
    }
}

/// Traps keyboard focus within `root`'s subtree. Tab cycles only inside; the
/// focus moves to the scope's first focusable. Returns false when the stack is
/// full or the node doesn't exist. `origin` is whatever caused the scope
/// to open — a menu opened by a mouse click passes `.pointer` (no ring); one
/// opened by an accelerator/keyboard passes `.keyboard` (ring shows right away).
pub fn pushFocusScope(engine: *EngineState, root: reg.NodeId, origin: events_mod.FocusOrigin) bool {
    if (engine.focus_scope_len >= EngineState.MAX_FOCUS_SCOPES) return false;
    if (engine.registry.getNode(root) == null) return false;
    engine.focus_scopes[engine.focus_scope_len] = .{ .root = root, .prev_focus = engine.focused_node };
    engine.focus_scope_len += 1;
    var list = std.array_list.Managed(reg.NodeId).init(engine.gpa.allocator());
    defer list.deinit();
    getFocusableNodes(&engine.registry, &engine.store, &list, root, 0) catch {};
    if (list.items.len > 0) {
        moveFocus(engine, list.items[0], origin);
    } else if (engine.store.getModifier(root, .focusable) != null) {
        // An overlay pushed the same frame it opens still has last frame's
        // zero-height geometry, so nothing inside is tabbable yet. Focus the
        // scope root itself (if focusable) so key_down routes into the scope.
        moveFocus(engine, root, origin);
    }
    return true;
}

/// Pops the top focus scope and restores the focus held before the push
/// (cleared if that node is gone, no longer focusable, or not tabbable).
/// Always `.restore`: closing an overlay and returning focus to what was
/// there before is not a new navigation, so the ring's current visibility
/// (whatever it was) carries over unchanged.
pub fn popFocusScope(engine: *EngineState) bool {
    if (engine.focus_scope_len == 0) return false;
    engine.focus_scope_len -= 1;
    const scope = engine.focus_scopes[engine.focus_scope_len];
    var restored: ?reg.NodeId = null;
    if (scope.prev_focus) |p| {
        if (engine.registry.getNode(p) != null and
            engine.store.getModifier(p, .focusable) != null and
            isTabbable(&engine.registry, &engine.store, p)) restored = p;
    }
    moveFocus(engine, restored, .restore);
    return true;
}

/// A focusable node is skipped by Tab when it is disabled, has no resolved
/// size, or lies fully outside an `overflow_hidden` ancestor's box (e.g. rows of
/// a closed dropdown menu clipped to height 0) — focusing an invisible or inert
/// node strands the focus ring.
fn isTabbable(registry: *reg.UIRegistry, store: *const props.PropertyStore, id: reg.NodeId) bool {
    if (store.modifierFlag(id, .disabled)) return false;
    return a11y.isVisible(registry, store, id);
}

fn getFocusableNodes(registry: *reg.UIRegistry, store: *const props.PropertyStore, list: *std.array_list.Managed(reg.NodeId), current: reg.NodeId, depth: usize) !void {
    if (depth >= reg.MAX_TREE_DEPTH) return;
    if (store.getModifier(current, .focusable) != null and isTabbable(registry, store, current)) {
        try list.append(current);
    }
    const node = registry.getNode(current) orelse return;
    var child_id = node.first_child;
    while (child_id != reg.NULL_NODE) {
        try getFocusableNodes(registry, store, list, child_id, depth + 1);
        const child_node = registry.getNode(child_id) orelse break;
        child_id = child_node.next_sibling;
    }
}

/// True if two native window handles refer to the same window (tag-aware,
/// platform-neutral — no win32 assumptions).
fn handlesEqual(a: platform_mod.NativeWindowHandle, b: platform_mod.NativeWindowHandle) bool {
    const Tag = @import("std").meta.Tag(platform_mod.NativeWindowHandle);
    if (@as(Tag, a) != @as(Tag, b)) return false;
    return switch (a) {
        .win32 => |x| x.hwnd == b.win32.hwnd,
        .macos => |x| x.ns_window == b.macos.ns_window,
        .linux => |x| x.surface == b.linux.surface,
    };
}

/// First active engine, used as the fallback target for handle-less events
/// (synthetic input, global resize) in the common single-window case.
fn firstActiveEngine() ?*EngineState {
    for (0..16) |i| {
        if (g_engines_active[i]) return &g_engines[i];
    }
    return null;
}

/// Resolves the engine that owns `handle`.
///
/// A handle-less event (synthetic input via the `celeris_dispatch_*` API) targets
/// the first active engine — that fallback is what the optional handle is for. An
/// event that DOES name a window but matches no engine is dropped: guessing is
/// always wrong once a second window exists, and it is not a hypothetical. Windows
/// fires WM_SIZE from inside `CreateWindowExA`, before the new window has been
/// recorded on its engine (its pool slot isn't even active yet), so the guess
/// resized the *main* window to the overlay's 460x56 and left its layout there.
fn engineForHandle(handle: ?platform_mod.NativeWindowHandle) ?*EngineState {
    const h = handle orelse return firstActiveEngine();
    for (0..16) |i| {
        if (!g_engines_active[i]) continue;
        if (g_engines[i].window) |w| {
            if (handlesEqual(w.handle, h)) return &g_engines[i];
        }
    }
    return null;
}

/// The single place engine events are delivered to the host, as a structured
/// `CelerisEvent`. `action_id`/`text` are copied into NUL-terminated stack buffers
/// for the C ABI (valid only for the duration of the callback).
/// Double-click timing. A mouse-down within this window AND distance of the
/// previous one continues the click sequence; anything else restarts it at 1.
/// Detected purely by timing so Win32 and Wayland behave identically.
const DOUBLE_CLICK_MS: i64 = 400;
const DOUBLE_CLICK_DIST_SQ: f32 = 16.0; // (4 px)²

/// Pure click-sequence counter: given the previous count, the gap since the last
/// click (ms) and the squared pointer distance, returns the new count.
fn nextClickCount(prev_count: u32, dt_ms: i64, dist_sq: f32) u32 {
    if (dt_ms >= 0 and dt_ms <= DOUBLE_CLICK_MS and dist_sq <= DOUBLE_CLICK_DIST_SQ) return prev_count + 1;
    return 1;
}

/// Reports every `on_resize`-observed node whose solved size changed in the last
/// solve. Called after `bakeAndRender`, never inside the solve: a handler may
/// rebuild or remove nodes, and that must land in the *next* frame's solve rather
/// than leave this frame's bake with unsolved geometry. Each node reports at most
/// once per solve, so a size↔content feedback loop advances one frame at a time
/// instead of spinning. Changes are collected first because delivery can mutate
/// the observer list.
fn emitResizes(engine: *EngineState) void {
    if (engine.registry.resize_observers.items.len == 0) return;
    const gpa = engine.registry.allocator;
    var changed: std.ArrayListUnmanaged(reg.UIRegistry.Resized) = .empty;
    defer changed.deinit(gpa);
    engine.registry.collectResized(&changed, gpa) catch |e| {
        log.warn("on_resize: collecting size changes failed: {}\n", .{e});
    };
    for (changed.items) |r| {
        // An earlier handler in this batch may have removed the node.
        // (`observe_resize` also guards a slot recycled within the batch.)
        const node = engine.registry.getNode(r.id) orelse continue;
        if (!node.observe_resize) continue;
        emitEvent(engine, .resize, r.id, "", r.w, r.h, 0, 0, "", 0);
    }
}

fn emitEvent(
    engine: *EngineState,
    event_type: events_mod.EventType,
    node_id: reg.NodeId,
    action_id: []const u8,
    x: f32,
    y: f32,
    key_code: u32,
    scroll_delta: f32,
    text: []const u8,
    modifiers: u32,
) void {
    const cb = engine.event_callback orelse return;
    var idbuf: [128]u8 = undefined;
    var txtbuf: [256]u8 = undefined; // room for IME preedit/commit strings
    const ev = events_mod.CelerisEvent{
        .event_type = @intFromEnum(event_type),
        .node_id = if (node_id == reg.NULL_NODE) 0 else node_id,
        .action_id = events_mod.toCString(&idbuf, action_id),
        .x = x,
        .y = y,
        .key_code = key_code,
        .scroll_delta = scroll_delta,
        .text = events_mod.toCString(&txtbuf, text),
        .modifiers = modifiers,
    };
    cb(&ev);
}

/// True if `node` is an editable text widget — used to enable IME only inside
/// text fields. TextInput/TextArea both set the I-beam (`cursor: "text"`), so
/// that's the editable marker.
fn imeActiveForNode(engine: *EngineState, node: ?reg.NodeId) bool {
    const n = node orelse return false;
    if (engine.store.getModifier(n, .cursor)) |cur| {
        if (cur == .string and std.mem.eql(u8, cur.string, "text")) return true;
    }
    return false;
}

/// A key_down for a modifier pressed on its own: VK_SHIFT/VK_CONTROL/VK_MENU
/// (0x10-0x12), their L/R variants (0xA0-0xA5) and the Windows keys
/// (0x5B/0x5C). Linux maps the modifier keysyms onto 0x10-0x12/0x5B
/// (`keysym.toVk`); code 0 is an unmapped key, NOT a modifier. Win32 Alt
/// arrives as WM_SYSKEYDOWN and never reaches here today; kept for parity.
fn isModifierOnlyKey(code: u32) bool {
    return switch (code) {
        0x10...0x12, 0x5B, 0x5C, 0xA0...0xA5 => true,
        else => false,
    };
}

/// Whether a keyboard activation (Enter/Space) on the focused node should
/// synthesize a click, and where (the node's center — same dispatch path as the
/// mouse). Null for non-clickable nodes and for text-editing targets (cursor
/// "text"), where Space/Enter must type into the buffer instead.
fn clickSynthTarget(store: *props.PropertyStore, registry: *reg.UIRegistry, focused: reg.NodeId) ?struct { x: f32, y: f32 } {
    if (store.getModifier(focused, .clickable) == null) return null;
    if (store.getModifier(focused, .cursor)) |cur| {
        if (cur == .string and std.mem.eql(u8, cur.string, "text")) return null;
    }
    const node = registry.getNode(focused) orelse return null;
    const g = node.geometry;
    return .{ .x = g.x + g.width / 2.0, .y = g.y + g.height / 2.0 };
}

// ── UIA action channel ──────────────────────────────────────────────────────
// Bridges a UIA action pattern (Invoke/Toggle), which UIA calls on its own RPC
// thread, to the real input path on the UI thread. The pattern object only calls
// `invoke`; the marshaling + actual click live here, so the automation exercises
// the exact same code a user's click does — no separate programmatic path to drift from real input.
/// The engine's UIA provider. Comptime-null off Windows, so the UIA (COM) code
/// behind every `if (uiaProvider(e)) |p|` is never analysed or linked there.
inline fn uiaProvider(e: *EngineState) ?*uia.CelerisUiaProvider {
    if (comptime builtin.os.tag != .windows) return null;
    return e.uia_provider;
}

const UiaInvokeCtx = struct { engine_id: i32, node_id: reg.NodeId, intent: uia.InvokeIntent };

/// Runs on the UI thread (drained from the task queue). Re-checks the action's
/// gate against fresh state (so Expand/Collapse/Select can't fire on a state that
/// changed since the COM-thread call), then dispatches the node's real click —
/// identical to a pointer/keyboard activation.
fn uiaInvokeMain(ctx_ptr: ?*anyopaque) callconv(.c) void {
    const c: *UiaInvokeCtx = @ptrCast(@alignCast(ctx_ptr));
    defer std.heap.c_allocator.destroy(c);
    const engine = getEngine(c.engine_id) orelse return;
    if (!engine.is_initialized) return;
    // A UIA pattern's Invoke/Toggle/Expand/Select call reaches here directly —
    // it never goes through hitTest's clip check (core/events.zig), so without
    // this gate a closed Menu/Dropdown's rows (hidden only via an
    // `overflow_hidden` ancestor collapsing to height 0, not by shrinking the
    // rows themselves) would still fire their action when invoked by
    // automation. Re-checked here, fresh, same as the intent gate below.
    if (!a11y.isVisible(&engine.registry, &engine.store, c.node_id)) return;
    const expanded = a11y.stateFlag(&engine.store, c.node_id, .expanded);
    const checked = a11y.stateFlag(&engine.store, c.node_id, .checked);
    if (!uia.shouldActuate(c.intent, expanded, checked)) return;
    const pt = clickSynthTarget(&engine.store, &engine.registry, c.node_id) orelse return;
    events_mod.dispatchEvent(makeEventCtx(engine), c.node_id, .click, .clickable_capture, .clickable, pt.x, pt.y) catch {};
    engine.registry.global_render_dirty = true;
}

/// Called on the UIA (COM) thread by a pattern object. Marshals onto the UI
/// thread via the task queue and returns immediately (patterns are fire-and-forget).
/// Frees the context if the queue push fails (OOM) so a dropped task can't leak.
fn uiaInvokeThunk(engine_id: i32, node_id: reg.NodeId, intent: uia.InvokeIntent) callconv(.c) void {
    const c = std.heap.c_allocator.create(UiaInvokeCtx) catch return;
    c.* = .{ .engine_id = engine_id, .node_id = node_id, .intent = intent };
    getTaskQueue().push(.{ .callback = uiaInvokeMain, .ctx = c }) catch {
        std.heap.c_allocator.destroy(c);
        return;
    };
    platform_mod.wake();
}

/// Replaces `node_id`'s editable text through the real keyboard/IME edit path:
/// focus the node, select all (Ctrl+A), then commit the new text (which replaces
/// the selection) — or a Backspace when clearing, since an empty commit is a
/// no-op. Runs on the UI thread. Same code a user's keystrokes drive, so
/// on_change/undo fire exactly as if typed.
fn setNodeTextViaInput(engine: *EngineState, node_id: reg.NodeId, text: []const u8) void {
    if (engine.registry.getNode(node_id) == null) return;
    // Read-only guard, on the UI thread against fresh state (moved here from the
    // COM-thread ValuePattern.SetValue so there's no unsynchronized store read).
    if (a11y.stateFlag(&engine.store, node_id, .readonly)) return;
    const modifier = engine.store.getModifier(node_id, .focusable) orelse return;
    const id_str = switch (modifier) {
        .string => |s| s,
        else => "unknown",
    };
    moveFocus(engine, node_id, .programmatic);
    emitEvent(engine, .key_down, node_id, id_str, 0, 0, 65, 0, "", events_mod.MOD_CTRL); // Ctrl+A
    if (text.len > 0) {
        emitEvent(engine, .text_commit, node_id, id_str, 0, 0, 0, 0, text, 0);
    } else {
        emitEvent(engine, .key_down, node_id, id_str, 0, 0, 8, 0, "", 0); // VK_BACK deletes the selection
    }
    engine.registry.global_render_dirty = true;
}

const UiaSetTextCtx = struct { engine_id: i32, node_id: reg.NodeId, text: []u8 };

fn uiaSetTextMain(ctx_ptr: ?*anyopaque) callconv(.c) void {
    const c: *UiaSetTextCtx = @ptrCast(@alignCast(ctx_ptr));
    defer {
        std.heap.c_allocator.free(c.text);
        std.heap.c_allocator.destroy(c);
    }
    const engine = getEngine(c.engine_id) orelse return;
    if (!engine.is_initialized) return;
    setNodeTextViaInput(engine, c.node_id, c.text);
}

/// Called on the UIA (COM) thread by ValuePattern.SetValue. Copies the text
/// (the caller's buffer is transient), marshals onto the UI thread, returns.
fn uiaSetTextThunk(engine_id: i32, node_id: reg.NodeId, text_ptr: [*]const u8, len: usize) callconv(.c) void {
    const copy = std.heap.c_allocator.alloc(u8, len) catch return;
    @memcpy(copy, text_ptr[0..len]);
    const c = std.heap.c_allocator.create(UiaSetTextCtx) catch {
        std.heap.c_allocator.free(copy);
        return;
    };
    c.* = .{ .engine_id = engine_id, .node_id = node_id, .text = copy };
    getTaskQueue().push(.{ .callback = uiaSetTextMain, .ctx = c }) catch {
        std.heap.c_allocator.free(copy);
        std.heap.c_allocator.destroy(c);
        return;
    };
    platform_mod.wake();
}

const UiaFocusCtx = struct { engine_id: i32, node_id: reg.NodeId };

fn uiaSetFocusMain(ctx_ptr: ?*anyopaque) callconv(.c) void {
    const c: *UiaFocusCtx = @ptrCast(@alignCast(ctx_ptr));
    defer std.heap.c_allocator.destroy(c);
    const engine = getEngine(c.engine_id) orelse return;
    if (!engine.is_initialized) return;
    if (engine.registry.getNode(c.node_id) == null) return;
    if (engine.store.getModifier(c.node_id, .focusable) == null) return; // only focusable elements
    moveFocus(engine, c.node_id, .uia_external);
    engine.registry.global_render_dirty = true;
}

/// Called on the UIA (COM) thread by IRawElementProviderFragment::SetFocus.
/// Marshals a focus move onto the UI thread; frees the ctx if the push fails.
fn uiaSetFocusThunk(engine_id: i32, node_id: reg.NodeId) callconv(.c) void {
    const c = std.heap.c_allocator.create(UiaFocusCtx) catch return;
    c.* = .{ .engine_id = engine_id, .node_id = node_id };
    getTaskQueue().push(.{ .callback = uiaSetFocusMain, .ctx = c }) catch {
        std.heap.c_allocator.destroy(c);
        return;
    };
    platform_mod.wake();
}

var g_uia_action_channel = uia.ActionChannel{ .invoke = uiaInvokeThunk, .set_text = uiaSetTextThunk, .set_focus = uiaSetFocusThunk };

/// Synthetic text replacement (also the ValuePattern.SetValue backend): replaces
/// the editable content of `node_id` via the real edit path. Call from the UI
/// thread (host / tests); the UIA provider reaches it through the task queue.
pub export fn celeris_dispatch_set_text(engine_id: i32, node_id: u32, text_ptr: [*c]const u8, len: usize) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    const text: []const u8 = if (len == 0 or text_ptr == null) "" else text_ptr[0..len];
    setNodeTextViaInput(engine, node_id, text);
    return 0;
}

fn parseCursor(s: []const u8) platform_mod.CursorType {
    if (std.mem.eql(u8, s, "pointer")) return .pointer;
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "resize_ew")) return .resize_ew;
    if (std.mem.eql(u8, s, "resize_ns")) return .resize_ns;
    return .default;
}

/// Resolves the cursor for the node under the pointer: the nearest ancestor with
/// an explicit `cursor` modifier wins; otherwise a `clickable` ancestor implies a
/// pointer (hand); else the default arrow.
/// Moves the hover to the nearest `.hoverable` ancestor-or-self of `top_hit`,
/// emitting mouse_leave to the old node and mouse_enter to the new one. The
/// single hover funnel: pointer motion and the post-rebuild recheck share it.
fn updateHover(engine: *EngineState, top_hit: ?reg.NodeId, x: f32, y: f32, mods: u32) void {
    var hit_hoverable: ?reg.NodeId = null;
    if (top_hit) |hit_id| {
        var current_id: reg.NodeId = hit_id;
        while (current_id != reg.NULL_NODE) {
            if (engine.store.getModifier(current_id, .hoverable)) |_| {
                hit_hoverable = current_id;
                break;
            }
            const node = engine.registry.getNode(current_id) orelse break;
            current_id = node.parent;
        }
    }
    if (engine.hovered_node == hit_hoverable) return;
    if (engine.hovered_node) |old_hover| {
        if (engine.store.getModifier(old_hover, .hoverable)) |val| {
            const id_str = switch (val) {
                .string => |s| s,
                else => "unknown",
            };
            emitEvent(engine, .mouse_leave, old_hover, id_str, x, y, 0, 0, "", mods);
        }
    }
    engine.hovered_node = hit_hoverable;
    if (engine.hovered_node) |new_hover| {
        if (engine.store.getModifier(new_hover, .hoverable)) |val| {
            const id_str = switch (val) {
                .string => |s| s,
                else => "unknown",
            };
            emitEvent(engine, .mouse_enter, new_hover, id_str, x, y, 0, 0, "", mods);
        }
    }
}

const MAX_PRESSED = 32;

/// Records the clickable nodes on the hit path of a mouse_down (target
/// first) — the ones `.mouse_down` is dispatched to and that must get the
/// matching `.mouse_up`.
fn capturePressed(engine: *EngineState, x: f32, y: f32) void {
    engine.pressed_len = 0;
    var cur = events_mod.hitTest(engine.hit_list.items, &engine.registry, &engine.store, x, y) orelse return;
    while (cur != reg.NULL_NODE and engine.pressed_len < MAX_PRESSED) {
        if (engine.store.getModifier(cur, .clickable) != null or engine.store.getModifier(cur, .clickable_capture) != null) {
            engine.pressed_nodes[engine.pressed_len] = cur;
            engine.pressed_len += 1;
        }
        const node = engine.registry.getNode(cur) orelse break;
        cur = node.parent;
    }
}

fn pressedActionId(engine: *EngineState, id: reg.NodeId) []const u8 {
    const m = engine.store.getModifier(id, .clickable) orelse return "";
    return if (m == .string) m.string else "";
}

/// Delivers `mouse_up` to every node that took the current press,
/// target first, then clears the capture. Nodes removed since were already
/// released by `releasePressed`.
fn releaseAllPressed(engine: *EngineState, x: f32, y: f32, mods: u32) void {
    // Snapshot: a mouse_up handler may rebuild, and the removal listener
    // edits `pressed_nodes` while we iterate.
    var ids: [MAX_PRESSED]reg.NodeId = undefined;
    const n = engine.pressed_len;
    @memcpy(ids[0..n], engine.pressed_nodes[0..n]);
    engine.pressed_len = 0;
    for (ids[0..n]) |id| {
        if (engine.registry.getNode(id) == null) continue;
        emitEvent(engine, .mouse_up, id, pressedActionId(engine, id), x, y, 0, 0, "", mods);
    }
}

/// Removal hook: if `id` took the current press, send it its mouse_up now and
/// drop it from the capture.
fn releasePressed(engine: *EngineState, id: reg.NodeId) void {
    var i: usize = 0;
    while (i < engine.pressed_len) : (i += 1) {
        if (engine.pressed_nodes[i] != id) continue;
        engine.pressed_len -= 1;
        engine.pressed_nodes[i] = engine.pressed_nodes[engine.pressed_len];
        const p = engine.last_pointer orelse PointerPos{ .x = 0, .y = 0 };
        emitEvent(engine, .mouse_up, id, "", p.x, p.y, 0, 0, "", 0);
        return;
    }
}

/// A rebuild that removed the hovered node (e.g. a Button re-mounted
/// by its own click) left the replacement with no hover edge — its surviving
/// `hovered` state never got a mouse_leave. The removal listener clears
/// `hovered_node` and arms this; once the fresh hit list is baked, hover is
/// re-evaluated at the last pointer position, so the node now under a still
/// pointer receives mouse_enter and a later move-away delivers mouse_leave.
fn recheckHover(engine: *EngineState) void {
    if (!engine.hover_recheck) return;
    engine.hover_recheck = false;
    const p = engine.last_pointer orelse return;
    const top_hit = events_mod.hitTest(engine.hit_list.items, &engine.registry, &engine.store, p.x, p.y);
    updateHover(engine, top_hit, p.x, p.y, 0);
}

fn resolveCursor(store: *props.PropertyStore, registry: *reg.UIRegistry, hit: ?reg.NodeId) platform_mod.CursorType {
    var id: reg.NodeId = hit orelse return .default;
    while (id != reg.NULL_NODE) {
        if (store.getModifier(id, .cursor)) |c| {
            return parseCursor(switch (c) {
                .string => |s| s,
                else => "",
            });
        }
        if (store.getModifier(id, .clickable) != null) return .pointer;
        const node = registry.getNode(id) orelse break;
        id = node.parent;
    }
    return .default;
}

/// Resolves the effective scroll axes of a wheel event. A native horizontal
/// delta (tilt wheel / touchpad) wins; otherwise Shift converts the vertical
/// delta into horizontal (the convention for mice without a tilt wheel).
/// Pure — unit-tested headless.
fn scrollAxes(delta: f32, dx: f32, shift: bool) struct { dy: f32, dx: f32 } {
    if (dx != 0) return .{ .dy = delta, .dx = dx };
    if (shift and delta != 0) return .{ .dy = 0, .dx = delta };
    return .{ .dy = delta, .dx = 0 };
}

fn handleOSInput(ctx: ?*anyopaque, event_in: platform_mod.InputEvent) void {
    // Synthetic input (celeris_dispatch_*) passes the target engine as ctx; the
    // real OS callback passes null and is resolved from the event's window handle.
    const engine_ptr: ?*EngineState = if (ctx) |c|
        @as(*EngineState, @ptrCast(@alignCast(c)))
    else
        engineForHandle(event_in.native_handle);

    const engine = engine_ptr orelse return;

    // Owner-modal: while a modal child window is alive, its parent ignores all
    // input (clicks/keys/scroll) until the child closes. The child itself has no
    // modal child, so its own input still flows.
    if (hasAliveModalChild(engine.id)) return;

    // OS pointer coordinates are physical (DPI-aware); the engine hit-tests and
    // reports events in logical pixels, so normalize once here.
    var event = event_in;
    if (engine.scale != 1.0) {
        event.x /= engine.scale;
        event.y /= engine.scale;
    }

    // Modifier bitmask for every event this input produces — keys AND pointer
    // (shift-click multi-select, shift-drag marquee). Node-routed pointer events
    // pick it up through `makeEventCtx` (engine.input_mods).
    var mods: u32 = 0;
    if (event.shift_held) mods |= events_mod.MOD_SHIFT;
    if (event.ctrl_held) mods |= events_mod.MOD_CTRL;
    if (event.alt_held) mods |= events_mod.MOD_ALT;
    engine.input_mods = mods;
    defer engine.input_mods = 0;

    // Last known pointer position, for re-evaluating hover after a rebuild
    // replaces the hovered node under a stationary pointer (see `recheckHover`).
    switch (event.event_type) {
        .mouse_move, .mouse_down, .mouse_up, .right_mouse_down, .right_mouse_up, .scroll => engine.last_pointer = .{ .x = event.x, .y = event.y },
        else => {},
    }

    if (event.event_type == .mouse_move) {
        emitEvent(engine, .mouse_move, reg.NULL_NODE, "", event.x, event.y, 0, 0, "", mods);

        const top_hit = events_mod.hitTest(engine.hit_list.items, &engine.registry, &engine.store, event.x, event.y);

        // Update the mouse cursor for what's under the pointer.
        if (engine.window != null) {
            const cur = resolveCursor(&engine.store, &engine.registry, top_hit);
            if (cur != engine.current_cursor) {
                engine.current_cursor = cur;
                platform_mod.setCursor(cur);
            }
        }

        updateHover(engine, top_hit, event.x, event.y, mods);
    } else if (event.event_type == .mouse_leave) {
        engine.last_pointer = null;
        // The pointer left the window — no node is hovered anymore. Emit the
        // same mouse_leave the hover tracking sends and clear the state, so
        // hover-driven signals (button backgrounds, tooltips) reset.
        if (engine.hovered_node) |old_hover| {
            if (engine.store.getModifier(old_hover, .hoverable)) |val| {
                const id_str = switch (val) {
                    .string => |s| s,
                    else => "unknown",
                };
                emitEvent(engine, .mouse_leave, old_hover, id_str, event.x, event.y, 0, 0, "", mods);
            }
            engine.hovered_node = null;
        }
    } else if (event.event_type == .mouse_down) {
        // Double/triple-click sequence bookkeeping, timing-only for parity.
        const now_click = nowMs();
        const cdx = event.x - engine.last_click_x;
        const cdy = event.y - engine.last_click_y;
        engine.click_count = nextClickCount(engine.click_count, now_click - engine.last_click_ms, cdx * cdx + cdy * cdy);
        engine.last_click_ms = now_click;
        engine.last_click_x = event.x;
        engine.last_click_y = event.y;

        emitEvent(engine, .global_mouse_down, reg.NULL_NODE, "", event.x, event.y, 0, 0, "", mods);

        capturePressed(engine, event.x, event.y);
        hitAndDispatch(engine, event.x, event.y, .mouse_down, .clickable_capture, .clickable);

        // Focus handling
        var new_focus: ?reg.NodeId = null;
        if (events_mod.hitTest(engine.hit_list.items, &engine.registry, &engine.store, event.x, event.y)) |hit_id| {
            var current_id: reg.NodeId = hit_id;
            while (current_id != reg.NULL_NODE) {
                if (engine.store.getModifier(current_id, .focusable)) |_| {
                    new_focus = current_id;
                    break;
                }
                const node = engine.registry.getNode(current_id) orelse break;
                current_id = node.parent;
            }
        }

        // One funnel for every focus move (Tab, scopes, UIA SetFocus all share it):
        // dirties the ring, toggles IME, emits blur/focus and raises the UIA focus
        // event. The click carries no coordinates into blur/focus — neither does Tab.
        // `.pointer`: a mouse click never shows the focus-visible ring.
        moveFocus(engine, new_focus, .pointer);

        // On the 2nd+ click of a sequence, deliver a double_click to the node
        // under the pointer, carrying the click count in key_code so widgets can
        // escalate (2 = word, 3 = line). Routed by the node's clickable action id.
        if (engine.click_count >= 2) {
            if (events_mod.hitTest(engine.hit_list.items, &engine.registry, &engine.store, event.x, event.y)) |hit_id| {
                if (engine.store.getModifier(hit_id, .clickable)) |mod| {
                    if (mod == .string) {
                        emitEvent(engine, .double_click, hit_id, mod.string, event.x, event.y, engine.click_count, 0, "", mods);
                    }
                }
            }
        }
    } else if (event.event_type == .mouse_up) {
        emitEvent(engine, .mouse_up, reg.NULL_NODE, "", event.x, event.y, 0, 0, "", mods);
        // Node-targeted release to the nodes that took the press, BEFORE the
        // click (DOM order: mouseup, then click) — a click handler that
        // rebuilds the tree can no longer strand the press state.
        releaseAllPressed(engine, event.x, event.y, mods);

        hitAndDispatch(engine, event.x, event.y, .click, .clickable_capture, .clickable);
    } else if (event.event_type == .right_mouse_down) {
        emitEvent(engine, .right_mouse_down, reg.NULL_NODE, "", event.x, event.y, 0, 0, "", mods);

        hitAndDispatch(engine, event.x, event.y, .right_mouse_down, .right_clickable_capture, .right_clickable);
    } else if (event.event_type == .right_mouse_up) {
        emitEvent(engine, .right_mouse_up, reg.NULL_NODE, "", event.x, event.y, 0, 0, "", mods);

        hitAndDispatch(engine, event.x, event.y, .right_mouse_up, .right_clickable_capture, .right_clickable);
    } else if (event.event_type == .key_down or event.event_type == .key_up or event.event_type == .char_input) {
        // F12 dumps the zone profiler to celeris_trace.json without leaving the
        // loop — lets you capture a stall as it happens, then open the file in
        // https://ui.perfetto.dev. The whole block is elided unless built with
        // -Dprofiling, so normal builds pay nothing and F12 reaches the app. The
        // first press also arms recording, so it works even without CELERIS_TRACE.
        if (comptime prof.enabled) {
            if (event.event_type == .key_down and event.key_code == fw_events.Key.f12.code()) {
                prof.enable(engineIo());
                prof.flush("celeris_trace.json") catch |e| log.warn("F12 trace flush failed: {}\n", .{e});
                return;
            }
        }
        // A focused `captures_tab` node (code editor, multi-line input, grid)
        // takes plain Tab/Shift+Tab as key_down. Ctrl+Tab, or Escape then
        // Tab, still traverse — no keyboard trap (within the active focus
        // scope, like plain Tab). Escape arms the exit without being consumed;
        // any other key_down disarms it, except a bare modifier press — so
        // Escape, Shift, Tab still leaves backwards.
        const tab_captured = blk: {
            if (event.event_type != .key_down) break :blk false;
            if (isModifierOnlyKey(event.key_code)) break :blk false;
            const focused_captures = if (engine.focused_node) |f|
                engine.store.modifierFlag(f, .captures_tab)
            else
                false;
            const is_tab = event.key_code == fw_events.Key.tab.code();
            const escaped = engine.tab_escape_armed;
            engine.tab_escape_armed = focused_captures and event.key_code == fw_events.Key.escape.code();
            break :blk is_tab and focused_captures and !event.ctrl_held and !escaped;
        };
        if (!tab_captured and event.event_type == .key_down and event.key_code == fw_events.Key.tab.code()) {
            var list = std.array_list.Managed(reg.NodeId).init(engine.gpa.allocator());
            defer list.deinit();
            // With a focus scope active, Tab traverses only the top scope's
            // subtree (focus trap); otherwise all roots.
            if (engine.focus_scope_len > 0) {
                getFocusableNodes(&engine.registry, &engine.store, &list, engine.focus_scopes[engine.focus_scope_len - 1].root, 0) catch {};
            } else {
                for (engine.registry.nodes.items) |node| {
                    if (node.alive and node.parent == reg.NULL_NODE) {
                        getFocusableNodes(&engine.registry, &engine.store, &list, node.id, 0) catch {};
                    }
                }
            }
            if (list.items.len > 0) {
                var current_idx: usize = if (event.shift_held) list.items.len - 1 else 0;
                if (engine.focused_node) |f| {
                    for (list.items, 0..) |id, idx| {
                        if (id == f) {
                            if (event.shift_held) {
                                current_idx = if (idx == 0) list.items.len - 1 else idx - 1;
                            } else {
                                current_idx = if (idx == list.items.len - 1) 0 else idx + 1;
                            }
                            break;
                        }
                    }
                }
                moveFocus(engine, list.items[current_idx], .keyboard);
            }
            return;
        }

        // Enter/Space on a focused clickable node synthesizes a click through
        // the same dispatch path as the mouse (decision: done once in the engine,
        // not per widget). Text-editing targets are exempt — there they type.
        if (event.event_type == .key_down and (event.key_code == fw_events.Key.enter.code() or event.key_code == fw_events.Key.space.code())) {
            if (engine.focused_node) |focused| {
                if (clickSynthTarget(&engine.store, &engine.registry, focused)) |c| {
                    events_mod.dispatchEvent(makeEventCtx(engine), focused, .click, .clickable_capture, .clickable, c.x, c.y) catch {};
                    return; // consumed as an activation, not delivered as key_down
                }
            }
        }

        // Keyboard routing (mods computed above)
        if (engine.focused_node) |focused| {
            const modifier = engine.store.getModifier(focused, .focusable) orelse return;
            const id_str = switch (modifier) {
                .string => |s| s,
                else => "unknown",
            };
            const et: events_mod.EventType = switch (event.event_type) {
                .key_down => .key_down,
                .key_up => .key_up,
                .char_input => .char_input,
                else => unreachable,
            };
            // For char_input the structured event carries the codepoint as UTF-8 text.
            var txtbuf: [8]u8 = undefined;
            var text_slice: []const u8 = "";
            if (event.event_type == .char_input) {
                if (std.math.cast(u21, event.key_code)) |cp| {
                    if (cp >= 32 and cp != 127) {
                        if (std.unicode.utf8Encode(cp, &txtbuf)) |nlen| text_slice = txtbuf[0..nlen] else |_| {}
                    }
                }
            }
            emitEvent(engine, et, focused, id_str, 0, 0, event.key_code, 0, text_slice, mods);
        } else if (event.event_type == .key_down) {
            // No focused node — still emit the key_down (target-less) so the
            // framework router can match accelerators (Ctrl+S must work without
            // focus). key_up/char_input stay focus-only.
            emitEvent(engine, .key_down, reg.NULL_NODE, "", 0, 0, event.key_code, 0, "", mods);
        }
    } else if (event.event_type == .ime_preedit or event.event_type == .ime_commit) {
        // IME composition is routed to the focused node, like keyboard input. The
        // platform carries the UTF-8 payload in event.text (preedit string, or the
        // committed string). On Win32 the COMMIT actually arrives via WM_CHAR →
        // char_input; ime_preedit here only drives the inline preedit display.
        if (engine.focused_node) |focused| {
            const modifier = engine.store.getModifier(focused, .focusable) orelse return;
            const id_str = switch (modifier) {
                .string => |s| s,
                else => "unknown",
            };
            const et: events_mod.EventType = if (event.event_type == .ime_preedit) .text_composition else .text_commit;
            emitEvent(engine, et, focused, id_str, 0, 0, 0, 0, event.text, 0);
        }
    } else if (event.event_type == .scroll) {
        const axes = scrollAxes(event.scroll_delta, event.scroll_dx, event.shift_held);
        const hit = events_mod.hitTest(engine.hit_list.items, &engine.registry, &engine.store, event.x, event.y);
        if (hit) |hit_id| {
            var current_id: reg.NodeId = hit_id;
            while (current_id != reg.NULL_NODE) {
                if (engine.store.getModifier(current_id, .scrollable)) |mod| {
                    if (axes.dy != 0) emitEvent(engine, .scroll, current_id, mod.string, event.x, event.y, 0, axes.dy, "", mods);
                    // Horizontal goes out as its own event type (additive
                    // C-ABI enum), delta in scroll_delta, positive = right.
                    if (axes.dx != 0) emitEvent(engine, .scroll_h, current_id, mod.string, event.x, event.y, 0, axes.dx, "", mods);
                    break;
                }
                const node = engine.registry.getNode(current_id) orelse break;
                current_id = node.parent;
            }
        }
    } else if (event.event_type == .drop) {
        // A file/text drop: deliver a `drop` event to the node under the pointer,
        // carrying the payload. The host routes on node id / action id + reads text.
        const hit = events_mod.hitTest(engine.hit_list.items, &engine.registry, &engine.store, event.x, event.y);
        const target = hit orelse reg.NULL_NODE;
        emitEvent(engine, .drop, target, dropActionId(engine, target), event.x, event.y, 0, 0, event.text, 0);
    } else if (event.event_type == .resize) {
        // Handled by liveResizeCallback to ensure modal drag smoothness
    }
}

/// The action id a drop should carry: the nearest ancestor's clickable / id /
/// focusable string (so a drop target a host registered a handler for is matched).
fn dropActionId(engine: *EngineState, node_id: reg.NodeId) []const u8 {
    var id = node_id;
    while (id != reg.NULL_NODE) {
        inline for (.{ .clickable, .id, .focusable }) |k| {
            if (engine.store.getModifier(id, k)) |m| {
                if (m == .string) return m.string;
            }
        }
        const node = engine.registry.getNode(id) orelse break;
        id = node.parent;
    }
    return "";
}

fn liveResizeCallback(handle: platform_mod.NativeWindowHandle, width: u32, height: u32, scale: f32) void {
    const engine = engineForHandle(handle) orelse return;

    if (!engine.is_initialized or engine.backend == null) return;

    // Minimize sends a 0×0 size; skip — there's nothing to render and a 0-sized
    // surface is invalid.
    if (width == 0 or height == 0) return;

    // The OS reports physical pixels (DPI-aware); the engine works in logical. The
    // platform passes the current DPI scale so a runtime DPI change (WM_DPICHANGED
    // / output rescale) updates the engine, not just on first creation.
    if (scale > 0) engine.scale = scale;
    const logical_w: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) / scale));
    const logical_h: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(height)) / scale));

    if (engine.backend) |*be| {
        be.resize(logical_w, logical_h, scale);
    }
    engine.renderer.width = logical_w;
    engine.renderer.height = logical_h;

    // A drag on a maximized window restores it via the OS (no button click), so
    // detect the transition here and let the framework rebuild the AppBar glyph.
    if (engine.window) |*w| {
        const now_max = w.isMaximized();
        if (now_max != engine.last_maximized) {
            engine.last_maximized = now_max;
            if (g_on_maximize_change) |cb| cb(engine.id);
        }
    }

    if (engine.debug_node_id) |node_id| {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "FPS: Live | {d} x {d}", .{ width, height }) catch "FPS Error";
        // setTextContent takes ownership (and frees) — never hand it the stack buffer.
        if (engine.store.stringAllocator().dupe(u8, text)) |owned| {
            engine.store.setTextContent(node_id, owned);
        } else |_| {}
    }

    if (engine.registry.nodes.items.len > 0) {
        const now_ms = nowMs();
        const delta_ms: f32 = @floatFromInt(@min(now_ms - engine.last_frame_time, 100));
        engine.last_frame_time = now_ms;
        _ = engine.animator.tick(delta_ms, &engine.store);

        const root_id = engine.registry.nodes.items[0].id;
        var flex = layout_mod.LayoutEngine.init(&engine.registry, &engine.store, if (engine.atlas) |*a| a else null);
        // Layout is in logical pixels (the surface is physical = logical × scale).
        flex.solve(root_id, 0, 0, @floatFromInt(logical_w), @floatFromInt(logical_h));
    }

    bakeAndRender(engine, true) catch return;
    // During a modal live-resize the main loop is blocked, so this is the only
    // place observers learn the new size while the user is still dragging.
    emitResizes(engine);
}

pub export fn celeris_start_loop() i32 {
    platform_mod.setResizeCallback(liveResizeCallback);
    platform_mod.setCloseRequestCallback(closeRequestCallback);
    // A signal written outside an OS event (worker thread, host timer) marks nodes
    // dirty but, without this, would not wake the loop to repaint. Route the end of
    // any effect-running propagation to the same thread-safe wake path as redraw.
    signals_mod.on_propagation_end = &wakeLoopAfterPropagation;

    // Initialize debug node for all engines
    for (0..16) |i| {
        if (!g_engines_active[i]) continue;
        var engine = &g_engines[i];
        if (!engine.is_headless) {
            for (engine.registry.nodes.items) |node| {
                if (engine.store.getModifier(node.id, .id)) |val| {
                    if (val == .string and std.mem.eql(u8, val.string, "debug_text")) {
                        engine.debug_node_id = node.id;
                        break;
                    }
                }
            }
        }
    }

    var last_time = nowMs();
    var last_tick = nowMs();
    var frame_count: u32 = 0;
    var last_fps: u32 = 0;

    // Frame profiler (opt-in via CELERIS_PROFILE). Reports, once per second:
    // loop iterations/s, actual GPU renders/s, and avg/max time spent in the
    // layout solve and in bake+render. Lets us see whether jank is "rendering
    // every frame" (stuck-dirty) vs "a single phase is slow".
    const profile = std.c.getenv("CELERIS_PROFILE") != null;

    // Zone profiler (requires a -Dprofiling build): CELERIS_TRACE=<path> turns it
    // on and names the Chrome Trace JSON written when the loop exits. Open the
    // file in https://ui.perfetto.dev for the flame chart / hot path.
    const trace_path: ?[]const u8 = if (std.c.getenv("CELERIS_TRACE")) |p| std.mem.span(p) else null;
    // In a -Dprofiling build, arm recording from the start so both F12 and the
    // exit dump always have data (otherwise the first F12 would arm-then-flush an
    // empty buffer). Inert in a normal build. CELERIS_TRACE only selects the
    // path written automatically when the loop exits.
    if (comptime prof.enabled) prof.enable(engineIo());

    var prof_layouts: u32 = 0;
    var prof_renders: u32 = 0;
    var prof_layout_ns_sum: i64 = 0;
    var prof_layout_ns_max: i64 = 0;
    var prof_render_ns_sum: i64 = 0;
    var prof_render_ns_max: i64 = 0;

    while (platform_mod.pollSystemEvents(null, handleOSInput)) {
        // Before anything reads an engine: a window closed from a handler last
        // iteration is freed here, where no frame is in flight.
        drainPendingDestroys();
        getTaskQueue().drain();

        frame_count += 1;
        // Tracks whether any engine actually rendered this iteration. If none did,
        // we sleep briefly instead of busy-spinning (pollSystemEvents is
        // non-blocking on both platforms) — a static window should cost ~0 CPU.
        var rendered_any = false;
        const now = nowMs();
        // The FPS overlay (debug_text) refreshes only on this 1 s tick: writing it
        // every iteration would keep the frame permanently dirty and turn the
        // on-demand loop into a spin.
        const fps_tick = (now - last_time >= 1000);
        if (fps_tick) {
            last_fps = frame_count;
            frame_count = 0;
            last_time = now;

            if (profile) {
                const l_avg: i64 = if (prof_layouts > 0) @divFloor(@divFloor(prof_layout_ns_sum, prof_layouts), 1000) else 0;
                const r_avg: i64 = if (prof_renders > 0) @divFloor(@divFloor(prof_render_ns_sum, prof_renders), 1000) else 0;
                std.debug.print("[PROFILE] loop_iters/s={d} renders/s={d} | layout x{d} avg={d}us max={d}us | bake+render x{d} avg={d}us max={d}us\n", .{
                    last_fps,                            prof_renders,
                    prof_layouts,                        l_avg,
                    @divFloor(prof_layout_ns_max, 1000), prof_renders,
                    r_avg,                               @divFloor(prof_render_ns_max, 1000),
                });
                prof_layouts = 0;
                prof_renders = 0;
                prof_layout_ns_sum = 0;
                prof_layout_ns_max = 0;
                prof_render_ns_sum = 0;
                prof_render_ns_max = 0;
            }
        }

        // Coarse heartbeat: drives the caret blink (one toggle per tick) and the
        // hot-reload poll. NOT the render/animation rate (those run every frame).
        // The cadence is declared once in `framework/events.zig` (`TICK_MS`) so
        // widgets converting durations to tick counts can't drift from the loop.
        const should_tick = (now - last_tick >= fw_events.TICK_MS);
        if (should_tick) {
            last_tick = now;
        }

        for (0..16) |i| {
            if (!g_engines_active[i]) continue;
            var engine = &g_engines[i];

            if (engine.is_headless) {
                // In headless mode we just render once if needed, but for now we skip the loop
                continue;
            }

            // Cross-thread redraw request (celeris_request_redraw): apply it on the
            // UI thread so we never touch registry flags from a worker.
            if (@atomicRmw(bool, &g_redraw_req[i], .Xchg, false, .acq_rel)) {
                engine.registry.global_render_dirty = true;
            }

            if (should_tick) {
                emitEvent(engine, .tick, reg.NULL_NODE, "", 0, 0, 0, 0, "", 0);
            }

            if (fps_tick) {
                if (engine.debug_node_id) |node_id| {
                    var buf: [64]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "FPS: {d} | {d} x {d}", .{ last_fps, engine.renderer.width, engine.renderer.height }) catch "FPS Error";
                    // setTextContent takes ownership (and frees) — never hand it
                    // the stack buffer.
                    if (engine.store.stringAllocator().dupe(u8, text)) |owned| {
                        engine.store.setTextContent(node_id, owned);
                    } else |_| {}
                }
            }

            if (engine.registry.nodes.items.len > 0) {
                const now_ms = nowMs();
                const delta_ms: f32 = @floatFromInt(@min(now_ms - engine.last_frame_time, 100));
                engine.last_frame_time = now_ms;
                // Animations write properties, which re-set the dirty flags below.
                _ = engine.animator.tick(delta_ms, &engine.store);

                // O(1) dirty check: the registry keeps these as a superset of the
                // per-node flags, so we avoid scanning every node each frame.
                const need_layout = engine.registry.global_layout_dirty;
                const need_render = need_layout or engine.registry.global_render_dirty;

                if (need_layout) {
                    const lt0 = if (profile) nowNs() else 0;
                    const lz = prof.zoneNamed("layout.solve");
                    const root_id = engine.registry.nodes.items[0].id;
                    var flex = layout_mod.LayoutEngine.init(&engine.registry, &engine.store, if (engine.atlas) |*a| a else null);
                    flex.solve(root_id, 0, 0, @floatFromInt(engine.renderer.width), @floatFromInt(engine.renderer.height));
                    lz.end();
                    engine.registry.global_layout_dirty = false;
                    if (profile) {
                        const dt = nowNs() - lt0;
                        prof_layouts += 1;
                        prof_layout_ns_sum += dt;
                        if (dt > prof_layout_ns_max) prof_layout_ns_max = dt;
                        // Per-solve breakdown: how much the incremental layout skipped.
                        const r = &engine.registry;
                        std.debug.print("[PROFILE]   solve {d}us: measured={d} reshaped={d} placed={d} skipped={d} (of {d} nodes)\n", .{
                            @divFloor(dt, 1000), r.dbg_measured, r.dbg_reshaped, r.dbg_placed, r.dbg_skipped, r.nodes.items.len,
                        });
                    }
                }

                // Nothing changed → skip bake + render; this engine stays idle.
                if (!need_render) continue;
                engine.registry.global_render_dirty = false;

                for (engine.registry.nodes.items) |*node| {
                    node.render_dirty = false;
                }
            }

            if (profile) {
                if (engine.backend) |*be| be.prof_on = true;
            }
            const rt0 = if (profile) nowNs() else 0;
            const bz = prof.zoneNamed("bake+render");
            bakeAndRender(engine, true) catch {
                bz.end();
                continue;
            };
            bz.end();
            rendered_any = true;
            // After the frame is on screen: report size changes from this frame's
            // solve. A handler's writes dirty layout, and `rendered_any` keeps the
            // loop from blocking, so the reaction lands next frame.
            emitResizes(engine);
            if (profile) {
                const dt = nowNs() - rt0;
                prof_renders += 1;
                prof_render_ns_sum += dt;
                if (dt > prof_render_ns_max) prof_render_ns_max = dt;
                // Only break down spike frames (>5ms) so we isolate the stalls.
                if (dt > 5_000_000) {
                    if (engine.backend) |*be| {
                        const phases = be.prof_surface_ns + be.prof_build_ns + be.prof_encode_ns + be.prof_submit_ns + be.prof_present_ns;
                        const bake_ns = dt - phases; // bakeRegistry (CPU prims + hit list)
                        std.debug.print("[PROFILE] !spike {d}us: bake={d} surface={d} build={d} encode={d} submit={d} present={d} (us)\n", .{
                            @divFloor(dt, 1000),                 @divFloor(bake_ns, 1000),
                            @divFloor(be.prof_surface_ns, 1000), @divFloor(be.prof_build_ns, 1000),
                            @divFloor(be.prof_encode_ns, 1000),  @divFloor(be.prof_submit_ns, 1000),
                            @divFloor(be.prof_present_ns, 1000),
                        });
                    }
                }
            }
        }

        // Idle: nothing rendered (FIFO vsync already paces frames that DO render).
        // Block until an OS event, a cross-thread wake() (posted task / redraw
        // request), or the next ~500 ms tick (caret blink + hot-reload poll) —
        // dropping idle CPU to ~0 while staying instantly responsive to workers.
        if (!rendered_any) {
            const since_tick = nowMs() - last_tick;
            const to_next_tick = 500 - since_tick;
            const timeout_ms: u32 = if (to_next_tick <= 0) 0 else @intCast(@min(to_next_tick, 500));
            platform_mod.waitEvents(timeout_ms);
        }
    }

    if (trace_path) |p| prof.flush(p) catch |e| log.warn("profiler flush failed: {}\n", .{e});

    return 0;
}

var g_task_queue: dispatch_mod.TaskQueue = undefined;
var g_task_queue_init: bool = false;
var g_task_queue_mutex: std.atomic.Mutex = .unlocked;

/// `pub` (rather than the C ABI) so a Zig-level test/harness can drive the
/// exact production queue `celeris_start_loop` drains each iteration — not a
/// mock — to exercise concurrent `celeris_post_task` producers against real
/// engine-mutating callbacks. Not part of the C-ABI surface.
pub fn getTaskQueue() *dispatch_mod.TaskQueue {
    if (@atomicLoad(bool, &g_task_queue_init, .acquire)) {
        return &g_task_queue;
    }
    while (!g_task_queue_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
    defer g_task_queue_mutex.unlock();
    if (!g_task_queue_init) {
        g_task_queue = dispatch_mod.TaskQueue.init(std.heap.c_allocator);
        @atomicStore(bool, &g_task_queue_init, true, .release);
    }
    return &g_task_queue;
}

pub export fn celeris_post_task(callback: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
    const q = getTaskQueue();
    q.push(.{ .callback = callback, .ctx = ctx }) catch {
        log.warn("celeris_post_task: dropped task due to OOM\n", .{});
    };
    // Wake an idle loop so the task runs this frame, not after the idle timeout.
    platform_mod.wake();
}

/// Per-engine "please repaint" flags, set from any thread by
/// `celeris_request_redraw` and consumed on the UI thread each loop iteration.
var g_redraw_req = [_]bool{false} ** 16;

/// Requests a repaint of `engine_id` from any thread (thread-safe). Marks the
/// engine render-dirty on the next loop iteration and wakes an idle loop. Note
/// signal/state mutation is NOT thread-safe — mutate via `celeris_post_task` and
/// let dirty-tracking schedule the frame; this is for forcing a frame when state
/// changed outside the signal system.
pub export fn celeris_request_redraw(engine_id: i32) void {
    // engine ids are 1-based; the flag array is indexed by slot (id - 1), like the
    // loop that consumes it. With one window the off-by-one was invisible (it armed
    // the next, unused slot) — with an overlay open it redrew the wrong window.
    if (engine_id <= 0 or engine_id > 16) return;
    @atomicStore(bool, &g_redraw_req[@intCast(engine_id - 1)], true, .release);
    platform_mod.wake();
}

/// Registered as `signals.on_propagation_end` (see `celeris_start_loop`): a signal
/// write that actually ran effects wakes the render loop, even when it happened
/// outside an OS event (background thread, host timer). Arms every engine's
/// thread-safe redraw flag and wakes an idle loop — the same path as
/// `celeris_request_redraw`, so it needs no engine-state reads across threads.
/// The per-engine dirty flags set by the effects (bindStyle/bindLayout/build) are
/// what actually gate layout vs render; this only guarantees the loop wakes to
/// look at them.
fn wakeLoopAfterPropagation() void {
    for (0..16) |i| {
        @atomicStore(bool, &g_redraw_req[i], true, .release);
    }
    platform_mod.wake();
}

/// Creates a primitive node. node_type: 0 = Box, 1 = Text, 2 = Image, 3 = Path.
/// An unknown value falls back to Box.
pub export fn celeris_node_create(engine_id: i32, node_type: u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    const t: reg.NodeType = switch (node_type) {
        1 => .text,
        2 => .image,
        3 => .path,
        else => .box,
    };
    const id = engine.registry.createNode(t) catch return -1;
    engine.store.registerNode(id) catch {
        // Roll back the registry node so a -1 return doesn't leave a live node
        // with no property-store row behind it (layout/paint would read a
        // half-initialized node).
        engine.registry.removeNode(id);
        return -1;
    };
    return @intCast(id);
}

/// Retrieves the absolute geometry of a node
pub export fn celeris_node_get_bounds(engine_id: i32, node_id: i32, out_x: ?*f32, out_y: ?*f32, out_w: ?*f32, out_h: ?*f32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    if (node_id < 0) return -1;
    if (engine.registry.getNode(@intCast(node_id))) |node| {
        // Each out-param is optional: a host asking only for the width may pass NULL.
        if (out_x) |p| p.* = node.geometry.x;
        if (out_y) |p| p.* = node.geometry.y;
        if (out_w) |p| p.* = node.geometry.width;
        if (out_h) |p| p.* = node.geometry.height;
        return 0;
    }
    return -1;
}

pub export fn celeris_measure_text(engine_id: i32, text: [*c]const u8, len: usize, font_size: f32) f32 {
    const engine = getEngine(engine_id) orelse return 0.0;
    if (engine.atlas == null or text == null or len == 0) return 0.0;
    const slice = text[0..len];

    if (engine.atlas) |*atlas| {
        // max_width = 0 to avoid wrapping and measure single line width
        if (atlas.measureTextMultiline(slice, font_size, 0, engine.gpa.allocator())) |layout| {
            var mut_layout = layout;
            defer mut_layout.deinit();
            return layout.max_width;
        } else |_| {}
    }
    return 0.0;
}

pub export fn celeris_get_caret_metrics(engine_id: i32, text: [*c]const u8, len: usize, font_size: f32, max_width: f32, char_index: usize, out_x_opt: ?*f32, out_y_opt: ?*f32, out_lh_opt: ?*f32) i32 {
    return celeris_get_caret_metrics_ex(engine_id, text, len, font_size, max_width, text_mod.LINE_HEIGHT_FACTOR, char_index, out_x_opt, out_y_opt, out_lh_opt);
}

/// `celeris_get_caret_metrics` for text whose node has a `line_height` style: pass
/// the same multiplier so the caret's line and y match the rendered lines. A
/// non-positive / non-finite factor means the default (1.55).
pub export fn celeris_get_caret_metrics_ex(engine_id: i32, text: [*c]const u8, len: usize, font_size: f32, max_width: f32, line_height: f32, char_index: usize, out_x_opt: ?*f32, out_y_opt: ?*f32, out_lh_opt: ?*f32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    const lh = text_mod.sanitizeLineHeight(line_height);
    // NULL out-params are allowed (the value is just not reported).
    var sink: [3]f32 = undefined;
    const out_x = out_x_opt orelse &sink[0];
    const out_y = out_y_opt orelse &sink[1];
    const out_line_height = out_lh_opt orelse &sink[2];
    if (engine.atlas == null or text == null or len == 0) {
        out_x.* = 0;
        out_y.* = 0;
        out_line_height.* = text_mod.lineHeightWith(font_size, lh);
        return 0;
    }

    const slice = text[0..len];
    if (engine.atlas) |*atlas| {
        if (atlas.measureTextMultilinePref(slice, font_size, max_width, 0, 0, lh, engine.gpa.allocator())) |layout| {
            var mut_layout = layout;
            defer mut_layout.deinit();
            const metrics = atlas.getCaretMetrics(slice, &layout, font_size, char_index, engine.scale);
            out_x.* = metrics.x;
            out_y.* = metrics.y;
            out_line_height.* = metrics.line_height;
            return @intCast(metrics.line_index);
        } else |_| {}
    }

    out_x.* = 0;
    out_y.* = 0;
    out_line_height.* = text_mod.lineHeightWith(font_size, lh);
    return 0;
}

pub export fn celeris_get_char_index_at(engine_id: i32, text: [*c]const u8, len: usize, font_size: f32, max_width: f32, local_x: f32, local_y: f32) i32 {
    return celeris_get_char_index_at_ex(engine_id, text, len, font_size, max_width, text_mod.LINE_HEIGHT_FACTOR, local_x, local_y);
}

/// `celeris_get_char_index_at` for text with a `line_height` style (same factor
/// the node has; non-positive / non-finite = default).
pub export fn celeris_get_char_index_at_ex(engine_id: i32, text: [*c]const u8, len: usize, font_size: f32, max_width: f32, line_height: f32, local_x: f32, local_y: f32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (engine.atlas == null or text == null or len == 0) return 0;

    const slice = text[0..len];
    if (engine.atlas) |*atlas| {
        if (atlas.measureTextMultilinePref(slice, font_size, max_width, 0, 0, text_mod.sanitizeLineHeight(line_height), engine.gpa.allocator())) |layout| {
            var mut_layout = layout;
            defer mut_layout.deinit();
            return @intCast(atlas.getCharIndexAt(slice, &layout, font_size, local_x, local_y));
        } else |_| {}
    }
    return 0;
}

pub export fn celeris_node_append_child(engine_id: i32, parent: u32, child: u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;

    // Reject cycles: a host could ask to append an ancestor under its own
    // descendant, which would make every tree walk (layout, bake, hit-test) loop
    // forever / overflow the stack. The builder path can't hit this; the C node
    // API can, so guard here.
    if (engine.registry.wouldCreateCycle(parent, child)) {
        setLastError("celeris_node_append_child: would create a cycle (parent {d}, child {d})", .{ parent, child });
        return -1;
    }
    if (engine.registry.getNode(parent) == null or engine.registry.getNode(child) == null) {
        setLastError("celeris_node_append_child: parent {d} or child {d} is not a live node", .{ parent, child });
        return -1;
    }

    // Detach from current parent if attached
    if (engine.registry.getNode(child)) |child_node| {
        if (child_node.parent != reg.NULL_NODE) {
            engine.registry.detachChild(child_node.parent, child);
        }
    }

    engine.registry.appendChild(parent, child);

    // The parent reflows; mark it (and ancestors) layout-dirty so the solver
    // revisits the branch, and flag the frame so the loop actually renders.
    engine.registry.markLayoutDirty(parent);

    return 0;
}

pub export fn celeris_node_insert_before(engine_id: i32, parent: u32, child: u32, ref_child: u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;

    // Same guard as append_child: inserting an ancestor under its own descendant
    // would make every tree walk loop forever.
    if (engine.registry.wouldCreateCycle(parent, child)) {
        setLastError("celeris_node_insert_before: would create a cycle (parent {d}, child {d})", .{ parent, child });
        return -1;
    }
    if (engine.registry.getNode(parent) == null or engine.registry.getNode(child) == null) {
        setLastError("celeris_node_insert_before: parent {d} or child {d} is not a live node", .{ parent, child });
        return -1;
    }

    // Detach from current parent if attached
    if (engine.registry.getNode(child)) |child_node| {
        if (child_node.parent != reg.NULL_NODE) {
            engine.registry.detachChild(child_node.parent, child);
        }
    }

    const ref_id = if (ref_child == 0xFFFFFFFF) reg.NULL_NODE else ref_child;
    engine.registry.insertBefore(parent, child, ref_id);

    // Parent reflows → mark the branch layout-dirty and flag the frame (see append).
    engine.registry.markLayoutDirty(parent);

    return 0;
}

pub export fn celeris_node_remove(engine_id: i32, node_id: u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;

    var parent_id: reg.NodeId = reg.NULL_NODE;
    if (engine.registry.getNode(node_id)) |node| {
        parent_id = node.parent;
    }

    engine.registry.removeNode(node_id);

    // Parent reflows after losing a child → mark the branch layout-dirty (removeNode
    // already flagged the frame globally; this drives the solver's per-node cache).
    if (parent_id != reg.NULL_NODE) engine.registry.markLayoutDirty(parent_id);

    return 0;
}

// To set values temporarily using the engine's value parser
pub export fn celeris_node_set_text_content(engine_id: i32, node_id: u32, text_ptr: [*c]const u8) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    // Validate the id BEFORE duplicating: `setTextContent` silently drops an
    // out-of-range node, and the copy it never took ownership of would leak on
    // every call — a host looping over stale ids leaks without any error signal.
    if (engine.registry.getNode(node_id) == null) return -1;
    if (text_ptr == null) return -1;
    const text = std.mem.span(text_ptr);
    const copy = engine.store.stringAllocator().dupe(u8, text) catch return -1;
    engine.store.setTextContent(node_id, copy);
    return 0;
}

// ─── String-keyed properties (see core/prop_parse.zig for key/value syntax) ──

const PropDomain = enum { style, layout, modifier };

fn nodeSetProp(comptime domain: PropDomain, engine_id: i32, node_id: u32, key_ptr: [*c]const u8, val_ptr: [*c]const u8) i32 {
    const fn_name = "celeris_node_add_" ++ @tagName(domain);
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    if (engine.registry.getNode(node_id) == null) return -1;
    if (key_ptr == null or val_ptr == null) return -1;
    const key_str = std.mem.span(key_ptr);
    const val_str = std.mem.span(val_ptr);
    const Key = switch (domain) {
        .style => props.StyleKey,
        .layout => props.LayoutKey,
        .modifier => props.ModifierKey,
    };
    const key = prop_parse.parseKey(Key, key_str) orelse {
        setLastError(fn_name ++ ": unknown key '{s}'", .{key_str});
        return -1;
    };
    const value = switch (domain) {
        .style => prop_parse.parseStyle(&engine.store, key, val_str),
        .layout => prop_parse.parseLayout(&engine.store, key, val_str),
        .modifier => prop_parse.parseModifier(&engine.store, key, val_str),
    } catch {
        setLastError(fn_name ++ ": invalid value '{s}' for '{s}'", .{ val_str, key_str });
        return -1;
    };
    const set = switch (domain) {
        .style => engine.store.setStyle(node_id, key, value),
        .layout => engine.store.setLayout(node_id, key, value),
        .modifier => engine.store.setModifier(node_id, key, value),
    };
    set catch {
        if (value == .string) engine.store.stringAllocator().free(value.string);
        return -1;
    };
    return 0;
}

/// Sets a style property from strings: `celeris_node_add_style(e, n, "background", "#1e1e1e")`.
pub export fn celeris_node_add_style(engine_id: i32, node_id: u32, key: [*c]const u8, val: [*c]const u8) i32 {
    return nodeSetProp(.style, engine_id, node_id, key, val);
}

/// Sets a layout property from strings: `celeris_node_add_layout(e, n, "width", "50%")`.
pub export fn celeris_node_add_layout(engine_id: i32, node_id: u32, key: [*c]const u8, val: [*c]const u8) i32 {
    return nodeSetProp(.layout, engine_id, node_id, key, val);
}

/// Sets a modifier from strings: `celeris_node_add_modifier(e, n, "clickable", "save")`.
pub export fn celeris_node_add_modifier(engine_id: i32, node_id: u32, key: [*c]const u8, val: [*c]const u8) i32 {
    return nodeSetProp(.modifier, engine_id, node_id, key, val);
}

fn easingFromInt(v: u32) animation_mod.Easing {
    return switch (v) {
        1 => .ease_in,
        2 => .ease_out,
        3 => .ease_in_out,
        4 => .spring,
        else => .linear,
    };
}

fn animate(comptime domain: PropDomain, engine_id: i32, node_id: u32, key_ptr: [*c]const u8, from: f32, to: f32, duration_ms: f32, easing: u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    if (engine.registry.getNode(node_id) == null) return -1;
    if (key_ptr == null) return -1;
    if (!std.math.isFinite(from) or !std.math.isFinite(to) or !std.math.isFinite(duration_ms) or duration_ms < 0) return -1;
    const key_str = std.mem.span(key_ptr);
    const target: animation_mod.AnimTarget = switch (domain) {
        .style => blk: {
            const key = prop_parse.parseKey(props.StyleKey, key_str) orelse return -1;
            if (!prop_parse.styleIsAnimatable(key)) return -1;
            break :blk .{ .style = .{ .node_id = node_id, .key = key } };
        },
        .layout => blk: {
            const key = prop_parse.parseKey(props.LayoutKey, key_str) orelse return -1;
            if (!prop_parse.layoutIsAnimatable(key)) return -1;
            break :blk .{ .layout = .{ .node_id = node_id, .key = key } };
        },
        .modifier => unreachable,
    };
    engine.animator.add(target, from, to, duration_ms, easingFromInt(easing)) catch return -1;
    return 0;
}

/// Animates a numeric layout property. easing: 0 linear, 1 ease-in, 2 ease-out,
/// 3 ease-in-out, 4 spring. Replaces any running animation on the same property.
pub export fn celeris_animate_layout(engine_id: i32, node_id: u32, key: [*c]const u8, from: f32, to: f32, duration_ms: f32, easing: u32) i32 {
    return animate(.layout, engine_id, node_id, key, from, to, duration_ms, easing);
}

/// Animates a numeric style property (opacity, radius, shadow_blur, …).
pub export fn celeris_animate_style(engine_id: i32, node_id: u32, key: [*c]const u8, from: f32, to: f32, duration_ms: f32, easing: u32) i32 {
    return animate(.style, engine_id, node_id, key, from, to, duration_ms, easing);
}

/// Stops every running animation on `node_id`, leaving properties at their current value.
pub export fn celeris_cancel_animations(engine_id: i32, node_id: u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    engine.animator.cancelNode(node_id);
    return 0;
}

/// Sets a `NodeType.path` node's geometry. `verts` is a flat `f32` array of
/// `float_count` values — a multiple of `celeris_path_vertex_stride()` (8):
/// `[x, y, c1x, c1y, c2x, c2y, move, close]` per vertex (see `core/path.zig`
/// for the segment-kind encoding). The store copies it. Returns -1 on a bad id,
/// a stride mismatch, or OOM. `float_count == 0` clears the path.
pub export fn celeris_node_set_path(engine_id: i32, node_id: u32, verts: [*c]const f32, float_count: u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    if (engine.registry.getNode(node_id) == null) return -1;
    const stride = path_mod.stride_f32;
    if (float_count % stride != 0) return -1;
    if (float_count != 0 and verts == null) return -1;
    const n_verts = float_count / stride;
    const slice: []const path_mod.PathVertex = if (n_verts == 0)
        &[_]path_mod.PathVertex{}
    else
        @as([*]const path_mod.PathVertex, @ptrCast(@alignCast(verts)))[0..n_verts];
    engine.store.setPath(node_id, slice) catch return -1;
    return 0;
}

/// Number of `f32`s per path vertex expected by `celeris_node_set_path`.
pub export fn celeris_path_vertex_stride() u32 {
    return @intCast(path_mod.stride_f32);
}

// Test/dispatch events manually (mostly for headless testing or host overrides)
// Uses engine_ptr = getEngine(engine_id), but since handleOSInput does HWND matching, we pass a dummy HWND?
// Synthetic input injection: the target engine is passed to handleOSInput as
// ctx, so no native window handle is needed (it defaults to null).
pub export fn celeris_dispatch_mouse_click(engine_id: i32, x: f32, y: f32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    log.info("Programmatic Mouse click at ({d:.1}, {d:.1})\n", .{ x, y });
    handleOSInput(engine, .{ .event_type = .mouse_down, .x = x, .y = y });
    handleOSInput(engine, .{ .event_type = .mouse_up, .x = x, .y = y });
    return 0;
}

pub export fn celeris_dispatch_keyboard_event(engine_id: i32, event_type: u32, key_code: u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    const ev_type: platform_mod.InputEventType = switch (event_type) {
        0 => .key_down,
        1 => .key_up,
        else => .char_input,
    };
    handleOSInput(engine, .{ .event_type = ev_type, .key_code = key_code });
    return 0;
}

/// Traps Tab within `node_id`'s subtree until the
/// matching pop; the focus moves to the scope's first focusable node.
pub export fn celeris_push_focus_scope(engine_id: i32, node_id: u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    // A raw C-ABI host call, not a mouse click through our own hit-testing —
    // closer to a programmatic/keyboard-driven open, so show the ring.
    return if (pushFocusScope(engine, node_id, .keyboard)) 0 else -1;
}

/// Pops the top focus scope, restoring the focus
/// held before the push (cleared if that node no longer exists / is focusable).
pub export fn celeris_pop_focus_scope(engine_id: i32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    return if (popFocusScope(engine)) 0 else -1;
}

pub export fn celeris_dispatch_scroll_event(engine_id: i32, x: f32, y: f32, delta: f32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    handleOSInput(engine, .{ .event_type = .scroll, .x = x, .y = y, .scroll_delta = delta });
    return 0;
}

/// Delivers a drag-and-drop drop at (x, y) with a UTF-8 payload (a newline-
/// separated path/URI list, or plain text). The platform layer calls this from
/// its native DnD handler (Win32 IDropTarget / Wayland data_device); a host can
/// also call it directly. Routed to the node under the pointer as a `drop` event.
pub export fn celeris_dispatch_drop(engine_id: i32, x: f32, y: f32, text: [*c]const u8) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    if (!engine.is_initialized) return -1;
    const slice: []const u8 = if (text != null) std.mem.span(@as([*:0]const u8, text)) else "";
    handleOSInput(engine, .{ .event_type = .drop, .x = x, .y = y, .text = slice });
    return 0;
}

fn serializeNodeToJson(engine: *EngineState, allocator: std.mem.Allocator, node_id: reg.NodeId, depth: usize) ![]const u8 {
    const node = engine.registry.getNode(node_id) orelse return allocator.dupe(u8, "null");
    // Bound recursion so a deeply nested tree cannot overflow the stack while
    // serializing. Past the cap we emit the node without its descendants.
    if (depth >= reg.MAX_TREE_DEPTH) {
        return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"truncated\":true}}", .{node_id});
    }

    var children_json = std.array_list.Managed([]const u8).init(allocator);
    defer children_json.deinit();

    var child_id = node.first_child;
    while (child_id != reg.NULL_NODE) {
        const child_str = try serializeNodeToJson(engine, allocator, child_id, depth + 1);
        try children_json.append(child_str);
        const child_node = engine.registry.getNode(child_id) orelse break;
        child_id = child_node.next_sibling;
    }

    const children_joined = try std.mem.join(allocator, ",", children_json.items);

    const node_type_str = switch (node.node_type) {
        .box => "box",
        .text => "text",
        .image => "image",
        .path => "path",
    };

    return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"type\":\"{s}\",\"x\":{d:.1},\"y\":{d:.1},\"width\":{d:.1},\"height\":{d:.1},\"children\":[{s}]}}", .{
        node_id,
        node_type_str,
        node.geometry.x,
        node.geometry.y,
        node.geometry.width,
        node.geometry.height,
        children_joined,
    });
}

pub export fn celeris_get_dom_json(engine_id: i32) [*c]const u8 {
    const engine = getEngine(engine_id) orelse return null;
    if (!engine.is_initialized) return null;

    // Serialize through an arena, exactly like the accessibility path below:
    // `serializeNodeToJson` allocates one string per node plus a joined string
    // per level and only ever returns the outermost one, so handing it the gpa
    // directly leaked every intermediate — the whole subtree, on every call.
    // A host polling the DOM per frame leaked megabytes a second.
    var arena = std.heap.ArenaAllocator.init(engine.gpa.allocator());
    defer arena.deinit();

    const json_str = serializeNodeToJson(engine, arena.allocator(), 0, 0) catch return null;
    const z_str = allocPrintZ(engine.gpa.allocator(), "{s}", .{json_str}) catch return null;
    return trackOwnedString(engine, z_str.ptr);
}

/// Returns the accessibility tree as JSON (role / accessible name / focused /
/// bounds, nested), for a host to feed a screen-reader provider (UI Automation /
/// AT-SPI). Engine-gpa-allocated; free with `celeris_free_string`. Null if empty.
pub export fn celeris_get_accessibility_json(engine_id: i32) [*c]const u8 {
    const engine = getEngine(engine_id) orelse return null;
    if (!engine.is_initialized or engine.registry.nodes.items.len == 0) return null;
    const root_id = engine.registry.nodes.items[0].id;

    // Serialize through an arena (frees the recursive intermediates in one shot),
    // then hand back a single gpa-owned NUL-terminated copy the host frees.
    var arena = std.heap.ArenaAllocator.init(engine.gpa.allocator());
    defer arena.deinit();
    const json = a11y.serializeNode(&engine.registry, &engine.store, engine.focused_node, arena.allocator(), root_id, 0) catch return null;
    const z = allocPrintZ(engine.gpa.allocator(), "{s}", .{json}) catch return null;
    return trackOwnedString(engine, z.ptr);
}

/// Frees a string returned by one of the engine-gpa-owned getters
/// (`celeris_get_dom_json`, `celeris_get_accessibility_json`, the clipboard
/// and file-dialog getters).
///
/// The devtools snapshot pointer must NOT be passed here — that buffer is
/// arena-owned and freed/reused automatically on the next snapshot call or at
/// `celeris_deinit` — but this no longer relies on the host having read that
/// warning: `str` is checked against `owned_strings` (the set of addresses
/// this engine has actually handed out this way) before anything is freed. A
/// pointer that isn't in the set — the devtools buffer, a stack/foreign
/// pointer, or one already freed here once — is a logged no-op instead of
/// corrupting the heap or double-freeing.
///
/// Thread-safe: `owned_strings` is mutex-guarded and the gpa is thread-safe, so
/// a worker that cancels a native file dialog can free the result directly.
pub export fn celeris_free_string(engine_id: i32, str: [*c]const u8) void {
    // getEngineForDialog, not getEngine: a worker that cancels a file dialog
    // frees the (null) result from off the UI thread. The map op below is
    // mutex-guarded and the gpa is thread-safe, so this is sound from either.
    const engine = getEngineForDialog(engine_id) orelse return;
    if (str == null) return;
    const addr = @intFromPtr(str);
    lockOwnedStrings(engine);
    const removed = engine.owned_strings.remove(addr);
    engine.owned_strings_mutex.unlock();
    if (!removed) {
        log.warn(
            "celeris_free_string: pointer {x} was not returned by an engine getter, or was already freed — refusing to free it (do NOT pass celeris_get_devtools_snapshot's pointer here; that one is arena-owned)\n",
            .{addr},
        );
        return;
    }
    engine.gpa.allocator().free(std.mem.span(str));
}

/// Writes UTF-8 `text` to the system clipboard. Returns 0 on success, -1 on
/// failure or if unsupported on this platform (e.g. Wayland is not wired yet).
pub export fn celeris_clipboard_set_text(engine_id: i32, text_ptr: [*c]const u8) i32 {
    _ = getEngine(engine_id) orelse return -1;
    if (text_ptr == null) return -1;
    return if (platform_mod.clipboardSetText(std.mem.span(text_ptr))) 0 else -1;
}

/// Returns the clipboard text as a NUL-terminated UTF-8 string, or null if empty
/// / unsupported. The buffer is engine-owned — free it with celeris_free_string.
pub export fn celeris_clipboard_get_text(engine_id: i32) [*c]const u8 {
    const engine = getEngine(engine_id) orelse return null;
    const a = engine.gpa.allocator();
    const text = platform_mod.clipboardGetText(a) orelse return null;
    return returnOwnedZ(engine, text);
}

/// The native window handle (for dialog modality), or null if no window.
fn engineOwnerHandle(engine: *EngineState) ?*anyopaque {
    const w = engine.window orelse return null;
    return switch (w.handle) {
        .win32 => |h| h.hwnd,
        else => null,
    };
}

fn optSpan(p: [*c]const u8) ?[]const u8 {
    return if (p != null) std.mem.span(p) else null;
}

/// Shows a native "open file" dialog. Returns the chosen path (engine-owned
/// UTF-8, free with celeris_free_string) or null if cancelled / unsupported.
/// `title` and `filter` ("*.txt") may be null.
///
/// Safe to call from a worker thread (see `getEngineForDialog`): the blocking
/// modal would otherwise freeze the frame loop, so the intended pattern is to
/// run it off the UI thread and post the path back with `celeris_post_task`.
pub export fn celeris_open_file_dialog(engine_id: i32, title: [*c]const u8, filter: [*c]const u8) [*c]const u8 {
    const engine = getEngineForDialog(engine_id) orelse return null;
    const a = engine.gpa.allocator();
    const path = platform_mod.openFileDialog(a, engineOwnerHandle(engine), optSpan(title), optSpan(filter)) orelse return null;
    return returnOwnedZ(engine, path);
}

/// Shows a native "save file" dialog. `default_name` pre-fills the filename.
pub export fn celeris_save_file_dialog(engine_id: i32, title: [*c]const u8, filter: [*c]const u8, default_name: [*c]const u8) [*c]const u8 {
    const engine = getEngineForDialog(engine_id) orelse return null;
    const a = engine.gpa.allocator();
    const path = platform_mod.saveFileDialog(a, engineOwnerHandle(engine), optSpan(title), optSpan(filter), optSpan(default_name)) orelse return null;
    return returnOwnedZ(engine, path);
}

/// Shows a native "select folder" dialog. Returns the chosen directory path
/// (engine-owned UTF-8, free with celeris_free_string) or null if cancelled /
/// unsupported. `title` and `initial_dir` may be null.
pub export fn celeris_pick_directory(engine_id: i32, title: [*c]const u8, initial_dir: [*c]const u8) [*c]const u8 {
    const engine = getEngineForDialog(engine_id) orelse return null;
    const a = engine.gpa.allocator();
    const path = platform_mod.pickDirectory(a, engineOwnerHandle(engine), optSpan(title), optSpan(initial_dir)) orelse return null;
    return returnOwnedZ(engine, path);
}

/// Returns a JSON snapshot of the tree. The returned buffer is owned by the
/// engine (arena-backed) and stays valid until the next snapshot call or
/// `celeris_deinit`. The host must NOT free it (see `celeris_free_string`).
pub export fn celeris_get_devtools_snapshot(engine_id: i32) [*c]const u8 {
    const engine = getEngine(engine_id) orelse return null;
    if (!engine.is_initialized) return null;

    _ = engine.dev_arena.reset(.retain_capacity);
    const allocator = engine.dev_arena.allocator();

    var root_id: reg.NodeId = reg.NULL_NODE;
    if (engine.registry.nodes.items.len > 0) {
        root_id = 0;
    }

    if (root_id != reg.NULL_NODE) {
        if (serializeNodeToJson(engine, allocator, root_id, 0)) |json_str| {
            if (allocPrintZ(allocator, "{s}", .{json_str})) |c_str| {
                return c_str.ptr;
            } else |_| {}
        } else |_| {}
    }

    return null;
}

// ─── Reactive signals by handle ─────────────────────────────────────
//
// The C-ABI surface for host-driven state. A host (C#, TS, …) creates a signal,
// binds it once to a node property, then only ever sets values; the binding
// effect writes the store and the existing dirty-tracking re-renders. The host
// manipulates *state*, never the node tree — reconciliation stays in Zig.
//
// A handle is the signal's index in the engine's pool. Handles are valid until
// `celeris_deinit`. Returns -1 / 0 on invalid handle, as documented per fn.

fn getSignal(engine: *EngineState, handle: i32) ?*HostSignal {
    if (handle < 0) return null;
    const idx: usize = @intCast(handle);
    if (idx >= engine.host_signals.items.len) return null;
    return engine.host_signals.items[idx];
}

/// Creates a signal initialised to the numeric value 0. Returns its handle, or
/// -1 on failure.
pub export fn celeris_signal_create(engine_id: i32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    const sig = engine.gpa.allocator().create(HostSignal) catch return -1;
    sig.* = HostSignal.init(engine.gpa.allocator(), .{ .number = 0 });
    engine.host_signals.append(sig) catch {
        sig.deinit();
        engine.gpa.allocator().destroy(sig);
        return -1;
    };
    return @intCast(engine.host_signals.items.len - 1);
}

pub export fn celeris_signal_set_f32(engine_id: i32, handle: i32, value: f32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    const sig = getSignal(engine, handle) orelse return -1;
    if (!std.math.isFinite(value)) return -1; // NaN/Inf would poison every bound layout
    sig.set(.{ .number = value });
    return 0;
}

/// unit: 0 = px, 1 = pt, 2 = percent (matches props.DimUnit).
pub export fn celeris_signal_set_dimension(engine_id: i32, handle: i32, value: f32, unit: u32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    const sig = getSignal(engine, handle) orelse return -1;
    if (!std.math.isFinite(value)) return -1;
    const u: props.DimUnit = switch (unit) {
        0 => .px,
        1 => .pt,
        2 => .percent,
        else => return -1,
    };
    sig.set(.{ .dimension = .{ .value = value, .unit = u } });
    return 0;
}

/// Channels are 0–255; alpha is 0.0–1.0.
pub export fn celeris_signal_set_color(engine_id: i32, handle: i32, r: u8, g: u8, b: u8, a: f32) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    const sig = getSignal(engine, handle) orelse return -1;
    if (!(a >= 0 and a <= 1)) return -1; // also rejects NaN
    sig.set(props.PropValue.rgbA(r, g, b, a));
    return 0;
}

/// Reads back the signal's numeric value (0 if not a number / invalid handle).
pub export fn celeris_signal_get_f32(engine_id: i32, handle: i32) f32 {
    const engine = getEngine(engine_id) orelse return 0;
    const sig = getSignal(engine, handle) orelse return 0;
    return switch (sig.peek()) {
        .number => |n| n,
        .dimension => |d| d.value,
        else => 0,
    };
}

/// Binds `handle` to a style property of `node_id` (e.g. "background", "opacity").
/// The current value applies immediately and on every later set. Returns -1 on a
/// bad engine/handle/node or an unknown key.
pub export fn celeris_signal_bind_style(engine_id: i32, handle: i32, node_id: u32, key_str: [*c]const u8) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    const sig = getSignal(engine, handle) orelse return -1;
    if (engine.registry.getNode(node_id) == null) return -1;
    if (key_str == null) return -1;
    const key = prop_parse.parseKey(props.StyleKey, std.mem.span(key_str)) orelse {
        setLastError("celeris_signal_bind_style: unknown style key '{s}'", .{std.mem.span(key_str)});
        return -1;
    };
    hostBind(.style, engine, sig, node_id, key) catch return -1;
    return 0;
}

/// Binds `handle` to a layout property of `node_id` (e.g. "width", "left").
pub export fn celeris_signal_bind_layout(engine_id: i32, handle: i32, node_id: u32, key_str: [*c]const u8) i32 {
    const engine = getEngine(engine_id) orelse return -1;
    const sig = getSignal(engine, handle) orelse return -1;
    if (engine.registry.getNode(node_id) == null) return -1;
    if (key_str == null) return -1;
    const key = prop_parse.parseKey(props.LayoutKey, std.mem.span(key_str)) orelse {
        setLastError("celeris_signal_bind_layout: unknown layout key '{s}'", .{std.mem.span(key_str)});
        return -1;
    };
    hostBind(.layout, engine, sig, node_id, key) catch return -1;
    return 0;
}

/// A host signal bound to one node property. Host signals are untyped (a fresh one
/// holds `.number = 0`, and `set_color` can follow `set_f32`), so every write is
/// converted to the shape the key is read in (`prop_parse.coerce`); a value with no
/// meaning for the key (a number for `background`, a color for `radius`) is skipped
/// and the property keeps its last good value. Writing it as-is crashed the renderer.
fn HostBinding(comptime domain: PropDomain) type {
    return struct {
        store: *props.PropertyStore,
        node_id: reg.NodeId,
        key: if (domain == .style) props.StyleKey else props.LayoutKey,
        signal: *HostSignal,

        fn run(self: *@This()) void {
            // Read the signal first either way, so the effect keeps its dependency.
            const v = self.signal.get();
            if (self.node_id == reg.NULL_NODE) return; // node removed (see host_binding_nodes)
            switch (domain) {
                .style => if (prop_parse.coerce(prop_parse.styleKind(self.key), v)) |ok| self.store.setStyle(self.node_id, self.key, ok) catch {},
                .layout => if (prop_parse.coerce(prop_parse.layoutKind(self.key), v)) |ok| self.store.setLayout(self.node_id, self.key, ok) catch {},
                .modifier => unreachable,
            }
        }
    };
}

fn hostBind(comptime domain: PropDomain, engine: *EngineState, sig: *HostSignal, node_id: u32, key: anytype) !void {
    const B = HostBinding(domain);
    const scope = &engine.signal_scope;
    const b = try scope.allocator.create(B);
    b.* = .{ .store = &engine.store, .node_id = node_id, .key = key, .signal = sig };
    scope.own(B, b) catch |err| {
        scope.allocator.destroy(b);
        return err;
    };
    try engine.host_binding_nodes.append(&b.node_id);
    _ = try scope.createEffect(b, B.run);
}

fn bakeAndRender(engine: *EngineState, render: bool) !void {
    try bakeAndRenderFrame(engine, render);
    // After the frame is out, so hover handlers (which may rebuild) never run
    // mid-bake/render; the fresh hit list is what they're evaluated against.
    recheckHover(engine);
}

fn bakeAndRenderFrame(engine: *EngineState, render: bool) !void {
    var frame_arena = std.heap.ArenaAllocator.init(engine.gpa.allocator());
    defer frame_arena.deinit();

    var prims = std.array_list.Managed(renderer_mod.RectPrimitive).init(frame_arena.allocator());
    var image_prims = std.array_list.Managed(renderer_mod.ImagePrimitive).init(frame_arena.allocator());
    var path_prims = std.array_list.Managed(renderer_mod.PathSegPrim).init(frame_arena.allocator());
    engine.hit_list.clearRetainingCapacity();
    const bz = prof.zoneNamed("bake");
    try renderer_mod.bakeRegistry(&engine.registry, &engine.store, &prims, &image_prims, &path_prims, &engine.hit_list, engine.focused_node, engine.focus_ring_color, engine.focus_highlight_mode, frame_arena.allocator());
    bz.end();

    if (!render) return;

    if (engine.overlay_rect) |rect| {
        prims.append(.{
            .x = rect.x,
            .y = rect.y,
            .width = rect.w,
            .height = rect.h,
            .color_r = rect.r,
            .color_g = rect.g,
            .color_b = rect.b,
            .color_a = rect.a,
            .border_radius = 4.0,
        }) catch {};
    }

    if (engine.backend) |*be| {
        try be.renderFrame(&engine.registry, &engine.store, prims.items, image_prims.items, path_prims.items);
    }
}

test "A bound signal set from a worker thread arms the loop's redraw flag" {
    const a = std.testing.allocator;

    // Simulate what celeris_start_loop() wires up.
    signals_mod.on_propagation_end = &wakeLoopAfterPropagation;
    defer signals_mod.on_propagation_end = null;
    @atomicStore(bool, &g_redraw_req[0], false, .release);

    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);

    const id = try registry.createNode(.box);
    try store.registerNode(id);

    var color = signals_mod.Signal(props.PropValue).init(a, .{ .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } });
    defer color.deinit();

    var scope = signals_mod.Scope.init(a);
    defer scope.deinit();
    try signals_mod.bindStyle(&scope, &store, id, .background, &color);

    // Write the signal from a background thread — outside any OS event.
    const Worker = struct {
        fn run(sig: *signals_mod.Signal(props.PropValue)) void {
            sig.set(.{ .color = .{ .r = 0, .g = 1, .b = 0, .a = 1 } });
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.run, .{&color});
    t.join();

    // The propagation ran the bindStyle effect, so the loop-wake path armed the
    // redraw flag the UI loop consumes (wake() itself no-ops with no live loop).
    try std.testing.expect(@atomicLoad(bool, &g_redraw_req[0], .acquire));
}

test "ClickSynthTarget: clickable node yields its center; text targets and non-clickables don't" {
    const a = std.testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);

    const btn = try registry.createNode(.box);
    try store.registerNode(btn);
    try store.setModifier(btn, .clickable, .{ .string = try store.stringAllocator().dupe(u8, "n1") });
    registry.getNode(btn).?.geometry = .{ .x = 10, .y = 20, .width = 100, .height = 40 };

    // Clickable → activation at the node center.
    const c = clickSynthTarget(&store, &registry, btn).?;
    try std.testing.expectEqual(@as(f32, 60), c.x);
    try std.testing.expectEqual(@as(f32, 40), c.y);

    // Text-editing target (cursor "text") → no synthesis (Space/Enter must type).
    try store.setModifier(btn, .cursor, .{ .string = try store.stringAllocator().dupe(u8, "text") });
    try std.testing.expectEqual(@as(?@TypeOf(c), null), clickSynthTarget(&store, &registry, btn));

    // Non-clickable node → no synthesis.
    const plain = try registry.createNode(.box);
    try store.registerNode(plain);
    try std.testing.expectEqual(@as(?@TypeOf(c), null), clickSynthTarget(&store, &registry, plain));
}

test "resolveCursor: clickable implies the hand; an explicit cursor on the node wins" {
    const a = std.testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);

    const parent = try registry.createNode(.box);
    try store.registerNode(parent);
    const child = try registry.createNode(.box);
    try store.registerNode(child);
    registry.getNode(child).?.parent = parent;
    try store.setModifier(parent, .clickable, .{ .string = try store.stringAllocator().dupe(u8, "p") });
    try store.setModifier(child, .clickable, .{ .string = try store.stringAllocator().dupe(u8, "c") });

    try std.testing.expectEqual(platform_mod.CursorType.pointer, resolveCursor(&store, &registry, child));
    // Explicit arrow on the parent only: the clickable child stops the walk first
    // (why Scrollbar pins "default" on both its track and its thumb).
    try store.setModifier(parent, .cursor, .{ .string = try store.stringAllocator().dupe(u8, "default") });
    try std.testing.expectEqual(platform_mod.CursorType.pointer, resolveCursor(&store, &registry, child));
    try store.setModifier(child, .cursor, .{ .string = try store.stringAllocator().dupe(u8, "default") });
    try std.testing.expectEqual(platform_mod.CursorType.default, resolveCursor(&store, &registry, child));
    try std.testing.expectEqual(platform_mod.CursorType.default, resolveCursor(&store, &registry, null));
}

test "Tab traversal skips disabled, zero-sized and clipped-away focusables" {
    const a = std.testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);

    const sa = store.stringAllocator();
    const root = try registry.createNode(.box);
    try store.registerNode(root);
    registry.getNode(root).?.geometry = .{ .x = 0, .y = 0, .width = 500, .height = 500 };

    // Three focusable children of the root: ok / disabled / zero-sized.
    var ids: [3]reg.NodeId = undefined;
    for (&ids) |*id| {
        id.* = try registry.createNode(.box);
        try store.registerNode(id.*);
        registry.appendChild(root, id.*);
        try store.setModifier(id.*, .focusable, .{ .string = try sa.dupe(u8, "f") });
        registry.getNode(id.*).?.geometry = .{ .x = 10, .y = 10, .width = 50, .height = 20 };
    }
    try store.setModifier(ids[1], .disabled, .{ .number = 1 });
    registry.getNode(ids[2]).?.geometry = .{ .x = 10, .y = 10, .width = 50, .height = 0 };

    // A fourth focusable sits under a clipping box whose bounds it falls outside
    // of (a closed dropdown's menu row: the row keeps its height, the clip is 0).
    const clip = try registry.createNode(.box);
    try store.registerNode(clip);
    registry.appendChild(root, clip);
    try store.setModifier(clip, .overflow_hidden, .{ .number = 1 });
    registry.getNode(clip).?.geometry = .{ .x = 0, .y = 100, .width = 100, .height = 0 };
    const clipped = try registry.createNode(.box);
    try store.registerNode(clipped);
    registry.appendChild(clip, clipped);
    try store.setModifier(clipped, .focusable, .{ .string = try sa.dupe(u8, "f") });
    registry.getNode(clipped).?.geometry = .{ .x = 10, .y = 100, .width = 50, .height = 20 };

    var list = std.array_list.Managed(reg.NodeId).init(a);
    defer list.deinit();
    try getFocusableNodes(&registry, &store, &list, root, 0);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(ids[0], list.items[0]);
}

test "ScrollAxes: native dx wins; Shift converts vertical to horizontal" {
    // Plain vertical wheel.
    var axes = scrollAxes(-1.0, 0, false);
    try std.testing.expectEqual(@as(f32, -1.0), axes.dy);
    try std.testing.expectEqual(@as(f32, 0), axes.dx);

    // Native horizontal (tilt wheel / touchpad) passes through untouched.
    axes = scrollAxes(0, 2.0, false);
    try std.testing.expectEqual(@as(f32, 0), axes.dy);
    try std.testing.expectEqual(@as(f32, 2.0), axes.dx);

    // Shift+vertical becomes horizontal (mice without a tilt wheel).
    axes = scrollAxes(-1.0, 0, true);
    try std.testing.expectEqual(@as(f32, 0), axes.dy);
    try std.testing.expectEqual(@as(f32, -1.0), axes.dx);

    // Shift does NOT hijack a native horizontal delta.
    axes = scrollAxes(-1.0, 2.0, true);
    try std.testing.expectEqual(@as(f32, -1.0), axes.dy);
    try std.testing.expectEqual(@as(f32, 2.0), axes.dx);
}

// Two focusables A, B under a root; records the key_downs A's handler sees.
const CapturesTabFixture = struct {
    const Seen = struct {
        tabs: u32 = 0,
        last_shift: bool = false,
        fn call(p: ?*anyopaque, ev: fw_events.Event) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            if (ev.key_code == fw_events.Key.tab.code()) {
                self.tabs += 1;
                self.last_shift = ev.shift;
            }
        }
    };
    engine: EngineState = undefined,
    router: fw_events.EventRouter = undefined,
    seen: Seen = .{},
    a: reg.NodeId = 0,
    b: reg.NodeId = 0,

    fn setUp(self: *CapturesTabFixture, captures: bool) !void {
        self.engine.init(true, .{});
        const sa = self.engine.store.stringAllocator();
        const root = try self.engine.registry.createNode(.box);
        try self.engine.store.registerNode(root);
        self.engine.registry.getNode(root).?.geometry = .{ .x = 0, .y = 0, .width = 500, .height = 500 };
        inline for (.{ &self.a, &self.b }, 0..) |id, i| {
            id.* = try self.engine.registry.createNode(.box);
            try self.engine.store.registerNode(id.*);
            self.engine.registry.appendChild(root, id.*);
            try self.engine.store.setModifier(id.*, .focusable, .{ .string = try sa.dupe(u8, "f") });
            self.engine.registry.getNode(id.*).?.geometry = .{ .x = 10, .y = 10 + 30 * i, .width = 50, .height = 20 };
        }
        if (captures) try self.engine.store.setModifier(self.a, .captures_tab, .{ .number = 1 });
        self.router = fw_events.EventRouter.init(std.testing.allocator);
        try self.router.onNode(self.a, .key_down, .{ .ptr = &self.seen, .call = Seen.call });
        mods_test_router = &self.router;
        self.engine.event_callback = modsTestForward;
        moveFocus(&self.engine, self.a, .programmatic);
    }
    fn tearDown(self: *CapturesTabFixture) void {
        mods_test_router = null;
        self.router.deinit();
        self.engine.deinit();
    }
    fn key(self: *CapturesTabFixture, code: u32, shift: bool, ctrl: bool) void {
        handleOSInput(&self.engine, .{ .event_type = .key_down, .key_code = code, .shift_held = shift, .ctrl_held = ctrl });
    }
};

test "no_focus_ring (via C-ABI string) leaves focus, Tab traversal and key routing unchanged" {
    var f: CapturesTabFixture = .{};
    try f.setUp(false);
    defer f.tearDown();
    // Same key + value parsing `celeris_node_add_modifier` runs.
    const key = prop_parse.parseKey(props.ModifierKey, "no_focus_ring") orelse return error.KeyNotParsed;
    try f.engine.store.setModifier(f.a, key, try prop_parse.parseModifier(&f.engine.store, key, "1"));
    try std.testing.expect(f.engine.store.modifierFlag(f.a, .no_focus_ring));
    const tab = fw_events.Key.tab.code();
    f.key(tab, false, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.b), f.engine.focused_node);
    f.key(tab, true, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.a), f.engine.focused_node);
    try std.testing.expectEqual(events_mod.FocusHighlightMode.keyboard, f.engine.focus_highlight_mode);
    try std.testing.expectEqual(@as(u32, 0), f.seen.tabs);
}

test "captures_tab absent: Tab/Shift+Tab move focus and never reach the node" {
    var f: CapturesTabFixture = .{};
    try f.setUp(false);
    defer f.tearDown();
    const tab = fw_events.Key.tab.code();
    f.key(tab, false, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.b), f.engine.focused_node);
    f.key(tab, true, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.a), f.engine.focused_node);
    try std.testing.expectEqual(@as(u32, 0), f.seen.tabs);
}

test "captures_tab: Tab and Shift+Tab reach the focused node's key_down; focus stays" {
    var f: CapturesTabFixture = .{};
    try f.setUp(true);
    defer f.tearDown();
    const tab = fw_events.Key.tab.code();
    f.key(tab, false, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.a), f.engine.focused_node);
    try std.testing.expectEqual(@as(u32, 1), f.seen.tabs);
    try std.testing.expect(!f.seen.last_shift);
    f.key(tab, true, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.a), f.engine.focused_node);
    try std.testing.expectEqual(@as(u32, 2), f.seen.tabs);
    try std.testing.expect(f.seen.last_shift);
}

test "captures_tab: Ctrl+Tab still traverses focus" {
    var f: CapturesTabFixture = .{};
    try f.setUp(true);
    defer f.tearDown();
    f.key(fw_events.Key.tab.code(), false, true);
    try std.testing.expectEqual(@as(?reg.NodeId, f.b), f.engine.focused_node);
    try std.testing.expectEqual(@as(u32, 0), f.seen.tabs);
}

test "captures_tab: Escape then Tab leaves; another key in between disarms the exit" {
    var f: CapturesTabFixture = .{};
    try f.setUp(true);
    defer f.tearDown();
    const tab = fw_events.Key.tab.code();
    const esc = fw_events.Key.escape.code();
    // Escape, other key, Tab → captured again.
    f.key(esc, false, false);
    f.key('A', false, false);
    f.key(tab, false, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.a), f.engine.focused_node);
    try std.testing.expectEqual(@as(u32, 1), f.seen.tabs);
    // Escape, Tab → focus moves out.
    f.key(esc, false, false);
    f.key(tab, false, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.b), f.engine.focused_node);
    try std.testing.expectEqual(@as(u32, 1), f.seen.tabs);
    try std.testing.expect(!f.engine.tab_escape_armed);
}

test "captures_tab: Escape, then a bare Shift key_down, then Shift+Tab still leaves backwards" {
    var f: CapturesTabFixture = .{};
    try f.setUp(true);
    defer f.tearDown();
    // Focus starts on A; Shift+Tab from the first node wraps to B.
    f.key(fw_events.Key.escape.code(), false, false);
    // Win32 sends VK_SHIFT; Linux maps Shift_L through keysym.toVk to the same code.
    f.key(fw_events.Key.shift.code(), true, false);
    f.key(keysym_mod.toVk(keysym_mod.Shift_R), true, false);
    f.key(fw_events.Key.tab.code(), true, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.b), f.engine.focused_node); // wraps A → B
    try std.testing.expectEqual(@as(u32, 0), f.seen.tabs);
}

test "captures_tab: an unmapped key (code 0, e.g. Linux ';') disarms Escape like any other key" {
    var f: CapturesTabFixture = .{};
    try f.setUp(true);
    defer f.tearDown();
    f.key(fw_events.Key.escape.code(), false, false);
    f.key(0, false, false);
    f.key(fw_events.Key.tab.code(), false, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.a), f.engine.focused_node);
    try std.testing.expectEqual(@as(u32, 1), f.seen.tabs);
}

test "captures_tab: a focus move disarms a pending Escape" {
    var f: CapturesTabFixture = .{};
    try f.setUp(true);
    defer f.tearDown();
    f.key(fw_events.Key.escape.code(), false, false);
    try std.testing.expect(f.engine.tab_escape_armed);
    moveFocus(&f.engine, f.b, .programmatic);
    moveFocus(&f.engine, f.a, .programmatic);
    f.key(fw_events.Key.tab.code(), false, false);
    try std.testing.expectEqual(@as(?reg.NodeId, f.a), f.engine.focused_node);
    try std.testing.expectEqual(@as(u32, 1), f.seen.tabs);
}

test "Window mouse_leave clears the hovered node" {
    var engine: EngineState = undefined;
    engine.init(true, .{});
    defer engine.deinit();
    const sa = engine.store.stringAllocator();

    const btn = try engine.registry.createNode(.box);
    try engine.store.registerNode(btn);
    engine.registry.getNode(btn).?.geometry = .{ .x = 0, .y = 0, .width = 100, .height = 40 };
    try engine.store.setModifier(btn, .hoverable, .{ .string = try sa.dupe(u8, "btn") });
    engine.hovered_node = btn;

    handleOSInput(&engine, .{ .event_type = .mouse_leave });
    try std.testing.expectEqual(@as(?reg.NodeId, null), engine.hovered_node);

    // Idempotent: a second leave with nothing hovered is a no-op.
    handleOSInput(&engine, .{ .event_type = .mouse_leave });
    try std.testing.expectEqual(@as(?reg.NodeId, null), engine.hovered_node);
}

test "Focus scope traps Tab inside the panel and pop restores the focus" {
    var engine: EngineState = undefined;
    engine.init(true, .{});
    defer engine.deinit();
    const sa = engine.store.stringAllocator();

    const root = try engine.registry.createNode(.box);
    try engine.store.registerNode(root);
    engine.registry.getNode(root).?.geometry = .{ .x = 0, .y = 0, .width = 500, .height = 500 };

    // Two focusables outside the panel, two inside.
    var outer: [2]reg.NodeId = undefined;
    var inner: [2]reg.NodeId = undefined;
    const panel = try engine.registry.createNode(.box);
    try engine.store.registerNode(panel);
    for (&outer) |*id| {
        id.* = try engine.registry.createNode(.box);
        try engine.store.registerNode(id.*);
        engine.registry.appendChild(root, id.*);
        try engine.store.setModifier(id.*, .focusable, .{ .string = try sa.dupe(u8, "f") });
        engine.registry.getNode(id.*).?.geometry = .{ .x = 0, .y = 0, .width = 50, .height = 20 };
    }
    engine.registry.appendChild(root, panel);
    engine.registry.getNode(panel).?.geometry = .{ .x = 0, .y = 100, .width = 200, .height = 200 };
    for (&inner) |*id| {
        id.* = try engine.registry.createNode(.box);
        try engine.store.registerNode(id.*);
        engine.registry.appendChild(panel, id.*);
        try engine.store.setModifier(id.*, .focusable, .{ .string = try sa.dupe(u8, "f") });
        engine.registry.getNode(id.*).?.geometry = .{ .x = 0, .y = 100, .width = 50, .height = 20 };
    }

    engine.focused_node = outer[0];

    // Push: focus jumps to the panel's first focusable; Tab's candidate list is
    // confined to the scope subtree (the same DFS the Tab handler runs).
    try std.testing.expect(pushFocusScope(&engine, panel, .keyboard));
    try std.testing.expectEqual(inner[0], engine.focused_node.?);
    var list = std.array_list.Managed(reg.NodeId).init(std.testing.allocator);
    defer list.deinit();
    try getFocusableNodes(&engine.registry, &engine.store, &list, engine.focus_scopes[engine.focus_scope_len - 1].root, 0);
    try std.testing.expectEqualSlices(reg.NodeId, &inner, list.items);

    // Pop: the pre-push focus comes back; popping an empty stack fails.
    try std.testing.expect(popFocusScope(&engine));
    try std.testing.expectEqual(outer[0], engine.focused_node.?);
    try std.testing.expect(!popFocusScope(&engine));

    // Pop with the previous owner reconciled away → focus cleared, not dangling.
    try std.testing.expect(pushFocusScope(&engine, panel, .keyboard));
    engine.registry.removeNode(outer[0]);
    _ = popFocusScope(&engine);
    try std.testing.expectEqual(@as(?reg.NodeId, null), engine.focused_node);
}

test "Removing the focused node clears focus (no dangling id on a recycled slot)" {
    var engine: EngineState = undefined;
    engine.init(true, .{});
    defer engine.deinit();
    const sa = engine.store.stringAllocator();

    var nodes: [2]reg.NodeId = undefined;
    for (&nodes) |*id| {
        id.* = try engine.registry.createNode(.box);
        try engine.store.registerNode(id.*);
        try engine.store.setModifier(id.*, .focusable, .{ .string = try sa.dupe(u8, "f") });
        engine.registry.getNode(id.*).?.geometry = .{ .x = 0, .y = 0, .width = 50, .height = 20 };
    }

    moveFocus(&engine, nodes[1], .keyboard);
    try std.testing.expectEqual(nodes[1], engine.focused_node.?);

    // Removing a *different* node leaves focus alone.
    engine.registry.removeNode(nodes[0]);
    try std.testing.expectEqual(nodes[1], engine.focused_node.?);

    // Removing the focused node itself clears it — routed through moveFocus, so
    // the focus-visible mode bookkeeping still ran (mode unchanged: .removed is not a nav).
    const mode_before = engine.focus_highlight_mode;
    engine.registry.removeNode(nodes[1]);
    try std.testing.expectEqual(@as(?reg.NodeId, null), engine.focused_node);
    try std.testing.expectEqual(mode_before, engine.focus_highlight_mode);

    // The freed slot is recycled; the new node must not inherit stale focus.
    const reused = try engine.registry.createNode(.box);
    try engine.store.registerNode(reused);
    try std.testing.expectEqual(@as(?reg.NodeId, null), engine.focused_node);
}

test "MoveFocus recomputes focus_highlight_mode from origin; .restore preserves it" {
    var engine: EngineState = undefined;
    engine.init(true, .{});
    defer engine.deinit();
    const sa = engine.store.stringAllocator();

    var nodes: [2]reg.NodeId = undefined;
    for (&nodes) |*id| {
        id.* = try engine.registry.createNode(.box);
        try engine.store.registerNode(id.*);
        try engine.store.setModifier(id.*, .focusable, .{ .string = try sa.dupe(u8, "f") });
    }

    // Default (no input yet): keyboard-visible, matching :focus-visible's
    // "initial/programmatic focus is visible" default.
    try std.testing.expectEqual(events_mod.FocusHighlightMode.keyboard, engine.focus_highlight_mode);

    moveFocus(&engine, nodes[0], .pointer);
    try std.testing.expectEqual(events_mod.FocusHighlightMode.pointer, engine.focus_highlight_mode);

    moveFocus(&engine, nodes[1], .keyboard);
    try std.testing.expectEqual(events_mod.FocusHighlightMode.keyboard, engine.focus_highlight_mode);

    // .pointer even when the target node doesn't change: a keyboard-focused
    // node clicked again should still drop into pointer mode (the ring should
    // disappear even though `focused_node` itself is a no-op write).
    moveFocus(&engine, nodes[1], .pointer);
    try std.testing.expectEqual(events_mod.FocusHighlightMode.pointer, engine.focus_highlight_mode);
    try std.testing.expect(engine.registry.global_render_dirty);
    engine.registry.global_render_dirty = false;

    // .restore (a focus-scope pop) must NOT flip the mode back to keyboard —
    // it's not a new navigation.
    moveFocus(&engine, nodes[0], .restore);
    try std.testing.expectEqual(events_mod.FocusHighlightMode.pointer, engine.focus_highlight_mode);

    // .uia_external and .programmatic both read as keyboard-visible.
    moveFocus(&engine, nodes[1], .uia_external);
    try std.testing.expectEqual(events_mod.FocusHighlightMode.keyboard, engine.focus_highlight_mode);
    moveFocus(&engine, nodes[0], .pointer);
    moveFocus(&engine, nodes[1], .programmatic);
    try std.testing.expectEqual(events_mod.FocusHighlightMode.keyboard, engine.focus_highlight_mode);
}

test "NextClickCount increments within the window and resets outside it" {
    // Fresh sequence.
    try std.testing.expectEqual(@as(u32, 1), nextClickCount(0, 0, 0));
    // Second click 200ms later, same spot → double.
    try std.testing.expectEqual(@as(u32, 2), nextClickCount(1, 200, 0));
    // Third click still in window and near → triple.
    try std.testing.expectEqual(@as(u32, 3), nextClickCount(2, 150, 9));
    // Too slow (600ms) → restart at 1.
    try std.testing.expectEqual(@as(u32, 1), nextClickCount(2, 600, 0));
    // In time but too far (dist² = 25 > 16) → restart at 1.
    try std.testing.expectEqual(@as(u32, 1), nextClickCount(2, 100, 25));
}

test "An app-supplied primary face wins over OS discovery, and its role faces over the system scan" {
    // The embedded Codicons blob stands in for an app's own typeface: it makes the
    // assertion independent of what is installed on the host, which is exactly the
    // property an app gets from setting `AppOptions.fonts`.
    const ttf = @embedFile("codicon_ttf");
    const saved = g_app_fonts;
    defer g_app_fonts = saved;

    setAppFonts(.{ .primary = ttf, .mono = ttf });
    var atlas = loadFontAtlas(std.testing.allocator) orelse return error.SkipZigTest;
    defer atlas.deinit();

    // fonts[0] is the primary: it is the app's face, byte for byte.
    try std.testing.expectEqualSlices(u8, ttf, atlas.fonts.items[0].ttf);
    // A supplied role is registered and resolves to a face of its own...
    try std.testing.expect(atlas.hasRoleFont(.mono));
    try std.testing.expect(atlas.fontIndexForRole(.mono) != 0);
    // ...while an unsupplied one keeps degrading (to a scanned face, or the primary).
    _ = atlas.fontIndexForRole(.bold);
}

test "No app fonts leaves discovery exactly as it was" {
    const saved = g_app_fonts;
    defer g_app_fonts = saved;

    setAppFonts(.{});
    var atlas = loadFontAtlas(std.testing.allocator) orelse return error.SkipZigTest;
    defer atlas.deinit();
    // Whatever the host turned up, it is not the icon font: the primary still comes
    // from the candidate list / fontconfig, and the Codicons blob is only a fallback.
    try std.testing.expect(atlas.icon_font_index == null or atlas.icon_font_index.? != 0);
}

test "The C-ABI setter copies the caller's bytes, and null clears back to discovery" {
    const saved = g_app_fonts;
    defer {
        freeOwnedAppFonts();
        g_app_fonts = saved;
    }

    const a = std.testing.allocator;
    const src = try a.dupe(u8, "not-a-real-font-but-bytes-are-bytes");
    var cfg = CelerisFontConfig{ .primary = .{ .data = src.ptr, .len = src.len } };
    try std.testing.expectEqual(@as(i32, 0), celeris_set_app_fonts(&cfg));
    // The host is free to release its buffer the moment the call returns.
    a.free(src);
    try std.testing.expect(g_app_fonts.primary != null);
    try std.testing.expectEqualSlices(u8, "not-a-real-font-but-bytes-are-bytes", g_app_fonts.primary.?);

    try std.testing.expectEqual(@as(i32, 0), celeris_set_app_fonts(null));
    try std.testing.expect(g_app_fonts.primary == null);
}

test "BUG: the TextMeasure handle must point at engine memory, not the build frame" {
    // Widgets (TextInput, TextArea, Tabs, Tooltip, VirtualList) and
    // `signals.forEach`'s effect context cache `b.measure` and call through it
    // long after `rebuildUI` has returned. While the context lived in a local of
    // `rebuildUI`, every cached copy dereferenced a dead stack frame: a UIA
    // SetValue arriving through the task queue re-entered the builder at a
    // shallower stack and segfaulted in `FontAtlas.fontFor`.
    //
    // The invariant is checked structurally — the handle must land inside the
    // EngineState — because reading a dead frame is UB that often "works".
    const config = CelerisConfig{ .is_headless = true };
    const engine_id = celeris_create_engine(&config);
    if (engine_id <= 0) return error.SkipZigTest; // no font atlas on this box
    defer celeris_deinit(engine_id);

    const engine = getEngine(engine_id) orelse return error.SkipZigTest;
    if (engine.atlas == null) return error.SkipZigTest;

    const Captured = struct {
        var measure: ?@import("framework/builder.zig").TextMeasure = null;
        fn build(b: *@import("framework/builder.zig").UIBuilder) anyerror!void {
            measure = b.measure; // exactly what a widget does with it
            const root = try b.openBox();
            try b.width(root, 100, .px);
            b.close();
        }
    };
    Captured.measure = null;
    try rebuildUI(engine_id, Captured.build);

    const captured = Captured.measure orelse return error.SkipZigTest;
    const ctx_addr = @intFromPtr(captured.ctx);
    const engine_start = @intFromPtr(engine);
    const engine_end = engine_start + @sizeOf(EngineState);
    try std.testing.expect(ctx_addr >= engine_start and ctx_addr < engine_end);

    // And it still measures after the build pass returned.
    try std.testing.expect(captured.width("hello", 14) > 0);
}

test "BUG: celeris_free_string only frees a pointer this engine actually owns" {
    // The documented footgun — "never pass the devtools snapshot pointer
    // here, that one is arena-owned" — used to rely entirely on the host
    // reading the comment: any pointer at all went straight to gpa.free.
    // owned_strings turns that into a checked operation.
    const config = CelerisConfig{ .is_headless = true };
    const engine_id = celeris_create_engine(&config);
    defer celeris_deinit(engine_id);
    const engine = getEngine(engine_id) orelse return error.SkipZigTest;

    // A stack pointer and a null are both safe no-ops, not a crash.
    var stack_buf: [8]u8 = "not gpa\x00".*;
    celeris_free_string(engine_id, &stack_buf);
    celeris_free_string(engine_id, null);

    // The devtools snapshot pointer specifically: arena-owned, must never be
    // freed through this path even though it's a real, live, engine pointer.
    try rebuildUI(engine_id, struct {
        fn build(b: *@import("framework/builder.zig").UIBuilder) anyerror!void {
            const root = try b.openBox();
            _ = try b.addText("hi");
            b.close();
            _ = root;
        }
    }.build);
    const snapshot = celeris_get_devtools_snapshot(engine_id);
    if (snapshot != null) {
        celeris_free_string(engine_id, snapshot); // must be a no-op, not corruption
        // The arena is still fine — reading through it again must not crash.
        _ = celeris_get_devtools_snapshot(engine_id);
    }

    // A genuinely owned pointer frees exactly once; the second call on the
    // same pointer is a no-op, not a double free.
    const owned = celeris_get_dom_json(engine_id);
    try std.testing.expect(owned != null);
    try std.testing.expect(engine.owned_strings.contains(@intFromPtr(owned)));
    celeris_free_string(engine_id, owned);
    try std.testing.expect(!engine.owned_strings.contains(@intFromPtr(owned)));
    celeris_free_string(engine_id, owned); // double free — must be a safe no-op
}

test "owned_strings survives concurrent track/free (native-dialog worker pattern)" {
    // A file dialog run on a worker thread calls trackOwnedString from that
    // worker while the UI thread may be freeing an earlier result — the race
    // owned_strings_mutex closes. Exercise the exact lock discipline both paths
    // use, from several threads at once, and require the map to come back
    // consistent and empty (an unguarded AutoHashMap corrupts or loses entries
    // under this).
    const config = CelerisConfig{ .is_headless = true };
    const engine_id = celeris_create_engine(&config);
    defer celeris_deinit(engine_id);
    const engine = getEngine(engine_id) orelse return error.SkipZigTest;

    const a = engine.gpa.allocator();
    const Worker = struct {
        fn run(e: *EngineState, alloc: std.mem.Allocator) void {
            var i: usize = 0;
            while (i < 500) : (i += 1) {
                const s = alloc.alloc(u8, 8) catch return;
                _ = trackOwnedString(e, @ptrCast(s.ptr));
                lockOwnedStrings(e);
                const hit = e.owned_strings.remove(@intFromPtr(s.ptr));
                e.owned_strings_mutex.unlock();
                std.debug.assert(hit); // we just put it — must still be there
                alloc.free(s);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ engine, a });
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, 0), engine.owned_strings.count());
}

test "Celeris_node_set_path: stride validation, copy, and clear" {
    const config = CelerisConfig{ .is_headless = true };
    const engine_id = celeris_create_engine(&config);
    defer celeris_deinit(engine_id);
    const engine = getEngine(engine_id) orelse return error.SkipZigTest;

    try std.testing.expectEqual(@as(u32, 8), celeris_path_vertex_stride());

    const node = celeris_node_create(engine_id, 3); // 3 = path
    try std.testing.expect(node >= 0);
    const nid: u32 = @intCast(node);
    try std.testing.expectEqual(reg.NodeType.path, engine.registry.getNode(nid).?.node_type);

    // Two vertices = 16 floats: [x,y,c1x,c1y,c2x,c2y,move,close] x2.
    var buf = [_]f32{
        0,  0,  0, 0, 0, 0, 0, 0,
        50, 10, 0, 0, 0, 0, 0, 0,
    };
    try std.testing.expectEqual(@as(i32, 0), celeris_node_set_path(engine_id, nid, &buf, 16));
    try std.testing.expectEqual(@as(usize, 2), engine.store.getPath(nid).?.len);
    try std.testing.expectEqual(@as(f32, 50), engine.store.getPath(nid).?[1].x);

    // Not a multiple of the stride → rejected, path unchanged.
    try std.testing.expectEqual(@as(i32, -1), celeris_node_set_path(engine_id, nid, &buf, 15));
    try std.testing.expectEqual(@as(usize, 2), engine.store.getPath(nid).?.len);

    // Bad node id → -1.
    try std.testing.expectEqual(@as(i32, -1), celeris_node_set_path(engine_id, 9999, &buf, 16));

    // float_count 0 clears.
    try std.testing.expectEqual(@as(i32, 0), celeris_node_set_path(engine_id, nid, &buf, 0));
    try std.testing.expectEqual(@as(?[]const path_mod.PathVertex, null), engine.store.getPath(nid));
}

// Pointer events carry Shift/Ctrl/Alt into node handlers.
var mods_test_router: ?*fw_events.EventRouter = null;
fn modsTestForward(ev: *const events_mod.CelerisEvent) callconv(.c) void {
    if (mods_test_router) |r| _ = r.dispatchEvent(ev);
}

test "pointer events carry modifiers: shift+mouse_down reaches the node handler with ev.shift" {
    var engine: EngineState = undefined;
    engine.init(true, .{});
    defer engine.deinit();
    const sa = engine.store.stringAllocator();

    // A root first: the router treats node_id 0 as "no target".
    const root = try engine.registry.createNode(.box);
    try engine.store.registerNode(root);
    const btn = try engine.registry.createNode(.box);
    try engine.store.registerNode(btn);
    engine.registry.appendChild(root, btn);
    engine.registry.getNode(btn).?.geometry = .{ .x = 0, .y = 0, .width = 100, .height = 40 };
    try engine.store.setModifier(btn, .clickable, .{ .string = try sa.dupe(u8, "row") });
    try engine.hit_list.append(.{ .id = btn, .z_index = 0, .draw_order = 0, .clip_rect = .{ .x = 0, .y = 0, .w = 1000, .h = 1000 } });

    var router = fw_events.EventRouter.init(std.testing.allocator);
    defer router.deinit();
    const Seen = struct {
        shift: ?bool = null,
        ctrl: ?bool = null,
        fn call(p: ?*anyopaque, ev: fw_events.Event) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            self.shift = ev.shift;
            self.ctrl = ev.ctrl;
        }
    };
    var seen = Seen{};
    try router.onNode(btn, .mouse_down, .{ .ptr = &seen, .call = Seen.call });
    mods_test_router = &router;
    defer mods_test_router = null;
    engine.event_callback = modsTestForward;

    handleOSInput(&engine, .{ .event_type = .mouse_down, .x = 10, .y = 10, .shift_held = true });
    try std.testing.expectEqual(@as(?bool, true), seen.shift);
    try std.testing.expectEqual(@as(?bool, false), seen.ctrl);

    // Without Shift the same press reports false, and the stamp doesn't leak.
    handleOSInput(&engine, .{ .event_type = .mouse_down, .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(?bool, false), seen.shift);
    try std.testing.expectEqual(@as(u32, 0), engine.input_mods);
}

// A Button re-mounted by a rebuild must never stay hovered.
const HoverRemountFixture = struct {
    const fw_component = @import("framework/component.zig");
    const fw_button = @import("framework/button.zig");
    const fw_theme = @import("framework/theme.zig");

    engine: *EngineState,
    router: *fw_events.EventRouter,
    mounts: *fw_component.MountTable,
    btn: *fw_button.Button,
    /// A sibling subtree below the button (the "canvas" the pointer moves to).
    sibling: reg.NodeId = reg.NULL_NODE,

    const Opts = struct {
        /// Run layout + bake afterwards (a frame). False = the pointer acts
        /// before the next frame, against the previous frame's hit list.
        frame: bool = true,
        /// Insert a 200px spacer above the button so it is no longer under
        /// the pointer after the rebuild.
        shift: bool = false,
    };

    /// Root (column) → [spacer] → wrapper keyed by `gen` → caller-owned
    /// Button, then a clickable sibling box. Bumping `gen` replaces the
    /// wrapper, so the Button's nodes are re-created while the instance (and
    /// its `hovered` signal) survives — a command-palette row shape.
    fn build(self: *HoverRemountFixture, gen: u64, opts: Opts) !void {
        var b = fw_component.UIBuilder.init(&self.engine.registry, &self.engine.store);
        b.theme = fw_theme.Theme.dark();
        var ctx = fw_component.BuildContext{ .builder = &b, .router = self.router, .mounts = self.mounts };
        const root = try b.openNodeKeyed(.box, null);
        try b.width(root, 400, .px);
        try b.height(root, 300, .px);
        try b.flexColumn(root);
        if (opts.shift) {
            const sp = try b.openNodeKeyed(.box, 99);
            try b.height(sp, 200, .px);
            b.close();
        }
        _ = try b.openNodeKeyed(.box, gen);
        try ctx.mount(self.btn);
        b.close();
        self.sibling = try b.openNodeKeyed(.box, 1000);
        try b.height(self.sibling, 60, .px);
        try b.clickable(self.sibling, "sibling");
        b.close();
        b.close();
        if (opts.frame) try frame(self.engine);
    }

    fn frame(e: *EngineState) !void {
        var flex = layout_mod.LayoutEngine.init(&e.registry, &e.store, null);
        flex.solve(0, 0, 0, 400, 300);
        try bakeAndRender(e, false);
    }
};

const HoverCase = enum {
    /// Pointer still over the re-mounted button after the frame, then leaves.
    still_over,
    /// Pointer leaves onto the sibling BEFORE the next frame (real mouse
    /// input batched with the click).
    leave_before_frame,
    /// The rebuild moves the button out from under a still pointer.
    moved_away,
};

fn hoverRemountScenario(case: HoverCase) !void {
    const F = HoverRemountFixture;
    const a = std.testing.allocator;
    var engine: EngineState = undefined;
    engine.init(true, .{});
    defer engine.deinit();

    var router = fw_events.EventRouter.init(a);
    defer router.deinit();
    var mounts = F.fw_component.MountTable.init(a);
    defer mounts.deinit();
    engine.registry.addNodeRemovedListener(&mounts, F.fw_component.MountTable.nodeRemovedListener);
    engine.registry.addNodeRemovedListener(&router, fw_events.EventRouter.nodeRemovedListener);
    mods_test_router = &router;
    defer mods_test_router = null;
    engine.event_callback = modsTestForward;

    var btn = F.fw_button.Button{ .label = "Row" };
    btn.onMount(a);
    defer btn.deinit();
    var fx = F{ .engine = &engine, .router = &router, .mounts = &mounts, .btn = &btn };

    try fx.build(0, .{});
    const g0 = engine.registry.getNode(btn.root).?.geometry;
    const cx = g0.x + g0.width / 2;
    const cy = g0.y + g0.height / 2;
    handleOSInput(&engine, .{ .event_type = .mouse_move, .x = cx, .y = cy });
    try std.testing.expect(btn.hovered.peek());

    const old_root = btn.root;
    switch (case) {
        .still_over => {
            try fx.build(1, .{});
            try std.testing.expect(btn.root != old_root);
            // The replacement under the still pointer is the hovered node...
            try std.testing.expectEqual(@as(?reg.NodeId, btn.root), engine.hovered_node);
            try std.testing.expect(btn.hovered.peek());
            // ...and gets the leave when the pointer moves onto the sibling.
            const sg = engine.registry.getNode(fx.sibling).?.geometry;
            handleOSInput(&engine, .{ .event_type = .mouse_move, .x = sg.x + 10, .y = sg.y + 10 });
        },
        .leave_before_frame => {
            try fx.build(1, .{ .frame = false });
            try std.testing.expect(btn.root != old_root);
            // Onto the sibling (where it sat last frame) before any bake.
            const sg = engine.registry.getNode(fx.sibling).?.geometry;
            handleOSInput(&engine, .{ .event_type = .mouse_move, .x = sg.x + 10, .y = sg.y + 10 });
            try F.frame(&engine);
        },
        .moved_away => {
            try fx.build(1, .{ .shift = true });
            try std.testing.expect(btn.root != old_root);
        },
    }
    try std.testing.expect(!btn.hovered.peek());
}

test "re-mounted hovered Button: pointer still over, then onto a sibling → unhovered" {
    try hoverRemountScenario(.still_over);
}

test "re-mounted hovered Button: pointer onto a sibling before the next frame → unhovered" {
    try hoverRemountScenario(.leave_before_frame);
}

test "re-mounted hovered Button no longer under the pointer → unhovered" {
    try hoverRemountScenario(.moved_away);
}

// Press: `pressed` must never outlive the press — no node-targeted
// mouse_up used to exist at all, and a click that re-mounts the button must
// not strand it either.
const PressFixture = struct {
    fx: HoverRemountFixture,
    gen: u64 = 0,
    rebuild_on_click: bool = true,

    fn onClick(self: *PressFixture, _: fw_events.Event) void {
        if (!self.rebuild_on_click) return;
        // "createNode": the click rebuilds the parent, re-mounting the button.
        self.gen += 1;
        self.fx.build(self.gen, .{}) catch {};
    }
};

const PressEnv = struct {
    engine: EngineState,
    router: fw_events.EventRouter,
    mounts: HoverRemountFixture.fw_component.MountTable,
    btn: HoverRemountFixture.fw_button.Button,
    pf: PressFixture,
    /// Background of the button at rest (not hovered, not pressed).
    resting: props.PropValue = undefined,

    fn init(self: *PressEnv) !void {
        const a = std.testing.allocator;
        self.engine.init(true, .{});
        self.router = fw_events.EventRouter.init(a);
        self.mounts = HoverRemountFixture.fw_component.MountTable.init(a);
        self.engine.registry.addNodeRemovedListener(&self.mounts, HoverRemountFixture.fw_component.MountTable.nodeRemovedListener);
        self.engine.registry.addNodeRemovedListener(&self.router, fw_events.EventRouter.nodeRemovedListener);
        mods_test_router = &self.router;
        self.engine.event_callback = modsTestForward;
        self.btn = .{ .label = "Row" };
        self.btn.onMount(a);
        self.pf = .{ .fx = .{ .engine = &self.engine, .router = &self.router, .mounts = &self.mounts, .btn = &self.btn } };
        var dummy = HoverRemountFixture.fw_component.BuildContext{ .builder = undefined };
        self.btn.on_click = dummy.handler(&self.pf, PressFixture.onClick);
        try self.pf.fx.build(0, .{});
        self.resting = self.engine.store.getStyle(self.btn.root, .background).?;
    }

    fn deinit(self: *PressEnv) void {
        mods_test_router = null;
        self.btn.deinit();
        self.mounts.deinit();
        self.router.deinit();
        self.engine.deinit();
    }

    fn center(self: *PressEnv) struct { x: f32, y: f32 } {
        const g = self.engine.registry.getNode(self.btn.root).?.geometry;
        return .{ .x = g.x + g.width / 2, .y = g.y + g.height / 2 };
    }

    fn expectResting(self: *PressEnv) !void {
        try std.testing.expect(!self.btn.pressed.peek());
        try std.testing.expect(!self.btn.hovered.peek());
        const bg = self.engine.store.getStyle(self.btn.root, .background).?.color;
        const r = self.resting.color;
        try std.testing.expectApproxEqAbs(r.r, bg.r, 0.001);
        try std.testing.expectApproxEqAbs(r.g, bg.g, 0.001);
        try std.testing.expectApproxEqAbs(r.b, bg.b, 0.001);
    }

    fn toSibling(self: *PressEnv) !void {
        const sg = self.engine.registry.getNode(self.pf.fx.sibling).?.geometry;
        handleOSInput(&self.engine, .{ .event_type = .mouse_move, .x = sg.x + 10, .y = sg.y + 10 });
        try HoverRemountFixture.frame(&self.engine);
    }
};

test "press: plain click releases pressed (engine sends a node mouse_up)" {
    var env: PressEnv = undefined;
    try env.init();
    defer env.deinit();
    env.pf.rebuild_on_click = false;
    const c = env.center();
    handleOSInput(&env.engine, .{ .event_type = .mouse_move, .x = c.x, .y = c.y });
    handleOSInput(&env.engine, .{ .event_type = .mouse_down, .x = c.x, .y = c.y });
    try std.testing.expect(env.btn.pressed.peek());
    handleOSInput(&env.engine, .{ .event_type = .mouse_up, .x = c.x, .y = c.y });
    try std.testing.expect(!env.btn.pressed.peek());
    try env.toSibling();
    try env.expectResting();
}

test "press: on_click re-mounts the button: down + up + click leave it unpressed, resting color" {
    var env: PressEnv = undefined;
    try env.init();
    defer env.deinit();
    const c = env.center();
    const old_root = env.btn.root;
    handleOSInput(&env.engine, .{ .event_type = .mouse_move, .x = c.x, .y = c.y });
    handleOSInput(&env.engine, .{ .event_type = .mouse_down, .x = c.x, .y = c.y });
    handleOSInput(&env.engine, .{ .event_type = .mouse_up, .x = c.x, .y = c.y }); // → click → rebuild
    try std.testing.expectEqual(@as(u64, 1), env.pf.gen);
    try std.testing.expect(env.btn.root != old_root);
    try std.testing.expect(!env.btn.pressed.peek());
    try env.toSibling();
    try env.expectResting();
}

test "press: mouse_down, rebuild, then mouse_up (engine path and routed to the new node id)" {
    var env: PressEnv = undefined;
    try env.init();
    defer env.deinit();
    env.pf.rebuild_on_click = false;
    const c = env.center();
    handleOSInput(&env.engine, .{ .event_type = .mouse_move, .x = c.x, .y = c.y });
    handleOSInput(&env.engine, .{ .event_type = .mouse_down, .x = c.x, .y = c.y });
    try std.testing.expect(env.btn.pressed.peek());

    // Rebuild between down and up re-mounts the button (the old node got its
    // release at removal).
    try env.pf.fx.build(7, .{});
    try std.testing.expect(!env.btn.pressed.peek());
    handleOSInput(&env.engine, .{ .event_type = .mouse_up, .x = c.x, .y = c.y });
    try std.testing.expect(!env.btn.pressed.peek());

    // A mouse_up routed to the NEW node id also releases it.
    handleOSInput(&env.engine, .{ .event_type = .mouse_down, .x = c.x, .y = c.y });
    try std.testing.expect(env.btn.pressed.peek());
    _ = env.router.route(.{ .name = "mouse_up", .id = "", .node_id = env.btn.root });
    try std.testing.expect(!env.btn.pressed.peek());
    handleOSInput(&env.engine, .{ .event_type = .mouse_up, .x = c.x, .y = c.y });
    try env.toSibling();
    try env.expectResting();
}

test "press: dragging a press off the button (mouse_leave) releases pressed" {
    var env: PressEnv = undefined;
    try env.init();
    defer env.deinit();
    env.pf.rebuild_on_click = false;
    const c = env.center();
    handleOSInput(&env.engine, .{ .event_type = .mouse_move, .x = c.x, .y = c.y });
    handleOSInput(&env.engine, .{ .event_type = .mouse_down, .x = c.x, .y = c.y });
    try std.testing.expect(env.btn.pressed.peek());
    try env.toSibling();
    try std.testing.expect(!env.btn.pressed.peek());
    try env.expectResting();
}

// Context menu opened from a right-click inside an offset, clipped canvas.
const CtxMenuFixture = struct {
    const fw_component = @import("framework/component.zig");
    const fw_menu = @import("framework/menu.zig");
    const fw_theme = @import("framework/theme.zig");

    engine: *EngineState,
    router: *fw_events.EventRouter,
    mounts: *fw_component.MountTable,
    menu: *fw_menu.Menu,
    target: reg.NodeId = reg.NULL_NODE,
    canvas: reg.NodeId = reg.NULL_NODE,
    rebuild_in_handler: bool = false,
    /// Canvas pan (render-only scroll offset), as a node-graph editor uses.
    pan: f32 = 0,

    fn onRight(self: *CtxMenuFixture, ev: fw_events.Event) void {
        self.menu.popupWindow(ev.x, ev.y, .pointer);
        if (self.rebuild_in_handler) self.build() catch {};
    }

    /// Window root (column) → 40px caption → canvas (grow, overflowHidden,
    /// clickable) holding a right-clickable target and the Menu.
    fn build(self: *CtxMenuFixture) !void {
        var b = fw_component.UIBuilder.init(&self.engine.registry, &self.engine.store);
        b.theme = fw_theme.Theme.dark();
        var ctx = fw_component.BuildContext{ .builder = &b, .router = self.router, .mounts = self.mounts };
        const root = try b.openNodeKeyed(.box, null);
        try b.width(root, 800, .px);
        try b.height(root, 600, .px);
        try b.flexColumn(root);
        const cap = try b.openNodeKeyed(.box, null);
        try b.height(cap, 40, .px);
        b.close();
        self.canvas = try b.openNodeKeyed(.box, null);
        try b.flexGrow(self.canvas, 1);
        try b.clickable(self.canvas, "canvas");
        try b.overflowHidden(self.canvas);
        if (self.pan != 0) {
            try self.engine.store.setLayout(self.canvas, .scroll_offset_x, .{ .dimension = .{ .value = self.pan, .unit = .px } });
            try self.engine.store.setLayout(self.canvas, .scroll_offset_y, .{ .dimension = .{ .value = self.pan, .unit = .px } });
        }
        self.target = try ctx.boxNode(.{ .width = 100, .height = 100, .on_right_click = ctx.handler(self, onRight) }, .{});
        try ctx.mount(self.menu);
        b.close();
        b.close();
        var flex = layout_mod.LayoutEngine.init(&self.engine.registry, &self.engine.store, null);
        flex.solve(root, 0, 0, 800, 600);
        try bakeAndRender(self.engine, false);
    }
};

fn ctxMenuScenario(rebuild_in_handler: bool, pan: f32) !void {
    const F = CtxMenuFixture;
    const a = std.testing.allocator;
    var engine: EngineState = undefined;
    engine.init(true, .{});
    defer engine.deinit();
    var router = fw_events.EventRouter.init(a);
    defer router.deinit();
    var mounts = F.fw_component.MountTable.init(a);
    defer mounts.deinit();
    engine.registry.addNodeRemovedListener(&mounts, F.fw_component.MountTable.nodeRemovedListener);
    engine.registry.addNodeRemovedListener(&router, fw_events.EventRouter.nodeRemovedListener);
    mods_test_router = &router;
    defer mods_test_router = null;
    engine.event_callback = modsTestForward;

    const menu = try F.fw_menu.Menu.init(a, "ctx");
    defer menu.deinit();
    try menu.addItem("Delete", "delete");
    try menu.addItem("Duplicate", "dup");

    var fx = F{ .engine = &engine, .router = &router, .mounts = &mounts, .menu = menu, .rebuild_in_handler = rebuild_in_handler, .pan = pan };
    try fx.build();

    // Right-press inside the target, window coordinates (canvas starts at y=40).
    handleOSInput(&engine, .{ .event_type = .right_mouse_down, .x = 50, .y = 90 });
    try fx.build(); // the press also rebuilds the tree
    try std.testing.expect(menu.isOpen());

    const pg = engine.registry.getNode(menu.panel_id).?.geometry;
    try std.testing.expect(pg.height > 0);
    // The panel opens AT the pointer (window space), not 40px below it.
    try std.testing.expectApproxEqAbs(@as(f32, 50), pg.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 90), pg.y, 0.5);
    // And it's actually hit-testable there: a row wins over the canvas.
    const hit = events_mod.hitTest(engine.hit_list.items, &engine.registry, &engine.store, pg.x + 20, pg.y + 10).?;
    try std.testing.expectEqual(menu.row_ids.items[0], hit);
}

test "right-click context menu in an offset overflowHidden canvas (rebuild after press)" {
    try ctxMenuScenario(false, 0);
}

test "right-click context menu, rebuild inside the handler" {
    try ctxMenuScenario(true, 0);
}

test "right-click context menu on a panned canvas opens at the pointer" {
    try ctxMenuScenario(false, -35);
}

// Hover follow-up, the palette shape. A reactive shell rebuilt by a row's own
// click; rows are mountOwned Buttons (with a content slot) inside a .fill
// ScrollView inside a card, next to a sibling canvas subtree.
const PaletteFixture = struct {
    const fw_component = @import("framework/component.zig");
    const fw_button = @import("framework/button.zig");
    const fw_scroll = @import("framework/scroll_view.zig");
    const fw_theme = @import("framework/theme.zig");

    const RowContent = struct {
        label: []const u8,
        pub fn build(self: *RowContent, ctx: *fw_component.BuildContext) !void {
            const b = ctx.builder;
            const row = try b.openBox();
            try b.flexRow(row);
            try b.flexGrow(row, 1);
            const stripe = try b.openBox();
            try b.width(stripe, 4, .px);
            try b.height(stripe, 16, .px);
            b.close();
            _ = try b.addText(self.label);
            b.close();
        }
        pub fn deinit(_: *RowContent) void {}
    };

    const Item = struct {
        shell: *Shell,
        key: []const u8,
        content: RowContent,
        fn onClick(self: *Item, _: fw_events.Event) void {
            // "createNode": bump the revision the shell reads → shell rebuild.
            self.shell.rev.set(self.shell.rev.peek() + 1);
        }
        pub fn build(self: *Item, ctx: *fw_component.BuildContext) !void {
            try ctx.mountOwned(fw_button.Button, .{
                .key = self.key,
                .label = self.content.label,
                .height = 28,
                .content = fw_component.childOf(RowContent, &self.content),
                .on_click = ctx.handler(self, onClick),
            });
        }
        pub fn deinit(_: *Item) void {}
    };

    const List = struct {
        items: []Item,
        pub fn build(self: *List, ctx: *fw_component.BuildContext) !void {
            const col = try ctx.builder.openBox();
            try ctx.builder.flexColumn(col);
            for (self.items) |*it| try it.build(ctx);
            ctx.builder.close();
        }
        pub fn deinit(_: *List) void {}
    };

    const Shell = struct {
        rev: signals_mod.Signal(u32),
        list: List,
        pub fn build(self: *Shell, ctx: *fw_component.BuildContext) !void {
            const b = ctx.builder;
            const rev = self.rev.get();
            const row = try b.openBox();
            try b.flexRow(row);
            try b.width(row, 800, .px);
            try b.height(row, 600, .px);
            // Canvas: a sibling subtree whose node count grows per revision
            // (the "created node"), shifting positional reuse after it.
            const canvas = try b.openBox();
            try b.flexGrow(canvas, 1);
            try b.clickable(canvas, "canvas");
            var i: u32 = 0;
            while (i < rev) : (i += 1) {
                const n = try b.openBox();
                try b.width(n, 10, .px);
                try b.height(n, 10, .px);
                b.close();
            }
            b.close();
            const card = try b.openBox();
            try b.width(card, 200, .px);
            try b.height(card, 300, .px);
            try b.flexColumn(card);
            const list = try b.openBox();
            try b.flexGrow(list, 1);
            try b.width(list, 100, .percent);
            try b.overflowHidden(list);
            try ctx.mountOwned(fw_scroll.ScrollView, .{
                .key = "palette-scroll",
                .fill = true,
                .content = fw_component.childOf(List, &self.list),
            });
            b.close();
            b.close();
            b.close();
        }
    };

    fn frame(e: *EngineState) !void {
        var flex = layout_mod.LayoutEngine.init(&e.registry, &e.store, null);
        flex.solve(0, 0, 0, 800, 600);
        try bakeAndRender(e, false);
    }

    /// The Button instance owning hoverable box `root` (its anchor's record).
    fn buttonOf(e: *EngineState, m: *fw_component.MountTable, root: reg.NodeId) *fw_button.Button {
        const anchor = e.registry.getNode(root).?.parent;
        return @ptrCast(@alignCast(m.get(anchor).?.component_ptr));
    }
};

test "hover: palette row clicked (shell rebuild), pointer to canvas: row unhovered" {
    const F = PaletteFixture;
    const a = std.testing.allocator;
    var engine: EngineState = undefined;
    engine.init(true, .{});
    defer engine.deinit();
    var router = fw_events.EventRouter.init(a);
    defer router.deinit();
    // Teardown order (LIFO): mounts, then the scope, then the signal they read.
    var items: [3]F.Item = undefined;
    var shell = F.Shell{ .rev = signals_mod.Signal(u32).init(a, 0), .list = .{ .items = &items } };
    defer shell.rev.deinit();
    var scope = signals_mod.Scope.init(a);
    defer scope.deinit();
    var mounts = F.fw_component.MountTable.init(a);
    defer mounts.deinit();
    engine.registry.addNodeRemovedListener(&mounts, F.fw_component.MountTable.nodeRemovedListener);
    engine.registry.addNodeRemovedListener(&router, fw_events.EventRouter.nodeRemovedListener);
    mods_test_router = &router;
    defer mods_test_router = null;
    engine.event_callback = modsTestForward;
    const labels = [_][]const u8{ "Source", "Filter", "Output" };
    for (&items, labels) |*it, l| it.* = .{ .shell = &shell, .key = l, .content = .{ .label = l } };

    var b = F.fw_component.UIBuilder.init(&engine.registry, &engine.store);
    b.theme = F.fw_theme.Theme.dark();
    var ctx = F.fw_component.BuildContext{ .builder = &b, .router = &router, .mounts = &mounts };
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountReactive(&scope, &shell);
    b.close();
    try F.frame(&engine);

    // Pointer onto the first row's Button.
    const row_root = blk: {
        for (engine.registry.nodes.items) |n| {
            // By role, not "first hoverable": the ScrollView's scrollbar thumb is
            // hoverable too.
            const is_button = if (engine.store.getModifier(n.id, .role)) |r| r == .string and std.mem.eql(u8, r.string, "button") else false;
            if (n.alive and is_button and engine.store.getModifier(n.id, .hoverable) != null and n.geometry.width > 0) break :blk n.id;
        }
        return error.NoRow;
    };
    const btn = F.buttonOf(&engine, &mounts, row_root);
    const rg = engine.registry.getNode(row_root).?.geometry;
    const px = rg.x + rg.width / 2;
    const py = rg.y + rg.height / 2;
    handleOSInput(&engine, .{ .event_type = .mouse_move, .x = px, .y = py });
    try std.testing.expect(btn.hovered.peek());

    // Click: the handler bumps the revision → the shell rebuilds mid-dispatch.
    handleOSInput(&engine, .{ .event_type = .mouse_down, .x = px, .y = py });
    handleOSInput(&engine, .{ .event_type = .mouse_up, .x = px, .y = py });
    try std.testing.expectEqual(@as(u32, 1), shell.rev.peek());
    try F.frame(&engine);
    handleOSInput(&engine, .{ .event_type = .mouse_move, .x = px, .y = py + 1 });

    // Onto the canvas — a different subtree.
    handleOSInput(&engine, .{ .event_type = .mouse_move, .x = 100, .y = 100 });
    try F.frame(&engine);
    try std.testing.expect(!btn.hovered.peek());
}

// Regression: the string-keyed C-ABI (node_add_style/layout/modifier, signal
// bind_style/bind_layout, animate_*, cancel_animations) was dropped together with
// the DSL parser, while include/celeris.h kept declaring it and the C# binding kept
// calling it — every host styling call died with EntryPointNotFoundException. These
// tests drive the real exports so the surface can't silently disappear again.
test "C-ABI: string-keyed style/layout/modifier setters reach the store" {
    const config = CelerisConfig{ .is_headless = true };
    const engine_id = celeris_create_engine(&config);
    if (engine_id <= 0) return error.SkipZigTest;
    defer celeris_deinit(engine_id);
    const engine = getEngine(engine_id) orelse return error.SkipZigTest;

    const node: u32 = @intCast(celeris_node_create(engine_id, 0));
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_style(engine_id, node, "background", "#ff0000"));
    try std.testing.expectEqual(@as(f32, 1), engine.store.getStyle(node, .background).?.color.r);
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_style(engine_id, node, "font-size", "18px"));
    try std.testing.expectEqual(@as(f32, 18), engine.store.getStyle(node, .font_size).?.dimension.value);
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_layout(engine_id, node, "width", "50%"));
    try std.testing.expectEqual(props.DimUnit.percent, engine.store.getLayout(node, .width).?.dimension.unit);
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_modifier(engine_id, node, "clickable", "save"));
    try std.testing.expectEqualStrings("save", engine.store.getModifier(node, .clickable).?.string);

    // Errors: unknown key, bad value, dead node, null pointers — all -1, store untouched.
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_style(engine_id, node, "colour", "#fff"));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_style(engine_id, node, "background", "not-a-color"));
    try std.testing.expectEqual(@as(f32, 1), engine.store.getStyle(node, .background).?.color.r);
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_style(engine_id, 999_999, "background", "#fff"));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_style(engine_id, node, null, "#fff"));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_modifier(engine_id, node, "clickable", null));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_style(-5, node, "background", "#fff"));
}

test "C-ABI: signal bind_style/bind_layout follow later sets" {
    const config = CelerisConfig{ .is_headless = true };
    const engine_id = celeris_create_engine(&config);
    if (engine_id <= 0) return error.SkipZigTest;
    defer celeris_deinit(engine_id);
    const engine = getEngine(engine_id) orelse return error.SkipZigTest;

    const node: u32 = @intCast(celeris_node_create(engine_id, 0));
    const sig = celeris_signal_create(engine_id);
    try std.testing.expect(sig >= 0);
    try std.testing.expectEqual(@as(i32, 0), celeris_signal_set_color(engine_id, sig, 0, 0, 255, 1));
    try std.testing.expectEqual(@as(i32, 0), celeris_signal_bind_style(engine_id, sig, node, "background"));
    try std.testing.expectEqual(@as(f32, 1), engine.store.getStyle(node, .background).?.color.b);
    _ = celeris_signal_set_color(engine_id, sig, 255, 0, 0, 1);
    try std.testing.expectEqual(@as(f32, 1), engine.store.getStyle(node, .background).?.color.r);

    const wsig = celeris_signal_create(engine_id);
    _ = celeris_signal_set_dimension(engine_id, wsig, 120, 0);
    try std.testing.expectEqual(@as(i32, 0), celeris_signal_bind_layout(engine_id, wsig, node, "width"));
    try std.testing.expectEqual(@as(f32, 120), engine.store.getLayout(node, .width).?.dimension.value);

    try std.testing.expectEqual(@as(i32, -1), celeris_signal_bind_style(engine_id, sig, node, "nope"));
    try std.testing.expectEqual(@as(i32, -1), celeris_signal_bind_style(engine_id, 9999, node, "background"));
    try std.testing.expectEqual(@as(i32, -1), celeris_signal_bind_layout(engine_id, wsig, 999_999, "width"));
}

test "C-ABI: animate_style interpolates, cancel stops it, non-numeric keys refused" {
    const config = CelerisConfig{ .is_headless = true };
    const engine_id = celeris_create_engine(&config);
    if (engine_id <= 0) return error.SkipZigTest;
    defer celeris_deinit(engine_id);
    const engine = getEngine(engine_id) orelse return error.SkipZigTest;

    const node: u32 = @intCast(celeris_node_create(engine_id, 0));
    try std.testing.expectEqual(@as(i32, 0), celeris_animate_style(engine_id, node, "opacity", 0, 1, 100, 0));
    _ = engine.animator.tick(50, &engine.store);
    const mid = engine.store.getStyle(node, .opacity).?.number;
    try std.testing.expect(mid > 0.3 and mid < 0.7);
    try std.testing.expectEqual(@as(i32, 0), celeris_cancel_animations(engine_id, node));
    _ = engine.animator.tick(50, &engine.store);
    try std.testing.expectEqual(mid, engine.store.getStyle(node, .opacity).?.number);

    try std.testing.expectEqual(@as(i32, 0), celeris_animate_layout(engine_id, node, "width", 10, 20, 100, 3));
    try std.testing.expectEqual(@as(i32, -1), celeris_animate_style(engine_id, node, "background", 0, 1, 100, 0));
    try std.testing.expectEqual(@as(i32, -1), celeris_animate_layout(engine_id, node, "flex_direction", 0, 1, 100, 0));
    try std.testing.expectEqual(@as(i32, -1), celeris_animate_style(engine_id, node, "opacity", 0, std.math.nan(f32), 100, 0));
    try std.testing.expectEqual(@as(i32, -1), celeris_animate_style(engine_id, 999_999, "opacity", 0, 1, 100, 0));
}

// ── Repros: a host must not be able to store a value of the wrong type ─────────
// The renderer reads each style key as one specific PropValue tag (radius as
// `.dimension`, z_index as `.number`, background as `.color`) and does not check.
// Every path by which a host writes a property — string setters, animations and
// signal bindings — has to produce exactly that tag, or the next bake reads an
// inactive union field (a panic in safe builds, garbage in ReleaseFast).

fn headlessEngineForTest() ?struct { id: i32, engine: *EngineState } {
    const config = CelerisConfig{ .is_headless = true };
    const id = celeris_create_engine(&config);
    if (id <= 0) return null;
    const engine = getEngine(id) orelse return null;
    return .{ .id = id, .engine = engine };
}

test "C-ABI repro: a keyword value on a px-only style key is refused, and the bake survives" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const n: u32 = @intCast(celeris_node_create(h.id, 0));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_style(h.id, n, "radius", "auto"));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_style(h.id, n, "border-width", "fill"));
    try bakeAndRenderFrame(h.engine, false);
}

test "C-ABI repro: animating a number-typed style key keeps it a number, and the bake survives" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const n: u32 = @intCast(celeris_node_create(h.id, 0));
    try std.testing.expectEqual(@as(i32, 0), celeris_animate_style(h.id, n, "z_index", 0, 4, 100, 0));
    _ = h.engine.animator.tick(50, &h.engine.store);
    try std.testing.expect(h.engine.store.getStyle(n, .z_index).? == .number);
    try bakeAndRenderFrame(h.engine, false);
}

test "C-ABI repro: animate_layout on flex_grow writes the number the solver reads" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const n: u32 = @intCast(celeris_node_create(h.id, 0));
    try std.testing.expectEqual(@as(i32, 0), celeris_animate_layout(h.id, n, "flex_grow", 0, 2, 100, 0));
    _ = h.engine.animator.tick(50, &h.engine.store);
    const v = h.engine.store.getLayout(n, .flex_grow).?;
    try std.testing.expect(v == .number);
    try std.testing.expectApproxEqAbs(@as(f32, 1), v.number, 0.01);
}

test "C-ABI repro: binding a fresh (number) signal to radius/background stores a renderable value" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const n: u32 = @intCast(celeris_node_create(h.id, 0));
    const sig = celeris_signal_create(h.id); // starts as .number = 0
    try std.testing.expectEqual(@as(i32, 0), celeris_signal_bind_style(h.id, sig, n, "radius"));
    try std.testing.expectEqual(@as(i32, 0), celeris_signal_bind_style(h.id, sig, n, "background"));
    try bakeAndRenderFrame(h.engine, false);
    // A number is a valid radius (px); it is not a color, so background stays unset.
    try std.testing.expectEqual(@as(f32, 0), h.engine.store.getStyle(n, .radius).?.dimension.value);
    try std.testing.expect(h.engine.store.getStyle(n, .background) == null);
    _ = celeris_signal_set_f32(h.id, sig, 6);
    try std.testing.expectEqual(@as(f32, 6), h.engine.store.getStyle(n, .radius).?.dimension.value);
    _ = celeris_signal_set_color(h.id, sig, 255, 0, 0, 1);
    try bakeAndRenderFrame(h.engine, false);
    try std.testing.expectEqual(@as(f32, 6), h.engine.store.getStyle(n, .radius).?.dimension.value);
    try std.testing.expectEqual(@as(f32, 1), h.engine.store.getStyle(n, .background).?.color.r);
}

test "C-ABI repro: width \"auto\"/\"fill\" size the node like unset/100%, not to zero" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const root: u32 = @intCast(celeris_node_create(h.id, 0));
    _ = celeris_node_add_layout(h.id, root, "width", "400px");
    _ = celeris_node_add_layout(h.id, root, "height", "300px");
    const a: u32 = @intCast(celeris_node_create(h.id, 0));
    const b: u32 = @intCast(celeris_node_create(h.id, 0));
    _ = celeris_node_append_child(h.id, root, a);
    _ = celeris_node_append_child(h.id, root, b);
    _ = celeris_node_add_layout(h.id, a, "height", "10px");
    _ = celeris_node_add_layout(h.id, b, "height", "10px");
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_layout(h.id, a, "width", "auto"));
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_layout(h.id, b, "width", "fill"));
    var flex = layout_mod.LayoutEngine.init(&h.engine.registry, &h.engine.store, null);
    flex.solve(root, 0, 0, 400, 300);
    // In a column, an unset width fills the parent; "fill" means 100%.
    try std.testing.expectEqual(@as(f32, 400), h.engine.registry.getNode(a).?.geometry.width);
    try std.testing.expectEqual(@as(f32, 400), h.engine.registry.getNode(b).?.geometry.width);
}

test "C-ABI repro: a flag modifier set to \"0\"/\"false\" is off, not on" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const n: u32 = @intCast(celeris_node_create(h.id, 0));
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_modifier(h.id, n, "pointer_events_none", "1"));
    try std.testing.expect(h.engine.store.getModifier(n, .pointer_events_none) != null);
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_modifier(h.id, n, "pointer_events_none", "0"));
    // Every reader (hit-testing, clipping, drag regions, Tab order) reads these
    // by value through modifierFlag, so an explicit "0" really is off.
    try std.testing.expect(!h.engine.store.modifierFlag(n, .pointer_events_none));
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_modifier(h.id, n, "overflow_hidden", "false"));
    try std.testing.expect(!h.engine.store.modifierFlag(n, .overflow_hidden));
    // And the hit-test really treats the node as hittable again.
    _ = celeris_node_add_modifier(h.id, n, "clickable", "n");
    h.engine.registry.getNode(n).?.geometry = .{ .x = 0, .y = 0, .width = 50, .height = 50 };
    try bakeAndRenderFrame(h.engine, false);
    try std.testing.expectEqual(@as(?reg.NodeId, n), events_mod.hitTest(h.engine.hit_list.items, &h.engine.registry, &h.engine.store, 10, 10));
    _ = celeris_node_add_modifier(h.id, n, "pointer_events_none", "true");
    try std.testing.expectEqual(@as(?reg.NodeId, null), events_mod.hitTest(h.engine.hit_list.items, &h.engine.registry, &h.engine.store, 10, 10));
}

test "C-ABI repro: units a key ignores are refused instead of silently accepted" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const n: u32 = @intCast(celeris_node_create(h.id, 0));
    // The solver reads gap/margins/padding as px only, the renderer reads every
    // style length as px: "10%" used to return 0 and then do nothing.
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_layout(h.id, n, "gap", "10%"));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_layout(h.id, n, "padding_left", "2pt"));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_style(h.id, n, "radius", "50%"));
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_layout(h.id, n, "width", "50%"));
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_layout(h.id, n, "gap", "8px"));
}

test "repro: a focusable node with disabled=false is still Tab-reachable" {
    // `UIBuilder.disabled(id, false)` and Menu write an explicit `.disabled = false`;
    // Tab order checked presence, so such a node was treated as disabled.
    const a = std.testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    const id = try registry.createNode(.box);
    try store.registerNode(id);
    registry.getNode(id).?.geometry = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    try store.setModifier(id, .disabled, .{ .boolean = false });
    try std.testing.expect(isTabbable(&registry, &store, id));
    try store.setModifier(id, .disabled, .{ .boolean = true });
    try std.testing.expect(!isTabbable(&registry, &store, id));
}

test "C-ABI repro: insert_before refuses to put an ancestor under its own descendant" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const a: u32 = @intCast(celeris_node_create(h.id, 0));
    const b: u32 = @intCast(celeris_node_create(h.id, 0));
    try std.testing.expectEqual(@as(i32, 0), celeris_node_append_child(h.id, a, b));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_insert_before(h.id, b, a, 0xFFFFFFFF));
    try std.testing.expect(!h.engine.registry.wouldCreateCycle(a, b)); // tree unchanged: b still under a
    try std.testing.expectEqual(a, h.engine.registry.getNode(b).?.parent);
}

test "C-ABI repro: signals refuse NaN/Inf instead of feeding them to layout" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const s = celeris_signal_create(h.id);
    try std.testing.expectEqual(@as(i32, -1), celeris_signal_set_f32(h.id, s, std.math.nan(f32)));
    try std.testing.expectEqual(@as(i32, -1), celeris_signal_set_dimension(h.id, s, std.math.inf(f32), 0));
    try std.testing.expectEqual(@as(i32, -1), celeris_signal_set_color(h.id, s, 1, 2, 3, std.math.nan(f32)));
    try std.testing.expectEqual(@as(i32, -1), celeris_signal_set_color(h.id, s, 1, 2, 3, 2.0)); // alpha is 0..1
    try std.testing.expectEqual(@as(f32, 0), celeris_signal_get_f32(h.id, s));
}

test "C-ABI repro: a removed node is refused by append_child/insert_before (fuzzer hang)" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const a: u32 = @intCast(celeris_node_create(h.id, 0));
    const b: u32 = @intCast(celeris_node_create(h.id, 0));
    _ = celeris_node_remove(h.id, b);
    try std.testing.expectEqual(@as(i32, -1), celeris_node_append_child(h.id, a, b));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_append_child(h.id, a, b));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_insert_before(h.id, a, b, 0xFFFFFFFF));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_append_child(h.id, b, a)); // dead parent
    try std.testing.expectEqual(@as(i32, 0), celeris_node_remove(h.id, a)); // terminates
}

test "C-ABI repro: a signal bound to a removed node does not write into the node that reuses its id" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const root: u32 = @intCast(celeris_node_create(h.id, 0));
    const n: u32 = @intCast(celeris_node_create(h.id, 0));
    _ = celeris_node_append_child(h.id, root, n);
    const sig = celeris_signal_create(h.id);
    try std.testing.expectEqual(@as(i32, 0), celeris_signal_bind_style(h.id, sig, n, "opacity"));
    _ = celeris_node_remove(h.id, n);
    const reused: u32 = @intCast(celeris_node_create(h.id, 0));
    try std.testing.expectEqual(n, reused); // the free list hands the slot back
    _ = celeris_signal_set_f32(h.id, sig, 0.25);
    try std.testing.expect(h.engine.store.getStyle(reused, .opacity) == null);
}

// Repro (key-by-key reader audit): `virtual_focus_target` holds a node id as a
// number, and both readers did `@intFromFloat` after only checking `>= 0`. A value
// that does not fit a NodeId (1e30 from a host, or any Zig writer) panicked with
// "integer part of floating point value out of bounds" on the next bake.
test "repro: an out-of-range virtual_focus_target is refused by the C-ABI and ignored by the bake" {
    const h = headlessEngineForTest() orelse return error.SkipZigTest;
    defer celeris_deinit(h.id);
    const n: u32 = @intCast(celeris_node_create(h.id, 0));
    _ = celeris_node_add_modifier(h.id, n, "focusable", "n");
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_modifier(h.id, n, "virtual_focus_target", "1e30"));
    try std.testing.expectEqual(@as(i32, -1), celeris_node_add_modifier(h.id, n, "virtual_focus_target", "2.5"));
    try std.testing.expectEqual(@as(i32, 0), celeris_node_add_modifier(h.id, n, "virtual_focus_target", "-1")); // "none"
    h.engine.focused_node = n;
    try h.engine.store.setModifier(n, .virtual_focus_target, .{ .number = 1e30 }); // a Zig writer
    try bakeAndRenderFrame(h.engine, false);
    try std.testing.expect(h.engine.store.modifierNodeRef(n, .virtual_focus_target) == null);
}

test "TextMeasure.widthStyled(.mono) lands on the x the renderer pens the next glyph at" {
    var atlas = loadFontAtlas(std.testing.allocator) orelse return error.SkipZigTest;
    defer atlas.deinit();
    // Without a monospace face the role degrades to the primary and there is
    // nothing to tell apart: skip rather than pass vacuously.
    if (!atlas.hasRoleFont(.mono)) return error.SkipZigTest;

    var ctx = MeasureContext{ .atlas = &atlas, .scale = 1.0 };
    const m = @import("framework/builder.zig").TextMeasure{
        .ctx = @ptrCast(&ctx),
        .measureFn = atlasMeasureWidth,
        .measureStyledFn = atlasMeasureWidthStyled,
    };
    const fs: f32 = 14;
    const text = "fn main() { const AVWAil = 1 + 2; } // iiiiWWWW mono vs proportional";

    // Mono and proportional disagree on the same run (the bug: width() used one rule for both).
    const w_mono = m.widthRole(text, fs, .mono);
    const w_prop = m.width(text, fs);
    try std.testing.expect(@abs(w_mono - w_prop) > 1.0);
    // Monospace: every prefix is (chars × one advance).
    const one = m.widthRole("i", fs, .mono);
    try std.testing.expectApproxEqAbs(one, m.widthRole("W", fs, .mono), 0.01);
    try std.testing.expectApproxEqAbs(one * @as(f32, @floatFromInt(text.len)), w_mono, 0.05);

    for ([_]f32{ 0, 1.5 }) |ls| {
        const pref = atlas.fontIndexForRole(.mono);
        var glyphs = std.array_list.Managed(text_mod.ShapedGlyph).init(std.testing.allocator);
        defer glyphs.deinit();
        try atlas.shapePref(text, fs, pref, ls, &glyphs);
        // Pen x before each glyph = sum of the previous advances, which is exactly how
        // the backend advances (wgpu_backend: pen_x += x_advance). Every prefix measured
        // through the widget handle must land there.
        var pen: f32 = 0;
        for (glyphs.items) |g| {
            const prefix = text[0..g.cluster];
            const w = m.widthStyled(prefix, fs, .{ .role = .mono, .letter_spacing = ls });
            try std.testing.expectApproxEqAbs(pen, w, 0.05);
            pen += g.x_advance;
        }
        // And it is the renderer's own caret x for that node's layout.
        var layout = try atlas.measureTextMultilinePref(text, fs, 1e6, pref, ls, text_mod.LINE_HEIGHT_FACTOR, std.testing.allocator);
        defer layout.deinit();
        const caret = atlas.getCaretMetrics(text, &layout, fs, 40, 1.0);
        try std.testing.expectApproxEqAbs(caret.x, m.widthStyled(text[0..40], fs, .{ .role = .mono, .letter_spacing = ls }), 0.01);
    }

    // The hit-test agrees: clicking just right of glyph 50's left edge on a long mono
    // line picks column 50, no accumulated drift.
    const comp = @import("framework/component.zig");
    const x50 = m.widthRole(text[0..50], fs, .mono) + one * 0.25;
    try std.testing.expectEqual(@as(usize, 50), comp.columnAtXStyled(m, text, fs, .{ .role = .mono }, x50));
}

test "rebuildUI hands widgets a TextMeasure with the styled hooks wired" {
    const config = CelerisConfig{ .is_headless = true };
    const engine_id = celeris_create_engine(&config);
    if (engine_id <= 0) return error.SkipZigTest;
    defer celeris_deinit(engine_id);
    const engine = getEngine(engine_id) orelse return error.SkipZigTest;
    const atlas = if (engine.atlas) |*a| a else return error.SkipZigTest;
    if (!atlas.hasRoleFont(.mono)) return error.SkipZigTest;

    const Captured = struct {
        var measure: ?@import("framework/builder.zig").TextMeasure = null;
        fn build(b: *@import("framework/builder.zig").UIBuilder) anyerror!void {
            measure = b.measure;
            const root = try b.openBox();
            try b.width(root, 100, .px);
            b.close();
        }
    };
    Captured.measure = null;
    try rebuildUI(engine_id, Captured.build);
    const m = Captured.measure orelse return error.SkipZigTest;

    // Without the hooks, both would silently fall back to the default face.
    try std.testing.expect(m.measureStyledFn != null);
    try std.testing.expect(m.verticalStyledFn != null);
    const text = "iiiiiiiiii";
    try std.testing.expect(@abs(m.widthRole(text, 14, .mono) - m.width(text, 14)) > 1.0);
    const pref = atlas.fontIndexForRole(.mono);
    try std.testing.expectApproxEqAbs(
        atlas.measureWidthPref(text, 14, pref, 1.5),
        m.widthStyled(text, 14, .{ .role = .mono, .letter_spacing = 1.5 }),
        0.001,
    );

    // verticalStyled reads the role's own face, exactly as the atlas computes it.
    const want = atlas.verticalLayoutWith(pref, 14, 40, 2, 1.2);
    const got = m.verticalStyled(14, 40, 2, 1.2, .mono);
    try std.testing.expectApproxEqAbs(want.baseline, got.baseline, 0.001);
    try std.testing.expectApproxEqAbs(want.line_height, got.line_height, 0.001);
    // .default through the styled door is the plain verticalWith.
    const d0 = m.verticalWith(14, 40, 2, 1.2);
    const d1 = m.verticalStyled(14, 40, 2, 1.2, .default);
    try std.testing.expectApproxEqAbs(d0.baseline, d1.baseline, 0.001);
}
