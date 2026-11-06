//! TextInput — reactive component migrated to the canonical pattern.
//!
//! Framework-owned via `ctx.mountOwned(TextInput, .{ .initial_text = "…" })`: no
//! `init`/`register`/`deinit`/action-id in user code. Buffers, signals and the
//! visuals scope are created in `onMount(self, allocator)`; `initial_text` seeds
//! the buffer once. Events (focus/blur/mouse/keyboard/IME) arrive through typed
//! per-node handlers registered in `build()` (`router.onNode`, one `onEvent`
//! dispatching by name — the edit model is untouched). The caret blink and
//! drag-select-follow (global mouse_move/up) are registered against `root_id`,
//! so both are pruned automatically when that node is removed.
//!
//! `focused` / `caret_on` are Signals; `rev` bumps on every text/cursor edit to
//! re-run the visuals effect. The effect writes the background/border (focus),
//! the text content and the caret position/opacity — all into the store, so
//! typing and the caret blink are render/layout writes, never a widget rebuild.
//!
//! Caret x is a monospace estimate when no text measurement is injected; exact
//! measurement comes from `builder.measure` (the font atlas) when present.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const text_mod = @import("../render/text.zig");

const PAD_L: f32 = 10.0;
/// Top inset of the text row inside the 36px control, and the row's own height.
/// The caret and the selection band are placed *within* that row by the shared
/// vertical metrics (`TextMeasure.vertical`) — never by their own px constants,
/// which is how they used to drift from the glyphs when the centering changed.
const PAD_T: f32 = 8.0;
const TEXT_H: f32 = 20.0;
const FONT_SIZE: f32 = 16.0;

/// Advance per character for the no-measurement path, at this control's font size.
fn charW() f32 {
    return component.fallbackCharWidth(FONT_SIZE);
}
const BULLET = "\u{2022}"; // • (U+2022, 3 UTF-8 bytes) — password mask glyph

