//! Client-drawn menu / context menu.
//!
//! Menus are NOT native (no HMENU / xdg_popup): the engine renders them itself as
//! an overlay, so they look identical on Win32 and Wayland, theme-match the custom
//! window chrome, and reuse the existing renderer + event system. A context menu is
//! a `Menu` controller (like `Dropdown`): items are added up front, `popup(x,y)`
//! opens it at a point, and selection flows through the normal `clickable`
//! action-id path — clicking an item fires a `click` event carrying that item's
//! `action_id`, which the host receives via the structured C-ABI callback. A Zig
//! host uses `on_select` (an `events.Handler` carrying its own context), which
//! fires for mouse AND keyboard selection. A full-window transparent backdrop catches
//! outside clicks to dismiss.
//!
//! Built once (like Dropdown): the backdrop + panel + rows always exist; `is_open`
//! drives panel/backdrop size (0 when closed → clipped, not hit-testable) and
//! `pos_x/pos_y` drive the panel position, all via one reactive effect. Keyboard
//! navigation (up/down/enter/escape) is provided as model logic the host wires to
//! key events.

const std = @import("std");
const builder_mod = @import("builder.zig");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const layout = @import("../layout/flexbox.zig");
const theme_mod = @import("theme.zig");
const icons = @import("icons.zig");

/// `Theme` tokens default to fully transparent (`theme.zig`'s `Color.transparent()`
/// default), so an untheme'd host (or `testTheme()` below) would render an
/// invisible panel if we used the token unconditionally. Falls back to the
/// literal this call site used before theming.
fn themeOr(token: theme_mod.Color, fallback: theme_mod.Color) theme_mod.Color {
    return if (token.a == 0) fallback else token;
}

const ROW_H: f32 = 28;
const SEP_H: f32 = 9; // 1px line + 4px margin top/bottom
const HEADER_H: f32 = 24;
const CHECK_COL: f32 = 24;

fn rowHeight(it: MenuItem) f32 {
    return switch (it.kind) {
        .separator => SEP_H,
        .header => HEADER_H,
        .item => ROW_H,
    };
}

/// Mark-column glyph: a bullet for radio items, a check for check items.
fn markGlyph(it: MenuItem, checked: bool) []const u8 {
    if (!checked) return "    ";
    return if (it.radio != null) "\u{2022}  " else "\u{2713}  ";
}
const PANEL_W: f32 = 200;
const PAD_Y: f32 = 4;

/// `header`: a dimmed, non-interactive group title (keyboard nav skips it, like
/// a separator). Add with `addHeader`.
pub const MenuItemKind = enum { item, separator, header };

/// Binds an item to one value of a caller-owned exclusive group — the menu
/// equivalent of a radio button (WinUI `RadioMenuFlyoutItem`, Qt exclusive
/// `QActionGroup`). The row shows a bullet while `group == value`, live (no
/// rebuild); choosing it writes `value` into `group` before `on_select` fires.
pub const MenuRadio = struct {
    group: *signals.Signal(usize),
    value: usize,
};

pub const MenuItem = struct {
    /// Borrowed — must outlive the menu (normally a string literal or
    /// host-owned buffer the host keeps alive; `Menu` never copies or frees it,
    /// including across `clearItems()`).
    label: []const u8 = "",
    /// Action id emitted (as a `click`) when the item is chosen. Borrowed, same
    /// contract as `label` — must outlive the menu/router. Ignored for submenu
    /// items (they open the child instead of emitting).
    action_id: []const u8 = "",
    kind: MenuItemKind = .item,
    /// Static initial value. Ignored once `enabled_signal` is set.
    enabled: bool = true,
    /// Static initial value. Ignored once `checked_signal` is set.
    checked: bool = false,
    /// Lifted state (caller-owned): when set, the live `checked`/`enabled` state
    /// comes from here instead of the static field above, and `updateVisuals`
    /// repaints the row when it changes — no rebuild needed. Same convention as
    /// `Tabs.active` / `TreeView.selected` / `SplitPane.ratio`. Deliberately not
    /// index-based (`setChecked(index, ...)`): `row_ids` is 1:1 with `items`
    /// *including separators*, so an index recorded by the host would silently
    /// desync the moment a separator is inserted or `clearItems()` runs.
    checked_signal: ?*signals.Signal(bool) = null,
    /// Symmetric with `checked_signal`: toggling live (either direction) dims
    /// or undims the label, disables or re-enables the row for mouse click and
    /// hover, and flips the a11y `disabled` state (UIA `IsEnabled`) — all via
    /// `updateVisuals`, no rebuild needed. Keyboard nav (`moveHighlight`,
    /// `firstEnabled`, `activateHighlighted`) also reads it live.
    enabled_signal: ?*signals.Signal(bool) = null,
    /// When set, this item opens a nested menu (host-owned) instead of emitting an
    /// action. Hovering or clicking it opens `submenu` to the side.
    submenu: ?*Menu = null,
    /// Accelerator chord shown right-aligned, dimmed (e.g. "Ctrl+S"). Borrowed,
    /// same contract as `label`. Purely visual — it does NOT register the
    /// accelerator; wire that separately via `router.setAccelerators`
    /// (`events.Accelerators`). Empty string (default) paints nothing.
    shortcut: []const u8 = "",
    /// Radio binding (see `MenuRadio`). Overrides `checked`/`checked_signal`.
    radio: ?MenuRadio = null,

    /// Build-time read: `peek()`, so `Menu.build` running inside the host's
    /// build effect does not subscribe the host's tree to the group/signal
    /// (every pick would rebuild it). `updateVisuals` uses the tracked
    /// `isChecked` instead.
    fn isCheckedUntracked(self: MenuItem) bool {
        if (self.radio) |r| return r.group.peek() == r.value;
        if (self.checked_signal) |s| return s.peek();
        return self.checked;
    }

    fn isChecked(self: MenuItem) bool {
        if (self.radio) |r| return r.group.get() == r.value;
        if (self.checked_signal) |s| return s.get();
        return self.checked;
    }
    fn isEnabledUntracked(self: MenuItem) bool {
        if (self.enabled_signal) |s| return s.peek();
        return self.enabled;
    }
    fn isEnabled(self: MenuItem) bool {
        if (self.enabled_signal) |s| return s.get();
        return self.enabled;
    }
};

