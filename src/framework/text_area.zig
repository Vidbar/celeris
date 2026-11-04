//! TextArea — reactive component migrated to the canonical pattern.
//!
//! Multi-line cousin of TextInput. Framework-owned via
//! `ctx.mountOwned(TextArea, .{ .initial_text = "…" })`: no `init`/`register`/
//! `deinit`/action-id in user code. Buffers, signals and the visuals scope are
//! created in `onMount(self, allocator)`; `initial_text` seeds the buffer once.
//! Events (focus/blur/click/keyboard/IME) arrive through typed per-node handlers
//! registered in `build()` (`router.onNode`, one `onEvent` dispatching by name —
//! the edit model is untouched). The caret blink uses the router's tick handler,
//! registered against `root_id` and pruned automatically when that node is
//! removed.
//!
//! `focused` / `caret_on` are Signals; `rev` bumps on every text/cursor edit to
//! re-run the visuals effect. The effect writes focus styling, the text content,
//! the caret position/opacity and the selection highlight into the store, so
//! typing and the blink are render/layout writes — never a widget rebuild.
//!
//! Selection mirrors TextInput's model (`sel_anchor` + shared
//! `component.selectionRange`) but the highlight is multi-line: the standard
//! editor three-rectangle model — a partial first line, a full middle block, and
//! a partial last line (see `updateVisuals`). Shift+arrows/Home/End extend,
//! click+drag selects, double-click picks the word and triple-click the line,
//! and copy/cut/paste/typing all act on the range.
//!
//! Caret/click positioning is a monospace, line-based estimate read from the
//! text node's solved geometry in the registry — no C-ABI round-trip. It does
//! not account for the engine's word-wrapping; exact metrics come from
//! `builder.measure` when present (same compromise documented in TextInput).
//!
//! Hosted by ScrollView through the `component.Child` handle.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const text_mod = @import("../render/text.zig");

/// Line height at the default size. Only for call sites with no instance at hand;
/// everything on a TextArea must use `self.lineH()`, which follows `font_size`.
const LINE_H: f32 = text_mod.lineHeight(16.0);
const PAD: f32 = 8.0;