pub const TextInput = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    /// Seed text, applied to the buffer once in `onMount`.
    initial_text: []const u8 = "",
    /// Typed submit handler, called on Enter with the root node's id.
    on_submit: ?events.Handler = null,
    /// Typed change handler, fired on real text mutations (insert/delete/paste/cut/
    /// IME commit/undo/redo) with the new buffer in `ev.text`. Caret and selection
    /// moves never fire it. Notification runs from the shared edit core
    /// (`component.applyEdit`/`editUndo`/`editRedo`), so TextInput and TextArea
    /// behave identically.
    on_change: ?events.Handler = null,
    /// Placeholder text shown (dimmed, `text_disabled`) while the buffer is empty.
    /// Purely visual — it never enters the edit model, so the caret stays at 0.
    placeholder: []const u8 = "",
    /// Password mode: the text node shows one `'•'` per codepoint (a shadow buffer,
    /// rebuilt on mutation); caret/click map over the bullets, and copy/cut are
    /// disabled so the secret never reaches the clipboard.
    is_password: bool = false,

    // State (created in onMount; preserved across rebuilds; freed in deinit —
    // the framework frees the instance itself).
    allocator: std.mem.Allocator = undefined,
    text_buffer: std.array_list.Managed(u8) = undefined,
    /// IME preedit (in-progress composition) shown inline at the caret but NOT part
    /// of `text_buffer` until committed. Empty when not composing.
    preedit: std.array_list.Managed(u8) = undefined,
    focused: signals.Signal(bool) = undefined,
    caret_on: signals.Signal(bool) = undefined,
    rev: signals.Signal(u32) = undefined,
    scope: signals.Scope = undefined,
    /// Undo/redo stack; every buffer mutation funnels through `applyEdit`.
    history: component.EditHistory = undefined,
    /// Password display shadow: `'•'` × codepoints of `text_buffer`, rebuilt on
    /// every mutation. Empty (unused) unless `is_password`.
    shadow: std.array_list.Managed(u8) = undefined,
    cursor_pos: usize = 0,
    /// Selection anchor; selection spans [min(anchor,cursor), max(...)] when set
    /// and != cursor. null = no selection.
    sel_anchor: ?usize = null,
    /// True while a mouse drag-select is in progress.
    selecting: bool = false,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    router: ?*events.EventRouter = null,
    measure: ?component.TextMeasure = null,
    clipboard: ?component.Clipboard = null,
    text_node: reg.NodeId = reg.NULL_NODE,
    caret_node: reg.NodeId = reg.NULL_NODE,
    sel_node: reg.NodeId = reg.NULL_NODE,
    preedit_node: reg.NodeId = reg.NULL_NODE,
    root_id: reg.NodeId = reg.NULL_NODE,
    theme: @import("theme.zig").Theme = .{},
    bound: bool = false,

    pub fn onMount(self: *TextInput, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        self.text_buffer = std.array_list.Managed(u8).init(allocator);
        self.preedit = std.array_list.Managed(u8).init(allocator);
        self.focused = signals.Signal(bool).init(allocator, false);
        self.caret_on = signals.Signal(bool).init(allocator, false);
        self.rev = signals.Signal(u32).init(allocator, 0);
        self.scope = signals.Scope.init(allocator);
        self.history = component.EditHistory.init(allocator);
        self.shadow = std.array_list.Managed(u8).init(allocator);
        self.text_buffer.appendSlice(self.initial_text) catch {};
        self.cursor_pos = self.text_buffer.items.len;
        self.rebuildShadow();
    }

    /// Disarms state only — the framework owns and frees the instance.
    pub fn deinit(self: *TextInput) void {
        self.scope.deinit();
        self.focused.deinit();
        self.caret_on.deinit();
        self.rev.deinit();
        self.history.deinit();
        self.text_buffer.deinit();
        self.preedit.deinit();
        self.shadow.deinit();
    }

    // ── UTF-8 cursor helpers ────────────────────────────────────────────────────
    // cursor_pos is a BYTE index into the UTF-8 buffer; prev/nextBoundary (shared
    // with TextArea, in component.zig) move/cut whole codepoints so an IME-committed
    // CJK char isn't sliced mid-sequence.

    fn prevBoundary(self: *const TextInput, i: usize) usize {
        return component.prevBoundary(self.text_buffer.items, i);
    }
    fn nextBoundary(self: *const TextInput, i: usize) usize {
        return component.nextBoundary(self.text_buffer.items, i);
    }

    /// Inserts a UTF-8 string at the cursor (replacing any selection), advancing the
    /// cursor past it and recording it for undo. Used by both normal char input and
    /// IME commit.
    pub fn insertText(self: *TextInput, text: []const u8) void {
        if (text.len == 0) return;
        const r = self.selRange();
        const at = if (r) |rr| rr.start else self.cursor_pos;
        const rl = if (r) |rr| rr.end - rr.start else 0;
        // Coalesce a plain single-codepoint keystroke into the previous undo step;
        // an insert that replaces a selection is always its own step.
        const coalesce = rl == 0 and component.coalescesInsert(text);
        component.applyEdit(self, at, rl, text, coalesce);
    }

    pub fn bumpRev(self: *TextInput) void {
        self.rebuildShadow();
        self.rev.set(self.rev.peek() +% 1);
    }

    // ── Password shadow ─────────────────────────────────────────────────────────
    // In password mode the visible/measured text is `'•'` × codepoints; the real
    // secret stays in `text_buffer`. Caret & click map through the codepoint index
    // so a single repeated glyph keeps them aligned regardless of glyph width.

    /// Rebuilds `shadow` to one bullet per codepoint of `text_buffer` (no-op when
    /// not in password mode). Called from `bumpRev`, so it tracks every mutation.
    fn rebuildShadow(self: *TextInput) void {
        self.shadow.clearRetainingCapacity();
        if (!self.is_password) return;
        var n = self.cpBefore(self.text_buffer.items.len);
        while (n > 0) : (n -= 1) self.shadow.appendSlice(BULLET) catch {};
    }

    /// Codepoints in `text_buffer[0..byte_i]`.
    fn cpBefore(self: *const TextInput, byte_i: usize) usize {
        const end = @min(byte_i, self.text_buffer.items.len);
        return std.unicode.utf8CountCodepoints(self.text_buffer.items[0..end]) catch end;
    }

    /// Real-buffer byte index at codepoint index `cp` (inverse of `cpBefore`).
    fn byteAtCp(self: *const TextInput, cp: usize) usize {
        var i: usize = 0;
        var n: usize = 0;
        while (n < cp and i < self.text_buffer.items.len) : (n += 1) i = self.nextBoundary(i);
        return i;
    }

    const Range = component.Range;

    /// The active selection, or null when there's no (or an empty) selection.
    /// (Shared, buffer-clamped selection model — see `component.selectionRange`.)
    pub fn selRange(self: *const TextInput) ?Range {
        return component.selectionRange(self.text_buffer.items.len, self.sel_anchor, self.cursor_pos);
    }

    /// Column under a pointer x (absolute), via exact measurement when available.
    fn colFromClick(self: *TextInput, gx: f32) usize {
        const store = self.store orelse return self.cursor_pos;
        const registry = store.registry orelse return self.cursor_pos;
        if (self.text_node == reg.NULL_NODE) return self.cursor_pos;
        const node = registry.getNode(self.text_node) orelse return self.cursor_pos;
        const local = gx - node.geometry.x;
        if (self.is_password) {
            // Hit-test the bullets, then map the codepoint index back to a real byte.
            const disp = component.columnAtX(self.measure, self.shadow.items, FONT_SIZE, local);
            return self.byteAtCp(disp / BULLET.len);
        }
        return component.columnAtX(self.measure, self.text_buffer.items, FONT_SIZE, local);
    }

    /// Copy, but never expose a password field's secret to the clipboard.
    fn clipboardCopy(self: *TextInput) void {
        if (self.is_password) return;
        component.clipboardCopySelection(self);
    }

    fn onTick(self: *TextInput) void {
        if (self.focused.peek()) self.caret_on.set(!self.caret_on.peek());
    }

    fn onGlobal(self: *TextInput, ev: events.Event) void {
        if (self.selecting and std.mem.eql(u8, ev.name, "mouse_move")) {
            self.cursor_pos = self.colFromClick(ev.x); // extend selection to the pointer
            self.bumpRev();
        } else if (std.mem.eql(u8, ev.name, "mouse_up")) {
            self.selecting = false;
        }
    }

    fn onEvent(self: *TextInput, ev: events.Event) void {
        if (std.mem.eql(u8, ev.name, "focus")) {
            self.focused.set(true);
            self.caret_on.set(true);
            return;
        }
        if (std.mem.eql(u8, ev.name, "blur")) {
            self.focused.set(false);
            self.selecting = false;
            return;
        }
        if (std.mem.eql(u8, ev.name, "mouse_down")) {
            const col = self.colFromClick(ev.x);
            if (ev.shift) {
                if (self.sel_anchor == null) self.sel_anchor = self.cursor_pos;
            } else {
                self.sel_anchor = col; // begin a fresh (empty) selection at the click
            }
            self.cursor_pos = col;
            self.selecting = true;
            self.caret_on.set(true);
            self.bumpRev();
            return;
        }
        if (std.mem.eql(u8, ev.name, "mouse_up")) {
            self.selecting = false;
            return;
        }
        if (std.mem.eql(u8, ev.name, "double_click")) {
            // key_code carries the click count: 2 = word, 3+ = whole line
            // (single-line input → the entire buffer).
            const col = self.colFromClick(ev.x);
            if (ev.key_code >= 3) {
                self.sel_anchor = 0;
                self.cursor_pos = self.text_buffer.items.len;
            } else {
                const w = component.wordRangeAt(self.text_buffer.items, col);
                self.sel_anchor = w.start;
                self.cursor_pos = w.end;
            }
            self.selecting = false;
            self.caret_on.set(true);
            self.bumpRev();
            return;
        }
        if (!self.focused.peek()) return;

        const kc: i64 = ev.key_code;
        const len = self.text_buffer.items.len;

        // Clamp positions to the buffer before any edit: they're byte indices that
        // can drift out of range (stale anchor, external prefill), and the
        // backspace/boundary paths below index `text_buffer` directly.
        if (self.cursor_pos > len) self.cursor_pos = len;
        if (self.sel_anchor) |a| {
            if (a > len) self.sel_anchor = len;
        }

        // Ctrl shortcuts: A / C / V / X / Z / Y.
        if (ev.ctrl and std.mem.eql(u8, ev.name, "key_down")) {
            switch (events.Key.fromCode(ev.key_code) orelse return) {
                .a => { // select all
                    self.sel_anchor = 0;
                    self.cursor_pos = len;
                    self.bumpRev();
                },
                .c => self.clipboardCopy(),
                .v => component.clipboardPaste(self, false),
                .x => { // cut (disabled in password mode — would leak via delete-to-clipboard)
                    if (self.is_password) return;
                    self.clipboardCopy();
                    if (self.selRange()) |r| {
                        component.applyEdit(self, r.start, r.end - r.start, "", false);
                    } else {
                        component.applyEdit(self, 0, len, "", false);
                    }
                    self.bumpRev();
                },
                .z => if (ev.shift) component.editRedo(self) else component.editUndo(self), // Ctrl+Z / Ctrl+Shift+Z
                .y => component.editRedo(self), // Ctrl+Y
                else => {},
            }
            return;
        }

        // IME: preedit updates the (uncommitted) composition; commit inserts UTF-8.
        if (component.handleImeEvent(self, ev)) return;

        if (std.mem.eql(u8, ev.name, "char_input")) {
            // Prefer the UTF-8 text the engine carries (handles non-ASCII / IME);
            // fall back to the raw ASCII key code for the test/legacy path.
            if (ev.text.len > 0) {
                if (ev.text.len == 1 and (ev.text[0] < 32 or ev.text[0] == 127)) return;
                self.insertText(ev.text);
                self.bumpRev();
            } else if (kc >= 32 and kc <= 126) {
                const byte: u8 = @intCast(kc);
                self.insertText(&[_]u8{byte});
                self.bumpRev();
            }
        } else if (std.mem.eql(u8, ev.name, "key_down")) {
            switch (events.Key.fromCode(ev.key_code) orelse return) {
                .backspace => { // backspace — delete the selection, else the codepoint before the cursor
                    if (self.selRange()) |r| {
                        component.applyEdit(self, r.start, r.end - r.start, "", false);
                    } else if (self.cursor_pos > 0) {
                        const prev = self.prevBoundary(self.cursor_pos);
                        component.applyEdit(self, prev, self.cursor_pos - prev, "", false);
                    }
                    self.bumpRev();
                },
                .left => self.moveCursor(self.prevBoundary(self.cursor_pos), ev.shift, .left), // left (1 codepoint)
                .right => self.moveCursor(self.nextBoundary(self.cursor_pos), ev.shift, .right), // right (1 codepoint)
                .home => self.moveCursor(0, ev.shift, .left), // Home
                .end => self.moveCursor(len, ev.shift, .right), // End
                .enter => {
                    if (self.on_submit) |h| h.call(h.ptr, .{ .name = "submit", .id = "", .node_id = self.root_id });
                },
                else => {},
            }
        }
    }

    /// Moves the cursor, extending the selection when shift is held; otherwise
    /// collapses an existing selection toward `dir` before a plain move.
    fn moveCursor(self: *TextInput, target: usize, extend: bool, dir: enum { left, right }) void {
        if (extend) {
            if (self.sel_anchor == null) self.sel_anchor = self.cursor_pos;
            self.cursor_pos = target;
        } else if (self.selRange()) |r| {
            self.cursor_pos = switch (dir) {
                .left => r.start,
                .right => r.end,
            };
            self.sel_anchor = null;
        } else {
            self.cursor_pos = target;
        }
        self.bumpRev();
    }

    /// Event kinds routed to `onEvent` by node id (one handler, name dispatch).
    const NODE_KINDS = [_]events.EventKind{
        .focus,    .blur,       .mouse_down,       .mouse_up,    .double_click,
        .key_down, .char_input, .text_composition, .text_commit,
    };

    pub fn build(self: *TextInput, ctx: *component.BuildContext) !void {
        const b = ctx.builder;
        self.theme = b.theme;
        self.store = b.store;
        self.router = ctx.router;
        self.measure = b.measure;
        self.clipboard = b.clipboard;

        const root = try b.openNodeKeyed(.box, null);
        self.root_id = root;
        try b.cursor(root, "text"); // I-beam over the input
        try b.width(root, 100, .percent);
        try b.height(root, 36, .px);
        try b.padding(root, 8, 10, 0, 10);
        try b.flexRow(root);
        // Autogenerated action id (same pattern as wireHandler): the C-ABI hit/focus
        // channel keeps its string, but routing is by node id + typed handlers.
        var idbuf: [16]u8 = undefined;
        const auto_id = std.fmt.bufPrint(&idbuf, "n{d}", .{root}) catch "n";
        try b.clickable(root, auto_id);
        try b.focusable(root, auto_id);
        // The accessible Name must stay the placeholder, stable regardless of
        // what's typed — the live buffer is the Value (ValuePattern), not the
        // Name. Without this, a UIA client would see the Name track keystrokes
        // and lose the identifier it searched by.
        if (self.placeholder.len > 0) try b.ariaLabel(root, self.placeholder);
        try b.overflowHidden(root);
        if (self.theme.radius_base > 0) try b.radius(root, self.theme.radius_base);

        if (ctx.router) |r| {
            const h = ctx.handler(self, onEvent);
            for (NODE_KINDS) |k| try r.onNode(root, k, h);
        }

        // Caret / selection band: derived from the same vertical metrics the renderer
        // places glyphs with, so the bar tracks the text instead of being guessed.
        const vl = self.caretBand();
        const band_y = PAD_T + vl.caret_top;

        // Selection highlight — a translucent box behind the text (drawn before
        // it). Width 0 = no selection; updateVisuals sizes/positions it.
        const sel = try b.openNodeKeyed(.box, null);
        self.sel_node = sel;
        try b.positionAbsolute(sel, PAD_L, band_y);
        try b.width(sel, 0, .px);
        try b.height(sel, vl.caret_height, .px);
        try b.backgroundAlpha(sel, self.theme.accent.r, self.theme.accent.g, self.theme.accent.b, 0.35);
        b.close();

        const text_node = try b.addText(self.text_buffer.items);
        self.text_node = text_node;
        try b.height(text_node, TEXT_H, .px);
        try b.fontSize(text_node, FONT_SIZE);
        try b.textColor(text_node, self.theme.text.r, self.theme.text.g, self.theme.text.b);

        const caret = try b.openNodeKeyed(.box, null);
        self.caret_node = caret;
        try b.positionAbsolute(caret, PAD_L, band_y);
        try b.width(caret, 2, .px);
        try b.height(caret, vl.caret_height, .px);
        try b.backgroundAlpha(caret, self.theme.accent.r, self.theme.accent.g, self.theme.accent.b, 1.0);
        b.close(); // caret

        // IME preedit: an inline text overlay at the caret, drawn in the accent
        // colour so the in-progress composition is visually distinct. Empty (and
        // thus invisible) until a text_composition event arrives. It is a text node
        // like the main one, so it takes the text row's box, not the caret band's.
        const pre = try b.addText("");
        self.preedit_node = pre;
        try b.positionAbsolute(pre, PAD_L, PAD_T);
        try b.height(pre, TEXT_H, .px);
        try b.fontSize(pre, FONT_SIZE);
        try b.textColor(pre, self.theme.accent.r, self.theme.accent.g, self.theme.accent.b);

        b.close(); // root

        // Re-applied after a rebuild in an untracked region so the store writes
        // don't subscribe the enclosing build-effect to focus/caret/rev.
        // Unconditional every build: both replace in place per owner (see
        // events.zig), and the node-removed hook prunes them on unmount.
        if (ctx.router) |r| {
            try r.onTick(self.root_id, self, onTick);
            try r.onGlobal(self.root_id, self, onGlobal); // drag-select follow + mouse_up
        }
        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn updateVisuals(self: *TextInput) void {
        const store = self.store orelse return;
        if (self.text_node == reg.NULL_NODE) return;
        const t = self.theme;
        const focused = self.focused.get();
        const caret_on = self.caret_on.get();
        _ = self.rev.get(); // subscribe to edits

        // Background + border reflect focus.
        const bg = if (focused) t.bg_input else t.bg_surface;
        store.setStyle(self.root_id, .background, props.PropValue.rgbA(bg.r, bg.g, bg.b, @as(f32, @floatFromInt(bg.a)) / 255.0)) catch {};
        if (t.border_width > 0) {
            store.setStyle(self.root_id, .border_width, .{ .dimension = .{ .value = t.border_width, .unit = .px } }) catch {};
            const bc = if (focused) t.accent else t.border_color;
            store.setStyle(self.root_id, .border_color, props.PropValue.rgbA(bc.r, bc.g, bc.b, @as(f32, @floatFromInt(bc.a)) / 255.0)) catch {};
        }

        // Displayed text: bullets (password), the dimmed placeholder (empty buffer),
        // else the buffer itself. The placeholder is visual only — the caret stays
        // at 0 and the edit model is untouched.
        const show_placeholder = !self.is_password and self.text_buffer.items.len == 0 and self.placeholder.len > 0;
        const display: []const u8 = if (self.is_password)
            self.shadow.items
        else if (show_placeholder)
            self.placeholder
        else
            self.text_buffer.items;
        // Text content (dupe — setTextContent owns/frees with the store allocator).
        if (store.stringAllocator().dupe(u8, display)) |owned| {
            store.setTextContent(self.text_node, owned);
        } else |_| {}
        const tcol = if (show_placeholder) t.text_disabled else t.text;
        store.setStyle(self.text_node, .color, props.PropValue.rgbA(tcol.r, tcol.g, tcol.b, 1.0)) catch {};

        // Caret position: exact (font atlas) when available, else monospace estimate.
        const cursor = @min(self.cursor_pos, self.text_buffer.items.len);
        const base_x = PAD_L + self.measureUpTo(cursor);

        // IME preedit: shown inline at the caret; the caret then sits AFTER it.
        var pre_w: f32 = 0;
        if (self.preedit_node != reg.NULL_NODE) {
            if (store.stringAllocator().dupe(u8, self.preedit.items)) |owned| {
                store.setTextContent(self.preedit_node, owned);
            } else |_| {}
            store.setLayout(self.preedit_node, .left, .{ .dimension = .{ .value = base_x, .unit = .px } }) catch {};
            if (self.preedit.items.len > 0) {
                pre_w = if (self.measure) |m| m.width(self.preedit.items, FONT_SIZE) else @as(f32, @floatFromInt(self.preedit.items.len)) * charW();
            }
        }

        const caret_x = base_x + pre_w;
        store.setLayout(self.caret_node, .left, .{ .dimension = .{ .value = caret_x, .unit = .px } }) catch {};
        store.setStyle(self.caret_node, .opacity, .{ .number = if (focused and caret_on) 1.0 else 0.0 }) catch {};

        // Selection highlight: span [start,end) in measured x; width 0 hides it.
        if (self.sel_node != reg.NULL_NODE) {
            var sel_x: f32 = PAD_L;
            var sel_w: f32 = 0;
            if (self.selRange()) |r| {
                const len = self.text_buffer.items.len;
                const s = @min(r.start, len);
                const e = @min(r.end, len);
                const x0 = self.measureUpTo(s);
                const x1 = self.measureUpTo(e);
                sel_x = PAD_L + x0;
                sel_w = x1 - x0;
            }
            store.setLayout(self.sel_node, .left, .{ .dimension = .{ .value = sel_x, .unit = .px } }) catch {};
            store.setLayout(self.sel_node, .width, .{ .dimension = .{ .value = sel_w, .unit = .px } }) catch {};
        }
    }

    /// Vertical band the caret and the selection occupy inside the text row. Goes
    /// through the injected metrics when the engine provided them (real font), and
    /// through the same computation over default proportions when it didn't — one
    /// rule either way. See `text.verticalLayoutFor`.
    fn caretBand(self: *TextInput) text_mod.VerticalLayout {
        if (self.measure) |m| return m.vertical(FONT_SIZE, TEXT_H, 1);
        return component.verticalFallback(FONT_SIZE, TEXT_H, 1);
    }

    /// Measured x of the caret/selection edge at real-buffer byte index `n` (exact
    /// via the atlas, else monospace). In password mode it measures the equivalent
    /// run of bullets so the caret tracks the masked glyphs, not the secret.
    fn measureUpTo(self: *TextInput, n: usize) f32 {
        if (self.is_password) {
            const cp = self.cpBefore(n);
            const slice = self.shadow.items[0..@min(cp * BULLET.len, self.shadow.items.len)];
            return if (self.measure) |m| m.width(slice, FONT_SIZE) else @as(f32, @floatFromInt(cp)) * charW();
        }
        const slice = self.text_buffer.items[0..@min(n, self.text_buffer.items.len)];
        return if (self.measure) |m| m.width(slice, FONT_SIZE) else @as(f32, @floatFromInt(slice.len)) * charW();
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const ts = @import("test_support.zig");
const TestEnv = ts.Harness;

/// Mounts a framework-owned TextInput under a fresh root and returns the
/// instance (mountSlider pattern from slider.zig). `with_measure`/
/// `with_clipboard` on the env install the shared text stubs.
fn mount(env: *TestEnv, init_props: anytype) !*TextInput {
    env.wire();
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = .{ .accent = .{ .r = 0, .g = 120, .b = 255 }, .bg_input = .{ .r = 30, .g = 30, .b = 30, .a = 255 }, .bg_surface = .{ .r = 50, .g = 50, .b = 50, .a = 255 }, .text = .{ .r = 255, .g = 255, .b = 255 } };
    if (env.with_measure) b.measure = .{ .ctx = @ptrCast(&ts.text_dummy), .measureFn = ts.mockMeasure };
    if (env.with_clipboard) b.clipboard = .{ .ctx = @ptrCast(&ts.text_dummy), .getFn = ts.stubClipGet, .setFn = ts.stubClipSet };
    var ctx = component.BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(TextInput, init_props);
    b.close();
    const anchor = env.registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));
}

