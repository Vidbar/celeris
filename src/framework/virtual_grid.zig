//! VirtualGrid — `VirtualList`'s 2D sibling.
//!
//! Windows BOTH axes over a **pull source** — `cell_at(payload, row, col)` and
//! `col_width_at(payload, col)`, not a materialized `items` slice — so a
//! 100k × 40 grid materializes only `~windowRows × windowCols` cell nodes.
//!
//! Structure (two-level keyed — flat cells would make `openNodeKeyed`'s per-call
//! linear scan O(rows×cols); nesting keeps every scan at one window dimension):
//!
//!   viewport            clip; owns on_scroll (Y) + on_scroll_h (X); focusable
//!   └─ body             column; scroll_offset_y = -row_scroll
//!      ├─ [top spacer]      key TOP_SPACER    height = row_start * row_height
//!      ├─ row wrapper       key = ABSOLUTE row index
//!      │   └─ strip     row; scroll_offset_x = -col_scroll
//!      │       ├─ [left spacer]  key LEFT_SPACER   width = col_offsets[col_start]
//!      │       ├─ cell          key = ABSOLUTE col index  (app's render fills it)
//!      │       └─ [right spacer] key RIGHT_SPACER  width = total_w - col_offsets[col_end]
//!      ├─ row wrapper …
//!      └─ [bottom spacer]   key BOTTOM_SPACER height = (row_count - row_end) * row_height
//!
//! Coarse/fine split, per axis (mirrors `VirtualList`): `row_start` / `col_start`
//! are memoized `Computed(usize)` — the range effect (`b.rootAt` repopulate)
//! fires only when a window crosses a cell boundary; the translation effects
//! write `scroll_offset_{y,x}` every scroll (render-only, no layout solve).
//! Vertical axis stays O(1) (`floor(top/row_height)`); the horizontal axis is
//! O(log col_count) — a prefix sum of column widths (`col_offsets`, rebuilt on
//! `data_rev`) + binary search.
//!
//! Owned behaviour is ONLY keyboard cell navigation (arrows / Tab / Home / End /
//! Page*), which writes the lifted `selected: ?*Signal(CellRange)` and scrolls
//! the focused cell into view. Headers, resize, sort, the edit UI, and cell
//! styling are the app's.