pub const TextArea = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    /// Seed text, applied to the buffer once in `onMount`.
    initial_text: []const u8 = "",
    /// Typed submit handler, called on Enter (without shift) with the root's id.
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
    font_size: f32 = 16.0,
    min_lines: ?usize = null,
    max_lines: ?usize = null,
    draw_background: bool = true,
    draw_border: bool = true,

    // State (created in onMount; preserved across rebuilds; freed in deinit —
    // the framework frees the instance itself).
    allocator: std.mem.Allocator = undefined,
    text_buffer: std.array_list.Managed(u8) = undefined,
    /// IME preedit (in-progress composition), shown inline at the caret but not
    /// part of `text_buffer` until committed.
    preedit: std.array_list.Managed(u8) = undefined,
    focused: signals.Signal(bool) = undefined,
    caret_on: signals.Signal(bool) = undefined,
    rev: signals.Signal(u32) = undefined,
    scope: signals.Scope = undefined,
    /// Undo/redo stack; every buffer mutation funnels through `applyEdit`.
    history: component.EditHistory = undefined,
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
    root_id: reg.NodeId = reg.NULL_NODE,
    text_node: reg.NodeId = reg.NULL_NODE,
    caret_node: reg.NodeId = reg.NULL_NODE,
    preedit_node: reg.NodeId = reg.NULL_NODE,
    // Multi-line selection highlight: three rects (first partial line, full middle
    // block, last partial line). Width/height 0 when unused.
    sel_first: reg.NodeId = reg.NULL_NODE,
    sel_mid: reg.NodeId = reg.NULL_NODE,
    sel_last: reg.NodeId = reg.NULL_NODE,
    theme: @import("theme.zig").Theme = .{},
    bound: bool = false,

    pub fn onMount(self: *TextArea, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        self.text_buffer = std.array_list.Managed(u8).init(allocator);
        self.preedit = std.array_list.Managed(u8).init(allocator);
        self.focused = signals.Signal(bool).init(allocator, false);
        self.caret_on = signals.Signal(bool).init(allocator, false);
        self.rev = signals.Signal(u32).init(allocator, 0);
        self.scope = signals.Scope.init(allocator);
        self.history = component.EditHistory.init(allocator);
        self.text_buffer.appendSlice(self.initial_text) catch {};
        self.cursor_pos = self.text_buffer.items.len;
    }

    /// Disarms state only — the framework owns and frees the instance.
    pub fn deinit(self: *TextArea) void {
        self.scope.deinit();
        self.focused.deinit();
        self.caret_on.deinit();
        self.rev.deinit();
        self.history.deinit();
        self.text_buffer.deinit();
        self.preedit.deinit();
    }

    /// This area's line height. Follows `font_size` — the caret, the row math and
    /// the selection rects all read it here so they can't be sized for one font
    /// size while the glyphs are drawn at another (see `text.lineHeight`).
    fn lineH(self: *const TextArea) f32 {
        return text_mod.lineHeight(self.font_size);
    }

    /// Advance per character for the no-measurement path, at this area's font size.
    fn charW(self: *const TextArea) f32 {
        return component.fallbackCharWidth(self.font_size);
    }

    // ── UTF-8 cursor helpers (cursor_pos is a byte index; step whole codepoints) ──
    // prev/nextBoundary are shared with TextInput, in component.zig.
    fn prevBoundary(self: *const TextArea, i: usize) usize {
        return component.prevBoundary(self.text_buffer.items, i);
    }
    fn nextBoundary(self: *const TextArea, i: usize) usize {
        return component.nextBoundary(self.text_buffer.items, i);
    }
    /// Inserts a UTF-8 string at the cursor (replacing any selection), advancing
    /// the cursor past it and recording it for undo. Used by both normal char
    /// input and IME commit.
    pub fn insertText(self: *TextArea, text: []const u8) void {
        if (text.len == 0) return;
        const r = self.selRange();
        const at = if (r) |rr| rr.start else self.cursor_pos;
        const rl = if (r) |rr| rr.end - rr.start else 0;
        const coalesce = rl == 0 and component.coalescesInsert(text);
        component.applyEdit(self, at, rl, text, coalesce);
    }

    pub fn bumpRev(self: *TextArea) void {
        self.rev.set(self.rev.peek() +% 1);
    }

    /// The active selection, or null when there's no (or empty) selection
    /// (shared, buffer-clamped model — see `component.selectionRange`).
    pub fn selRange(self: *const TextArea) ?component.Range {
        return component.selectionRange(self.text_buffer.items.len, self.sel_anchor, self.cursor_pos);
    }

    fn onTick(self: *TextArea) void {
        if (self.focused.peek()) self.caret_on.set(!self.caret_on.peek());
    }

    fn onGlobal(self: *TextArea, ev: events.Event) void {
        if (self.selecting and std.mem.eql(u8, ev.name, "mouse_move")) {
            self.cursor_pos = self.indexFromClick(ev.x, ev.y); // extend to the pointer
            self.bumpRev();
        } else if (std.mem.eql(u8, ev.name, "mouse_up")) {
            self.selecting = false;
        }
    }

    fn onEvent(self: *TextArea, ev: events.Event) void {
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
            self.focused.set(true);
            self.caret_on.set(true);
            const pos = self.indexFromClick(ev.x, ev.y);
            if (ev.shift) {
                if (self.sel_anchor == null) self.sel_anchor = self.cursor_pos;
            } else {
                self.sel_anchor = pos; // begin a fresh (empty) selection at the click
            }
            self.cursor_pos = pos;
            self.selecting = true;
            self.bumpRev();
            return;
        }
        if (std.mem.eql(u8, ev.name, "mouse_up")) {
            self.selecting = false;
            return;
        }
        if (std.mem.eql(u8, ev.name, "double_click")) {
            // key_code carries the click count: 2 = word, 3+ = whole line.
            const pos = self.indexFromClick(ev.x, ev.y);
            if (ev.key_code >= 3) {
                const buf = self.text_buffer.items;
                const line = lineColAt(buf, pos).line;
                self.sel_anchor = indexForLineCol(buf, line, 0);
                self.cursor_pos = lineEndIndex(buf, line);
            } else {
                const w = component.wordRangeAt(self.text_buffer.items, pos);
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

        // Clamp positions to the buffer before any edit: byte indices can drift out
        // of range (stale anchor, external prefill) and the paths below index the
        // buffer directly.
        if (self.cursor_pos > len) self.cursor_pos = len;
        if (self.sel_anchor) |a| {
            if (a > len) self.sel_anchor = len;
        }

        // Ctrl shortcuts (VK: A=65, C=67, V=86, X=88, Z=90, Y=89).
        if (ev.ctrl and std.mem.eql(u8, ev.name, "key_down")) {
            switch (kc) {
                65 => { // select all
                    self.sel_anchor = 0;
                    self.cursor_pos = len;
                    self.bumpRev();
                },
                67 => component.clipboardCopySelection(self),
                86 => component.clipboardPaste(self, true),
                88 => { // cut
                    component.clipboardCopySelection(self);
                    if (self.selRange()) |r| {
                        component.applyEdit(self, r.start, r.end - r.start, "", false);
                    } else {
                        component.applyEdit(self, 0, len, "", false);
                    }
                    self.bumpRev();
                },
                90 => if (ev.shift) component.editRedo(self) else component.editUndo(self), // Ctrl+Z / Ctrl+Shift+Z
                89 => component.editRedo(self), // Ctrl+Y
                else => {},
            }
            return;
        }

        // IME composition / commit.
        if (component.handleImeEvent(self, ev)) return;

        if (std.mem.eql(u8, ev.name, "char_input")) {
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
            if (kc == 13 and !ev.shift) {
                if (self.on_submit) |h| {
                    h.call(h.ptr, .{ .name = "submit", .id = "", .node_id = self.root_id });
                    return;
                }
            }
            self.handleKey(kc, ev.shift);
        }
    }

    fn handleKey(self: *TextArea, kc: i64, shift: bool) void {
        switch (kc) {
            8 => { // backspace — delete the selection, else the codepoint before the cursor
                if (self.selRange()) |r| {
                    component.applyEdit(self, r.start, r.end - r.start, "", false);
                } else if (self.cursor_pos > 0) {
                    const prev = self.prevBoundary(self.cursor_pos);
                    component.applyEdit(self, prev, self.cursor_pos - prev, "", false);
                }
                self.bumpRev();
            },
            13 => { // enter — replaces any selection with a newline
                const r = self.selRange();
                const at = if (r) |rr| rr.start else self.cursor_pos;
                const rl = if (r) |rr| rr.end - rr.start else 0;
                component.applyEdit(self, at, rl, "\n", false);
                self.bumpRev();
            },
            37 => self.applyMove(self.prevBoundary(self.cursor_pos), shift, .left), // left
            39 => self.applyMove(self.nextBoundary(self.cursor_pos), shift, .right), // right
            36 => self.applyMove(lineStartOf(self.text_buffer.items, self.cursor_pos), shift, .left), // Home
            35 => self.applyMove(lineEndIndex(self.text_buffer.items, lineColAt(self.text_buffer.items, self.cursor_pos).line), shift, .right), // End
            38 => self.applyMove(self.lineTarget(-1), shift, .vertical), // up
            40 => self.applyMove(self.lineTarget(1), shift, .vertical), // down
            else => {},
        }
    }

    /// Byte offset one line up/down from the cursor, preserving the column.
    fn lineTarget(self: *TextArea, delta: i32) usize {
        const buf = self.text_buffer.items;
        const lc = lineColAt(buf, self.cursor_pos);
        const target_line: i64 = @as(i64, @intCast(lc.line)) + delta;
        if (target_line < 0) return 0;
        return indexForLineCol(buf, @intCast(target_line), lc.col);
    }

    /// Moves the cursor to `target`, extending the selection when `shift` is held;
    /// otherwise collapses an existing selection toward `dir` before the move.
    fn applyMove(self: *TextArea, target: usize, extend: bool, dir: enum { left, right, vertical }) void {
        if (extend) {
            if (self.sel_anchor == null) self.sel_anchor = self.cursor_pos;
            self.cursor_pos = target;
        } else if (self.selRange()) |r| {
            self.cursor_pos = switch (dir) {
                .left => r.start,
                .right => r.end,
                .vertical => target,
            };
            self.sel_anchor = null;
        } else {
            self.cursor_pos = target;
        }
        self.bumpRev();
    }

    /// Byte index for a click at absolute (gx, gy), from the text node's geometry.
    fn indexFromClick(self: *TextArea, gx: f32, gy: f32) usize {
        const store = self.store orelse return self.cursor_pos;
        const registry = store.registry orelse return self.cursor_pos;
        if (self.text_node == reg.NULL_NODE) return self.cursor_pos;
        const node = registry.getNode(self.text_node) orelse return self.cursor_pos;
        const local_x = gx - node.geometry.x;
        const local_y = gy - node.geometry.y;

        const line: usize = if (local_y <= 0) 0 else @intFromFloat(local_y / self.lineH());
        const buf = self.text_buffer.items;
        const line_start = indexForLineCol(buf, line, 0);
        const line_end = lineEndIndex(buf, line);
        const col = component.columnAtX(self.measure, buf[line_start..line_end], self.font_size, local_x);
        return indexForLineCol(buf, line, col);
    }

    /// Event kinds routed to `onEvent` by node id (one handler, name dispatch).
    const NODE_KINDS = [_]events.EventKind{
        .focus,    .blur,       .mouse_down,       .mouse_up,    .double_click,
        .key_down, .char_input, .text_composition, .text_commit,
    };

    pub fn build(self: *TextArea, ctx: *component.BuildContext) !void {
        const b = ctx.builder;
        self.theme = b.theme;
        self.store = b.store;
        self.router = ctx.router;
        self.measure = b.measure;
        self.clipboard = b.clipboard;

        const root = try b.openNodeKeyed(.box, null);
        self.root_id = root;
        try b.cursor(root, "text"); // I-beam over the editor
        try b.width(root, 100, .percent);

        if (self.min_lines) |ml| {
            const min_h = (PAD * 2.0) + (@as(f32, @floatFromInt(ml)) * self.lineH());
            try b.minHeight(root, min_h, .px);
        }
        if (self.max_lines) |ml| {
            const max_h = (PAD * 2.0) + (@as(f32, @floatFromInt(ml)) * self.lineH());
            try b.maxHeight(root, max_h, .px);
        }

        if (self.min_lines == null and self.max_lines == null) {
            try b.height(root, 100, .percent);
        }
        try b.padding(root, PAD, PAD, PAD, PAD);
        try b.role(root, "textarea");
        // Autogenerated action id (same pattern as wireHandler): the C-ABI hit/focus
        // channel keeps its string, but routing is by node id + typed handlers.
        var idbuf: [16]u8 = undefined;
        const auto_id = std.fmt.bufPrint(&idbuf, "n{d}", .{root}) catch "n";
        try b.clickable(root, auto_id);
        try b.focusable(root, auto_id);
        try b.overflowHidden(root);
        try b.radius(root, self.theme.radius_base);

        if (ctx.router) |r| {
            const h = ctx.handler(self, onEvent);
            for (NODE_KINDS) |k| try r.onNode(root, k, h);
        }

        // Selection highlight — three translucent boxes behind the text (drawn
        // before it): a partial first line, a full middle block and a partial last
        // line. Width/height 0 = unused; updateVisuals sizes/positions them.
        inline for (.{ "sel_first", "sel_mid", "sel_last" }) |field| {
            const sn = try b.openNodeKeyed(.box, null);
            @field(self, field) = sn;
            try b.positionAbsolute(sn, PAD, PAD);
            try b.width(sn, 0, .px);
            try b.height(sn, 0, .px);
            try b.backgroundAlpha(sn, self.theme.accent.r, self.theme.accent.g, self.theme.accent.b, 0.35);
            b.close();
        }

        const text_node = try b.addText(self.text_buffer.items);
        self.text_node = text_node;
        try b.width(text_node, 100, .percent);
        try b.fontSize(text_node, self.font_size);
        try b.textColor(text_node, self.theme.text.r, self.theme.text.g, self.theme.text.b);

        const caret = try b.openNodeKeyed(.box, null);
        self.caret_node = caret;
        try b.positionAbsolute(caret, PAD, PAD);
        try b.width(caret, 2, .px);
        try b.height(caret, self.lineH(), .px);
        try b.backgroundAlpha(caret, self.theme.accent.r, self.theme.accent.g, self.theme.accent.b, 1.0);
        b.close(); // caret

        // IME preedit overlay at the caret (accent colour), empty until composing.
        const pre = try b.addText("");
        self.preedit_node = pre;
        try b.positionAbsolute(pre, PAD, PAD);
        try b.fontSize(pre, self.font_size);
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

    fn updateVisuals(self: *TextArea) void {
        const store = self.store orelse return;
        if (self.text_node == reg.NULL_NODE) return;
        const t = self.theme;
        const focused = self.focused.get();
        const caret_on = self.caret_on.get();
        _ = self.rev.get(); // subscribe to edits

        // Background + border reflect focus.
        if (self.draw_background) {
            const bg = if (focused) t.bg_input else t.bg_surface;
            store.setStyle(self.root_id, .background, props.PropValue.rgbA(bg.r, bg.g, bg.b, @as(f32, @floatFromInt(bg.a)) / 255.0)) catch {};
        } else {
            store.setStyle(self.root_id, .background, props.PropValue.rgbA(0, 0, 0, 0.0)) catch {};
        }

        if (self.draw_border) {
            if (t.border_width > 0) {
                store.setStyle(self.root_id, .border_width, .{ .dimension = .{ .value = t.border_width, .unit = .px } }) catch {};
                const bc = if (focused) t.accent else t.border_color;
                store.setStyle(self.root_id, .border_color, props.PropValue.rgbA(bc.r, bc.g, bc.b, @as(f32, @floatFromInt(bc.a)) / 255.0)) catch {};
            }
        } else {
            store.setStyle(self.root_id, .border_width, .{ .dimension = .{ .value = 0, .unit = .px } }) catch {};
        }

        // Displayed text: the dimmed placeholder while empty, else the buffer. The
        // placeholder is visual only — the caret stays at 0 and the model is untouched.
        const show_placeholder = self.text_buffer.items.len == 0 and self.placeholder.len > 0;
        const display: []const u8 = if (show_placeholder) self.placeholder else self.text_buffer.items;
        // Text content (dupe — setTextContent owns/frees with the store allocator).
        if (store.stringAllocator().dupe(u8, display)) |owned| {
            store.setTextContent(self.text_node, owned);
        } else |_| {}
        const tcol = if (show_placeholder) t.text_disabled else t.text;
        store.setStyle(self.text_node, .color, props.PropValue.rgbA(tcol.r, tcol.g, tcol.b, 1.0)) catch {};

        self.updateSelection(store);

        // Caret: exact horizontal (measure the current line up to the cursor when
        // the atlas is available) + line-based vertical; monospace x as fallback.
        const lc = lineColAt(self.text_buffer.items, self.cursor_pos);
        const caret_x = blk: {
            if (self.measure) |m| {
                const line_start = indexForLineCol(self.text_buffer.items, lc.line, 0);
                const cursor = @min(self.cursor_pos, self.text_buffer.items.len);
                break :blk PAD + m.width(self.text_buffer.items[line_start..cursor], self.font_size);
            }
            break :blk PAD + @as(f32, @floatFromInt(lc.col)) * self.charW();
        };
        const caret_y = PAD + rowTop(lc.line, self.lineH());

        // IME preedit: rendered inline at the caret; the caret then sits after it.
        var pre_w: f32 = 0;
        if (self.preedit_node != reg.NULL_NODE) {
            if (store.stringAllocator().dupe(u8, self.preedit.items)) |owned| {
                store.setTextContent(self.preedit_node, owned);
            } else |_| {}
            store.setLayout(self.preedit_node, .left, .{ .dimension = .{ .value = caret_x, .unit = .px } }) catch {};
            store.setLayout(self.preedit_node, .top, .{ .dimension = .{ .value = caret_y, .unit = .px } }) catch {};
            if (self.preedit.items.len > 0) {
                pre_w = if (self.measure) |m| m.width(self.preedit.items, self.font_size) else @as(f32, @floatFromInt(self.preedit.items.len)) * self.charW();
            }
        }

        store.setLayout(self.caret_node, .left, .{ .dimension = .{ .value = caret_x + pre_w, .unit = .px } }) catch {};
        store.setLayout(self.caret_node, .top, .{ .dimension = .{ .value = caret_y, .unit = .px } }) catch {};
        store.setStyle(self.caret_node, .opacity, .{ .number = if (focused and caret_on) 1.0 else 0.0 }) catch {};
    }

    /// x offset (without PAD) of byte position `pos` within its own line — exact
    /// via the atlas, else a monospace estimate.
    fn xForPos(self: *TextArea, pos: usize) f32 {
        const buf = self.text_buffer.items;
        const lc = lineColAt(buf, pos);
        if (self.measure) |m| {
            const line_start = indexForLineCol(buf, lc.line, 0);
            return m.width(buf[line_start..@min(pos, buf.len)], self.font_size);
        }
        return @as(f32, @floatFromInt(lc.col)) * self.charW();
    }

    /// Rendered width of `line`'s text (up to its newline / the buffer end).
    fn lineWidthOf(self: *TextArea, line: usize) f32 {
        const buf = self.text_buffer.items;
        return self.xForPos(lineEndIndex(buf, line));
    }

    /// Sizes the three selection rects (first partial line, full middle block,
    /// last partial line) from the active range; width/height 0 hides each.
    fn updateSelection(self: *TextArea, store: *props.PropertyStore) void {
        const hide = struct {
            fn f(s: *props.PropertyStore, node: reg.NodeId) void {
                s.setLayout(node, .width, .{ .dimension = .{ .value = 0, .unit = .px } }) catch {};
                s.setLayout(node, .height, .{ .dimension = .{ .value = 0, .unit = .px } }) catch {};
            }
        }.f;
        hide(store, self.sel_first);
        hide(store, self.sel_mid);
        hide(store, self.sel_last);

        const r = self.selRange() orelse return;
        const buf = self.text_buffer.items;
        const s = lineColAt(buf, r.start);
        const e = lineColAt(buf, r.end);
        const lh = self.lineH();

        const place = struct {
            fn f(st: *props.PropertyStore, node: reg.NodeId, left: f32, top: f32, w: f32, h: f32) void {
                st.setLayout(node, .left, .{ .dimension = .{ .value = left, .unit = .px } }) catch {};
                st.setLayout(node, .top, .{ .dimension = .{ .value = top, .unit = .px } }) catch {};
                st.setLayout(node, .width, .{ .dimension = .{ .value = @max(w, 0), .unit = .px } }) catch {};
                st.setLayout(node, .height, .{ .dimension = .{ .value = h, .unit = .px } }) catch {};
            }
        }.f;

        if (s.line == e.line) {
            const x0 = self.xForPos(r.start);
            const x1 = self.xForPos(r.end);
            place(store, self.sel_first, PAD + x0, PAD + rowTop(s.line, lh), x1 - x0, lh);
            return;
        }

        // First line: from the start column to the end of that line.
        const x0 = self.xForPos(r.start);
        const first_end = self.lineWidthOf(s.line);
        place(store, self.sel_first, PAD + x0, PAD + rowTop(s.line, lh), first_end - x0, lh);

        // Middle block: the full lines strictly between first and last, widened to
        // the widest of them.
        if (e.line > s.line + 1) {
            var max_w: f32 = 0;
            var ln = s.line + 1;
            while (ln < e.line) : (ln += 1) max_w = @max(max_w, self.lineWidthOf(ln));
            const rows: f32 = @floatFromInt(e.line - s.line - 1);
            place(store, self.sel_mid, PAD, PAD + rowTop(s.line + 1, lh), max_w, rows * lh);
        }

        // Last line: from its start to the end column.
        const x1 = self.xForPos(r.end);
        place(store, self.sel_last, PAD, PAD + rowTop(e.line, lh), x1, lh);
    }
};

/// Top offset (without PAD) of a line's row, at line height `lh`.
fn rowTop(line: usize, lh: f32) f32 {
    return @as(f32, @floatFromInt(line)) * lh;
}

const LineCol = struct { line: usize, col: usize };

/// Line/column of a byte offset, counting '\n' as line breaks.
fn lineColAt(buf: []const u8, pos: usize) LineCol {
    var line: usize = 0;
    var col: usize = 0;
    const end = @min(pos, buf.len);
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (buf[i] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

/// Byte offset of (line, col), clamped to the requested line's length and to the
/// buffer end. Column past a line's end snaps to the newline.
fn indexForLineCol(buf: []const u8, line: usize, col: usize) usize {
    var cur_line: usize = 0;
    var i: usize = 0;
    // Advance to the start of the target line.
    while (i < buf.len and cur_line < line) : (i += 1) {
        if (buf[i] == '\n') cur_line += 1;
    }
    if (cur_line < line) return buf.len; // requested line is past the end
    // Walk up to `col` columns or until the line ends.
    var c: usize = 0;
    while (i < buf.len and buf[i] != '\n' and c < col) : (i += 1) c += 1;
    return i;
}

/// Byte offset of the start of the line containing `pos` (just after the previous
/// '\n', or 0).
fn lineStartOf(buf: []const u8, pos: usize) usize {
    const p = @min(pos, buf.len);
    return indexForLineCol(buf, lineColAt(buf, p).line, 0);
}

/// Byte offset of the end of `line` (the position of its '\n', or the buffer end).
fn lineEndIndex(buf: []const u8, line: usize) usize {
    var i = indexForLineCol(buf, line, 0);
    while (i < buf.len and buf[i] != '\n') i += 1;
    return i;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "lineColAt / indexForLineCol round-trip across newlines" {
    const buf = "ab\ncde\nf";
    try testing.expectEqual(LineCol{ .line = 0, .col = 0 }, lineColAt(buf, 0));
    try testing.expectEqual(LineCol{ .line = 0, .col = 2 }, lineColAt(buf, 2));
    try testing.expectEqual(LineCol{ .line = 1, .col = 0 }, lineColAt(buf, 3)); // just after first \n
    try testing.expectEqual(LineCol{ .line = 1, .col = 2 }, lineColAt(buf, 5));
    try testing.expectEqual(LineCol{ .line = 2, .col = 1 }, lineColAt(buf, 8));

    // Column clamps to line length.
    try testing.expectEqual(@as(usize, 2), indexForLineCol(buf, 0, 99)); // end of "ab"
    try testing.expectEqual(@as(usize, 3), indexForLineCol(buf, 1, 0));
    try testing.expectEqual(@as(usize, 6), indexForLineCol(buf, 1, 99)); // end of "cde"
    try testing.expectEqual(buf.len, indexForLineCol(buf, 9, 0)); // past last line
}

const ts = @import("test_support.zig");
const TestEnv = ts.Harness;

/// Mounts a framework-owned TextArea under a fresh root and returns the
/// instance (mountSlider pattern from slider.zig). `with_measure`/
/// `with_clipboard` on the env install the shared text stubs.
fn mount(env: *TestEnv, init_props: anytype) !*TextArea {
    env.wire();
    var b = component.UIBuilder.init(&env.registry, &env.store);
    if (env.with_measure) b.measure = .{ .ctx = @ptrCast(&ts.text_dummy), .measureFn = ts.mockMeasure };
    if (env.with_clipboard) b.clipboard = .{ .ctx = @ptrCast(&ts.text_dummy), .getFn = ts.stubClipGet, .setFn = ts.stubClipSet };
    var ctx = component.BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(TextArea, init_props);
    b.close();
    const anchor = env.registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));
}

test "TextArea typing, Enter, and vertical caret navigation" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const ta = try mount(&env, .{});
    const id = ta.root_id;

    // Focus, type "ab", Enter, type "cd" → "ab\ncd" (typed per-node routing).
    env.route(.{ .name = "focus", .id = "", .node_id = id });
    try testing.expect(ta.focused.peek());
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 97 }); // 'a'
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 98 }); // 'b'
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 13 }); // Enter
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 99 }); // 'c'
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 100 }); // 'd'
    try testing.expectEqualStrings("ab\ncd", env.store.getTextContent(ta.text_node).?);
    try testing.expectEqual(@as(usize, 5), ta.cursor_pos);

    // Caret sits on line 1, col 2.
    try testing.expectApproxEqAbs(PAD + LINE_H, env.store.getLayout(ta.caret_node, .top).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(PAD + 2 * ta.charW(), env.store.getLayout(ta.caret_node, .left).?.dimension.value, 0.001);

    // Arrow up preserves column (2) → lands at index 2 on line 0.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 38 });
    try testing.expectEqual(@as(usize, 2), ta.cursor_pos);
    try testing.expectApproxEqAbs(@as(f32, PAD), env.store.getLayout(ta.caret_node, .top).?.dimension.value, 0.001);

    // Backspace removes the 'b'.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 8 });
    try testing.expectEqualStrings("a\ncd", env.store.getTextContent(ta.text_node).?);

    // Tick toggles the caret; blur hides it.
    env.route(.{ .name = "tick", .id = "" });
    env.route(.{ .name = "blur", .id = "", .node_id = id });
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getStyle(ta.caret_node, .opacity).?.number, 0.001);
}