test "TextInput typing updates content and caret; focus toggles caret visibility" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{});
    const id = input.root_id;

    // Focus, then type "Hi" (typed per-node routing — no action-id strings).
    env.route(.{ .name = "focus", .id = "", .node_id = id });
    try testing.expect(input.focused.peek());
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 72 }); // 'H'
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 105 }); // 'i'

    try testing.expectEqualStrings("Hi", env.store.getTextContent(input.text_node).?);
    try testing.expectEqual(@as(usize, 2), input.cursor_pos);
    // Caret advanced 2 chars from the left padding.
    try testing.expectApproxEqAbs(PAD_L + 2 * charW(), env.store.getLayout(input.caret_node, .left).?.dimension.value, 0.001);

    // Caret visible while focused + on.
    try testing.expectApproxEqAbs(@as(f32, 1.0), env.store.getStyle(input.caret_node, .opacity).?.number, 0.001);

    // Backspace removes one char.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.backspace.code() });
    try testing.expectEqualStrings("H", env.store.getTextContent(input.text_node).?);

    // Tick toggles caret; blur hides it.
    env.route(.{ .name = "tick", .id = "" });
    try testing.expect(!input.caret_on.peek());
    env.route(.{ .name = "blur", .id = "", .node_id = id });
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getStyle(input.caret_node, .opacity).?.number, 0.001);
}