const std = @import("std");
const component = @import("component.zig");
const builder_mod = @import("builder.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;

/// A cell address.
pub const CellCoord = struct { row: usize = 0, col: usize = 0 };

/// A selected region. `focus == anchor` → a single cell. The grid only ever
/// writes a collapsed range (on navigation); an app that wants Shift+Arrow
/// range-extend does that in its own key handler and writes `selected` itself.
pub const CellRange = struct {
    anchor: CellCoord = .{},
    focus: CellCoord = .{},
};

// Spacer reconciliation keys — far from any absolute row/col index.
const TOP_SPACER_KEY: u64 = std.math.maxInt(u64);
const BOTTOM_SPACER_KEY: u64 = std.math.maxInt(u64) - 1;
const LEFT_SPACER_KEY: u64 = std.math.maxInt(u64) - 2;
const RIGHT_SPACER_KEY: u64 = std.math.maxInt(u64) - 3;

// Key codes (match core/events / the platform layer's virtual-key mapping).

pub fn VirtualGrid(comptime Datum: type) type {
    return struct {
        const Self = @This();

        /// Cell renderer: `render(payload, ctx, datum, row, col)`. Fills the cell
        /// wrapper (already sized). Build with `cellFn`.
        pub const RenderFn = *const fn (?*anyopaque, *BuildContext, Datum, usize, usize) anyerror!void;
        /// Pull source: the datum for a materialized cell.
        pub const CellAtFn = *const fn (?*anyopaque, usize, usize) Datum;
        /// Pull source: the width (px) of a column. Called for materialized
        /// columns and once per column when the prefix sum is (re)built.
        pub const ColWidthFn = *const fn (?*anyopaque, usize) f32;

        // ── Props (from init_props; re-applied on rebuild) ──────────────────────
        row_count: usize = 0,
        col_count: usize = 0,
        cell_at: CellAtFn = undefined,
        col_width_at: ColWidthFn = undefined,
        render: RenderFn = undefined,
        payload: ?*anyopaque = null,

        row_height: f32 = 24,
        /// Fixed viewport size (px). With `fill` they are only the frame-0
        /// estimate, used until the first solve reports the real size.
        viewport_width: f32 = 600,
        viewport_height: f32 = 400,
        /// Size the viewport to 100%×100% of the parent and track the real size
        /// via `on_resize`: a bigger window materializes more rows/columns
        /// without a scroll.
        fill: bool = false,
        /// Extra rows AND columns kept outside the viewport so a fast scroll
        /// doesn't flash blank before the next range rebuild.
        overdraw: u32 = 4,

        /// Lifted selection (caller-owned). The grid reads it to paint a
        /// highlight and writes a collapsed range on a navigation keypress.
        selected: ?*signals.Signal(CellRange) = null,
        /// Lifted data-revision (the `VirtualList` pattern): after mutating the
        /// source or the column widths, `.set(rev+1)` re-materializes and
        /// rebuilds the column prefix sum without a parent rebuild.
        data_rev: ?*signals.Signal(u32) = null,

        /// Optional caller-owned scroll offsets (px, `>= 0`). Pass them to sync a
        /// frozen header / first column, or to scroll the grid programmatically;
        /// the grid clamps what it writes. Omit → the internal fallbacks.
        row_scroll: ?*signals.Signal(f32) = null,
        col_scroll: ?*signals.Signal(f32) = null,

        // ── State (created in onMount / first build) ────────────────────────────
        row_scroll_int: signals.Signal(f32) = undefined,
        col_scroll_int: signals.Signal(f32) = undefined,
        scope: signals.Scope = undefined,
        row_start_sig: *signals.Computed(usize) = undefined,
        col_start_sig: *signals.Computed(usize) = undefined,
        /// Solved viewport size from `on_resize` (`fill` only); 0×0 = not solved
        /// yet, use the `viewport_width/height` estimate.
        measured: signals.Signal(Size) = undefined,
        /// How many rows/columns the viewport spans, memoized from `measured`:
        /// the range effect re-runs only when a resize changes what fits.
        shape_sig: *signals.Computed(Shape) = undefined,
        /// Prefix sum of column widths: `col_offsets[c]` = x of column c's left
        /// edge, `col_offsets[col_count]` = total width. Rebuilt lazily when the
        /// observed `data_rev` moves.
        col_offsets: std.array_list.Managed(f32) = undefined,
        col_offsets_rev: u32 = std.math.maxInt(u32),

        // ── Captured during build() ────────────────────────────────────────────
        store: ?*props.PropertyStore = null,
        registry: ?*reg.UIRegistry = null,
        router: ?*events.EventRouter = null,
        mounts: ?*component.MountTable = null,
        measure: ?component.TextMeasure = null,
        theme: theme_mod.Theme = undefined,
        viewport_node: reg.NodeId = reg.NULL_NODE,
        body_node: reg.NodeId = reg.NULL_NODE,
        bound: bool = false,

        pub fn onMount(self: *Self, allocator: std.mem.Allocator) void {
            self.row_scroll_int = signals.Signal(f32).init(allocator, 0);
            self.col_scroll_int = signals.Signal(f32).init(allocator, 0);
            self.measured = signals.Signal(Size).init(allocator, .{});
            self.scope = signals.Scope.init(allocator);
            self.col_offsets = std.array_list.Managed(f32).init(allocator);
        }

        pub fn deinit(self: *Self) void {
            self.scope.deinit();
            self.measured.deinit();
            self.row_scroll_int.deinit();
            self.col_scroll_int.deinit();
            self.col_offsets.deinit();
        }

        /// The active scroll signals: caller-owned if the `row_scroll` /
        /// `col_scroll` props were passed (so an app can sync a frozen header or
        /// scroll programmatically — the `ScrollView.offset` pattern), else the
        /// internal fallbacks.
        fn rowScrollSig(self: *Self) *signals.Signal(f32) {
            return self.row_scroll orelse &self.row_scroll_int;
        }
        fn colScrollSig(self: *Self) *signals.Signal(f32) {
            return self.col_scroll orelse &self.col_scroll_int;
        }

        // ── Range math ─────────────────────────────────────────────────────────

        const Size = struct { w: f32 = 0, h: f32 = 0 };
        const Shape = struct { rows: usize, cols_px: i64 };

        /// Viewport extent the window is sized for: the solved size once
        /// `on_resize` reported it (`fill`), else the props.
        fn vpW(self: *const Self) f32 {
            const m = self.measured.peek();
            return if (self.fill and m.w > 0) m.w else self.viewport_width;
        }
        fn vpH(self: *const Self) f32 {
            const m = self.measured.peek();
            return if (self.fill and m.h > 0) m.h else self.viewport_height;
        }

        /// `shape_sig`'s compute. Rows are exact; columns have variable widths, so
        /// the width is bucketed to whole pixels (the column end is recomputed in
        /// `populate` from the live width anyway).
        fn computeShape(self: *Self) Shape {
            _ = self.measured.get();
            return .{ .rows = self.visibleRows(), .cols_px = @intFromFloat(@ceil(self.vpW())) };
        }

        fn onResize(self: *Self, ev: events.Event) void {
            self.measured.set(.{ .w = ev.width, .h = ev.height });
            // A bigger viewport lowers both max scrolls: re-clamp.
            self.setRowScroll(self.rowScrollSig().peek());
            self.setColScroll(self.colScrollSig().peek());
        }

        fn visibleRows(self: *const Self) usize {
            if (self.row_height <= 0) return 0;
            return @intFromFloat(@ceil(self.vpH() / self.row_height));
        }

        fn windowRows(self: *const Self) usize {
            return self.visibleRows() + 2 * @as(usize, self.overdraw);
        }

        fn totalRowHeight(self: *const Self) f32 {
            return @as(f32, @floatFromInt(self.row_count)) * self.row_height;
        }

        fn totalColWidth(self: *Self) f32 {
            self.ensureColOffsets();
            if (self.col_offsets.items.len == 0) return 0;
            return self.col_offsets.items[self.col_offsets.items.len - 1];
        }

        /// (Re)builds `col_offsets` if the observed `data_rev` has moved (or on
        /// the first call). Cheap on a hit — one comparison.
        fn ensureColOffsets(self: *Self) void {
            const dr: u32 = if (self.data_rev) |rv| rv.peek() else 0;
            if (self.col_offsets_rev == dr and self.col_offsets.items.len == self.col_count + 1) return;
            self.col_offsets.clearRetainingCapacity();
            self.col_offsets.append(0) catch return;
            var acc: f32 = 0;
            var c: usize = 0;
            while (c < self.col_count) : (c += 1) {
                acc += @max(0, self.col_width_at(self.payload, c));
                self.col_offsets.append(acc) catch return;
            }
            self.col_offsets_rev = dr;
        }

        /// First materialized row index for the current vertical scroll:
        /// `floor(top / row_height) - overdraw`, floored at 0. Memoized in
        /// `row_start_sig`. Reads `row_scroll` reactively.
        fn computeRowStart(self: *Self) usize {
            if (self.row_height <= 0) return 0;
            const top = self.rowScrollSig().get();
            const first: i64 = @intFromFloat(@floor(top / self.row_height));
            const start = first - @as(i64, self.overdraw);
            return if (start < 0) 0 else @intCast(start);
        }

        /// First materialized column index: the last column whose left edge is
        /// `<= col_scroll`, minus overdraw. Binary search over `col_offsets`.
        /// Subscribes to `col_scroll` and `data_rev`.
        fn computeColStart(self: *Self) usize {
            if (self.data_rev) |rv| _ = rv.get(); // subscribe: widths may change
            self.ensureColOffsets();
            const x = self.colScrollSig().get();
            const offs = self.col_offsets.items;
            if (offs.len < 2) return 0;
            // upper_bound(offs, x) - 1 : index of the column containing x.
            var lo: usize = 0;
            var hi: usize = offs.len; // exclusive
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (offs[mid] <= x) lo = mid + 1 else hi = mid;
            }
            const contains: i64 = @as(i64, @intCast(lo)) - 1; // >= 0 since offs[0] == 0 <= x
            const start = contains - @as(i64, self.overdraw);
            return if (start < 0) 0 else @intCast(start);
        }

        /// One-past-last materialized column: the first column whose LEFT edge is
        /// `>= col_scroll + viewport_width`, plus overdraw, clamped to
        /// `col_count`. Binary search over `col_offsets` (already current here —
        /// `populate` calls `ensureColOffsets` first).
        fn colEnd(self: *Self, c_start: usize) usize {
            const offs = self.col_offsets.items;
            if (offs.len < 2) return 0;
            const right = self.colScrollSig().peek() + self.vpW();
            var lo: usize = c_start;
            var hi: usize = offs.len; // exclusive
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (offs[mid] < right) lo = mid + 1 else hi = mid;
            }
            const end = lo + self.overdraw; // lo = first col whose left edge >= right
            return @min(end, self.col_count);
        }

        // ── Scroll handling ───────────────────────────────────────────────────

        fn onScrollY(self: *Self, ev: events.Event) void {
            self.setRowScroll(self.rowScrollSig().peek() - ev.scroll_delta * 20.0);
        }

        fn onScrollX(self: *Self, ev: events.Event) void {
            self.setColScroll(self.colScrollSig().peek() - ev.scroll_delta * 20.0);
        }

        fn setRowScroll(self: *Self, value: f32) void {
            var t = value;
            if (t < 0) t = 0;
            const max_t = @max(0.0, self.totalRowHeight() - self.vpH());
            if (t > max_t) t = max_t;
            self.rowScrollSig().set(t);
        }

        fn setColScroll(self: *Self, value: f32) void {
            var t = value;
            if (t < 0) t = 0;
            const max_t = @max(0.0, self.totalColWidth() - self.vpW());
            if (t > max_t) t = max_t;
            self.colScrollSig().set(t);
        }

        // ── Keyboard navigation (the one owned behaviour) ─────────────────────

        fn onKey(self: *Self, ev: events.Event) void {
            if (self.row_count == 0 or self.col_count == 0) return;
            const sel = self.selected;
            const cur: CellCoord = if (sel) |s| s.peek().focus else .{};
            var f = cur;
            const max_r = self.row_count - 1;
            const max_c = self.col_count - 1;

            switch (events.Key.fromCode(ev.key_code) orelse return) {
                .left => f.col = if (f.col == 0) 0 else f.col - 1,
                .right => f.col = @min(max_c, f.col + 1),
                .up => f.row = if (f.row == 0) 0 else f.row - 1,
                .down => f.row = @min(max_r, f.row + 1),
                .home => if (ev.ctrl) {
                    f = .{ .row = 0, .col = 0 };
                } else {
                    f.col = 0;
                },
                .end => if (ev.ctrl) {
                    f = .{ .row = max_r, .col = max_c };
                } else {
                    f.col = max_c;
                },
                .page_up => {
                    const step = @max(1, self.visibleRows());
                    f.row = if (f.row < step) 0 else f.row - step;
                },
                .page_down => {
                    const step = @max(1, self.visibleRows());
                    f.row = @min(max_r, f.row + step);
                },
                .tab => {
                    if (ev.shift) {
                        if (f.col == 0) {
                            if (f.row > 0) {
                                f.row -= 1;
                                f.col = max_c;
                            }
                        } else f.col -= 1;
                    } else {
                        if (f.col == max_c) {
                            if (f.row < max_r) {
                                f.row += 1;
                                f.col = 0;
                            }
                        } else f.col += 1;
                    }
                },
                else => return,
            }

            if (f.row == cur.row and f.col == cur.col) return;
            if (sel) |s| s.set(.{ .anchor = f, .focus = f });
            self.scrollToCell(f);
        }

        /// Clamps `row_scroll` / `col_scroll` so `cell`'s box is inside the
        /// viewport (the `TreeView.ensureRowVisible` pattern — peek+set only, no
        /// `.get()`, so this never subscribes an effect to the offsets).
        fn scrollToCell(self: *Self, cell: CellCoord) void {
            // Vertical.
            const cell_top = @as(f32, @floatFromInt(cell.row)) * self.row_height;
            const cell_bot = cell_top + self.row_height;
            var rs = self.rowScrollSig().peek();
            if (cell_top < rs) {
                rs = cell_top;
            } else if (cell_bot > rs + self.vpH()) {
                rs = cell_bot - self.vpH();
            }
            self.setRowScroll(rs);

            // Horizontal.
            self.ensureColOffsets();
            if (self.col_offsets.items.len > cell.col + 1) {
                const cell_left = self.col_offsets.items[cell.col];
                const cell_right = self.col_offsets.items[cell.col + 1];
                var cs = self.colScrollSig().peek();
                if (cell_left < cs) {
                    cs = cell_left;
                } else if (cell_right > cs + self.vpW()) {
                    cs = cell_right - self.vpW();
                }
                self.setColScroll(cs);
            }
        }

        // ── Effects ───────────────────────────────────────────────────────────

        /// Coarse: repopulates `body` with the current row × col window. Fires
        /// once per boundary crossed on EITHER axis, and on data-revision bumps.
        fn rebuildRange(self: *Self) void {
            const registry = self.registry orelse return;
            _ = self.row_start_sig.get(); // subscribe: vertical window shifts
            _ = self.col_start_sig.get(); // subscribe: horizontal window shifts
            _ = self.shape_sig.get(); // subscribe: viewport resized (fill)
            if (self.data_rev) |rv| _ = rv.get(); // subscribe: data / widths change
            if (self.body_node == reg.NULL_NODE) return;

            var b = builder_mod.UIBuilder.init(registry, self.store.?);
            b.theme = self.theme;
            b.measure = self.measure;
            b.rootAt(self.body_node) catch return;
            var ctx = BuildContext{ .builder = &b, .router = self.router, .mounts = self.mounts };
            self.populate(&b, &ctx) catch {};
            std.debug.assert(b.parent_stack.len == 1);
            b.close();
            registry.markLayoutDirty(self.body_node);
        }

        fn populate(self: *Self, b: *builder_mod.UIBuilder, ctx: *BuildContext) !void {
            self.ensureColOffsets();
            const rc = self.row_count;
            const cc = self.col_count;
            const rh = self.row_height;

            const win_r = self.windowRows();
            var r_start = self.row_start_sig.peek();
            var r_end = r_start + win_r;
            if (r_end > rc) r_end = rc;
            if (r_end == rc and rc > win_r) r_start = rc - win_r;
            if (r_start > rc) r_start = rc;

            var c_start = self.col_start_sig.peek();
            if (c_start > cc) c_start = cc;
            const c_end = self.colEnd(c_start);

            const total_w = self.totalColWidth();
            const left_w = if (self.col_offsets.items.len > c_start) self.col_offsets.items[c_start] else 0;
            const right_w = if (self.col_offsets.items.len > c_end) total_w - self.col_offsets.items[c_end] else 0;

            // Top spacer: lifts row `r_start` to y = r_start*row_height in body.
            const top = try b.openNodeKeyed(.box, TOP_SPACER_KEY);
            try b.width(top, 100, .percent);
            try b.height(top, @as(f32, @floatFromInt(r_start)) * rh, .px);
            b.close();

            var r = r_start;
            while (r < r_end) : (r += 1) {
                const row_wrap = try b.openNodeKeyed(.box, @as(u64, r));
                try b.width(row_wrap, 100, .percent);
                try b.height(row_wrap, rh, .px);
                try b.store.setLayout(row_wrap, .flex_direction, .{ .keyword = .row });
                try b.overflowHidden(row_wrap);

                // The strip carries the horizontal translation for this row.
                const strip = try b.openNodeKeyed(.box, @as(u64, r) ^ 0x8000_0000_0000_0000);
                try b.height(strip, rh, .px);
                try b.store.setLayout(strip, .flex_direction, .{ .keyword = .row });

                const lsp = try b.openNodeKeyed(.box, LEFT_SPACER_KEY);
                try b.width(lsp, @max(0, left_w), .px);
                try b.height(lsp, rh, .px);
                b.close();

                var c = c_start;
                while (c < c_end) : (c += 1) {
                    const cell = try b.openNodeKeyed(.box, @as(u64, c));
                    try b.width(cell, @max(0, self.col_width_at(self.payload, c)), .px);
                    try b.height(cell, rh, .px);
                    try self.render(self.payload, ctx, self.cell_at(self.payload, r, c), r, c);
                    b.close();
                }

                const rsp = try b.openNodeKeyed(.box, RIGHT_SPACER_KEY);
                try b.width(rsp, @max(0, right_w), .px);
                try b.height(rsp, rh, .px);
                b.close();

                b.close(); // strip
                b.close(); // row_wrap
            }

            const bot = try b.openNodeKeyed(.box, BOTTOM_SPACER_KEY);
            try b.width(bot, 100, .percent);
            try b.height(bot, @as(f32, @floatFromInt(rc - r_end)) * rh, .px);
            b.close();
        }

        /// Fine: translate the body by `-row_scroll` and each row strip by
        /// `-col_scroll` (render-only). Subscribed to both scroll signals.
        fn updateTranslation(self: *Self) void {
            const store = self.store orelse return;
            const registry = self.registry orelse return;
            if (self.viewport_node == reg.NULL_NODE) return;
            const rtop = self.rowScrollSig().get();
            const cx = self.colScrollSig().get();
            store.setLayout(self.viewport_node, .scroll_offset_y, .{ .dimension = .{ .value = -rtop, .unit = .px } }) catch {};

            if (self.body_node == reg.NULL_NODE) return;
            // Walk the current row wrappers; each has one strip child.
            var child = registry.getNode(self.body_node).?.first_child;
            while (child != reg.NULL_NODE) : (child = registry.getNode(child).?.next_sibling) {
                const wrap = registry.getNode(child) orelse continue;
                if (wrap.key == null) continue; // spacer
                if (wrap.key.? >= BOTTOM_SPACER_KEY) continue;
                const strip = wrap.first_child;
                if (strip == reg.NULL_NODE) continue;
                store.setLayout(strip, .scroll_offset_x, .{ .dimension = .{ .value = -cx, .unit = .px } }) catch {};
            }
        }

        // ── Build ─────────────────────────────────────────────────────────────

        pub fn build(self: *Self, ctx: *BuildContext) !void {
            const b = ctx.builder;
            self.store = b.store;
            self.registry = b.registry;
            self.router = ctx.router;
            self.mounts = ctx.mounts;
            self.measure = b.measure;
            self.theme = b.theme;

            const viewport = if (self.fill) try ctx.boxNode(.{
                .width = component.pct(100),
                .height = component.pct(100),
                .direction = .column,
                .focusable = true,
                .on_scroll = ctx.handler(self, onScrollY),
                .on_scroll_h = ctx.handler(self, onScrollX),
                .on_key = ctx.handler(self, onKey),
                .on_resize = ctx.handler(self, onResize),
            }, .{
                Body{ .vg = self },
            }) else try ctx.boxNode(.{
                .width = self.viewport_width,
                .height = self.viewport_height,
                .direction = .column,
                .focusable = true,
                .on_scroll = ctx.handler(self, onScrollY),
                .on_scroll_h = ctx.handler(self, onScrollX),
                .on_key = ctx.handler(self, onKey),
            }, .{
                Body{ .vg = self },
            });
            self.viewport_node = viewport;
            try b.overflowHidden(viewport);
            // Tab/Shift+Tab move the active cell (onKey); Ctrl+Tab or
            // Escape→Tab leave the grid — see ModifierKey.captures_tab.
            try b.capturesTab(viewport);

            if (!self.bound) {
                self.row_start_sig = try self.scope.createComputed(usize, self, computeRowStart);
                self.col_start_sig = try self.scope.createComputed(usize, self, computeColStart);
                self.shape_sig = try self.scope.createComputed(Shape, self, computeShape);
                _ = try self.scope.createEffect(self, rebuildRange);
                _ = try self.scope.createEffect(self, updateTranslation);
                self.bound = true;
            } else {
                const prev = signals.untrackedBegin();
                self.rebuildRange();
                self.updateTranslation();
                signals.untrackedEnd(prev);
            }
        }

        pub const Body = struct {
            vg: *Self,
            pub fn build(self: *Body, ctx: *BuildContext) !void {
                const body = try ctx.builder.openNodeKeyed(.box, null);
                self.vg.body_node = body;
                try ctx.builder.width(body, 100, .percent);
                try ctx.builder.store.setLayout(body, .flex_direction, .{ .keyword = .column });
                ctx.builder.close();
            }
            pub fn deinit(_: *Body) void {}
        };

        /// Erases a typed cell renderer `fn (P, *BuildContext, Datum, usize, usize) !void`
        /// into a `RenderFn`. Pair with `.payload = p`.
        pub fn cellFn(comptime P: type, comptime f: fn (P, *BuildContext, Datum, usize, usize) anyerror!void) RenderFn {
            const Wrap = struct {
                fn call(erased: ?*anyopaque, ctx: *BuildContext, d: Datum, row: usize, col: usize) anyerror!void {
                    const typed: P = @ptrCast(@alignCast(erased.?));
                    return f(typed, ctx, d, row, col);
                }
            };
            return Wrap.call;
        }

        /// Erases a typed pull source `fn (P, row, col) Datum` into a `CellAtFn`.
        pub fn sourceFn(comptime P: type, comptime f: fn (P, usize, usize) Datum) CellAtFn {
            const Wrap = struct {
                fn call(erased: ?*anyopaque, row: usize, col: usize) Datum {
                    return f(@ptrCast(@alignCast(erased.?)), row, col);
                }
            };
            return Wrap.call;
        }

        /// Erases a typed column-width source `fn (P, col) f32` into a `ColWidthFn`.
        pub fn colWidthFn(comptime P: type, comptime f: fn (P, usize) f32) ColWidthFn {
            const Wrap = struct {
                fn call(erased: ?*anyopaque, col: usize) f32 {
                    return f(@ptrCast(@alignCast(erased.?)), col);
                }
            };
            return Wrap.call;
        }
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const TestEnv = @import("test_support.zig").Harness;

const Cell = struct { r: usize, c: usize };

const Src = struct {
    draws: usize = 0,
    fn cellAt(_: *Src, row: usize, col: usize) Cell {
        return .{ .r = row, .c = col };
    }
    fn colWidth(_: *Src, col: usize) f32 {
        return if (col % 2 == 0) 80 else 120; // deliberately non-uniform
    }
    fn draw(self: *Src, ctx: *BuildContext, d: Cell, row: usize, col: usize) anyerror!void {
        _ = d;
        _ = row;
        _ = col;
        self.draws += 1;
        _ = try ctx.builder.addText("");
    }
};

const VG = VirtualGrid(Cell);

fn mountVG(env: *TestEnv, init_props: anytype) !*VG {
    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = theme_mod.Theme.dark();
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    _ = try b.openNodeKeyed(.box, null);
    try ctx.mountOwned(VG, init_props);
    b.close();
    const anchor = env.registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(env.mounts.get(anchor).?.component_ptr));
}