pub const Menu = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    /// Focusable action id of the panel ("<id>__panel"). Focus lands here while
    /// the menu is open so key_down routes to the menu. Owned.
    focus_id: []u8,
    /// Fired when a leaf item is chosen — by mouse or by keyboard (Enter), in
    /// this menu or in any of its submenus (only the ROOT menu's handler fires).
    /// The event is synthesized, identical for both input paths:
    /// `name = "select"`, `id` = the chosen item's `action_id`, `node_id` = its
    /// row. Build it with `ctx.handler(self, onMenuSelect)`; `ptr` must outlive
    /// the menu. The menu is already closed when the handler runs, so the handler
    /// may reopen it or open a dialog. It must not `deinit` the menu
    /// synchronously (the same click is still being dispatched to the menu's
    /// backdrop) — defer that with `application.postTask`. This is the authoritative
    /// selection channel: the raw `click` a C-ABI host sees on the structured
    /// callback exists for mouse selections only (Enter arrives there as a
    /// `key_down` on the panel).
    on_select: ?events.Handler = null,

    items: std.array_list.Managed(MenuItem),

    is_open: signals.Signal(bool),
    pos_x: signals.Signal(f32),
    pos_y: signals.Signal(f32),
    /// Highlighted item index for keyboard nav (-1 = none).
    highlighted: signals.Signal(i32),
    scope: signals.Scope,

    /// Clamp on the content-measured panel width — without it a long
    /// dynamic label (e.g. a "Recent files" path) could stretch the panel
    /// arbitrarily wide. Rows don't wrap or ellipsize past this, they just
    /// overflow visually; still better than an unbounded panel.
    max_width: f32 = 480,

    store: ?*props.PropertyStore = null,
    backdrop_id: reg.NodeId = reg.NULL_NODE,
    panel_id: reg.NodeId = reg.NULL_NODE,
    /// Per-item node id (separators included), aligned 1:1 with `items`. Typed
    /// row handlers resolve the clicked/hovered item against this.
    row_ids: std.array_list.Managed(reg.NodeId),
    /// Per-item checkmark text node id, aligned 1:1 with `items` (`NULL_NODE`
    /// for separators). Lets `updateVisuals` flip `checked_signal` items live
    /// via `setTextContent` instead of rebuilding.
    check_ids: std.array_list.Managed(reg.NodeId),
    /// Per-item label text node id, aligned 1:1 with `items` (`NULL_NODE` for
    /// separators). Lets `updateVisuals` dim/undim `enabled_signal` items live.
    label_ids: std.array_list.Managed(reg.NodeId),
    theme: theme_mod.Theme = .{},
    bound: bool = false,
    /// Focus-scope control captured from the live builder. Null headless →
    /// keyboard nav still works when key events are routed, but Tab isn't trapped.
    focus_scope: ?builder_mod.FocusScopeHooks = null,
    /// True while this (root) menu holds a pushed focus scope; close() pops it.
    scope_pushed: bool = false,
    /// Submenu wiring: a submenu has a parent and no interactive backdrop (the
    /// root menu's backdrop catches outside clicks for the whole chain). `open_sub`
    /// is the at-most-one currently-open child.
    is_submenu: bool = false,
    parent_menu: ?*Menu = null,
    open_sub: ?*Menu = null,
    /// Set on the root menu by `onRowEvent` when a `click` just opened a submenu,
    /// so the same click bubbling up to the backdrop's `onDismiss` doesn't tear
    /// the chain back down in the same gesture. Cleared the moment `onDismiss`
    /// consumes it (one-shot — a *later* click still dismisses normally).
    suppress_dismiss: bool = false,
    /// Set by every items mutation (`add*`, `clearItems`), cleared by `build`:
    /// while set, `row_ids`/`check_ids`/`label_ids` describe the previous
    /// items and `updateVisuals` must not paint through them.
    rows_stale: bool = false,
    /// Set when this panel was placed on the left of its requested point (a
    /// context menu flipped at the right window edge, a submenu cascading
    /// left). Its submenus then try the left side first, so a cascade keeps
    /// one direction instead of zigzagging.
    open_left: bool = false,
    /// The window's size when this menu was opened (null before the first
    /// layout). A root menu closes when the window stops matching it.
    opened_window: ?Rect = null,

    pub fn init(allocator: std.mem.Allocator, id: []const u8) !*Menu {
        const self = try allocator.create(Menu);
        self.* = .{
            .allocator = allocator,
            .id = id,
            .focus_id = try std.fmt.allocPrint(allocator, "{s}__panel", .{id}),
            .items = std.array_list.Managed(MenuItem).init(allocator),
            .is_open = signals.Signal(bool).init(allocator, false),
            .pos_x = signals.Signal(f32).init(allocator, 0),
            .pos_y = signals.Signal(f32).init(allocator, 0),
            .highlighted = signals.Signal(i32).init(allocator, -1),
            .scope = signals.Scope.init(allocator),
            .row_ids = std.array_list.Managed(reg.NodeId).init(allocator),
            .check_ids = std.array_list.Managed(reg.NodeId).init(allocator),
            .label_ids = std.array_list.Managed(reg.NodeId).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Menu) void {
        self.scope.deinit();
        self.is_open.deinit();
        self.pos_x.deinit();
        self.pos_y.deinit();
        self.highlighted.deinit();
        self.items.deinit();
        self.row_ids.deinit();
        self.check_ids.deinit();
        self.label_ids.deinit();
        self.allocator.free(self.focus_id);
        self.allocator.destroy(self);
        // Note: nested `submenu` Menus are host-owned; the host deinits them.
    }

    /// Adds an item that opens `sub` (host-owned) instead of emitting an action.
    pub fn addSubmenu(self: *Menu, label: []const u8, sub: *Menu) !void {
        try self.items.append(.{ .label = label, .submenu = sub });
        self.rows_stale = true;
    }

    pub fn addItem(self: *Menu, label: []const u8, action_id: []const u8) !void {
        try self.items.append(.{ .label = label, .action_id = action_id });
        self.rows_stale = true;
    }
    pub fn addItemEx(self: *Menu, item: MenuItem) !void {
        try self.items.append(item);
        self.rows_stale = true;
    }
    pub fn addSeparator(self: *Menu) !void {
        try self.items.append(.{ .kind = .separator, .enabled = false });
        self.rows_stale = true;
    }
    /// Adds a dimmed, non-selectable group title (e.g. "Recent").
    pub fn addHeader(self: *Menu, label: []const u8) !void {
        try self.items.append(.{ .kind = .header, .label = label, .enabled = false });
        self.rows_stale = true;
    }
    /// Adds an item of an exclusive group (see `MenuRadio`). `action_id` may be
    /// empty when the host only reads `group`.
    pub fn addRadio(self: *Menu, label: []const u8, action_id: []const u8, group: *signals.Signal(usize), value: usize) !void {
        try self.items.append(.{ .label = label, .action_id = action_id, .radio = .{ .group = group, .value = value } });
        self.rows_stale = true;
    }

    /// Empties `items` (e.g. to reload a "Recent files" submenu). Frees nothing —
    /// `label`/`action_id` stay host-owned, exactly as when adding items — and
    /// closes + unlinks any submenu items being cleared (so `open_sub`/
    /// `parent_menu` on the child never point at a discarded entry).
    ///
    /// This does NOT itself trigger a repaint: unlike `checked_signal`/
    /// `enabled_signal` (which `updateVisuals` observes directly, live, no
    /// rebuild), a *structural* change — the row count itself — needs the
    /// panel's rows rebuilt, and `Menu` is a host-owned controller with no
    /// standing subscription into the app's rebuild cycle to do that on its own
    /// (unlike a framework-`mountOwned` widget such as `Tabs`, whose `active`
    /// signal drives its own effect-triggered `rootAt` rebuild). Contract:
    /// clear, repopulate with `addItem`/`addItemEx`, then trigger the same
    /// top-level rebuild your app already uses for any other state change,
    /// before the menu is next opened. `popup()` does not rebuild rows either.
    pub fn clearItems(self: *Menu) void {
        for (self.items.items) |it| {
            if (it.submenu) |sub| {
                sub.close();
                sub.parent_menu = null;
                if (self.open_sub == sub) self.open_sub = null;
            }
        }
        self.items.clearRetainingCapacity();
        self.rows_stale = true;
        self.highlighted.set(-1);
    }

    /// Opens the menu at (x, y) in logical pixels, relative to the node the Menu
    /// is mounted into (the backdrop's containing block). From a pointer handler
    /// use `popupWindow(ev.x, ev.y, ...)` instead. A root menu (not a submenu)
    /// pushes a focus scope on its panel: focus moves into the panel so
    /// key_down routes to the menu, and Tab is trapped inside while open.
    ///
    /// `origin` (focus-visible) is why the menu is opening — defaults to
    /// `.pointer` since every current caller (a `MenuBar` button's click
    /// handler, `on_select`-less test helpers) is mouse-driven; pass
    /// `.keyboard` explicitly for an accelerator-driven open once one exists.
    ///
    /// The panel is kept inside the window (the top of its ancestor chain): past the
    /// right edge it opens to the left of `x`, past the bottom edge above `y`
    /// (where that fits), and it is finally clamped so it never starts left
    /// of / above the window. Before the first layout it opens at (x, y)
    /// as given.
    pub fn popup(self: *Menu, x: f32, y: f32, origin: events.FocusOrigin) void {
        const size = self.panelSize();
        if (self.visibleBounds()) |bnd| {
            const px = fitAxis(x, x - size.w, size.w, bnd.x, bnd.w);
            const py = fitAxis(y, y - size.h, size.h, bnd.y, bnd.h);
            self.open_left = px < x;
            self.openAt(px, py, origin);
        } else {
            self.open_left = false;
            self.openAt(x, y, origin);
        }
    }

    fn onBackdropResize(self: *Menu, _: events.Event) void {
        self.closeIfWindowResized();
    }

    /// Closes a root menu whose window no longer has the size it was opened
    /// at. Called from the backdrop's resize report and the tick; opening
    /// itself resizes the backdrop (0 → its container), which is why this
    /// compares the window size, not the report.
    fn closeIfWindowResized(self: *Menu) void {
        if (self.is_submenu or !self.is_open.peek()) return;
        const was = self.opened_window orelse return;
        const now = self.visibleBounds() orelse return;
        if (@abs(now.w - was.w) > 0.5 or @abs(now.h - was.h) > 0.5) self.close();
    }

    /// Opens at (x, y) exactly — the shared tail of every `popup*` entry point,
    /// after placement has been decided.
    fn openAt(self: *Menu, x: f32, y: f32, origin: events.FocusOrigin) void {
        self.opened_window = self.visibleBounds();
        self.pos_x.set(x);
        self.pos_y.set(y);
        self.highlighted.set(-1);
        // A fresh open never inherits a one-shot suppression left over from an
        // earlier click (fireSelect re-arms it after this when it must).
        self.suppress_dismiss = false;
        self.is_open.set(true);
        if (!self.is_submenu and !self.scope_pushed and self.panel_id != reg.NULL_NODE) {
            if (self.focus_scope) |fs| {
                if (fs.push(self.panel_id, origin)) self.scope_pushed = true;
            }
        }
    }

    /// Opens the menu at a **window-space** point — what `ev.x`/`ev.y` carry, so
    /// a context menu is `menu.popupWindow(ev.x, ev.y, .pointer)` from a
    /// right-click handler. `popup` takes coordinates in the backdrop's
    /// containing block (the node the Menu is mounted into); this converts by
    /// subtracting that block's resolved origin, which already includes any
    /// ancestor offset (a custom caption above the canvas) and any
    /// `scroll_offset_x/y` pan. Before the first layout it falls back to `popup`.
    pub fn popupWindow(self: *Menu, x: f32, y: f32, origin: events.FocusOrigin) void {
        var lx = x;
        var ly = y;
        if (self.store) |st| {
            if (st.registry) |rg| {
                // The backdrop is `position: absolute; left: 0; top: 0`, so its
                // geometry is its containing block's origin, open or closed.
                if (rg.getNode(self.backdrop_id)) |bd| {
                    lx -= bd.geometry.x;
                    ly -= bd.geometry.y;
                }
            }
        }
        self.popup(lx, ly, origin);
    }

    /// Opens the menu docked under `anchor` (left edges aligned, `gap` px below
    /// its bottom edge), from the anchor's resolved geometry — what a
    /// menu button / split button / toolbar selector does. Call it from the
    /// anchor's click handler (layout has run by then); pass `.keyboard` when
    /// Enter/Space opened it and highlight `firstEnabled()` yourself if wanted.
    /// Before the anchor has been laid out it opens at the containing block's
    /// origin.
    ///
    /// Kept inside the window (the top of its ancestor chain): a panel that would
    /// cross the right edge aligns its right edge with the anchor's instead,
    /// one that would cross the bottom edge opens above the anchor; if neither
    /// side fits it takes the roomier one, then clamps so it never starts left
    /// of / above the window.
    pub fn popupBelow(self: *Menu, anchor: reg.NodeId, gap: f32, origin: events.FocusOrigin) void {
        const st = self.store orelse return self.popup(0, 0, origin);
        const rg = st.registry orelse return self.popup(0, 0, origin);
        const n = rg.getNode(anchor) orelse return self.popup(0, 0, origin);
        // Anchor rect in the backdrop's containing block (see `popupWindow`).
        var ax = n.geometry.x;
        var ay = n.geometry.y;
        if (rg.getNode(self.backdrop_id)) |bd| {
            ax -= bd.geometry.x;
            ay -= bd.geometry.y;
        }
        const aw = n.geometry.width;
        const ah = n.geometry.height;
        const below = ay + ah + gap;
        const bnd = self.visibleBounds() orelse {
            self.open_left = false;
            return self.openAt(ax, below, origin);
        };
        const size = self.panelSize();
        const px = fitAxis(ax, ax + aw - size.w, size.w, bnd.x, bnd.w);
        const py = fitAxis(below, ay - gap - size.h, size.h, bnd.y, bnd.h);
        self.open_left = px < ax;
        self.openAt(px, py, origin);
    }

    const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
    const Size = struct { w: f32, h: f32 };

    /// The window — the top of the backdrop's ancestor chain — in the panel's
    /// own coordinate space (the one `pos_x/pos_y` live in). It is the window,
    /// not the containing block: a `MenuBar` mounts its menus inside a 44 px
    /// caption, and bounding by that would pin a taller panel over the bar.
    /// Subtracting the backdrop's origin folds in any `scroll_offset_x/y` pan.
    /// Null before the first layout (nothing to clamp against).
    fn visibleBounds(self: *Menu) ?Rect {
        const st = self.store orelse return null;
        const rg = st.registry orelse return null;
        const bd = rg.getNode(self.backdrop_id) orelse return null;
        var p = rg.getNode(bd.parent) orelse return null;
        while (rg.getNode(p.parent)) |up| p = up;
        if (p.geometry.width <= 0 or p.geometry.height <= 0) return null;
        return .{
            .x = p.geometry.x - bd.geometry.x,
            .y = p.geometry.y - bd.geometry.y,
            .w = p.geometry.width,
            .h = p.geometry.height,
        };
    }

    /// The panel's size once open. Width is the resolved geometry — explicit,
    /// so valid even while closed — falling back to the unmeasured estimate
    /// before the first layout; height is the content height (0 while closed
    /// in the layout, so it can't come from geometry).
    fn panelSize(self: *Menu) Size {
        var w: f32 = 0;
        if (self.store) |st| {
            if (st.registry) |rg| {
                if (rg.getNode(self.panel_id)) |node| w = node.geometry.width;
            }
        }
        if (w <= 0) w = self.contentWidth(null);
        return .{ .w = w, .h = self.contentHeight() };
    }

    /// One axis of the placement: a `size`-long span inside `[lo, lo + len]`.
    /// `pref` if it fits, else `alt` if that fits, else whichever of the two
    /// has more room; then clamped so it never starts before `lo` (a span
    /// larger than the area pins to `lo`).
    fn fitAxis(pref: f32, alt: f32, size: f32, lo: f32, len: f32) f32 {
        const hi = lo + len;
        var v = pref;
        if (pref < lo or pref + size > hi) {
            if (alt >= lo and alt + size <= hi) {
                v = alt;
            } else if (alt + size - lo > hi - pref) {
                v = alt;
            }
        }
        return @max(lo, @min(v, hi - size));
    }

    /// Closes this menu and, recursively, any open submenu beneath it. Pops the
    /// focus scope pushed by `popup` (restoring the focus held before opening).
    pub fn close(self: *Menu) void {
        self.is_open.set(false);
        if (self.open_sub) |s| {
            s.close();
            self.open_sub = null;
        }
        if (self.scope_pushed) {
            self.scope_pushed = false;
            if (self.focus_scope) |fs| _ = fs.pop();
        }
    }

    pub fn isOpen(self: *Menu) bool {
        return self.is_open.peek();
    }

    /// The top of the parent chain (the menu the host opened + owns on_select).
    fn rootMenu(self: *Menu) *Menu {
        var m = self;
        while (m.parent_menu) |p| m = p;
        return m;
    }

    /// Nesting depth: 0 for the root menu, 1 for its submenus, 2 for their
    /// submenus, etc. Drives z-index so deeper panels always paint (and
    /// hit-test) above their ancestors.
    fn depth(self: *Menu) u32 {
        var d: u32 = 0;
        var m = self;
        while (m.parent_menu) |p| {
            d += 1;
            m = p;
        }
        return d;
    }

    /// Y offset (within the panel) of the row for item `i`.
    fn rowOffsetY(self: *Menu, idx: usize) f32 {
        var y: f32 = PAD_Y;
        for (self.items.items, 0..) |it, i| {
            if (i == idx) break;
            y += rowHeight(it);
        }
        return y;
    }

    /// Opens item `idx`'s submenu to the right of its row, closing any sibling
    /// submenu that was open.
    fn openSubAt(self: *Menu, sub: *Menu, idx: usize, origin: events.FocusOrigin) void {
        if (self.open_sub) |prev| {
            if (prev != sub) prev.close();
        }
        self.open_sub = sub;
        // The panel's width is now content-measured, not the fixed PANEL_W,
        // so the submenu offset must use the resolved geometry (same pattern as
        // `MenuBar.onButton`) — falling back to the PANEL_W minimum if layout
        // hasn't run yet (e.g. → pressed the same frame the parent opened).
        var panel_w: f32 = PANEL_W;
        if (self.store) |st| {
            if (st.registry) |rg| {
                if (rg.getNode(self.panel_id)) |node| {
                    if (node.geometry.width > 0) panel_w = node.geometry.width;
                }
            }
        }
        // Right of the parent (overlapping it by 4 px), or mirrored to its
        // left; a cascade that already went left tries left first. Vertically
        // top-aligned with the row, or bottom-aligned with it when that runs
        // past the bottom edge.
        const px = self.pos_x.peek();
        const right = px + panel_w - 4;
        const size = sub.panelSize();
        const left = px - size.w + 4;
        const row_y = self.pos_y.peek() + self.rowOffsetY(idx);
        const row_h = rowHeight(self.items.items[idx]);
        const bnd = sub.visibleBounds() orelse {
            sub.open_left = false;
            return sub.openAt(right, row_y, origin);
        };
        const x = if (self.open_left)
            fitAxis(left, right, size.w, bnd.x, bnd.w)
        else
            fitAxis(right, left, size.w, bnd.x, bnd.w);
        sub.open_left = x < px;
        sub.openAt(x, fitAxis(row_y, row_y + row_h - size.h, size.h, bnd.y, bnd.h), origin);
    }

    fn onDismiss(self: *Menu, ev: events.Event) void {
        // Only the root menu has an interactive backdrop; an outside click closes
        // the whole chain. Dismiss on `click` (mouse_up) only — NOT `mouse_down`:
        // the rows are descendants of the backdrop, so a press on a row bubbles
        // here too. Closing on mouse_down would tear the menu down (and re-bake the
        // hit list without the rows) before the row's own `click` can fire on
        // mouse_up, so item selection would silently never run.
        if (std.mem.eql(u8, ev.name, "click")) {
            if (self.suppress_dismiss) {
                self.suppress_dismiss = false;
                return;
            }
            self.close();
        }
    }

    /// One typed handler for every enabled row (click + hover): resolves the item
    /// by matching the event's node against `row_ids` (no per-item routing
    /// strings; the leaf rows still CARRY their `action_id` as the clickable
    /// modifier because that string is what C hosts receive on the structured
    /// callback).
    fn onRowEvent(self: *Menu, ev: events.Event) void {
        // Items changed and the rows are not rebuilt yet: a row node maps to
        // the OLD list, so its index may be out of range or name another item.
        if (self.rows_stale) return;
        const idx = blk: {
            for (self.row_ids.items, 0..) |rid, i| {
                if (rid == ev.node_id) break :blk i;
            }
            return;
        };
        const it = self.items.items[idx];
        if (it.kind != .item or !it.isEnabled()) return;

        if (it.submenu) |sub| {
            // Hover or click on a submenu row opens the child to the side —
            // both mouse-driven, so `.pointer`: no ring on the submenu.
            if (std.mem.eql(u8, ev.name, "click") or std.mem.eql(u8, ev.name, "mouse_enter")) {
                self.highlighted.set(@intCast(idx));
                self.openSubAt(sub, idx, .pointer);
                // The `click` that just opened this submenu is still bubbling up
                // to the root's backdrop `onDismiss` — arm the one-shot suppression
                // so it doesn't close the chain it was just asked to open.
                if (std.mem.eql(u8, ev.name, "click")) self.rootMenu().suppress_dismiss = true;
            }
            return;
        }
        // Hovering a leaf highlights it (mouse and keyboard drive the same
        // `highlighted` signal `updateVisuals` paints) and collapses any
        // sibling submenu that was open.
        if (std.mem.eql(u8, ev.name, "mouse_enter")) {
            self.highlighted.set(@intCast(idx));
            if (self.open_sub) |s| {
                s.close();
                self.open_sub = null;
            }
            return;
        }
        if (!std.mem.eql(u8, ev.name, "click")) return;
        self.fireSelect(idx, .pointer);
    }

    /// The single selection path (mouse click and Enter): closes the whole chain
    /// from the root, then fires the root's `on_select` with a synthesized
    /// "select" event. Everything the event needs is copied to locals before
    /// `close()`, so a handler that reopens the menu sees it in a clean state.
    ///
    /// A mouse selection's `click` is still bubbling: after this returns it
    /// reaches the root backdrop's `onDismiss`, which would close a menu the
    /// handler just reopened. So if — and only if — the handler reopened it,
    /// arm the one-shot `suppress_dismiss` for that click (as opening a submenu
    /// does). Enter has no trailing click and never arms it. (The root is
    /// touched after the call, which is why the handler must not `deinit` it.)
    fn fireSelect(self: *Menu, idx: usize, origin: events.FocusOrigin) void {
        const r = self.rootMenu();
        const h = r.on_select;
        const radio = self.items.items[idx].radio;
        const ev: events.Event = .{
            .name = "select",
            .id = self.items.items[idx].action_id,
            .node_id = if (idx < self.row_ids.items.len) self.row_ids.items[idx] else 0,
        };
        r.close();
        // A radio item commits its value after the chain is closed (effects on
        // the group run synchronously and may reopen or reload the menu) and
        // before `on_select`, so the handler already sees the new selection.
        if (radio) |rad| {
            if (rad.group.peek() != rad.value) rad.group.set(rad.value);
        }
        if (h) |handler| handler.call(handler.ptr, ev);
        if (origin == .pointer and r.isOpen()) r.suppress_dismiss = true;
    }

    // ── Keyboard navigation (model logic; host wires it to key events) ──────────

    /// First selectable (enabled, non-separator) item index, or -1 if none.
    pub fn firstEnabled(self: *Menu) i32 {
        for (self.items.items, 0..) |it, i| {
            if (it.kind == .item and it.isEnabled()) return @intCast(i);
        }
        return -1;
    }

    /// Moves the highlight by `dir` (+1 down / -1 up), skipping separators and
    /// disabled items, wrapping around. No-op if nothing is selectable.
    pub fn moveHighlight(self: *Menu, dir: i32) void {
        const n: i32 = @intCast(self.items.items.len);
        if (n == 0) return;
        var cur = self.highlighted.peek();
        var steps: i32 = 0;
        while (steps < n) : (steps += 1) {
            cur += dir;
            if (cur < 0) cur = n - 1;
            if (cur >= n) cur = 0;
            const it = self.items.items[@intCast(cur)];
            if (it.kind == .item and it.isEnabled()) {
                self.highlighted.set(cur);
                return;
            }
        }
    }

    /// Activates the highlighted item, if any: a submenu item opens its child
    /// (first item highlighted); a leaf closes the whole chain and fires the
    /// root's on_select.
    pub fn activateHighlighted(self: *Menu) void {
        const hi = self.highlighted.peek();
        if (hi < 0 or hi >= @as(i32, @intCast(self.items.items.len))) return;
        const it = self.items.items[@intCast(hi)];
        if (it.kind != .item or !it.isEnabled()) return;
        if (it.submenu) |sub| {
            // `activateHighlighted` only runs from Enter — always keyboard.
            self.openSubAt(sub, @intCast(hi), .keyboard);
            sub.highlighted.set(sub.firstEnabled());
            return;
        }
        self.fireSelect(@intCast(hi), .keyboard);
    }

    /// The deepest open submenu under this menu (or this menu itself) — the one
    /// keyboard input operates on. Focus stays trapped on the root's panel, so
    /// the root's key handler delegates here.
    fn activeMenu(self: *Menu) *Menu {
        var m = self;
        while (m.open_sub) |s| {
            if (!s.isOpen()) break;
            m = s;
        }
        return m;
    }

    /// key_down handler on the panel: ↑/↓ move the highlight, Enter
    /// activates, Escape closes the chain, → opens the highlighted submenu,
    /// ← closes the deepest open submenu.
    fn onKey(self: *Menu, ev: events.Event) void {
        if (!std.mem.eql(u8, ev.name, "key_down")) return;
        if (!self.is_open.peek()) return;
        const m = self.activeMenu();
        switch (events.Key.fromCode(ev.key_code) orelse return) {
            .up => m.moveHighlight(-1),
            .down => m.moveHighlight(1),
            .enter => m.activateHighlighted(),
            .escape => self.rootMenu().close(),
            .right => {
                const hi = m.highlighted.peek();
                if (hi >= 0 and hi < @as(i32, @intCast(m.items.items.len))) {
                    const it = m.items.items[@intCast(hi)];
                    if (it.submenu) |sub| {
                        m.openSubAt(sub, @intCast(hi), .keyboard); // -> is a key press
                        sub.highlighted.set(sub.firstEnabled());
                    }
                }
            },
            .left => {
                if (m.parent_menu) |p| {
                    m.close();
                    p.open_sub = null;
                }
            },
            else => {},
        }
    }

    // ── Rendering ───────────────────────────────────────────────────────────────

    pub fn build(self: *Menu, ctx: *component.BuildContext) !void {
        const b = ctx.builder;
        self.theme = b.theme;
        self.store = b.store;
        self.row_ids.clearRetainingCapacity();
        // Rows rebuilt from `items` below. If the items changed since the last
        // build, the visuals effect is still subscribed to the OLD items' signals
        // (`bindVisuals` re-applies untracked), so it is recreated at the end.
        const rows_were_stale = self.rows_stale;
        self.rows_stale = false;
        self.check_ids.clearRetainingCapacity();
        self.label_ids.clearRetainingCapacity();

        // Backdrop: a full-window transparent box that dismisses on click. Sized to
        // 0 when closed so it neither paints nor hit-tests. Submenus get NO
        // interactive backdrop — the root's catches outside clicks for the chain.
        const backdrop = try b.openNodeKeyed(.box, null);
        self.backdrop_id = backdrop;
        try b.store.setLayout(backdrop, .position, .{ .keyword = .absolute });
        try b.store.setLayout(backdrop, .left, .{ .dimension = .{ .value = 0, .unit = .px } });
        try b.store.setLayout(backdrop, .top, .{ .dimension = .{ .value = 0, .unit = .px } });
        try b.backgroundAlpha(backdrop, 0, 0, 0, 0.0);
        // A Menu built inside a MenuBar embedded in a draggable caption
        // sits inside that caption's drag region too — the open panel (and its
        // dismiss-click backdrop) must not also start a window drag.
        try b.noDrag(backdrop);
        if (!self.is_submenu) {
            try clickableAuto(b, backdrop);
            // Same convention as row ariaLabel above: clickableAuto hoists this
            // node to a UIA Button, and without an explicit name it exposes an
            // unnamed Button spanning the whole panel to screen readers/UIA.
            try b.ariaLabel(backdrop, "Close menu");
            if (ctx.router) |r| try r.onNode(backdrop, .click, ctx.handler(self, onDismiss));
            // Close on a window resize (WinUI does the same): a placement
            // decided for the old size can now run past an edge. The backdrop
            // spans its container while open, so it resizes with the window in
            // the same frame; the tick covers a fixed-size container (a 44 px
            // caption when only the window height changes).
            try ctx.onResize(backdrop, ctx.handler(self, onBackdropResize));
            if (ctx.router) |r| try r.onTick(backdrop, self, closeIfWindowResized);
        }

        // Panel: positioned at (x,y); column of rows; clipped (height 0 when closed).
        const panel = try b.openNodeKeyed(.box, null);
        self.panel_id = panel;
        try b.store.setLayout(panel, .position, .{ .keyword = .absolute });
        // Computed from content instead of the old fixed PANEL_W for
        // every panel regardless of content. NOT the engine's flex "hug" —
        // shrink-to-fit width only auto-propagates one level (a box whose
        // *direct* parent is a flex row measures its own intrinsic extent);
        // it doesn't recurse through a column of full-width rows the way a
        // menu panel needs, so a `minWidth`-only panel measured out to the
        // full backdrop width instead of its content (caught by the geometry
        // test below). Measuring the widest label directly with `b.measure`
        // (same mechanism `text_input.zig` uses for caret placement) is the
        // reliable option; falls back to a char-count estimate headless.
        try b.width(panel, self.contentWidth(b.measure), .px);
        try b.flexColumn(panel);
        try b.padding(panel, PAD_Y, 0, PAD_Y, 0);
        try b.overflowHidden(panel);
        const panel_border = themeOr(self.theme.border_color, .{ .r = 100, .g = 100, .b = 100 });
        const panel_bg = themeOr(self.theme.surface_highest, .{ .r = 25, .g = 25, .b = 25 });
        try b.borderWidth(panel, 1);
        try b.borderColorOf(panel, panel_border);
        try b.radius(panel, 6);
        try b.backgroundAlpha(panel, panel_bg.r, panel_bg.g, panel_bg.b, 1.0);
        // Depth-aware: a submenu panel must draw (and hit-test) above its
        // ancestors, or overlapping regions resolve `ElementFromPoint` to the
        // parent panel and nested rows never see `mouse_enter` — no highlight
        // at depth ≥2. `parent_menu` is already wired by the time a submenu's
        // own `build()` runs (the parent sets it right before calling here).
        try b.zIndex(panel, 100 + @as(f32, @floatFromInt(self.depth())) * 10);
        // Focus lands on the panel while open (via the popup's focus scope),
        // so key_down routes here; closed panels are height-0 → not tabbable.
        try b.focusable(panel, self.focus_id);
        self.focus_scope = b.focus_scope;
        if (ctx.router) |r| try r.onNode(panel, .key_down, ctx.handler(self, onKey));

        for (self.items.items) |it| {
            if (it.kind == .separator) {
                const sep = try b.openNodeKeyed(.box, null);
                try self.row_ids.append(sep);
                try self.check_ids.append(reg.NULL_NODE);
                try self.label_ids.append(reg.NULL_NODE);
                // No explicit width: the panel now has an explicit (content-
                // measured) width, and default cross-axis `stretch`
                // fills the separator to it — equivalent to the old `100%`,
                // without depending on it.
                try b.height(sep, 1, .px);
                try b.marginTop(sep, 4);
                try b.marginBottom(sep, 4);
                const sep_color = themeOr(self.theme.border_color, .{ .r = 80, .g = 80, .b = 80 });
                try b.backgroundOf(sep, sep_color);
                b.close();
                continue;
            }
            if (it.kind == .header) {
                // Group title: no hit modifiers, no handler, skipped by keyboard
                // nav (`kind != .item`). Indented to the label column.
                const hdr = try b.openNodeKeyed(.box, null);
                try self.row_ids.append(hdr);
                try self.check_ids.append(reg.NULL_NODE);
                try self.label_ids.append(reg.NULL_NODE);
                try b.height(hdr, HEADER_H, .px);
                try b.padding(hdr, 0, 12, 0, 12 + CHECK_COL);
                try b.flexRow(hdr);
                try b.alignItems(hdr, .center);
                try b.role(hdr, "heading");
                try b.ariaLabel(hdr, it.label);
                const ht = try b.addText(it.label);
                try b.fontSize(ht, 12);
                const hc = themeOr(self.theme.text_secondary, .{ .r = 140, .g = 140, .b = 140 });
                try b.textColor(ht, hc.r, hc.g, hc.b);
                b.close();
                continue;
            }

            const row = try b.openNodeKeyed(.box, null);
            try self.row_ids.append(row);
            // No explicit width — stretches to the panel's width; see the
            // separator's comment above.
            try b.height(row, ROW_H, .px);
            try b.padding(row, 0, 12, 0, 12);
            try b.flexRow(row);
            try b.alignItems(row, .center);
            // Zig-side dispatch is typed by (node, kind) → onRowEvent. Leaf rows
            // keep their `action_id` as the clickable modifier — that string is
            // the C-ABI contract (the host's structured callback receives it);
            // submenu rows are internal, so they use the autogenerated id.
            // Hit modifiers + handler are registered UNCONDITIONALLY (not gated
            // on build-time enabled state): `onRowEvent` already re-checks
            // `it.isEnabled()` live on every event (below), so gating
            // registration here would just make that live check unreachable for
            // an item built disabled. Registering always is what makes
            // `enabled_signal` symmetric with `checked_signal` — flipping it
            // back to `true` makes the row clickable again with no rebuild
            // (`hitTest` in uia.zig walks by geometry/z-index, never by this
            // modifier, so an unclickable row being "clickable-registered"
            // doesn't change what a click or a11y point-navigation hits).
            const build_enabled = it.isEnabledUntracked();
            if (it.submenu != null or (it.action_id.len == 0 and it.radio != null)) {
                // Radio rows may carry no action id (the host reads the group).
                try clickableAuto(b, row);
                try hoverableAuto(b, row);
            } else if (it.action_id.len > 0) {
                try b.clickable(row, it.action_id);
                try b.hoverable(row, it.action_id);
            }
            if (it.kind == .item and (it.submenu != null or it.action_id.len > 0 or it.radio != null)) {
                if (ctx.router) |r| {
                    const h = ctx.handler(self, onRowEvent);
                    try r.onNode(row, .click, h);
                    try r.onNode(row, .mouse_enter, h);
                }
            }
            // a11y: `IsEnabled` (UIA) must reflect live state, not build state —
            // same family as `checked` above. Live updates for `enabled_signal`
            // items mirror this in `updateVisuals` below.
            try b.setDisabled(row, !build_enabled);

            // Explicit accessible name: without this, `accessibleName` would fall
            // back to the row's first text child in document order — the
            // checkmark placeholder below, not the label — so a screen reader
            // would hear "    " for every row (same pattern as `checkbox.zig`'s
            // indicator glyph vs. its label).
            try b.ariaLabel(row, it.label);
            // Checked is a11y *state*, not text — baking it into the name (the
            // old "\u{2713}  " placeholder) would change the control's name
            // every time it's toggled, which a screen reader doesn't expect.
            // Live updates for `checked_signal` items mirror this in
            // `updateVisuals` below.
            try b.setChecked(row, it.isCheckedUntracked());

            // Checkmark column (kept even when unchecked so labels align — purely
            // visual now that `checked` is exposed as state above). Content is
            // re-set live by `updateVisuals` when `checked_signal` changes.
            const check = try b.addText(markGlyph(it, it.isCheckedUntracked()));
            try self.check_ids.append(check);
            try b.fontSize(check, 14);
            try b.textColor(check, self.theme.text.r, self.theme.text.g, self.theme.text.b);

            const label = try b.addText(it.label);
            try self.label_ids.append(label);
            try b.fontSize(label, 14);
            // Grows to fill leftover row space, pushing the shortcut chord (if
            // any) to the row's right edge instead of hugging the label.
            try b.flexGrow(label, 1);
            // Disabled items are dimmed; color re-set live by `updateVisuals`
            // when `enabled_signal` changes.
            if (build_enabled) {
                try b.textColor(label, self.theme.text.r, self.theme.text.g, self.theme.text.b);
            } else {
                const disabled_color = themeOr(self.theme.text_disabled, .{ .r = 128, .g = 128, .b = 128 });
                try b.textColor(label, disabled_color.r, disabled_color.g, disabled_color.b);
            }

            // Accelerator chord, right-aligned and dimmed — purely visual (see
            // `MenuItem.shortcut` doc-comment).
            if (it.shortcut.len > 0) {
                const shortcut_color = themeOr(self.theme.text_secondary, .{ .r = 140, .g = 140, .b = 140 });
                const shortcut = try b.addText(it.shortcut);
                try b.fontSize(shortcut, 12);
                try b.textColor(shortcut, shortcut_color.r, shortcut_color.g, shortcut_color.b);
            }

            // Submenu arrow indicator (Codicon chevron; the margin replaces the
            // two leading spaces the old "  ▸" text used as a gap).
            if (it.submenu != null) {
                const arrow = try b.addText(icons.chevron_right);
                try b.marginLeft(arrow, 8);
                try b.fontSize(arrow, 12);
                try b.textColor(arrow, self.theme.text.r, self.theme.text.g, self.theme.text.b);
            }
            b.close(); // row
        }
        b.close(); // panel
        b.close(); // backdrop

        // Submenus are sibling overlays built AFTER this menu, so they draw on top.
        // Building also links the chain (this used to happen in register()).
        for (self.items.items) |it| {
            if (it.submenu) |sub| {
                sub.is_submenu = true;
                sub.parent_menu = self;
                try sub.build(ctx);
            }
        }

        // Effect created once; on later builds re-applied UNTRACKED. A tracked
        // call here subscribed whatever build-effect mounted the Menu (the app
        // root) to is_open/pos/highlighted, so every popup()/hover rebuilt the
        // host's whole tree in the same gesture.
        if (rows_were_stale and self.bound) {
            self.scope.deinit();
            self.scope = signals.Scope.init(self.allocator);
            self.bound = false;
        }
        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn contentHeight(self: *Menu) f32 {
        var h: f32 = PAD_Y * 2;
        for (self.items.items) |it| {
            h += rowHeight(it);
        }
        return h;
    }

    /// Widest row's content width (checkmark column + label + submenu arrow +
    /// row padding), clamped to `[PANEL_W, max_width]`. `measure` is `b.measure`
    /// — null in headless/test builds, where it falls back to a fixed
    /// per-character estimate (good enough for a lower-bound sanity check, not
    /// pixel-accurate).
    fn contentWidth(self: *Menu, measure: ?builder_mod.TextMeasure) f32 {
        const check_col: f32 = CHECK_COL; // reserved for the "✓  " glyph column
        const h_padding: f32 = 24; // row's 12px left + 12px right padding
        const arrow_w: f32 = 20; // 8 px gap + 12 px chevron_right icon
        const shortcut_gap: f32 = 16; // space between label and shortcut chord
        var w: f32 = PANEL_W;
        for (self.items.items) |it| {
            if (it.kind == .header) {
                const hw = if (measure) |m| m.width(it.label, 12) else @as(f32, @floatFromInt(it.label.len)) * 7.0;
                w = @max(w, check_col + hw + h_padding);
                continue;
            }
            if (it.kind != .item) continue;
            const label_w = if (measure) |m|
                m.width(it.label, 14)
            else
                @as(f32, @floatFromInt(it.label.len)) * 8.0;
            var row_w = check_col + label_w + h_padding;
            if (it.submenu != null) row_w += arrow_w;
            if (it.shortcut.len > 0) {
                const shortcut_w = if (measure) |m|
                    m.width(it.shortcut, 12)
                else
                    @as(f32, @floatFromInt(it.shortcut.len)) * 7.0;
                row_w += shortcut_gap + shortcut_w;
            }
            w = @max(w, row_w);
        }
        return @min(w, self.max_width);
    }

    fn updateVisuals(self: *Menu) void {
        const store = self.store orelse return;
        if (self.panel_id == reg.NULL_NODE) return;
        const open = self.is_open.get();
        const x = self.pos_x.get();
        const y = self.pos_y.get();
        const hi = self.highlighted.get();
        const t = self.theme;

        // Backdrop: full window when open (root only — submenus rely on the root's),
        // 0 otherwise (not painted / not hittable).
        const full: props.PropValue = .{ .dimension = .{ .value = 100, .unit = .percent } };
        const zero: props.PropValue = .{ .dimension = .{ .value = 0, .unit = .px } };
        const bd_on = open and !self.is_submenu;
        store.setLayout(self.backdrop_id, .width, if (bd_on) full else zero) catch {};
        store.setLayout(self.backdrop_id, .height, if (bd_on) full else zero) catch {};

        // Panel position + height (0 when closed → clipped via overflow_hidden).
        store.setLayout(self.panel_id, .left, .{ .dimension = .{ .value = x, .unit = .px } }) catch {};
        store.setLayout(self.panel_id, .top, .{ .dimension = .{ .value = y, .unit = .px } }) catch {};
        const ph: f32 = if (open) self.contentHeight() else 0;
        store.setLayout(self.panel_id, .height, .{ .dimension = .{ .value = ph, .unit = .px } }) catch {};

        // Roving focus: real engine focus stays on the panel (Tab-trap,
        // key_down routing) — the RING follows the highlighted row instead,
        // the `aria-activedescendant` pattern (see `ModifierKey.virtual_focus_target`
        // and the matching redirect in `renderer.zig`). -1 (no row highlighted,
        // e.g. freshly opened before any arrow key) clears the redirect, so the
        // ring falls back to painting around the whole panel.
        const target: f32 = if (open and hi >= 0 and hi < @as(i32, @intCast(self.row_ids.items.len)))
            @floatFromInt(self.row_ids.items[@intCast(hi)])
        else
            -1;
        store.setModifier(self.panel_id, .virtual_focus_target, .{ .number = target }) catch {};

        // Keyboard highlight on the matching row, and live checked/enabled state
        // for items with a lifted-state signal — both read via `.get()`
        // inside this effect, so a signal write re-runs this function directly,
        // no rebuild involved.
        for (self.items.items, 0..) |it, i| {
            if (it.kind != .item) continue;
            if (self.rows_stale) {
                // Items changed (clearItems/add*) and the rows are not rebuilt
                // yet: `row_ids` still describe the OLD list (other length,
                // other kinds), so paint nothing. Still read the signals,
                // tracked, so this effect follows the NEW items' signals — the
                // rebuild re-applies it untracked.
                _ = it.isChecked();
                if (it.enabled_signal) |s| _ = s.get();
                continue;
            }
            const row_id = self.row_ids.items[i];
            const on = (open and hi == @as(i32, @intCast(i)));
            const a: f32 = if (on) 110.0 / 255.0 else 0.0;
            store.setStyle(row_id, .background, .{ .color = .{
                .r = @as(f32, @floatFromInt(t.accent.r)) / 255.0,
                .g = @as(f32, @floatFromInt(t.accent.g)) / 255.0,
                .b = @as(f32, @floatFromInt(t.accent.b)) / 255.0,
                .a = a,
            } }) catch {};

            if (it.checked_signal != null or it.radio != null) {
                const checked = it.isChecked(); // tracked `.get()` on the signal/group
                const check_id = self.check_ids.items[i];
                if (check_id != reg.NULL_NODE) {
                    if (store.stringAllocator().dupe(u8, markGlyph(it, checked))) |s| {
                        store.setTextContent(check_id, s);
                    } else |_| {}
                }
                // Keep the a11y `.checked` state (set at build time above) in
                // sync with the live signal — same live-update path as the
                // visual glyph, just on the state channel instead of text.
                store.setModifier(row_id, .checked, .{ .boolean = checked }) catch {};
            }
            if (it.enabled_signal) |sig| {
                const enabled = sig.get();
                const label_id = self.label_ids.items[i];
                if (label_id != reg.NULL_NODE) {
                    const color = if (enabled) t.text else themeOr(t.text_disabled, .{ .r = 128, .g = 128, .b = 128 });
                    store.setStyle(label_id, .color, props.PropValue.rgbA(color.r, color.g, color.b, 1.0)) catch {};
                }
                // Keep the a11y `disabled` state (set at build time above) in
                // sync with the live signal, same as `.checked` above — this is
                // what UIA `IsEnabled` reads (uia.zig).
                store.setModifier(row_id, .disabled, .{ .boolean = !enabled }) catch {};
            }
        }
    }
};

/// Hit modifiers with the autogenerated "n{id}" action-id (internal rows — the
/// C-ABI channel stays intact, just without a meaningful string).
fn clickableAuto(b: *component.UIBuilder, id: reg.NodeId) !void {
    var buf: [16]u8 = undefined;
    try b.clickable(id, std.fmt.bufPrint(&buf, "n{d}", .{id}) catch "n");
}
fn hoverableAuto(b: *component.UIBuilder, id: reg.NodeId) !void {
    var buf: [16]u8 = undefined;
    try b.hoverable(id, std.fmt.bufPrint(&buf, "n{d}", .{id}) catch "n");
}

// ── MenuBar ───────────────────────────────────────────────────────────────────
//
// A horizontal strip of labelled buttons (File, Edit, …), each opening a `Menu`
// below it. Composition over `Menu`: the bar owns no menu logic itself — it just
// positions and toggles the host-owned menus. At most one menu open at a time.

const BAR_H: f32 = 32;
/// Default bar height in px — exported so a host embedding `MenuBar` in its own
/// caption (e.g. alongside a logo) can align the caption to it without
/// duplicating the literal.
pub const DEFAULT_HEIGHT: f32 = BAR_H;

pub const MenuBar = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    entries: std.array_list.Managed(Entry),
    store: ?*props.PropertyStore = null,
    registry: ?*reg.UIRegistry = null,
    theme: theme_mod.Theme = .{},
    /// Bar height in px. Default matches the classic standalone bar; a host
    /// embedding the bar in a shorter/taller caption sets this to match it.
    height: f32 = DEFAULT_HEIGHT,
    /// Background color; `null` = the theme's `surface_high` (today's look).
    /// Pass `Color.transparent()` explicitly for a see-through bar — e.g. when
    /// embedding inside a caption that already paints its own background.
    background: ?theme_mod.Color = null,
    /// When true, the bar sizes to its content (hug) instead of `width: 100%`.
    /// Only takes effect if the host places the bar inside a flex row — a
    /// hugged bar in a flex column still gets the row's full width.
    hug: bool = false,
    /// Corner radius (px) of each top-level button's highlight (hover and
    /// open menu). 0 = square corners.
    item_radius: f32 = 0,
    /// Horizontal space (px) between adjacent top-level buttons, so two
    /// highlights side by side don't touch.
    item_gap: f32 = 0,

    /// Index of the button under the pointer (-1 = none). Internal state; the
    /// highlight effect reads it together with each menu's `is_open`.
    hovered: signals.Signal(i32),
    scope: signals.Scope,
    highlight_effect: ?*signals.Effect = null,
    /// Button count the effect was created for.
    highlight_count: usize = 0,

    const Entry = struct {
        label: []const u8,
        menu: *Menu,
        btn_id: reg.NodeId = reg.NULL_NODE,
    };

    pub fn init(allocator: std.mem.Allocator, id: []const u8) !*MenuBar {
        const self = try allocator.create(MenuBar);
        self.* = .{
            .allocator = allocator,
            .id = id,
            .entries = std.array_list.Managed(Entry).init(allocator),
            .hovered = signals.Signal(i32).init(allocator, -1),
            .scope = signals.Scope.init(allocator),
        };
        return self;
    }

    /// Deinit the bar BEFORE its menus (the natural `defer` order when the
    /// menus are created first): the highlight effect observes each menu's
    /// `is_open` signal.
    pub fn deinit(self: *MenuBar) void {
        self.scope.deinit();
        self.hovered.deinit();
        self.entries.deinit();
        self.allocator.destroy(self);
        // Menus are host-owned; not freed here.
    }

    /// Adds a top-level button that opens `menu`. Order = left-to-right.
    pub fn addMenu(self: *MenuBar, label: []const u8, menu: *Menu) !void {
        try self.entries.append(.{ .label = label, .menu = menu });
    }

    /// One typed handler for every top-level button: resolves the entry by
    /// matching the event's node against the button ids (no per-button
    /// routing strings).
    fn onButton(self: *MenuBar, ev: events.Event) void {
        const enter = std.mem.eql(u8, ev.name, "mouse_enter");
        if (enter or std.mem.eql(u8, ev.name, "mouse_leave")) {
            for (self.entries.items, 0..) |e, i| {
                if (e.btn_id != ev.node_id) continue;
                const idx: i32 = @intCast(i);
                if (enter) {
                    self.hovered.set(idx);
                } else if (self.hovered.peek() == idx) {
                    self.hovered.set(-1);
                }
                return;
            }
            return;
        }
        if (!std.mem.eql(u8, ev.name, "click")) return;
        for (self.entries.items) |e| {
            if (e.btn_id != ev.node_id) continue;
            const was_open = e.menu.isOpen();
            self.closeAll();
            // Toggle: clicking an already-open button's label just closes it.
            if (!was_open) {
                // Drop the menu directly below the button, using its resolved
                // (window-space) geometry — layout has already run by the time a
                // click arrives. `popupWindow` maps it into the menu's own
                // containing block, so a MenuBar nested inside an offset
                // container (e.g. a custom window caption) isn't shifted by it.
                // `popupBelow` also keeps it inside the window (right-aligned
                // with the button near the right edge).
                // Only entry point today is the button's `.click` handler
                // (registered below) — always mouse-driven, so `.pointer`.
                if (self.registry != null and self.registry.?.getNode(e.btn_id) != null) {
                    e.menu.popupBelow(e.btn_id, 0, .pointer);
                } else {
                    e.menu.popupWindow(0, self.height, .pointer);
                }
            }
            return;
        }
    }

    pub fn closeAll(self: *MenuBar) void {
        for (self.entries.items) |e| e.menu.close();
    }

    pub fn build(self: *MenuBar, ctx: *component.BuildContext) !void {
        const b = ctx.builder;
        self.theme = b.theme;
        self.store = b.store;
        self.registry = b.registry;

        const bar = try b.openNodeKeyed(.box, null);
        if (!self.hug) try b.width(bar, 100, .percent);
        // Hugged content must not be told to shrink below its intrinsic size
        // when the row runs short on space — the same protection `Caption`'s
        // own wordmark/badge already carry — or a button's text gets
        // re-measured against a squeezed box and wraps mid-word.
        try b.flexShrink(bar, 0);
        try b.height(bar, self.height, .px);
        try b.flexRow(bar);
        // `stretch` (not `center`), deliberately: buttons below have NO
        // explicit height of their own — see the comment on `btn` for why —
        // so this is what gives them the bar's full height.
        try b.alignItems(bar, .stretch);
        const bg = self.background orelse self.theme.surface_high;
        try b.backgroundAlpha(bar, bg.r, bg.g, bg.b, @as(f32, @floatFromInt(bg.a)) / 255.0);
        if (self.item_gap > 0) try b.gap(bar, self.item_gap);

        for (self.entries.items) |*e| {
            const btn = try b.openNodeKeyed(.box, null);
            e.btn_id = btn;
            // Deliberately NO explicit height here (unlike `bar` above): `btn`
            // hugs its width to its label (parent `bar` is a row, no width
            // prop → intrinsic-measure path). A node with an explicit height
            // ALSO gets its children re-measured a second time, in
            // `measureChildrenPass`, against its own now-resolved width
            // (flexbox.zig) — for a box that hugs to fit exactly one text
            // child, that second pass re-shapes the text against its own
            // just-computed, now-too-tight width and wraps it (e.g. "Ver" ->
            // "Ve"/"r"). `bar` itself is safe with an explicit height because
            // its resolved width already spans every button, not just one —
            // but `btn` is a 1:1 fit, so it stays heightless here and gets
            // its height from `bar`'s cross-axis `stretch` instead, which
            // only resizes the box after measurement and never re-triggers
            // text shaping.
            try b.flexShrink(btn, 0);
            try b.padding(btn, 0, 12, 0, 12);
            try b.flexRow(btn);
            try b.alignItems(btn, .center);
            try clickableAuto(b, btn);
            try hoverableAuto(b, btn);
            // When embedded in a draggable caption, a click here must open
            // the menu, not start a window drag (the caption's drag region is an
            // ancestor of this button and would otherwise also see the mouse_down).
            try b.noDrag(btn);
            if (self.item_radius > 0) try b.radius(btn, self.item_radius);
            if (ctx.router) |r| {
                const h = ctx.handler(self, onButton);
                try r.onNode(btn, .click, h);
                try r.onNode(btn, .mouse_enter, h);
                try r.onNode(btn, .mouse_leave, h);
            }
            const lbl = try b.addText(e.label);
            try b.fontSize(lbl, 14);
            try b.flexShrink(lbl, 0);
            try b.textColor(lbl, self.theme.text.r, self.theme.text.g, self.theme.text.b);
            b.close(); // btn
        }
        b.close(); // bar

        // Each menu is an overlay sibling of the bar.
        for (self.entries.items) |e| try e.menu.build(ctx);

        // Button highlight: one fine effect, render-only (no rebuild). It
        // observes `hovered` and every menu's `is_open`, so ANY close path
        // (Escape, outside click, selection, switching menus) clears the
        // open highlight — there is no imperative paint to forget.
        // The effect only tracks the menus it saw on its first (tracked) run;
        // a later rebuild re-applies it untracked. When the set of buttons
        // changed (`addMenu` after the first build), recreate it so the new
        // menus' `is_open` is observed too.
        if (self.highlight_effect) |eff| {
            if (self.highlight_count != self.entries.items.len) {
                self.scope.destroyEffect(eff);
                self.highlight_effect = null;
            }
        }
        if (self.highlight_effect == null) {
            self.highlight_effect = try self.scope.createEffect(self, updateVisuals);
            self.highlight_count = self.entries.items.len;
        } else {
            const prev = signals.untrackedBegin();
            updateVisuals(self);
            signals.untrackedEnd(prev);
        }
    }

    /// M3 state layers over whatever the bar paints: the theme's `text` color
    /// at the hover opacity, and at the pressed opacity while the button's
    /// menu is open (the open menu wins over hover).
    fn updateVisuals(self: *MenuBar) void {
        const store = self.store orelse return;
        const hov = self.hovered.get();
        const on = self.theme.text;
        const SL = theme_mod.Theme.StateLayer;
        for (self.entries.items, 0..) |e, i| {
            const open = e.menu.is_open.get();
            if (e.btn_id == reg.NULL_NODE) continue;
            const a: f32 = if (open) SL.pressed.opacity() else if (hov == @as(i32, @intCast(i))) SL.hover.opacity() else 0.0;
            store.setStyle(e.btn_id, .background, props.PropValue.rgbA(on.r, on.g, on.b, a)) catch {};
        }
    }
};