test "TextInput IME: commit inserts a multi-byte UTF-8 string at the cursor" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{});
    env.route(.{ .name = "focus", .id = "", .node_id = input.root_id });

    // Commit a 2-codepoint CJK string (each 3 bytes → 6 bytes total).
    env.route(.{ .name = "text_commit", .id = "", .node_id = input.root_id, .text = "\u{65E5}\u{672C}" });
    try testing.expectEqualStrings("\u{65E5}\u{672C}", env.store.getTextContent(input.text_node).?);
    try testing.expectEqual(@as(usize, 6), input.cursor_pos);
    try testing.expectEqual(@as(usize, 0), input.preedit.items.len);
}

test "TextInput IME: preedit shows inline but isn't committed until text_commit" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{});
    const id = input.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Composition in progress: preedit is rendered, the buffer stays empty.
    env.route(.{ .name = "text_composition", .id = "", .node_id = id, .text = "\u{306B}\u{307B}" }); // にほ
    try testing.expectEqualStrings("\u{306B}\u{307B}", env.store.getTextContent(input.preedit_node).?);
    try testing.expectEqualStrings("", env.store.getTextContent(input.text_node).?);

    // Commit the candidate → buffer gets the final string, preedit clears.
    env.route(.{ .name = "text_commit", .id = "", .node_id = id, .text = "\u{65E5}\u{672C}" }); // 日本
    try testing.expectEqualStrings("\u{65E5}\u{672C}", env.store.getTextContent(input.text_node).?);
    try testing.expectEqualStrings("", env.store.getTextContent(input.preedit_node).?);

    // An empty composition cancels (no leftover preedit).
    env.route(.{ .name = "text_composition", .id = "", .node_id = id, .text = "\u{306B}" });
    try testing.expect(input.preedit.items.len > 0);
    env.route(.{ .name = "text_composition", .id = "", .node_id = id, .text = "" });
    try testing.expectEqual(@as(usize, 0), input.preedit.items.len);
}