fn childCount(registry: *reg.UIRegistry, parent: reg.NodeId) usize {
    var n: usize = 0;
    var cur = registry.getNode(parent).?.first_child;
    while (cur != reg.NULL_NODE) : (cur = registry.getNode(cur).?.next_sibling) n += 1;
    return n;
}

/// Only the prop fields (names/types a subset of VG) — a full `VG` literal would
/// carry `undefined` state fields into `applyProps` on rebuild.
const Props = struct {
    row_count: usize = 10_000,
    col_count: usize = 200,
    cell_at: VG.CellAtFn,
    col_width_at: VG.ColWidthFn,
    render: VG.RenderFn,
    payload: ?*anyopaque,
    row_height: f32 = 20,
    viewport_width: f32 = 400,
    viewport_height: f32 = 400,
    fill: bool = false,
    overdraw: u32 = 4,
    selected: ?*signals.Signal(CellRange) = null,
    data_rev: ?*signals.Signal(u32) = null,
};

fn baseProps(src: *Src) Props {
    return .{
        .cell_at = VG.sourceFn(*Src, Src.cellAt),
        .col_width_at = VG.colWidthFn(*Src, Src.colWidth),
        .render = VG.cellFn(*Src, Src.draw),
        .payload = src,
    };
}

/// The first materialized row strip, and the count of real cell wrappers in it.
fn firstStrip(registry: *reg.UIRegistry, body: reg.NodeId) reg.NodeId {
    const top = registry.getNode(body).?.first_child; // top spacer
    const row_wrap = registry.getNode(top).?.next_sibling;
    return registry.getNode(row_wrap).?.first_child; // strip
}