// ── Accelerators ──────────────────────────────────────────────────────────────
//
// Moved to events.zig: the EventRouter now consumes the table itself on
// key_down via `router.setAccelerators(&accels)`, firing the matched action's
// handlers before focus routing. Re-exported here for existing imports.

pub const Accelerator = events.Accelerator;
pub const Accelerators = events.Accelerators;

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const ts = @import("test_support.zig");

fn testTheme() theme_mod.Theme {
    return .{
        .accent = .{ .r = 0, .g = 120, .b = 255 },
        .bg_input = .{ .r = 30, .g = 30, .b = 30 },
        .bg_surface = .{ .r = 50, .g = 50, .b = 50 },
        .text = .{ .r = 255, .g = 255, .b = 255 },
    };
}

/// Builds a menu with: Cut, Copy, (sep), Paste(disabled), (sep), Select All(checked).
/// Typed row handlers are registered during build() (no register() step).
fn buildTestMenu(env: *ts.Harness) !*Menu {
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    const m = try Menu.init(testing.allocator, "ctx");
    try m.addItem("Cut", "cut");
    try m.addItem("Copy", "copy");
    try m.addSeparator();
    try m.addItemEx(.{ .label = "Paste", .action_id = "paste", .enabled = false });
    try m.addSeparator();
    try m.addItemEx(.{ .label = "Select All", .action_id = "selall", .checked = true });
    // Build under an app root: node id 0 is "none"/root and is excluded from
    // typed by-node dispatch, so the menu's own nodes must not be node 0.
    const app_root = try bld.openBox();
    try m.build(&ctx);
    bld.close();
    _ = app_root;
    return m;
}