test "TextInput UTF-8: char_input text, backspace and arrows step whole codepoints" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{});
    const id = input.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // char_input carrying UTF-8 text inserts the codepoint (not just ASCII).
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .text = "a" });
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .text = "\u{00E9}" }); // é (2 bytes)
    try testing.expectEqualStrings("a\u{00E9}", env.store.getTextContent(input.text_node).?);
    try testing.expectEqual(@as(usize, 3), input.cursor_pos); // 1 + 2 bytes

    // Backspace removes the whole 'é' codepoint (2 bytes), not one byte.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.backspace.code() });
    try testing.expectEqualStrings("a", env.store.getTextContent(input.text_node).?);
    try testing.expectEqual(@as(usize, 1), input.cursor_pos);

    // Build "a日本" and walk the cursor by codepoint.
    env.route(.{ .name = "text_commit", .id = "", .node_id = id, .text = "\u{65E5}\u{672C}" }); // 日本
    try testing.expectEqual(@as(usize, 7), input.cursor_pos); // 1 + 3 + 3
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.left.code() }); // left → before 本
    try testing.expectEqual(@as(usize, 4), input.cursor_pos);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.left.code() }); // left → before 日
    try testing.expectEqual(@as(usize, 1), input.cursor_pos);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.right.code() }); // right → after 日
    try testing.expectEqual(@as(usize, 4), input.cursor_pos);
}