fn cellCount(registry: *reg.UIRegistry, strip: reg.NodeId) usize {
    var n: usize = 0;
    var cur = registry.getNode(strip).?.first_child;
    while (cur != reg.NULL_NODE) : (cur = registry.getNode(cur).?.next_sibling) {
        const node = registry.getNode(cur).?;
        if (node.key != null and node.key.? <= RIGHT_SPACER_KEY - 1) n += 1; // abs-col key, not a spacer
    }
    return n;
}

test "VirtualGrid windows both axes, not row_count*col_count cells" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var src = Src{};

    const p = baseProps(&src);
    const vg = try mountVG(&env, p);

    // Vertical window = ceil(400/20) + 2*4 = 28 rows. body = top + 28 wraps + bottom.
    try testing.expectEqual(@as(usize, 28), vg.windowRows());
    try testing.expectEqual(@as(usize, 30), childCount(&env.registry, vg.body_node));

    // Horizontal: col widths alternate 80/120 (avg 100), viewport 400 → ~4-5
    // visible + overdraw both sides. Far fewer than 200.
    const strip = firstStrip(&env.registry, vg.body_node);
    const cells = cellCount(&env.registry, strip);
    try testing.expect(cells > 0 and cells < 30); // ~5 visible + overdraw, not 200

    // Draw calls are O(window) — a naive grid would call render 10000*200 =
    // 2,000,000 times.
    try testing.expect(src.draws >= 28 * cells and src.draws < 28 * 40 * 3);

    // Top / left spacers start at 0; bottom spacer reserves the rest.
    var cur = env.registry.getNode(vg.body_node).?.first_child;
    try testing.expectApproxEqAbs(@as(f32, 0), env.store.getLayout(cur, .height).?.dimension.value, 0.001);
    while (env.registry.getNode(cur).?.next_sibling != reg.NULL_NODE) cur = env.registry.getNode(cur).?.next_sibling;
    try testing.expectApproxEqAbs(@as(f32, (10_000 - 28) * 20), env.store.getLayout(cur, .height).?.dimension.value, 0.5);
}