test "TextArea placeholder shows dimmed while empty and vanishes on first char" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const ta = try mount(&env, .{ .placeholder = "Type here..." });
    const id = ta.root_id;

    // Empty buffer → dimmed placeholder, model untouched (caret 0, buffer empty).
    try testing.expectEqualStrings("Type here...", env.store.getTextContent(ta.text_node).?);
    try testing.expectEqual(@as(usize, 0), ta.cursor_pos);
    try testing.expectEqual(@as(usize, 0), ta.text_buffer.items.len);
    const dim = env.store.getStyle(ta.text_node, .color).?.color;
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(ta.theme.text_disabled.r)) / 255.0, dim.r, 0.001);

    // First char → placeholder gone, normal colour.
    env.route(.{ .name = "focus", .id = "", .node_id = id });
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 'a' });
    try testing.expectEqualStrings("a", env.store.getTextContent(ta.text_node).?);
    const norm = env.store.getStyle(ta.text_node, .color).?.color;
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(ta.theme.text.r)) / 255.0, norm.r, 0.001);
}

test "TextArea IME + UTF-8: preedit, commit, and codepoint-aware backspace/arrows" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const ta = try mount(&env, .{});
    const id = ta.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Preedit shows but isn't committed; then commit inserts the final CJK string.
    env.route(.{ .name = "text_composition", .id = "", .node_id = id, .text = "\u{306B}\u{307B}" });
    try testing.expectEqualStrings("\u{306B}\u{307B}", env.store.getTextContent(ta.preedit_node).?);
    try testing.expectEqualStrings("", env.store.getTextContent(ta.text_node).?);
    env.route(.{ .name = "text_commit", .id = "", .node_id = id, .text = "\u{65E5}\u{672C}" }); // 日本
    try testing.expectEqualStrings("\u{65E5}\u{672C}", env.store.getTextContent(ta.text_node).?);
    try testing.expectEqualStrings("", env.store.getTextContent(ta.preedit_node).?);
    try testing.expectEqual(@as(usize, 6), ta.cursor_pos);

    // Left steps one codepoint (3 bytes), backspace removes a whole codepoint.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 37 });
    try testing.expectEqual(@as(usize, 3), ta.cursor_pos);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 39 }); // back to end
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 8 }); // delete 本
    try testing.expectEqualStrings("\u{65E5}", env.store.getTextContent(ta.text_node).?);
    try testing.expectEqual(@as(usize, 3), ta.cursor_pos);

    // char_input carrying UTF-8 inserts it (not just ASCII).
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .text = "\u{00E9}" }); // é
    try testing.expectEqualStrings("\u{65E5}\u{00E9}", env.store.getTextContent(ta.text_node).?);
}