/// Routes an event to a menu row by item index (typed by-node dispatch).
fn clickRow(env: *ts.Harness, m: *Menu, idx: usize) void {
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = m.row_ids.items[idx] });
}
fn hoverRow(env: *ts.Harness, m: *Menu, idx: usize) void {
    _ = env.router.route(.{ .name = "mouse_enter", .id = "", .node_id = m.row_ids.items[idx] });
}

/// Captures the last on_select action + call count. Fields are static (shared
/// across tests), so each test resets `calls`/`last_len` before asserting.
const Probe = struct {
    var last: [32]u8 = undefined;
    var last_len: usize = 0;
    var calls: u32 = 0;
    const handler: events.Handler = .{ .ptr = null, .call = onSelect };
    fn onSelect(_: ?*anyopaque, ev: events.Event) void {
        std.mem.copyForwards(u8, &last, ev.id);
        last_len = ev.id.len;
        calls += 1;
    }
};

/// Instance-state host (no statics): proves each menu delivers to its OWN host.
const Host = struct {
    calls: u32 = 0,
    last: [32]u8 = undefined,
    last_len: usize = 0,
    last_name: []const u8 = "",
    last_node: reg.NodeId = 0,
    fn onSelect(self: *Host, ev: events.Event) void {
        std.mem.copyForwards(u8, &self.last, ev.id);
        self.last_len = ev.id.len;
        self.last_name = ev.name;
        self.last_node = ev.node_id;
        self.calls += 1;
    }
    fn action(self: *const Host) []const u8 {
        return self.last[0..self.last_len];
    }
};