test "VirtualGrid vertical scroll: sub-row is render-only, crossing a row reuses in-range wrappers" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var src = Src{};
    const vg = try mountVG(&env, baseProps(&src));

    const draws0 = src.draws;
    env.registry.global_layout_dirty = false;

    // 8 px < one row → start stays 0, render-only translation.
    _ = env.router.route(.{ .name = "scroll", .id = "", .node_id = vg.viewport_node, .scroll_delta = -0.4 });
    try testing.expectApproxEqAbs(@as(f32, 8), vg.rowScrollSig().peek(), 0.001);
    try testing.expectEqual(@as(usize, 0), vg.row_start_sig.peek());
    try testing.expectEqual(draws0, src.draws);
    try testing.expect(!env.registry.global_layout_dirty);
    try testing.expectApproxEqAbs(@as(f32, -8), env.store.getLayout(vg.viewport_node, .scroll_offset_y).?.dimension.value, 0.001);

    // Cross 5 rows (100 px): start = floor(100/20) - 4 = 1. Row 10 stays in range,
    // keeps its NodeId.
    var before = std.array_list.Managed(reg.NodeId).init(testing.allocator);
    defer before.deinit();
    var c = env.registry.getNode(vg.body_node).?.first_child;
    while (c != reg.NULL_NODE) : (c = env.registry.getNode(c).?.next_sibling) try before.append(c);

    _ = env.router.route(.{ .name = "scroll", .id = "", .node_id = vg.viewport_node, .scroll_delta = -4.6 });
    try testing.expectEqual(@as(usize, 1), vg.row_start_sig.peek());
    try testing.expectEqual(@as(usize, 30), childCount(&env.registry, vg.body_node));

    var after = std.array_list.Managed(reg.NodeId).init(testing.allocator);
    defer after.deinit();
    c = env.registry.getNode(vg.body_node).?.first_child;
    while (c != reg.NULL_NODE) : (c = env.registry.getNode(c).?.next_sibling) try after.append(c);
    // before: [top, rows 0..27, bottom] → row 10 = before[11].
    // after:  [top, rows 1..28, bottom] → row 10 = after[10].
    try testing.expectEqual(before.items[11], after.items[10]);
}