test "TextArea click positions the cursor from solved geometry" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const ta = try mount(&env, .{ .initial_text = "hello\nworld" });
    const id = ta.root_id;

    // Solved layout: text node at origin.
    env.registry.getNode(ta.text_node).?.geometry = .{ .x = 0, .y = 0, .width = 200, .height = 40 };

    // Click on the second line, ~col 3 → index of 'l' in "world".
    env.route(.{ .name = "mouse_down", .id = "", .node_id = id, .x = 24.0, .y = 25.0 });
    try testing.expectEqual(indexForLineCol("hello\nworld", 1, 3), ta.cursor_pos);
}

test "TextArea click uses measured x to pick the column on the clicked line" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_measure = true; // 10px/char
    const ta = try mount(&env, .{ .initial_text = "ab\ncde" });
    const id = ta.root_id;
    env.registry.getNode(ta.text_node).?.geometry = .{ .x = 0, .y = 0, .width = 200, .height = 40 };

    // Click line 1 (y=25 → line 1), x=12: 'c'[0,10)mid5, 'd'[10,20)mid15 → 12<15 →
    // col 1 → index 4 ('d') in "ab\ncde".
    env.route(.{ .name = "mouse_down", .id = "", .node_id = id, .x = 12.0, .y = 25.0 });
    try testing.expectEqual(indexForLineCol("ab\ncde", 1, 1), ta.cursor_pos);
    try testing.expectEqual(@as(usize, 4), ta.cursor_pos);
}