test "TextInput caret uses injected text measurement when present (exact, not monospace)" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_measure = true;
    const input = try mount(&env, .{});
    const id = input.root_id;

    env.route(.{ .name = "focus", .id = "", .node_id = id });
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 72 }); // 'H'
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 105 }); // 'i'

    // Caret x = PAD_L + measured("Hi") = PAD_L + 2*10 = PAD_L + 20 (not 2*charW()=16).
    try testing.expectApproxEqAbs(PAD_L + 20.0, env.store.getLayout(input.caret_node, .left).?.dimension.value, 0.001);
}

test "TextInput mouse_down positions the cursor by measured x (midpoint rule)" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_measure = true; // 10px/char
    const input = try mount(&env, .{ .initial_text = "hello" });
    const id = input.root_id;

    // Solved layout: text node at x=0.
    env.registry.getNode(input.text_node).?.geometry = .{ .x = 0, .y = 0, .width = 200, .height = 20 };

    // mouse_down at x=12: 'h' [0,10) mid 5, 'e' [10,20) mid 15 → 12 < 15 → before 'e' (1).
    env.route(.{ .name = "mouse_down", .id = "", .node_id = id, .x = 12.0, .y = 5.0 });
    try testing.expectEqual(@as(usize, 1), input.cursor_pos);

    // Past the end → clamps to text length.
    env.route(.{ .name = "mouse_down", .id = "", .node_id = id, .x = 999.0, .y = 5.0 });
    try testing.expectEqual(@as(usize, 5), input.cursor_pos);
}

test "TextInput double_click selects the word, triple selects the line" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_measure = true; // 10px/char
    const input = try mount(&env, .{ .initial_text = "this world" });
    const id = input.root_id;
    env.registry.getNode(input.text_node).?.geometry = .{ .x = 0, .y = 0, .width = 200, .height = 20 };

    // Double-click at x=12 (col 1, inside "this") selects the whole word.
    env.route(.{ .name = "double_click", .id = "", .node_id = id, .x = 12.0, .y = 5.0, .key_code = 2 });
    try testing.expectEqual(@as(?usize, 0), input.sel_anchor);
    try testing.expectEqual(@as(usize, 4), input.cursor_pos);
    try testing.expectEqualStrings("this", input.text_buffer.items[0..4]);

    // Triple-click (key_code 3) selects the entire single-line buffer.
    env.route(.{ .name = "double_click", .id = "", .node_id = id, .x = 12.0, .y = 5.0, .key_code = 3 });
    try testing.expectEqual(@as(?usize, 0), input.sel_anchor);
    try testing.expectEqual(@as(usize, 10), input.cursor_pos);
}

test "TextInput Ctrl+C copies the buffer; Ctrl+V pastes at the cursor" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_clipboard = true;
    const input = try mount(&env, .{});
    const id = input.root_id;

    env.route(.{ .name = "focus", .id = "", .node_id = id });
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 72 }); // 'H'
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 105 }); // 'i'

    // Ctrl+C copies the whole buffer (VK_C = 67).
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.c.code(), .ctrl = true });
    try testing.expectEqualStrings("Hi", ts.stub_clip_buf[0..ts.stub_clip_len]);

    // Ctrl+V (VK_V = 86) pastes at the cursor (end) → "HiHi".
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.v.code(), .ctrl = true });
    try testing.expectEqualStrings("HiHi", env.store.getTextContent(input.text_node).?);
    try testing.expectEqual(@as(usize, 4), input.cursor_pos);
}

test "TextInput: a stale out-of-range selection is clamped on edit instead of panicking" {
    // Regression: cursor_pos / sel_anchor are byte indices that can drift past the
    // buffer (external prefill/clear, a shrinking edit). Pre-fix, selRange returned
    // an end beyond text_buffer.items.len and deleteSelection's orderedRemove walked
    // off the end → "index out of bounds" panic on a normal backspace.
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{ .initial_text = "hello" }); // len 5
    const id = input.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Indices pointing past the end of the buffer.
    input.sel_anchor = 10;
    input.cursor_pos = 0;

    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.backspace.code() }); // backspace

    // No panic; the selection is clamped to the buffer and removed cleanly.
    try testing.expectEqualStrings("", env.store.getTextContent(input.text_node).?);
    try testing.expectEqual(@as(usize, 0), input.cursor_pos);
    try testing.expectEqual(@as(?usize, null), input.sel_anchor);
}

test "TextInput: typing over an empty click-selection leaves no phantom selection" {
    // Regression: a plain click sets sel_anchor == cursor (an empty selection).
    // insertText calls deleteSelection, which (correctly) does nothing for an empty
    // range — but pre-fix it also left sel_anchor set, so once the cursor advanced
    // past the inserted text a 1-char "phantom" selection the user never made
    // survived, and could later index out of the buffer after a shrinking edit.
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{});
    const id = input.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Click into the (empty) field: begins an empty selection at the caret.
    env.route(.{ .name = "mouse_down", .id = "", .node_id = id, .x = 0.0, .y = 0.0 });
    try testing.expect(input.sel_anchor != null);

    // Type a char → the empty selection must be cleared, not promoted to a phantom.
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .text = "a" });
    try testing.expectEqualStrings("a", env.store.getTextContent(input.text_node).?);
    try testing.expectEqual(@as(usize, 1), input.cursor_pos);
    try testing.expectEqual(@as(?usize, null), input.sel_anchor);
    try testing.expect(input.selRange() == null);
}

test "TextInput selection: select-all highlights+copies; typing replaces; shift-arrow extends" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_measure = true; // 10px/char
    env.with_clipboard = true;
    const input = try mount(&env, .{ .initial_text = "Hello" });
    const id = input.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Ctrl+A selects all → highlight spans the 5 chars (5×10px) and copy gets it.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.a.code(), .ctrl = true });
    try testing.expectApproxEqAbs(@as(f32, 50.0), env.store.getLayout(input.sel_node, .width).?.dimension.value, 0.001);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.c.code(), .ctrl = true });
    try testing.expectEqualStrings("Hello", ts.stub_clip_buf[0..ts.stub_clip_len]);

    // Typing replaces the whole selection → "Z", cursor at 1, highlight gone.
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 90 }); // 'Z'
    try testing.expectEqualStrings("Z", env.store.getTextContent(input.text_node).?);
    try testing.expectEqual(@as(usize, 1), input.cursor_pos);
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getLayout(input.sel_node, .width).?.dimension.value, 0.001);

    // Type "ab" → "Zab", cursor 3. Shift+Left twice selects "ab"; backspace deletes it.
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 97 }); // 'a'
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 98 }); // 'b'
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.left.code(), .shift = true }); // shift+Left
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.left.code(), .shift = true });
    try testing.expectEqual(@as(usize, 1), input.cursor_pos);
    try testing.expect(input.selRange() != null);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.backspace.code() }); // backspace deletes selection
    try testing.expectEqualStrings("Z", env.store.getTextContent(input.text_node).?);
    try testing.expectEqual(@as(usize, 1), input.cursor_pos);
}