test "VirtualGrid horizontal scroll translates each row strip (scroll_offset_x)" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var src = Src{};
    const vg = try mountVG(&env, baseProps(&src));

    _ = env.router.route(.{ .name = "scroll_h", .id = "", .node_id = vg.viewport_node, .scroll_delta = -3.0 });
    try testing.expectApproxEqAbs(@as(f32, 60), vg.colScrollSig().peek(), 0.001);

    // Every materialized row strip carries -60 on scroll_offset_x.
    var wrap = env.registry.getNode(vg.body_node).?.first_child;
    var checked: usize = 0;
    while (wrap != reg.NULL_NODE) : (wrap = env.registry.getNode(wrap).?.next_sibling) {
        const w = env.registry.getNode(wrap).?;
        if (w.key == null or w.key.? >= BOTTOM_SPACER_KEY) continue;
        const strip = w.first_child;
        try testing.expectApproxEqAbs(@as(f32, -60), env.store.getLayout(strip, .scroll_offset_x).?.dimension.value, 0.001);
        checked += 1;
    }
    try testing.expect(checked == 28);
}

test "VirtualGrid opts its viewport into captures_tab; Tab/Shift+Tab move the active cell" {
    var sel = signals.Signal(CellRange).init(testing.allocator, .{});
    defer sel.deinit();
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var src = Src{};
    var p = baseProps(&src);
    p.selected = &sel;
    const vg = try mountVG(&env, p);

    try testing.expect(vg.store.?.modifierFlag(vg.viewport_node, .captures_tab));
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = vg.viewport_node, .key_code = events.Key.tab.code() });
    try testing.expectEqual(CellCoord{ .row = 0, .col = 1 }, sel.peek().focus);
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = vg.viewport_node, .key_code = events.Key.tab.code(), .shift = true });
    try testing.expectEqual(CellCoord{ .row = 0, .col = 0 }, sel.peek().focus);
}