test "Menu: two menus with two hosts each deliver to their own host" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    const a = try Menu.init(testing.allocator, "menu_a");
    defer a.deinit();
    try a.addItem("New", "file.new");
    const b = try Menu.init(testing.allocator, "menu_b");
    defer b.deinit();
    try b.addItem("Zoom", "view.zoom");

    var host_a: Host = .{};
    var host_b: Host = .{};
    a.on_select = ctx.handler(&host_a, Host.onSelect);
    b.on_select = ctx.handler(&host_b, Host.onSelect);

    const app_root = try bld.openBox();
    try a.build(&ctx);
    try b.build(&ctx);
    bld.close();
    _ = app_root;

    a.popup(0, 0, .pointer);
    clickRow(&env, a, 0);
    b.popup(0, 0, .pointer);
    clickRow(&env, b, 0);

    try testing.expectEqual(@as(u32, 1), host_a.calls);
    try testing.expectEqual(@as(u32, 1), host_b.calls);
    try testing.expectEqualStrings("file.new", host_a.action());
    try testing.expectEqualStrings("view.zoom", host_b.action());
}

test "Menu: mouse and keyboard selection deliver the identical select event" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    const m = try buildTestMenu(&env);
    defer m.deinit();

    var mouse: Host = .{};
    m.on_select = events.makeHandler(&mouse, Host.onSelect);
    m.popup(0, 0, .pointer);
    clickRow(&env, m, 1); // Copy

    var kbd: Host = .{};
    m.on_select = events.makeHandler(&kbd, Host.onSelect);
    m.popup(0, 0, .pointer);
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.down.code() });
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.down.code() });
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.enter.code() });

    try testing.expectEqual(@as(u32, 1), mouse.calls);
    try testing.expectEqual(@as(u32, 1), kbd.calls);
    try testing.expectEqualStrings("select", mouse.last_name);
    try testing.expectEqualStrings("select", kbd.last_name);
    try testing.expectEqualStrings("copy", mouse.action());
    try testing.expectEqualStrings("copy", kbd.action());
    try testing.expectEqual(m.row_ids.items[1], mouse.last_node);
    try testing.expectEqual(mouse.last_node, kbd.last_node);
}

test "Menu: on_select handler may reopen the menu (reentrancy)" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    const m = try buildTestMenu(&env);
    defer m.deinit();

    const Reopen = struct {
        var fired: bool = false;
        fn f(menu: *Menu, ev: events.Event) void {
            // Already closed when the handler runs.
            fired = std.mem.eql(u8, ev.id, "cut") and !menu.isOpen();
            menu.popup(40, 40, .pointer);
        }
    };
    Reopen.fired = false;
    m.on_select = events.makeHandler(m, Reopen.f);
    m.popup(0, 0, .pointer);
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.down.code() });
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.enter.code() });
    try testing.expect(Reopen.fired);
    try testing.expect(m.isOpen());
    try testing.expectEqual(@as(i32, -1), m.highlighted.peek());
}

/// A real mouse selection: the engine bubbles the row's `click` up to the
/// backdrop (the rows are its descendants), so route both, in that order.
fn clickRowBubbling(env: *ts.Harness, m: *Menu, idx: usize) void {
    clickRow(env, m, idx);
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = m.backdrop_id });
}

test "Menu: reopening from on_select survives the click bubbling to the backdrop" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    const m = try buildTestMenu(&env);
    defer m.deinit();

    const Reopen = struct {
        fn f(menu: *Menu, _: events.Event) void {
            menu.popup(40, 40, .pointer);
        }
    };
    m.on_select = events.makeHandler(m, Reopen.f);
    m.popup(0, 0, .pointer);
    clickRowBubbling(&env, m, 0);
    try testing.expect(m.isOpen()); // before the fix: closed by onDismiss

    // The suppression was one-shot: a genuine outside click still dismisses.
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = m.backdrop_id });
    try testing.expect(!m.isOpen());
}

test "Menu: a mouse selection that does not reopen leaves no stale dismiss suppression" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    const m = try buildTestMenu(&env);
    defer m.deinit();

    var host: Host = .{};
    m.on_select = events.makeHandler(&host, Host.onSelect);
    m.popup(0, 0, .pointer);
    clickRowBubbling(&env, m, 0); // the bubble consumes the suppression
    try testing.expectEqual(@as(u32, 1), host.calls);
    try testing.expect(!m.isOpen());

    // Reopened later by the host: the first outside click must close it.
    m.popup(0, 0, .pointer);
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = m.backdrop_id });
    try testing.expect(!m.isOpen());
}

test "Menu: Enter does not arm the dismiss suppression (no trailing click)" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    const m = try buildTestMenu(&env);
    defer m.deinit();

    const Reopen = struct {
        fn f(menu: *Menu, _: events.Event) void {
            menu.popup(40, 40, .pointer);
        }
    };
    m.on_select = events.makeHandler(m, Reopen.f);
    m.popup(0, 0, .pointer);
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.down.code() });
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.enter.code() });
    try testing.expect(m.isOpen());
    // The very next outside click is genuine and must dismiss.
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = m.backdrop_id });
    try testing.expect(!m.isOpen());
}

test "Menu: closed panel has zero height; popup positions + opens it" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const m = try buildTestMenu(&env);
    defer m.deinit();

    // Closed initially: panel + backdrop are zero-sized.
    try testing.expectApproxEqAbs(@as(f32, 0), env.store.getLayout(m.panel_id, .height).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), env.store.getLayout(m.backdrop_id, .width).?.dimension.value, 0.001);

    m.popup(150, 80, .pointer);
    try testing.expect(m.isOpen());
    try testing.expectApproxEqAbs(@as(f32, 150), env.store.getLayout(m.panel_id, .left).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 80), env.store.getLayout(m.panel_id, .top).?.dimension.value, 0.001);
    // Height = 2*PAD_Y + 4 item rows (Paste is disabled but still drawn) + 2 separators.
    const expected = PAD_Y * 2 + 4 * ROW_H + 2 * SEP_H;
    try testing.expectApproxEqAbs(expected, env.store.getLayout(m.panel_id, .height).?.dimension.value, 0.001);
    // Backdrop now covers the window.
    try testing.expectEqual(props.DimUnit.percent, env.store.getLayout(m.backdrop_id, .width).?.dimension.unit);
}

test "Menu: enabled items are clickable with their action id; separator has none, disabled still registers it (live re-enable, F-enabled-signal)" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const m = try buildTestMenu(&env);
    defer m.deinit();

    // items: [Cut, Copy, sep, Paste(disabled), sep, Select All]
    try testing.expectEqualStrings("cut", env.store.getModifier(m.row_ids.items[0], .clickable).?.string);
    try testing.expectEqualStrings("copy", env.store.getModifier(m.row_ids.items[1], .clickable).?.string);
    try testing.expectEqual(@as(?props.PropValue, null), env.store.getModifier(m.row_ids.items[2], .clickable)); // separator
    // Paste is build-disabled but still gets its clickable modifier + handler
    // registered — `onRowEvent` is what gates on `isEnabled()`, live, so a
    // signal flipping it back to enabled needs no rebuild to become clickable.
    try testing.expectEqualStrings("paste", env.store.getModifier(m.row_ids.items[3], .clickable).?.string);
    try testing.expectEqualStrings("selall", env.store.getModifier(m.row_ids.items[5], .clickable).?.string);

    // a11y `disabled` state mirrors build-time `enabled` for every item.
    try testing.expect(env.store.getModifier(m.row_ids.items[0], .disabled).?.boolean == false);
    try testing.expect(env.store.getModifier(m.row_ids.items[3], .disabled).?.boolean == true);
}

test "Menu: clicking an item fires on_select with its action id and closes" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const m = try buildTestMenu(&env);
    defer m.deinit();

    Probe.calls = 0;
    Probe.last_len = 0;
    m.on_select = Probe.handler;

    m.popup(10, 10, .pointer);
    clickRow(&env, m, 1); // Copy

    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expectEqualStrings("copy", Probe.last[0..Probe.last_len]);
    try testing.expect(!m.isOpen()); // selection closes the menu
    try testing.expectApproxEqAbs(@as(f32, 0), env.store.getLayout(m.panel_id, .height).?.dimension.value, 0.001);

    // A disabled item's handler is registered but `onRowEvent` bails on
    // `!isEnabled()`, so on_select stays put.
    m.popup(10, 10, .pointer);
    clickRow(&env, m, 3); // Paste (disabled)
    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expect(m.isOpen());
}

test "Menu: enabled_signal is live and symmetric — re-enabling a built-disabled item makes it clickable again with no rebuild" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    var enabled_sig = signals.Signal(bool).init(testing.allocator, false);
    defer enabled_sig.deinit();

    const m = try Menu.init(testing.allocator, "ctx2");
    defer m.deinit();
    try m.addItemEx(.{ .label = "Stop Recording", .action_id = "stop_rec", .enabled_signal = &enabled_sig });

    const app_root = try bld.openBox();
    try m.build(&ctx);
    bld.close();
    _ = app_root;

    // Built disabled: dimmed, a11y disabled, keyboard nav skips it, and a
    // click does nothing (onRowEvent's live isEnabled() check bails).
    try testing.expect(env.store.getModifier(m.row_ids.items[0], .disabled).?.boolean == true);
    try testing.expectEqual(@as(i32, -1), m.firstEnabled());

    Probe.calls = 0;
    m.on_select = Probe.handler;
    m.popup(10, 10, .pointer);
    clickRow(&env, m, 0);
    try testing.expectEqual(@as(u32, 0), Probe.calls);
    try testing.expect(m.isOpen()); // no selection happened, so nothing closed it

    // Flip the signal live — no rebuild — and the row must become clickable
    // and a11y-enabled immediately (live update, same path as
    // `checked_signal`'s `updateVisuals`).
    enabled_sig.set(true);
    try testing.expect(env.store.getModifier(m.row_ids.items[0], .disabled).?.boolean == false);
    try testing.expectEqual(@as(i32, 0), m.firstEnabled());

    clickRow(&env, m, 0);
    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expectEqualStrings("stop_rec", Probe.last[0..Probe.last_len]);
    try testing.expect(!m.isOpen());
}

test "Menu: a press bubbling to the backdrop does NOT dismiss; only a click (mouse_up) does" {
    // Regression for the "context menu unusable" bug: rows are descendants of the
    // backdrop, so pressing a row bubbles a `mouse_down` up to the backdrop. When
    // onDismiss reacted to mouse_down it tore the menu down (re-baking the hit list
    // without the rows) before the row's own `click` could land on mouse_up, so the
    // item action never fired. The unit tests missed it by dispatching `click`
    // directly, skipping the real mouse_down → frame → mouse_up sequence.
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const m = try buildTestMenu(&env);
    defer m.deinit();

    Probe.calls = 0;
    Probe.last_len = 0;
    m.on_select = Probe.handler;

    m.popup(10, 10, .pointer);
    try testing.expect(m.isOpen());

    // The press on a row bubbles a mouse_down up to the backdrop. It must NOT close
    // (the backdrop only handles `click`, i.e. mouse_up).
    _ = env.router.route(.{ .name = "mouse_down", .id = "", .node_id = m.backdrop_id });
    try testing.expect(m.isOpen());

    // The item's own click (mouse_up) then still lands → on_select fires + closes.
    clickRow(&env, m, 1); // Copy
    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expectEqualStrings("copy", Probe.last[0..Probe.last_len]);
    try testing.expect(!m.isOpen());

    // A genuine outside click (mouse_up on the backdrop) still dismisses.
    m.popup(10, 10, .pointer);
    try testing.expect(m.isOpen());
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = m.backdrop_id });
    try testing.expect(!m.isOpen());
}

test "Menu: backdrop click dismisses" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const m = try buildTestMenu(&env);
    defer m.deinit();

    m.popup(10, 10, .pointer);
    try testing.expect(m.isOpen());
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = m.backdrop_id });
    try testing.expect(!m.isOpen());
}