test "TextInput: the UIA SetValue sequence (focus, Ctrl+A, text_commit) replaces the whole buffer" {
    // Mirrors what c_api.setNodeTextViaInput emits for ValuePattern.SetValue, so
    // automation exercises the real edit path rather than a parallel shortcut.
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{ .initial_text = "old value" });
    const id = input.root_id;

    env.route(.{ .name = "focus", .id = "", .node_id = id });
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.a.code(), .ctrl = true }); // Ctrl+A
    env.route(.{ .name = "text_commit", .id = "", .node_id = id, .text = "new" });

    try testing.expectEqualStrings("new", env.store.getTextContent(input.text_node).?);
    try testing.expectEqualStrings("new", input.text_buffer.items);
    try testing.expectEqual(@as(usize, 3), input.cursor_pos);

    // Clearing: select-all then Backspace (an empty commit is a no-op) empties it.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.a.code(), .ctrl = true });
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.backspace.code() }); // Backspace
    try testing.expectEqualStrings("", input.text_buffer.items);
}

test "TextInput on_submit fires on Enter with the root node id (typed handler)" {
    const Sink = struct {
        var submits: u32 = 0;
        var last_node: u32 = 0;
        fn onSubmit(_: ?*anyopaque, ev: events.Event) void {
            submits += 1;
            last_node = ev.node_id;
        }
    };
    Sink.submits = 0;
    Sink.last_node = 0;

    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{ .on_submit = events.Handler{ .ptr = null, .call = Sink.onSubmit } });
    const id = input.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.enter.code() }); // Enter
    try testing.expectEqual(@as(u32, 1), Sink.submits);
    try testing.expectEqual(id, Sink.last_node);
}

test "TextInput on_change fires on text mutations only, carrying the new buffer (not on caret moves)" {
    const Sink = struct {
        var calls: u32 = 0;
        var last_buf: [64]u8 = undefined;
        var last_len: usize = 0;
        fn onChange(_: ?*anyopaque, ev: events.Event) void {
            calls += 1;
            std.mem.copyForwards(u8, &last_buf, ev.text);
            last_len = ev.text.len;
        }
    };
    Sink.calls = 0;
    Sink.last_len = 0;

    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{ .on_change = events.Handler{ .ptr = null, .call = Sink.onChange } });
    const id = input.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Typing 'H' fires once with the new content.
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 72 }); // 'H'
    try testing.expectEqual(@as(u32, 1), Sink.calls);
    try testing.expectEqualStrings("H", Sink.last_buf[0..Sink.last_len]);
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 105 }); // 'i'
    try testing.expectEqual(@as(u32, 2), Sink.calls);
    try testing.expectEqualStrings("Hi", Sink.last_buf[0..Sink.last_len]);

    // Moving the caret (left arrow) is not a text mutation — no fire.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.left.code() }); // left
    try testing.expectEqual(@as(u32, 2), Sink.calls);

    // Backspace deletes and fires with the reduced text.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.backspace.code() }); // backspace (cursor at 1 → deletes 'H')
    try testing.expectEqual(@as(u32, 3), Sink.calls);
    try testing.expectEqualStrings("i", Sink.last_buf[0..Sink.last_len]);
}

test "TextInput undo/redo coalesces word-wise; a new edit truncates the redo branch" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{});
    const id = input.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Type "this world" → three coalesced edits: "this", " ", "world".
    for ("this world") |ch| env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = ch });
    try testing.expectEqualStrings("this world", env.store.getTextContent(input.text_node).?);

    // Undo peels off whole words/separators, not single letters.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.z.code(), .ctrl = true }); // Ctrl+Z
    try testing.expectEqualStrings("this ", env.store.getTextContent(input.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.z.code(), .ctrl = true });
    try testing.expectEqualStrings("this", env.store.getTextContent(input.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.z.code(), .ctrl = true });
    try testing.expectEqualStrings("", env.store.getTextContent(input.text_node).?);

    // Redo re-applies in order.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.y.code(), .ctrl = true }); // Ctrl+Y
    try testing.expectEqualStrings("this", env.store.getTextContent(input.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.y.code(), .ctrl = true });
    try testing.expectEqualStrings("this ", env.store.getTextContent(input.text_node).?);

    // A new edit here truncates the pending redo ("world"): Ctrl+Y after it is a no-op.
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 'x' });
    try testing.expectEqualStrings("this x", env.store.getTextContent(input.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.y.code(), .ctrl = true });
    try testing.expectEqualStrings("this x", env.store.getTextContent(input.text_node).?);
}

test "TextInput undo/redo: type-over-selection, paste and IME commit are single steps" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_clipboard = true;
    const input = try mount(&env, .{ .initial_text = "Hello" });
    const id = input.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Ctrl+A then type 'X' replaces the whole selection in one step.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.a.code(), .ctrl = true });
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 'X' });
    try testing.expectEqualStrings("X", env.store.getTextContent(input.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.z.code(), .ctrl = true }); // undo → whole "Hello" back
    try testing.expectEqualStrings("Hello", env.store.getTextContent(input.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.y.code(), .ctrl = true }); // redo → "X"
    try testing.expectEqualStrings("X", env.store.getTextContent(input.text_node).?);

    // Paste is one step (cursor at 1 after 'X').
    _ = ts.stubClipSet(undefined, "YZ");
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.v.code(), .ctrl = true }); // Ctrl+V
    try testing.expectEqualStrings("XYZ", env.store.getTextContent(input.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.z.code(), .ctrl = true });
    try testing.expectEqualStrings("X", env.store.getTextContent(input.text_node).?);

    // An IME commit is one undoable step too.
    env.route(.{ .name = "text_commit", .id = "", .node_id = id, .text = "\u{65E5}" }); // 日
    try testing.expectEqualStrings("X\u{65E5}", env.store.getTextContent(input.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.z.code(), .ctrl = true });
    try testing.expectEqualStrings("X", env.store.getTextContent(input.text_node).?);
}