test "VirtualGrid keyboard navigation moves the lifted selection and scrolls into view" {
    var sel = signals.Signal(CellRange).init(testing.allocator, .{});
    defer sel.deinit();

    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var src = Src{};
    var p = baseProps(&src);
    p.selected = &sel;
    const vg = try mountVG(&env, p);

    // Arrow Down then Right → focus (1,1).
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = vg.viewport_node, .key_code = events.Key.down.code() });
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = vg.viewport_node, .key_code = events.Key.right.code() });
    try testing.expectEqual(CellCoord{ .row = 1, .col = 1 }, sel.peek().focus);
    try testing.expectEqual(sel.peek().anchor, sel.peek().focus); // collapsed

    // PageDown jumps ~visibleRows and scrolls the focused cell into view.
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = vg.viewport_node, .key_code = events.Key.page_down.code() });
    try testing.expectEqual(@as(usize, 1 + 20), sel.peek().focus.row); // visibleRows = 400/20
    try testing.expect(vg.rowScrollSig().peek() > 0); // scrolled down to reveal it

    // Ctrl+End → last cell.
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = vg.viewport_node, .key_code = events.Key.end.code(), .ctrl = true });
    try testing.expectEqual(CellCoord{ .row = 9_999, .col = 199 }, sel.peek().focus);

    // Ctrl+Home → back to origin.
    _ = env.router.route(.{ .name = "key_down", .id = "", .node_id = vg.viewport_node, .key_code = events.Key.home.code(), .ctrl = true });
    try testing.expectEqual(CellCoord{ .row = 0, .col = 0 }, sel.peek().focus);
    try testing.expectApproxEqAbs(@as(f32, 0), vg.rowScrollSig().peek(), 0.001);
}