test "Menu: submenu opens to the side on hover/click; leaf selection closes the chain" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    // root: [Open, "Recent" ▸ submenu{ a.txt, b.txt }]
    const sub = try Menu.init(testing.allocator, "recent");
    defer sub.deinit();
    try sub.addItem("a.txt", "recent_a");
    try sub.addItem("b.txt", "recent_b");

    const root = try Menu.init(testing.allocator, "file");
    defer root.deinit();
    try root.addItem("Open", "open");
    try root.addSubmenu("Recent", sub);

    Probe.calls = 0;
    root.on_select = Probe.handler;

    const app_root0 = try bld.openBox();
    try root.build(&ctx);
    bld.close();
    _ = app_root0;

    // build() flags the child as a submenu (no own backdrop) + links the parent.
    try testing.expect(sub.is_submenu);
    try testing.expectEqual(root, sub.parent_menu.?);

    root.popup(20, 30, .pointer);
    try testing.expect(root.isOpen());
    try testing.expect(!sub.isOpen());

    // Hover the "Recent" row (item index 1) → submenu opens to the right of it.
    hoverRow(&env, root, 1);
    try testing.expect(sub.isOpen());
    try testing.expectEqual(sub, root.open_sub.?);
    // Positioned at parent.x + PANEL_W - 4, parent.y + rowOffset(1) (= PAD_Y + ROW_H).
    try testing.expectApproxEqAbs(20 + PANEL_W - 4, env.store.getLayout(sub.panel_id, .left).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(30 + PAD_Y + ROW_H, env.store.getLayout(sub.panel_id, .top).?.dimension.value, 0.001);

    // Click a leaf inside the submenu (b.txt = index 1) → fires on_select + closes chain.
    clickRow(&env, sub, 1);
    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expectEqualStrings("recent_b", Probe.last[0..Probe.last_len]);
    try testing.expect(!root.isOpen());
    try testing.expect(!sub.isOpen());
}

test "Menu: panel width is content-measured (min PANEL_W), wider for a longer label" {
    // Real solve (not store-only, per this file's "test geometry not the
    // store" convention) — proves `contentWidth` actually resolves to
    // a wider panel on screen for a long label, not just that the prop was set.
    var short_env = ts.Harness.init(testing.allocator);
    defer short_env.deinit();
    short_env.store.setRegistry(&short_env.registry);
    var short_bld = component.UIBuilder.init(&short_env.registry, &short_env.store);
    short_bld.theme = testTheme();
    var short_ctx = component.BuildContext.initWithRouter(&short_bld, &short_env.router);
    const short_root = try short_bld.openBox();
    const short_m = try Menu.init(testing.allocator, "short");
    defer short_m.deinit();
    try short_m.addItem("Go", "go");
    try short_m.build(&short_ctx);
    short_bld.close();
    short_m.popup(0, 0, .pointer);
    short_env.solve(short_root, 1000, 800);
    const short_w = short_env.geom(short_m.panel_id).width;
    // A one-word label measures below PANEL_W → clamped up to the minimum.
    try testing.expectApproxEqAbs(@as(f32, PANEL_W), short_w, 0.5);

    var long_env = ts.Harness.init(testing.allocator);
    defer long_env.deinit();
    long_env.store.setRegistry(&long_env.registry);
    var long_bld = component.UIBuilder.init(&long_env.registry, &long_env.store);
    long_bld.theme = testTheme();
    var long_ctx = component.BuildContext.initWithRouter(&long_bld, &long_env.router);
    const long_root = try long_bld.openBox();
    const long_m = try Menu.init(testing.allocator, "long");
    defer long_m.deinit();
    try long_m.addItem("Sincronizar colaboracion en tiempo real con el equipo", "sync");
    try long_m.build(&long_ctx);
    long_bld.close();
    long_m.popup(0, 0, .pointer);
    long_env.solve(long_root, 1000, 800);
    const long_w = long_env.geom(long_m.panel_id).width;

    try testing.expect(long_w > short_w);
    try testing.expect(long_w >= PANEL_W);

    // Closed → open → closed leaves the width stable (no stale hug from a
    // stretched-to-window measurement while the backdrop was 0-wide).
    long_m.close();
    long_env.solve(long_root, 1000, 800);
    long_m.popup(0, 0, .pointer);
    long_env.solve(long_root, 1000, 800);
    try testing.expectApproxEqAbs(long_w, long_env.geom(long_m.panel_id).width, 0.5);
}

test "Menu: shortcut chord paints right-aligned without changing row height" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);
    const root = try bld.openBox();

    const m = try Menu.init(testing.allocator, "shortcuts");
    defer m.deinit();
    try m.addItemEx(.{ .label = "Save", .action_id = "save", .shortcut = "Ctrl+S" });
    try m.build(&ctx);
    bld.close();
    m.popup(0, 0, .pointer);
    env.solve(root, 1000, 800);

    const row_geom = env.geom(m.row_ids.items[0]);
    try testing.expectApproxEqAbs(@as(f32, ROW_H), row_geom.height, 0.5);

    // Find the shortcut text node among the row's children by content.
    var shortcut_x: ?f32 = null;
    var child = env.registry.getNode(m.row_ids.items[0]).?.first_child;
    while (child != reg.NULL_NODE) {
        if (env.store.getTextContent(child)) |text| {
            if (std.mem.eql(u8, text, "Ctrl+S")) shortcut_x = env.geom(child).x;
        }
        child = env.registry.getNode(child).?.next_sibling;
    }
    try testing.expect(shortcut_x != null);
    // Right-aligned: its right edge lands at (or just inside) the row's own
    // right edge, not immediately after the label.
    const shortcut_geom_x = shortcut_x.?;
    try testing.expect(shortcut_geom_x > row_geom.x + row_geom.width * 0.4);
}

test "Menu: hovering a leaf collapses an open sibling submenu" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    const sub = try Menu.init(testing.allocator, "more");
    defer sub.deinit();
    try sub.addItem("Deep", "deep");

    const root = try Menu.init(testing.allocator, "root");
    defer root.deinit();
    try root.addSubmenu("More", sub); // index 0
    try root.addItem("Plain", "plain"); // index 1

    const app_root1 = try bld.openBox();
    try root.build(&ctx);
    bld.close();
    _ = app_root1;
    root.popup(0, 0, .pointer);

    hoverRow(&env, root, 0); // "More" submenu row
    try testing.expect(sub.isOpen());
    // Moving onto the plain leaf collapses the submenu.
    hoverRow(&env, root, 1); // "Plain"
    try testing.expect(!sub.isOpen());
    try testing.expect(root.isOpen()); // root stays open
}

test "Menu: keyboard nav skips separators + disabled, wraps, and activates" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const m = try buildTestMenu(&env);
    defer m.deinit();

    m.on_select = Probe.handler;
    m.popup(0, 0, .pointer);

    // items idx: 0 Cut, 1 Copy, 2 sep, 3 Paste(disabled), 4 sep, 5 Select All.
    m.moveHighlight(1); // -1 → 0 (Cut)
    try testing.expectEqual(@as(i32, 0), m.highlighted.peek());
    m.moveHighlight(1); // 0 → 1 (Copy)
    try testing.expectEqual(@as(i32, 1), m.highlighted.peek());
    m.moveHighlight(1); // 1 → skip sep(2)+Paste(3,disabled)+sep(4) → 5 (Select All)
    try testing.expectEqual(@as(i32, 5), m.highlighted.peek());
    m.moveHighlight(1); // 5 → wrap → 0 (Cut)
    try testing.expectEqual(@as(i32, 0), m.highlighted.peek());
    m.moveHighlight(-1); // 0 → wrap up → 5 (Select All)
    try testing.expectEqual(@as(i32, 5), m.highlighted.peek());

    m.activateHighlighted();
    try testing.expectEqualStrings("selall", Probe.last[0..Probe.last_len]);
    try testing.expect(!m.isOpen());
}

test "Menu: virtual_focus_target on the panel tracks the highlighted row (roving focus)" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const m = try buildTestMenu(&env);
    defer m.deinit();

    // No highlight yet: cleared (-1) so the ring falls back to the panel.
    m.popup(0, 0, .keyboard);
    var v = env.store.getModifier(m.panel_id, .virtual_focus_target).?;
    try testing.expectEqual(@as(f32, -1), v.number);

    // Highlight moves to Cut (row 0): the panel's redirect target follows it.
    m.moveHighlight(1);
    try testing.expectEqual(@as(i32, 0), m.highlighted.peek());
    v = env.store.getModifier(m.panel_id, .virtual_focus_target).?;
    try testing.expectEqual(@as(f32, @floatFromInt(m.row_ids.items[0])), v.number);

    // Moves again, to Copy (row 1): follows again, not stuck on row 0.
    m.moveHighlight(1);
    try testing.expectEqual(@as(i32, 1), m.highlighted.peek());
    v = env.store.getModifier(m.panel_id, .virtual_focus_target).?;
    try testing.expectEqual(@as(f32, @floatFromInt(m.row_ids.items[1])), v.number);

    // Closing clears it again (nothing to highlight in a closed menu).
    m.close();
    v = env.store.getModifier(m.panel_id, .virtual_focus_target).?;
    try testing.expectEqual(@as(f32, -1), v.number);
}

test "Menu: key_down on the panel drives nav — ↓↓ Enter selects, Escape closes" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const m = try buildTestMenu(&env);
    defer m.deinit();

    Probe.calls = 0;
    Probe.last_len = 0;
    m.on_select = Probe.handler;

    // The panel is focusable so the focus scope can land on it.
    try testing.expectEqualStrings("ctx__panel", env.store.getModifier(m.panel_id, .focusable).?.string);

    m.popup(10, 10, .pointer);
    // ↓ ↓ → highlight lands on Copy (index 1); Enter activates it.
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.down.code() });
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.down.code() });
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.enter.code() });
    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expectEqualStrings("copy", Probe.last[0..Probe.last_len]);
    try testing.expect(!m.isOpen());

    // Escape closes without selecting.
    m.popup(10, 10, .pointer);
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.escape.code() });
    try testing.expect(!m.isOpen());
    try testing.expectEqual(@as(u32, 1), Probe.calls);

    // Keys on a closed menu are ignored.
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.enter.code() });
    try testing.expectEqual(@as(u32, 1), Probe.calls);
}

test "Menu: popup pushes a focus scope on the panel; close pops it (once)" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    const FS = struct {
        var pushes: u32 = 0;
        var pops: u32 = 0;
        var last_root: reg.NodeId = reg.NULL_NODE;
        fn push(_: *anyopaque, root: reg.NodeId, _: events.FocusOrigin) bool {
            pushes += 1;
            last_root = root;
            return true;
        }
        fn pop(_: *anyopaque) bool {
            pops += 1;
            return true;
        }
    };
    FS.pushes = 0;
    FS.pops = 0;
    var dummy: u8 = 0;
    bld.focus_scope = .{ .ctx = @ptrCast(&dummy), .pushFn = FS.push, .popFn = FS.pop };
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    const m = try Menu.init(testing.allocator, "fsm");
    defer m.deinit();
    try m.addItem("One", "one");
    try m.build(&ctx);

    m.popup(5, 5, .pointer);
    try testing.expectEqual(@as(u32, 1), FS.pushes);
    try testing.expectEqual(m.panel_id, FS.last_root);

    m.close();
    try testing.expectEqual(@as(u32, 1), FS.pops);
    m.close(); // idempotent: no double pop
    try testing.expectEqual(@as(u32, 1), FS.pops);

    // Escape (key path) also pops exactly once.
    m.popup(5, 5, .pointer);
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = m.panel_id, .key_code = events.Key.escape.code() });
    try testing.expectEqual(@as(u32, 2), FS.pushes);
    try testing.expectEqual(@as(u32, 2), FS.pops);
}

test "Menu: →/← open and close the highlighted submenu; Enter inside selects through the chain" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    const sub = try Menu.init(testing.allocator, "recent");
    defer sub.deinit();
    try sub.addItem("a.txt", "recent_a");
    try sub.addItem("b.txt", "recent_b");

    const root = try Menu.init(testing.allocator, "file");
    defer root.deinit();
    try root.addItem("Open", "open"); // index 0
    try root.addSubmenu("Recent", sub); // index 1

    Probe.calls = 0;
    root.on_select = Probe.handler;

    // Overlays are built UNDER the app root, as in real use — top-level builds
    // would positionally alias root's and sub's nodes (the builder reuses the
    // first root node), cross-wiring their key handlers.
    const app_root = try bld.openBox();
    try bld.width(app_root, 100, .percent);
    try bld.height(app_root, 600, .px);
    try root.build(&ctx);
    bld.close();
    root.popup(0, 0, .pointer);

    const key = struct {
        fn hit(r: *events.EventRouter, node: reg.NodeId, code: u32) void {
            _ = r.route(.{ .name = "key_down", .id = "", .node_id = node, .key_code = code });
        }
    }.hit;

    // ↓ ↓ highlights "Recent"; → opens it with its first item highlighted.
    key(&env.router, root.panel_id, events.Key.down.code());
    key(&env.router, root.panel_id, events.Key.down.code());
    try testing.expectEqual(@as(i32, 1), root.highlighted.peek());
    key(&env.router, root.panel_id, events.Key.right.code());
    try testing.expect(sub.isOpen());
    try testing.expectEqual(@as(i32, 0), sub.highlighted.peek());

    // ← closes the submenu; keyboard control returns to the root.
    key(&env.router, root.panel_id, events.Key.left.code());
    try testing.expect(!sub.isOpen());
    try testing.expect(root.isOpen());

    // Enter on the highlighted submenu row also opens it; ↓ Enter selects b.txt
    // through the chain (keys still arrive at the ROOT panel — focus is trapped
    // there — and are delegated to the deepest open submenu).
    key(&env.router, root.panel_id, events.Key.enter.code());
    try testing.expect(sub.isOpen());
    key(&env.router, root.panel_id, events.Key.down.code());
    key(&env.router, root.panel_id, events.Key.enter.code());
    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expectEqualStrings("recent_b", Probe.last[0..Probe.last_len]);
    try testing.expect(!root.isOpen());
    try testing.expect(!sub.isOpen());
}

test "MenuBar: clicking a button opens its menu below it; switching closes the other; re-click toggles" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    const file = try Menu.init(testing.allocator, "file");
    defer file.deinit();
    try file.addItem("New", "new");
    const edit = try Menu.init(testing.allocator, "edit");
    defer edit.deinit();
    try edit.addItem("Undo", "undo");

    const bar = try MenuBar.init(testing.allocator, "mbar");
    defer bar.deinit();
    try bar.addMenu("File", file);
    try bar.addMenu("Edit", edit);

    // Overlays (bar + menus) are built UNDER the app root, as in real use — not as
    // separate root trees (the builder reuses the first root node otherwise).
    const app_root = try bld.openBox();
    try bld.width(app_root, 100, .percent);
    try bld.height(app_root, 600, .px);
    try bar.build(&ctx);
    bld.close();

    // Resolve geometry so the bar can place each menu under its button.
    var le = layout.LayoutEngine.init(&env.registry, &env.store, null);
    le.solve(app_root, 0, 0, 800, 600);

    const clickBtn = struct {
        fn go(r: *events.EventRouter, b: *MenuBar, i: usize) void {
            _ = r.route(.{ .name = "click", .id = "", .node_id = b.entries.items[i].btn_id });
        }
    }.go;

    // Click File → File menu opens directly below the bar.
    clickBtn(&env.router, bar, 0);
    try testing.expect(file.isOpen());
    try testing.expectApproxEqAbs(BAR_H, env.store.getLayout(file.panel_id, .top).?.dimension.value, 0.001);

    // Click Edit → File closes, Edit opens (one at a time).
    clickBtn(&env.router, bar, 1);
    try testing.expect(!file.isOpen());
    try testing.expect(edit.isOpen());

    // Re-click Edit → toggles it closed.
    clickBtn(&env.router, bar, 1);
    try testing.expect(!edit.isOpen());
}