test "TextArea on_submit fires on plain Enter (typed handler); shift+Enter inserts a newline" {
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
    const ta = try mount(&env, .{ .on_submit = events.Handler{ .ptr = null, .call = Sink.onSubmit } });
    const id = ta.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 13 }); // Enter → submit
    try testing.expectEqual(@as(u32, 1), Sink.submits);
    try testing.expectEqual(id, Sink.last_node);
    try testing.expectEqual(@as(usize, 0), ta.text_buffer.items.len); // no newline inserted

    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 13, .shift = true }); // shift+Enter
    try testing.expectEqual(@as(u32, 1), Sink.submits); // unchanged
    try testing.expectEqualStrings("\n", ta.text_buffer.items);
}

test "TextArea on_change fires on mutations (incl. undo/redo) but not on caret moves" {
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
    const ta = try mount(&env, .{ .on_change = events.Handler{ .ptr = null, .call = Sink.onChange } });
    const id = ta.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Type "ab" → two fires, last buffer "ab".
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 'a' });
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 'b' });
    try testing.expectEqual(@as(u32, 2), Sink.calls);
    try testing.expectEqualStrings("ab", Sink.last_buf[0..Sink.last_len]);

    // Home (caret move) does not fire.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 36 }); // Home
    try testing.expectEqual(@as(u32, 2), Sink.calls);

    // Undo fires with the reduced buffer; redo fires with it restored.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 90, .ctrl = true }); // Ctrl+Z (undo "ab" coalesced)
    try testing.expectEqual(@as(u32, 3), Sink.calls);
    try testing.expectEqualStrings("", Sink.last_buf[0..Sink.last_len]);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 89, .ctrl = true }); // Ctrl+Y (redo)
    try testing.expectEqual(@as(u32, 4), Sink.calls);
    try testing.expectEqualStrings("ab", Sink.last_buf[0..Sink.last_len]);
}