test "VirtualGrid data_rev bump rebuilds the column prefix sum and re-materializes" {
    var rev = signals.Signal(u32).init(testing.allocator, 0);
    defer rev.deinit();

    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var src = Src{};
    var p = baseProps(&src);
    p.col_count = 3;
    p.data_rev = &rev;
    const vg = try mountVG(&env, p);

    // 3 columns, widths 80/120/80 → total 280, offsets [0, 80, 200, 280].
    try testing.expectApproxEqAbs(@as(f32, 280), vg.totalColWidth(), 0.001);
    const strip0 = firstStrip(&env.registry, vg.body_node);
    try testing.expectEqual(@as(usize, 3), cellCount(&env.registry, strip0));

    // Grow to 6 columns, bump the revision → prefix sum rebuilt, more cells.
    vg.col_count = 6;
    rev.set(1);
    try testing.expectApproxEqAbs(@as(f32, 80 + 120 + 80 + 120 + 80 + 120), vg.totalColWidth(), 0.001);
    const strip1 = firstStrip(&env.registry, vg.body_node);
    try testing.expectEqual(@as(usize, 6), cellCount(&env.registry, strip1));
}

test "VirtualGrid fill: growing the window materializes more rows and columns, no scroll needed" {
    var env = TestEnv.init(testing.allocator);
    defer env.deinit();
    env.wire();
    var src = Src{};

    var b = component.UIBuilder.init(&env.registry, &env.store);
    b.theme = theme_mod.Theme.dark();
    var ctx = BuildContext{ .builder = &b, .router = &env.router, .mounts = &env.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try b.width(root, 100, .percent);
    try b.height(root, 100, .percent);
    var p = baseProps(&src);
    p.fill = true;
    p.viewport_width = 100; // deliberately wrong frame-0 estimates
    p.viewport_height = 100;
    try ctx.mountOwned(VG, p);
    b.close();
    const vg: *VG = @ptrCast(@alignCast(env.mounts.get(env.registry.getNode(root).?.first_child).?.component_ptr));

    try testing.expectEqual(@as(usize, 5 + 8), vg.windowRows());
    const cells_est = cellCount(&env.registry, firstStrip(&env.registry, vg.body_node));

    _ = try env.frame(root, 400, 400);
    _ = try env.frame(root, 400, 400);
    try testing.expectEqual(@as(usize, 20 + 8), vg.windowRows());
    try testing.expectEqual(@as(usize, 30), childCount(&env.registry, vg.body_node));
    const cells_400 = cellCount(&env.registry, firstStrip(&env.registry, vg.body_node));
    try testing.expect(cells_400 > cells_est);

    _ = try env.frame(root, 1200, 1000);
    _ = try env.frame(root, 1200, 1000);
    try testing.expectEqual(@as(usize, 50 + 8), vg.windowRows());
    const cells_1200 = cellCount(&env.registry, firstStrip(&env.registry, vg.body_node));
    try testing.expect(cells_1200 > cells_400);
}