/// Builds the bar (and its menus) under a 100% x 600 px app root; returns the root.
fn buildTestBar(bld: *component.UIBuilder, ctx: *component.BuildContext, bar: *MenuBar) !reg.NodeId {
    const app_root = try bld.openBox();
    try bld.width(app_root, 100, .percent);
    try bld.height(app_root, 600, .px);
    try bar.build(ctx);
    bld.close();
    return app_root;
}

fn btnAlpha(env: *ts.Harness, bar: *MenuBar, i: usize) f32 {
    return env.store.getStyle(bar.entries.items[i].btn_id, .background).?.color.a;
}

test "MenuBar: hover and open-menu highlight are a fine effect cleared by every close path" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    const file = try Menu.init(testing.allocator, "file");
    defer file.deinit();
    try file.addItem("New", "new");
    const edit = try Menu.init(testing.allocator, "edit");
    defer edit.deinit();
    try edit.addItem("Undo", "undo");
    const bar = try MenuBar.init(testing.allocator, "mbar");
    defer bar.deinit();
    try bar.addMenu("File", file);
    try bar.addMenu("Edit", edit);
    const root = try buildTestBar(&bld, &ctx, bar);
    env.solve(root, 800, 600);

    const SL = theme_mod.Theme.StateLayer;
    const hov = SL.hover.opacity();
    const pressed = SL.pressed.opacity();
    const File = bar.entries.items[0].btn_id;
    try testing.expectApproxEqAbs(@as(f32, 0), btnAlpha(&env, bar, 0), 0.001);

    for (env.registry.nodes.items) |*n| {
        n.layout_dirty = false;
        n.render_dirty = false;
    }
    // Hover → state layer, render-only.
    _ = env.router.route(.{ .name = "mouse_enter", .id = "", .node_id = File });
    try testing.expectApproxEqAbs(hov, btnAlpha(&env, bar, 0), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), btnAlpha(&env, bar, 1), 0.001);
    var any_layout = false;
    for (env.registry.nodes.items) |*n| {
        if (n.alive and n.layout_dirty) any_layout = true;
    }
    try testing.expect(!any_layout);

    // Click → open highlight (wins over hover).
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = File });
    try testing.expect(file.isOpen());
    try testing.expectApproxEqAbs(pressed, btnAlpha(&env, bar, 0), 0.01);

    // Escape closes the menu WITHOUT going through the bar → highlight drops
    // back to hover.
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = file.panel_id, .key_code = events.Key.escape.code() });
    try testing.expect(!file.isOpen());
    try testing.expectApproxEqAbs(hov, btnAlpha(&env, bar, 0), 0.01);

    // Leave → idle.
    _ = env.router.route(.{ .name = "mouse_leave", .id = "", .node_id = File });
    try testing.expectApproxEqAbs(@as(f32, 0), btnAlpha(&env, bar, 0), 0.001);

    // Open Edit, then an outside click on the backdrop closes it → no highlight.
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = bar.entries.items[1].btn_id });
    try testing.expectApproxEqAbs(pressed, btnAlpha(&env, bar, 1), 0.01);
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = edit.backdrop_id });
    try testing.expect(!edit.isOpen());
    try testing.expectApproxEqAbs(@as(f32, 0), btnAlpha(&env, bar, 1), 0.001);
}

test "MenuBar: item_radius rounds the buttons and item_gap spaces them; defaults unchanged" {
    for ([_]bool{ false, true }) |custom| {
        var env = ts.Harness.init(testing.allocator);
        defer env.deinit();
        env.store.setRegistry(&env.registry);
        var bld = component.UIBuilder.init(&env.registry, &env.store);
        bld.theme = testTheme();
        var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

        const file = try Menu.init(testing.allocator, "file");
        defer file.deinit();
        const edit = try Menu.init(testing.allocator, "edit");
        defer edit.deinit();
        const bar = try MenuBar.init(testing.allocator, "mbar");
        defer bar.deinit();
        try bar.addMenu("File", file);
        try bar.addMenu("Edit", edit);
        bar.height = 26;
        if (custom) {
            bar.item_radius = 4;
            bar.item_gap = 6;
        }
        const root = try buildTestBar(&bld, &ctx, bar);
        env.solve(root, 800, 600);

        const b0 = bar.entries.items[0].btn_id;
        const g0 = env.geom(b0);
        const g1 = env.geom(bar.entries.items[1].btn_id);
        // Height still comes from MenuBar.height in both cases.
        try testing.expectApproxEqAbs(@as(f32, 26), g0.height, 0.01);
        try testing.expectApproxEqAbs(@as(f32, 26), g1.height, 0.01);
        if (custom) {
            try testing.expectApproxEqAbs(@as(f32, 4), env.store.getStyle(b0, .radius).?.dimension.value, 0.001);
            try testing.expectApproxEqAbs(@as(f32, 6), g1.x - (g0.x + g0.width), 0.01);
        } else {
            try testing.expect(env.store.getStyle(b0, .radius) == null);
            try testing.expectApproxEqAbs(@as(f32, 0), g1.x - (g0.x + g0.width), 0.01);
        }
    }
}

test "MenuBar: a menu added after the first build still gets its open highlight" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    const file = try Menu.init(testing.allocator, "file");
    defer file.deinit();
    try file.addItem("New", "new");
    const debug = try Menu.init(testing.allocator, "debug");
    defer debug.deinit();
    try debug.addItem("Start", "start");
    const bar = try MenuBar.init(testing.allocator, "mbar");
    defer bar.deinit();
    try bar.addMenu("File", file);
    _ = try buildTestBar(&bld, &ctx, bar);

    // Add a menu later and rebuild the same tree.
    try bar.addMenu("Debug", debug);
    bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    ctx = component.BuildContext.initWithRouter(&bld, &env.router);
    const root = try buildTestBar(&bld, &ctx, bar);
    env.solve(root, 800, 600);

    const pressed = theme_mod.Theme.StateLayer.pressed.opacity();
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = bar.entries.items[1].btn_id });
    try testing.expect(debug.isOpen());
    try testing.expectApproxEqAbs(pressed, btnAlpha(&env, bar, 1), 0.01);
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = debug.panel_id, .key_code = events.Key.escape.code() });
    try testing.expect(!debug.isOpen());
    try testing.expectApproxEqAbs(@as(f32, 0), btnAlpha(&env, bar, 1), 0.001);
}

test "MenuBar: in a 44 px caption, the last button's wide menu opens below it, right-aligned, inside the window" {
    // The titlebar_proto shape: a hugged MenuBar at the right end of a 44 px
    // caption row, so its menus are mounted INSIDE the caption. Bounds must be
    // the window: bounded by the caption, a taller panel fits neither below
    // nor above and would be pinned over the bar.
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);

    const file = try Menu.init(testing.allocator, "file");
    defer file.deinit();
    try file.addItem("New", "new");
    const view = try Menu.init(testing.allocator, "view");
    defer view.deinit();
    view.max_width = 400;
    try view.addItem("A label long enough to need the whole four hundred pixel panel width", "x");
    try view.addItem("Zoom", "zoom");
    const bar = try MenuBar.init(testing.allocator, "mbar");
    defer bar.deinit();
    bar.height = 44;
    bar.hug = true;
    try bar.addMenu("File", file);
    try bar.addMenu("View", view);

    const root = try bld.openBox();
    try bld.width(root, 800, .px);
    try bld.height(root, 600, .px);
    try bld.flexColumn(root);
    const caption = try bld.openBox();
    try bld.flexRow(caption);
    try bld.height(caption, 44, .px);
    const spacer = try bld.openBox();
    try bld.flexGrow(spacer, 1);
    bld.close();
    try bar.build(&ctx);
    bld.close(); // caption
    bld.close(); // root
    env.solve(root, 800, 600);

    const btn = bar.entries.items[1].btn_id;
    const b = env.geom(btn);
    try testing.expect(b.x + b.width > 800 - 100); // really at the right edge

    _ = env.router.route(.{ .name = "click", .id = "", .node_id = btn });
    env.solve(root, 800, 600);
    try testing.expect(view.isOpen());
    const p = env.geom(view.panel_id);
    try expectInside(p, 800, 600);
    try testing.expectApproxEqAbs(@as(f32, 44), p.y, 0.5);
    try testing.expectApproxEqAbs(b.x + b.width, p.x + p.width, 0.5);
}
test "Menu: a window resize closes the open menu; opening it does not" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);
    const m = try Menu.init(testing.allocator, "rs");
    defer m.deinit();
    try m.addItem("One", "one");
    const root = try bld.openBox();
    try bld.width(root, 100, .percent);
    try bld.height(root, 100, .percent);
    try m.build(&ctx);
    bld.close();
    env.solve(root, 800, 600);

    // Opening grows the backdrop 0 → full; that report must not close it.
    m.popupWindow(100, 100, .pointer);
    _ = try env.frame(root, 800, 600);
    try testing.expect(m.isOpen());
    _ = env.router.route(.{ .name = "tick", .id = "" });
    try testing.expect(m.isOpen());

    // Same frame as the resize: the backdrop report closes it.
    _ = try env.frame(root, 700, 600);
    try testing.expect(!m.isOpen());
}

test "Menu: a height-only resize closes a menu in a fixed-height caption by the next tick" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);
    const m = try Menu.init(testing.allocator, "cap");
    defer m.deinit();
    try m.addItem("One", "one");
    const root = try bld.openBox();
    try bld.width(root, 100, .percent);
    try bld.height(root, 100, .percent);
    try bld.flexColumn(root);
    const caption = try bld.openBox();
    try bld.height(caption, 44, .px);
    try m.build(&ctx);
    bld.close();
    bld.close();
    env.solve(root, 800, 600);

    m.popupWindow(100, 44, .pointer);
    _ = try env.frame(root, 800, 600);
    // The caption (the backdrop's container) keeps 800x44: no resize report.
    try testing.expectEqual(@as(usize, 0), try env.frame(root, 800, 500));
    try testing.expect(m.isOpen());
    _ = env.router.route(.{ .name = "tick", .id = "" });
    try testing.expect(!m.isOpen());
}

test "Accelerators: chord lookup respects every modifier" {
    var acc = Accelerators.init(testing.allocator);
    defer acc.deinit();

    // Distinguishable bodies (not both empty no-ops) so the `call` pointers below
    // can't theoretically fold to the same address under identical-code-folding.
    const Tag = struct {
        var saves: u32 = 0;
        var redos: u32 = 0;
        fn save(_: ?*anyopaque, _: events.Event) void {
            saves += 1;
        }
        fn redo(_: ?*anyopaque, _: events.Event) void {
            redos += 1;
        }
    };
    try acc.add(.{ .key_code = 'S', .ctrl = true, .handler = .{ .ptr = null, .call = Tag.save } });
    try acc.add(.{ .key_code = 'Z', .ctrl = true, .shift = true, .handler = .{ .ptr = null, .call = Tag.redo } });

    try testing.expectEqual(Tag.save, acc.match('S', true, false, false).?.call);
    try testing.expectEqual(Tag.redo, acc.match('Z', true, true, false).?.call);
    // Wrong / missing modifiers → no match.
    try testing.expectEqual(@as(?events.Handler, null), acc.match('S', false, false, false));
    try testing.expectEqual(@as(?events.Handler, null), acc.match('Z', true, false, false));
    try testing.expectEqual(@as(?events.Handler, null), acc.match('X', true, false, false));
}

/// Host component that mounts a Menu inside its own tracked build — the shape
/// of an app root that builds its context menu every frame.
const MenuHost = struct {
    var builds: u32 = 0;
    menu: *Menu,
    pub fn build(self: *MenuHost, ctx: *component.BuildContext) !void {
        builds += 1;
        const n = try ctx.builder.openNodeKeyed(.box, null);
        try ctx.mount(self.menu);
        ctx.builder.close();
        _ = n;
    }
};

test "Menu: popup/close/hover don't re-run the build of the component that mounts it" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();

    const m = try Menu.init(testing.allocator, "ctx");
    defer m.deinit();
    try m.addItem("Delete", "delete");

    var scope = signals.Scope.init(testing.allocator);
    defer scope.deinit();
    var host = MenuHost{ .menu = m };
    MenuHost.builds = 0;

    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = testTheme();
    var ctx = component.BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountReactive(&scope, &host);
    b.close();
    try testing.expectEqual(@as(u32, 1), MenuHost.builds);

    // Re-mount once more (a parent-driven rebuild) — the re-apply path.
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountReactive(&scope, &host);
    b.close();
    try testing.expectEqual(@as(u32, 2), MenuHost.builds);

    // Menu state changes repaint through the Menu's own effect only.
    m.popup(10, 10, .pointer);
    m.highlighted.set(0);
    m.close();
    try testing.expectEqual(@as(u32, 2), MenuHost.builds);
    // ...and the visuals still follow (closed → zero-height panel).
    try testing.expectApproxEqAbs(@as(f32, 0), env.store.getLayout(m.panel_id, .height).?.dimension.value, 0.001);
}

test "Menu.popupWindow maps window coords into the menu's containing block" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();

    const m = try Menu.init(testing.allocator, "ctx");
    defer m.deinit();
    try m.addItem("Delete", "delete");

    // root (800x600, column) → 40px caption → container holding the menu.
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = testTheme();
    var ctx = component.BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try b.width(root, 800, .px);
    try b.height(root, 600, .px);
    try b.flexColumn(root);
    const cap = try b.openNodeKeyed(.box, null);
    try b.height(cap, 40, .px);
    b.close();
    const holder = try b.openNodeKeyed(.box, null);
    try b.flexGrow(holder, 1);
    try ctx.mount(m);
    b.close();
    b.close();
    env.solve(root, 800, 600);

    m.popupWindow(120, 90, .pointer);
    env.solve(root, 800, 600);
    try testing.expectApproxEqAbs(@as(f32, 50), env.store.getLayout(m.panel_id, .top).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 120), env.geom(m.panel_id).x, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 90), env.geom(m.panel_id).y, 0.5);
}

// ── Radio items, headers, anchored popup (the "selector with actions" parts) ──

/// Run-configuration picker: header, three radio items bound to `sel`, a
/// separator and one command row — the composition docs/FRAMEWORK_API.md
/// documents as "Selector with actions".
fn buildSelectorMenu(env: *ts.Harness, sel: *signals.Signal(usize)) !*Menu {
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);
    const m = try Menu.init(testing.allocator, "runcfg");
    try m.addHeader("Configurations");
    try m.addRadio("App", "", sel, 0);
    try m.addRadio("Tests", "", sel, 1);
    try m.addRadio("Bench", "", sel, 2);
    try m.addSeparator();
    try m.addItem("Edit Configurations...", "edit_configs");
    const app_root = try bld.openBox();
    try m.build(&ctx);
    bld.close();
    _ = app_root;
    return m;
}