test "TextArea undo/redo: multi-line paste is one step; typing coalesces per word" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_clipboard = true;
    const ta = try mount(&env, .{});
    const id = ta.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Paste a multi-line string in one step.
    _ = ts.stubClipSet(undefined, "a\nb");
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 86, .ctrl = true }); // Ctrl+V
    try testing.expectEqualStrings("a\nb", env.store.getTextContent(ta.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 90, .ctrl = true }); // undo → whole paste gone
    try testing.expectEqualStrings("", env.store.getTextContent(ta.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 89, .ctrl = true }); // redo
    try testing.expectEqualStrings("a\nb", env.store.getTextContent(ta.text_node).?);

    // Type " cd": the space is its own step, "cd" coalesces.
    for (" cd") |ch| env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = ch });
    try testing.expectEqualStrings("a\nb cd", env.store.getTextContent(ta.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 90, .ctrl = true }); // undo "cd"
    try testing.expectEqualStrings("a\nb ", env.store.getTextContent(ta.text_node).?);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 90, .ctrl = true }); // undo " "
    try testing.expectEqualStrings("a\nb", env.store.getTextContent(ta.text_node).?);
}

test "TextArea removes its tick and global handlers on unmount" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);
    env.registry.addNodeRemovedListener(&env.mounts, component.MountTable.nodeRemovedListener);
    env.registry.addNodeRemovedListener(&env.router, events.EventRouter.nodeRemovedListener);

    var b = component.UIBuilder.init(&env.registry, &env.store);
    var ctx = component.BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(TextArea, .{});
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