test "TextInput placeholder shows dimmed while empty and vanishes on first char" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{ .placeholder = "Search..." });
    const id = input.root_id;

    // Empty buffer → placeholder rendered in the dimmed (text_disabled) colour,
    // but the edit model is untouched (caret at 0, buffer empty).
    try testing.expectEqualStrings("Search...", env.store.getTextContent(input.text_node).?);
    try testing.expectEqual(@as(usize, 0), input.cursor_pos);
    try testing.expectEqual(@as(usize, 0), input.text_buffer.items.len);
    const dim = env.store.getStyle(input.text_node, .color).?.color;
    const td = input.theme.text_disabled;
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(td.r)) / 255.0, dim.r, 0.001);

    // First char → placeholder gone, buffer text shown in the normal colour.
    env.route(.{ .name = "focus", .id = "", .node_id = id });
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 'a' });
    try testing.expectEqualStrings("a", env.store.getTextContent(input.text_node).?);
    const norm = env.store.getStyle(input.text_node, .color).?.color;
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(input.theme.text.r)) / 255.0, norm.r, 0.001);
}

test "TextInput password masks the buffer with bullets and never copies" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_clipboard = true;
    const input = try mount(&env, .{ .is_password = true, .initial_text = "abc" });
    const id = input.root_id;

    // Displayed text is one bullet per codepoint; the real secret stays in the buffer.
    try testing.expectEqualStrings("\u{2022}\u{2022}\u{2022}", env.store.getTextContent(input.text_node).?);
    try testing.expect(!std.mem.eql(u8, "abc", env.store.getTextContent(input.text_node).?));
    try testing.expectEqualStrings("abc", input.text_buffer.items);

    // Ctrl+A + Ctrl+C must not leak the secret to the clipboard.
    ts.stub_clip_len = 0;
    env.route(.{ .name = "focus", .id = "", .node_id = id });
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.a.code(), .ctrl = true }); // select all
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.c.code(), .ctrl = true }); // Ctrl+C
    try testing.expectEqual(@as(usize, 0), ts.stub_clip_len);
    // Ctrl+X is disabled too: the buffer is untouched.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.x.code(), .ctrl = true }); // Ctrl+X
    try testing.expectEqualStrings("abc", input.text_buffer.items);
    try testing.expectEqual(@as(usize, 0), ts.stub_clip_len);

    // A new codepoint extends the mask by exactly one bullet.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = events.Key.right.code() }); // right → collapse selection to end
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 'd' });
    try testing.expectEqualStrings("\u{2022}\u{2022}\u{2022}\u{2022}", env.store.getTextContent(input.text_node).?);
    try testing.expectEqualStrings("abcd", input.text_buffer.items);
}

test "TextInput password caret & click map through the bullet run" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_measure = true; // 10px per char (incl. the 3-byte bullet slice → 10px each)
    const input = try mount(&env, .{ .is_password = true, .initial_text = "abc" });
    const id = input.root_id;
    env.registry.getNode(input.text_node).?.geometry = .{ .x = 0, .y = 0, .width = 200, .height = 20 };
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Caret after "abc" → 3 bullets. mockMeasure returns 10px per byte, and the
    // bullet slice is 3 codepoints × 3 bytes = 9 bytes → 90px. So the mask advance
    // differs from the secret's, proving we measure the bullets, not the plaintext.
    const caret_x = env.store.getLayout(input.caret_node, .left).?.dimension.value;
    try testing.expectApproxEqAbs(PAD_L + 90.0, caret_x, 0.001);

    // Click near the first bullet boundary maps back to a real-buffer byte index.
    // Bullet 0 spans [0,30)px mid 15, bullet 1 [30,60) mid 45 → x=32 lands before
    // bullet 1 → codepoint 1 → byte 1 in "abc".
    env.route(.{ .name = "mouse_down", .id = "", .node_id = id, .x = 32.0, .y = 5.0 });
    try testing.expectEqual(@as(usize, 1), input.cursor_pos);
}

test "TextInput removes its tick and global handlers on unmount" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    env.registry.addNodeRemovedListener(&env.mounts, component.MountTable.nodeRemovedListener);
    env.registry.addNodeRemovedListener(&env.router, events.EventRouter.nodeRemovedListener);

    var b = component.UIBuilder.init(&env.registry, &env.store);
    var ctx = component.BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(TextInput, .{});
    b.close();
    try testing.expectEqual(@as(usize, 1), env.router.tick_handlers.items.len);
    try testing.expectEqual(@as(usize, 1), env.router.global_handlers.items.len);

    // Rebuild the root empty → the anchor is reconciled away → onUnmount removes
    // the tick + global handlers (and the instance is freed without leak).
    try b.rootAt(root);
    b.close();
    try testing.expectEqual(@as(usize, 0), env.router.tick_handlers.items.len);
    try testing.expectEqual(@as(usize, 0), env.router.global_handlers.items.len);
}

test "The caret band is derived from the shared vertical metrics and covers the glyphs' ink" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const input = try mount(&env, .{ .initial_text = "Adjuntar" });

    // The one source of truth, asked the same way the widget asks it.
    const vl = text_mod.verticalLayoutFor(.{}, FONT_SIZE, TEXT_H, 1);

    for ([_]reg.NodeId{ input.caret_node, input.sel_node }) |band| {
        try testing.expectApproxEqAbs(
            PAD_T + vl.caret_top,
            env.store.getLayout(band, .top).?.dimension.value,
            0.001,
        );
        try testing.expectApproxEqAbs(
            vl.caret_height,
            env.store.getLayout(band, .height).?.dimension.value,
            0.001,
        );
    }

    // What the derivation buys: the band brackets the ink it is supposed to mark —
    // from the top of the capitals to the bottom of the descenders. Hardcoded px
    // satisfied this only for the font size and box height they were written for.
    try testing.expect(vl.caret_top <= vl.cap_top);
    try testing.expect(vl.caret_top + vl.caret_height >= vl.ink_bottom);
}