test "Menu radio: bullet follows the group live; choosing writes the group, then on_select" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var sel = signals.Signal(usize).init(testing.allocator, 2);
    defer sel.deinit();
    const m = try buildSelectorMenu(&env, &sel);
    defer m.deinit();
    Probe.calls = 0;
    m.on_select = Probe.handler;

    try testing.expectEqualStrings("    ", env.store.getTextContent(m.check_ids.items[1]).?);
    try testing.expectEqualStrings("\u{2022}  ", env.store.getTextContent(m.check_ids.items[3]).?);

    // A programmatic write moves the bullet with no rebuild.
    sel.set(0);
    try testing.expectEqualStrings("\u{2022}  ", env.store.getTextContent(m.check_ids.items[1]).?);
    try testing.expectEqualStrings("    ", env.store.getTextContent(m.check_ids.items[3]).?);
    try testing.expectEqual(true, env.store.getModifier(m.row_ids.items[1], .checked).?.boolean);

    m.popup(0, 0, .pointer);
    clickRow(&env, m, 2); // "Tests" (row 0 is the header)
    try testing.expectEqual(@as(usize, 1), sel.peek());
    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expect(!m.isOpen());
}

test "Menu action row next to radios: fires its own id, closes, leaves the selection alone" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var sel = signals.Signal(usize).init(testing.allocator, 2);
    defer sel.deinit();
    const m = try buildSelectorMenu(&env, &sel);
    defer m.deinit();
    Probe.calls = 0;
    m.on_select = Probe.handler;

    m.popup(0, 0, .pointer);
    clickRow(&env, m, 5);
    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expectEqualStrings("edit_configs", Probe.last[0..Probe.last_len]);
    try testing.expect(!m.isOpen());
    try testing.expectEqual(@as(usize, 2), sel.peek());
}

test "Menu header: not clickable, skipped by keyboard nav, counted in panel height" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var sel = signals.Signal(usize).init(testing.allocator, 0);
    defer sel.deinit();
    const m = try buildSelectorMenu(&env, &sel);
    defer m.deinit();
    Probe.calls = 0;
    m.on_select = Probe.handler;

    m.popup(0, 0, .pointer);
    clickRow(&env, m, 0);
    try testing.expectEqual(@as(u32, 0), Probe.calls);
    try testing.expect(m.isOpen());

    try testing.expectEqual(@as(i32, 1), m.firstEnabled());
    m.highlighted.set(1);
    m.moveHighlight(-1); // wraps past the header to the last item
    try testing.expectEqual(@as(i32, 5), m.highlighted.peek());

    const want = PAD_Y * 2 + HEADER_H + 4 * ROW_H + SEP_H;
    try testing.expectApproxEqAbs(want, env.store.getLayout(m.panel_id, .height).?.dimension.value, 0.001);
}

test "Menu.popupBelow docks the panel under the anchor's resolved geometry" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);
    const m = try Menu.init(testing.allocator, "anchored");
    defer m.deinit();
    try m.addItem("One", "one");

    const root = try bld.openBox();
    try bld.width(root, 800, .px);
    try bld.height(root, 600, .px);
    try bld.padding(root, 40, 0, 0, 60);
    const anchor = try bld.openBox();
    try bld.width(anchor, 120, .px);
    try bld.height(anchor, 26, .px);
    bld.close();
    try m.build(&ctx);
    bld.close();
    env.solve(root, 800, 600);

    m.popupBelow(anchor, 2, .pointer);
    env.solve(root, 800, 600);
    const a = env.geom(anchor);
    const p = env.geom(m.panel_id);
    try testing.expectApproxEqAbs(a.x, p.x, 0.5);
    try testing.expectApproxEqAbs(a.y + a.height + 2, p.y, 0.5);
}

// ── Keeping popups inside the window ──

/// 800x600 root with an absolutely placed 80x26 anchor at (ax, ay) and `m`
/// mounted next to it; solved once.
fn buildEdgeScene(env: *ts.Harness, m: *Menu, ax: f32, ay: f32) !struct { root: reg.NodeId, anchor: reg.NodeId } {
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);
    const root = try bld.openBox();
    try bld.width(root, 800, .px);
    try bld.height(root, 600, .px);
    const anchor = try bld.openBox();
    try env.store.setLayout(anchor, .position, .{ .keyword = .absolute });
    try env.store.setLayout(anchor, .left, .{ .dimension = .{ .value = ax, .unit = .px } });
    try env.store.setLayout(anchor, .top, .{ .dimension = .{ .value = ay, .unit = .px } });
    try bld.width(anchor, 80, .px);
    try bld.height(anchor, 26, .px);
    bld.close();
    try m.build(&ctx);
    bld.close();
    env.solve(root, 800, 600);
    return .{ .root = root, .anchor = anchor };
}

fn expectInside(p: anytype, w: f32, h: f32) !void {
    try testing.expect(p.x >= -0.5 and p.y >= -0.5);
    try testing.expect(p.x + p.width <= w + 0.5);
    try testing.expect(p.y + p.height <= h + 0.5);
}

test "Menu.popupBelow: a 400 px menu 100 px from the right edge opens fully inside, right-aligned with the anchor" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const m = try Menu.init(testing.allocator, "wide");
    defer m.deinit();
    m.max_width = 400;
    try m.addItem("A label long enough to need the whole four hundred pixel panel width", "x");
    // Anchor's right edge sits 100 px from the window's right edge.
    const s = try buildEdgeScene(&env, m, 620, 40);

    m.popupBelow(s.anchor, 2, .pointer);
    env.solve(s.root, 800, 600);
    const a = env.geom(s.anchor);
    const p = env.geom(m.panel_id);
    try testing.expectApproxEqAbs(@as(f32, 400), p.width, 0.5);
    try expectInside(p, 800, 600);
    try testing.expectApproxEqAbs(a.x + a.width, p.x + p.width, 0.5);
    try testing.expectApproxEqAbs(a.y + a.height + 2, p.y, 0.5);
}

test "Menu.popupBelow: near the bottom edge it opens above the anchor" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const m = try Menu.init(testing.allocator, "low");
    defer m.deinit();
    try m.addItem("One", "one");
    try m.addItem("Two", "two");
    try m.addItem("Three", "three");
    const s = try buildEdgeScene(&env, m, 100, 560);

    m.popupBelow(s.anchor, 2, .pointer);
    env.solve(s.root, 800, 600);
    const a = env.geom(s.anchor);
    const p = env.geom(m.panel_id);
    try expectInside(p, 800, 600);
    try testing.expectApproxEqAbs(a.y - 2, p.y + p.height, 0.5);
    try testing.expectApproxEqAbs(a.x, p.x, 0.5);
}

test "Menu.popupWindow: a context menu at the bottom-right corner flips left/up, never negative" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const m = try Menu.init(testing.allocator, "corner");
    defer m.deinit();
    try m.addItem("Cut", "cut");
    try m.addItem("Copy", "copy");
    const s = try buildEdgeScene(&env, m, 0, 0);

    m.popupWindow(790, 590, .pointer);
    env.solve(s.root, 800, 600);
    const p = env.geom(m.panel_id);
    try expectInside(p, 800, 600);
    try testing.expectApproxEqAbs(@as(f32, 790), p.x + p.width, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 590), p.y + p.height, 0.5);

    // Wider than the window: pinned to x = 0, not negative.
    m.close();
    try env.store.setLayout(m.panel_id, .width, .{ .dimension = .{ .value = 1000, .unit = .px } });
    env.solve(s.root, 800, 600);
    m.popupWindow(400, 10, .pointer);
    env.solve(s.root, 800, 600);
    try testing.expectApproxEqAbs(@as(f32, 0), env.geom(m.panel_id).x, 0.5);
}

test "Menu submenu: against the right edge it cascades left, and its submenu keeps going left" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const root_m = try Menu.init(testing.allocator, "r");
    defer root_m.deinit();
    const sub = try Menu.init(testing.allocator, "s");
    defer sub.deinit();
    const sub2 = try Menu.init(testing.allocator, "s2");
    defer sub2.deinit();
    try sub2.addItem("Leaf", "leaf");
    try sub.addSubmenu("Deeper", sub2);
    try root_m.addSubmenu("More", sub);

    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);
    const root = try bld.openBox();
    try bld.width(root, 800, .px);
    try bld.height(root, 600, .px);
    try root_m.build(&ctx);
    try sub.build(&ctx);
    try sub2.build(&ctx);
    bld.close();
    env.solve(root, 800, 600);

    // Root fits (its right edge 10 px from the window's), its submenu can't.
    const rw = env.geom(root_m.panel_id).width;
    root_m.popup(790 - rw, 20, .pointer);
    env.solve(root, 800, 600);
    root_m.openSubAt(sub, 0, .keyboard);
    env.solve(root, 800, 600);
    const rp = env.geom(root_m.panel_id);
    const sp = env.geom(sub.panel_id);
    try expectInside(sp, 800, 600);
    try testing.expectApproxEqAbs(rp.x + 4, sp.x + sp.width, 0.5);

    sub.openSubAt(sub2, 0, .keyboard);
    env.solve(root, 800, 600);
    const s2 = env.geom(sub2.panel_id);
    try expectInside(s2, 800, 600);
    try testing.expectApproxEqAbs(sp.x + 4, s2.x + s2.width, 0.5);
}

test "Menu.popupWindow: in a scrolled container the menu stays inside the visible area" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.wire();
    const m = try Menu.init(testing.allocator, "scrolled");
    defer m.deinit();
    try m.addItem("One", "one");

    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);
    const root = try bld.openBox();
    try bld.width(root, 800, .px);
    try bld.height(root, 600, .px);
    try env.store.setLayout(root, .scroll_offset_y, .{ .dimension = .{ .value = 300, .unit = .px } });
    try m.build(&ctx);
    bld.close();
    env.solve(root, 800, 600);

    m.popupWindow(100, 590, .pointer);
    env.solve(root, 800, 600);
    const p = env.geom(m.panel_id);
    try expectInside(p, 800, 600);
    // Flipped above the pointer in the *visible* area; bounds that ignored the
    // 300 px pan would clamp it far higher (window y ~260).
    try testing.expectApproxEqAbs(@as(f32, 590), p.y + p.height, 0.5);
}

test "BUG: reloading items (clearItems + addRadio) then writing the group indexed stale rows out of bounds" {
    // Review finding: `updateVisuals` walked `items` but indexed `row_ids`,
    // which keep the OLD (shorter) list until the next rebuild — any tracked
    // write in between (a radio group, `highlighted`) ran it mismatched.
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var sel = signals.Signal(usize).init(testing.allocator, 0);
    defer sel.deinit();
    const m = try buildSelectorMenu(&env, &sel);
    defer m.deinit();

    m.clearItems();
    try m.addHeader("More");
    for (0..8) |i| try m.addRadio("x", "", &sel, i);
    sel.set(5); // re-runs updateVisuals before any rebuild: must not panic
    try testing.expectEqual(@as(usize, 5), sel.peek());
}

test "Menu.build inside a host build effect does not subscribe the host to radio/check/enabled signals" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var sel = signals.Signal(usize).init(testing.allocator, 0);
    defer sel.deinit();
    var chk = signals.Signal(bool).init(testing.allocator, false);
    defer chk.deinit();
    var en = signals.Signal(bool).init(testing.allocator, true);
    defer en.deinit();

    const m = try Menu.init(testing.allocator, "tracked");
    defer m.deinit();
    try m.addRadio("A", "", &sel, 0);
    try m.addRadio("B", "", &sel, 1);
    try m.addItemEx(.{ .label = "C", .action_id = "c", .checked_signal = &chk, .enabled_signal = &en });

    const BuildHost = struct {
        env: *ts.Harness,
        menu: *Menu,
        runs: u32 = 0,
        fn build(self: *@This()) void {
            self.runs += 1;
            var bld = component.UIBuilder.init(&self.env.registry, &self.env.store);
            bld.theme = testTheme();
            var ctx = component.BuildContext.initWithRouter(&bld, &self.env.router);
            _ = bld.openBox() catch unreachable;
            self.menu.build(&ctx) catch unreachable;
            bld.close();
        }
    };
    var host = BuildHost{ .env = &env, .menu = m };
    var scope = signals.Scope.init(testing.allocator);
    defer scope.deinit();
    _ = try scope.createEffect(&host, BuildHost.build);
    try testing.expectEqual(@as(u32, 1), host.runs);

    sel.set(1);
    chk.set(true);
    en.set(false);
    try testing.expectEqual(@as(u32, 1), host.runs);
    // ...while the menu's own effect still repaints live.
    try testing.expectEqualStrings("\u{2022}  ", env.store.getTextContent(m.check_ids.items[1]).?);
}

test "Menu radio: the chain is closed before the group is written (group effects see a closed menu)" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var sel = signals.Signal(usize).init(testing.allocator, 0);
    defer sel.deinit();
    const m = try buildSelectorMenu(&env, &sel);
    defer m.deinit();

    const Watch = struct {
        menu: *Menu,
        sel: *signals.Signal(usize),
        open_when_changed: ?bool = null,
        fn run(self: *@This()) void {
            if (self.sel.get() == 0) return;
            self.open_when_changed = self.menu.isOpen();
        }
    };
    var w = Watch{ .menu = m, .sel = &sel };
    var scope = signals.Scope.init(testing.allocator);
    defer scope.deinit();
    _ = try scope.createEffect(&w, Watch.run);

    m.popup(0, 0, .pointer);
    clickRow(&env, m, 2); // "Tests"
    try testing.expectEqual(@as(?bool, false), w.open_when_changed);
}

test "Menu reloaded to the same length with other kinds: stale rows are not repainted; new signals are followed after the rebuild" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var sel = signals.Signal(usize).init(testing.allocator, 0);
    defer sel.deinit();
    const m = try buildSelectorMenu(&env, &sel); // [header, r0, r1, r2, sep, item]
    defer m.deinit();
    const old_sep = m.row_ids.items[4];
    const sep_bg = env.store.getStyle(old_sep, .background).?.color.a;

    // Same count (6), different kinds: radios where the separator was.
    var other = signals.Signal(usize).init(testing.allocator, 0);
    defer other.deinit();
    m.clearItems();
    for (0..6) |i| try m.addRadio("x", "", &other, i);
    other.set(4);
    try testing.expectApproxEqAbs(sep_bg, env.store.getStyle(old_sep, .background).?.color.a, 0.001);

    // Rebuild: rows match again, and the NEW group drives the bullets live.
    var bld = component.UIBuilder.init(&env.registry, &env.store);
    bld.theme = testTheme();
    var ctx = component.BuildContext.initWithRouter(&bld, &env.router);
    _ = try bld.openBox();
    try m.build(&ctx);
    bld.close();
    try testing.expectEqualStrings("\u{2022}  ", env.store.getTextContent(m.check_ids.items[4]).?);
    other.set(1);
    try testing.expectEqualStrings("\u{2022}  ", env.store.getTextContent(m.check_ids.items[1]).?);
    try testing.expectEqualStrings("    ", env.store.getTextContent(m.check_ids.items[4]).?);
}

test "Menu ignores row clicks/hovers while its rows are stale (items changed, not rebuilt)" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    var sel = signals.Signal(usize).init(testing.allocator, 0);
    defer sel.deinit();
    const m = try buildSelectorMenu(&env, &sel); // 6 rows
    defer m.deinit();
    Probe.calls = 0;
    m.on_select = Probe.handler;
    m.popup(0, 0, .pointer);

    const old_row5 = m.row_ids.items[5];
    m.clearItems();
    try m.addItem("Only", "only");
    // Old row 5 has no item 5 any more: must neither panic nor select.
    _ = env.router.route(.{ .name = "mouse_enter", .id = "", .node_id = old_row5 });
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = old_row5 });
    // Old row 1 would map to the NEW item 0's neighbour: must not fire either.
    _ = env.router.route(.{ .name = "click", .id = "", .node_id = m.row_ids.items[0] });
    try testing.expectEqual(@as(u32, 0), Probe.calls);
}