test "TextArea selection: shift+arrows extend, typing replaces, backspace deletes range" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    const ta = try mount(&env, .{ .initial_text = "abcd" });
    const id = ta.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Cursor at end (4). Shift+Left twice selects "cd".
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 37, .shift = true });
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 37, .shift = true });
    try testing.expectEqual(@as(usize, 2), ta.cursor_pos);
    try testing.expect(ta.selRange() != null);

    // Typing replaces the selection → "abX", cursor at 3, no selection left.
    env.route(.{ .name = "char_input", .id = "", .node_id = id, .key_code = 88 }); // 'X'
    try testing.expectEqualStrings("abX", env.store.getTextContent(ta.text_node).?);
    try testing.expectEqual(@as(usize, 3), ta.cursor_pos);
    try testing.expect(ta.selRange() == null);

    // Shift+Home selects back to the line start; backspace deletes the whole range.
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 36, .shift = true });
    try testing.expectEqual(@as(usize, 0), ta.cursor_pos);
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 8 });
    try testing.expectEqualStrings("", env.store.getTextContent(ta.text_node).?);
}

test "TextArea multi-line highlight: 3 rects with correct bounds; cut collapses the range" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.with_measure = true; // 10px/char
    env.with_clipboard = true;
    const ta = try mount(&env, .{ .initial_text = "ab\ncde\nfg" });
    const id = ta.root_id;
    env.route(.{ .name = "focus", .id = "", .node_id = id });

    // Select from line0 col1 (index 1) to line2 col1 (index 8): spans 3 lines.
    ta.sel_anchor = 1;
    ta.cursor_pos = 8;
    ta.bumpRev();

    // First line rect: from x=10 ("a") to end of "ab" (x=20) → width 10, on row 0.
    try testing.expectApproxEqAbs(PAD + 10.0, env.store.getLayout(ta.sel_first, .left).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10.0), env.store.getLayout(ta.sel_first, .width).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, PAD), env.store.getLayout(ta.sel_first, .top).?.dimension.value, 0.001);

    // Middle block: full line1 "cde" (width 30), one row tall at row 1.
    try testing.expectApproxEqAbs(@as(f32, PAD), env.store.getLayout(ta.sel_mid, .left).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 30.0), env.store.getLayout(ta.sel_mid, .width).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(PAD + LINE_H, env.store.getLayout(ta.sel_mid, .top).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(LINE_H, env.store.getLayout(ta.sel_mid, .height).?.dimension.value, 0.001);

    // Last line rect: from start to col1 of "fg" (x=10), on row 2.
    try testing.expectApproxEqAbs(@as(f32, PAD), env.store.getLayout(ta.sel_last, .left).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10.0), env.store.getLayout(ta.sel_last, .width).?.dimension.value, 0.001);
    try testing.expectApproxEqAbs(PAD + 2 * LINE_H, env.store.getLayout(ta.sel_last, .top).?.dimension.value, 0.001);

    // Ctrl+X cuts the range "b\ncde\nf" → buffer "ag", caret at the range start (1).
    env.route(.{ .name = "key_down", .id = "", .node_id = id, .key_code = 88, .ctrl = true });
    try testing.expectEqualStrings("b\ncde\nf", ts.stub_clip_buf[0..ts.stub_clip_len]);
    try testing.expectEqualStrings("ag", env.store.getTextContent(ta.text_node).?);
    try testing.expectEqual(@as(usize, 1), ta.cursor_pos);
    // Highlight cleared after the cut (no selection).
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.store.getLayout(ta.sel_first, .width).?.dimension.value, 0.001);
}

test "The caret and the row math follow font_size, not a hardcoded 16px line" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    // A non-default size: with the line height frozen at 16px, the caret was the
    // wrong height and every row after the first sat at the wrong y.
    const ta = try mount(&env, .{ .initial_text = "uno\ndos", .font_size = 24.0 });
    const lh = text_mod.lineHeight(24.0);

    try testing.expectApproxEqAbs(lh, env.store.getLayout(ta.caret_node, .height).?.dimension.value, 0.001);
    try testing.expect(lh != LINE_H); // the sizes really differ — the test has teeth

    // Caret on the second line sits one *scaled* row down.
    ta.cursor_pos = ta.text_buffer.items.len;
    ta.bumpRev();
    try testing.expectApproxEqAbs(PAD + lh, env.store.getLayout(ta.caret_node, .top).?.dimension.value, 0.001);
}
