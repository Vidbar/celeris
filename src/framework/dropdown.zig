//! Dropdown — reactive component migrated to the canonical Button pattern.
//!
//! Framework-owned via `ctx.mountOwned(Dropdown, .{ .options = &.{ "A", "B" } })`: no
//! `init`/`register`/`deinit`/action-id in user code. Options are a `[]const []const u8`
//! prop (owned by the caller). `is_open`/`selected`/`hovered` are `Signal`s auto-created
//! in `onMount`. The menu and rows are built once with `overflow_hidden`; an effect
//! drives the menu height (0 when closed → clipped, not hit-testable), selection
//! highlight, trigger background, arrow glyph and current label — all render-only.
//!
//! Per-option clicks use ONE typed handler that resolves the index by matching the
//! event's `node_id` against the captured row ids (no per-index string ids). A
//! full-window backdrop (absolute, 0-sized when closed) dismisses on click.
//!
//! Selection follows the lifted-state convention (`Tabs.active`): pass
//! `.selected = &my_signal` (a caller-owned `Signal(usize)`) to drive it from the
//! app — write it at any time (e.g. after reloading `options`) and the trigger
//! follows without a rebuild; a user pick writes it back. Omit it to use the
//! internal state seeded from `initial_selected`. `on_change` fires on a user
//! pick (click or ↑/↓) with `ev.name = "change"` and `ev.item_id` = the index.
//!
//! Dropdown is a *value picker* only. A picker that also runs commands
//! ("Edit Configurations…") or groups options under headers is a `Button` +
//! `fw.menu.Menu` with radio items — see "Selector with actions" in
//! docs/FRAMEWORK_API.md.

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");
const builder_mod = @import("builder.zig");

const BuildContext = component.BuildContext;
const Text = component.Text;
const EdgeInsets = component.EdgeInsets;

/// Gap between the trigger's bottom edge and the open menu.
const MENU_GAP: f32 = 4;
/// Option rows never get shorter than this, however small the trigger.
const MIN_ROW_H: f32 = 24;

pub const Dropdown = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    options: []const []const u8 = &.{},
    /// Optional caller-owned selected index (two-way, lifted-state convention).
    /// The shown option is always `min(selected, options.len - 1)`: after
    /// `options` shrinks, write a valid index yourself if you need the stored
    /// value to match (the widget never writes the signal on its own).
    selected: ?*signals.Signal(usize) = null,
    /// Seed of the internal state when no `selected` signal is passed.
    initial_selected: usize = 0,
    /// Fires on a user pick (click or ↑/↓) that changes the selection — never
    /// for a programmatic write. `ev.name = "change"`, `ev.item_id` = the new
    /// index, `ev.node_id` = the trigger.
    on_change: ?events.Handler = null,
    /// Trigger width in px; `null` = fit the widest option (plus padding and
    /// arrow), so every menu row fits and the trigger keeps one width whatever
    /// is selected — what WinUI's `ComboBox` does.
    width: ?f32 = 150,
    /// Trigger height in px; option rows use it too (min 24).
    height: f32 = 32,
    /// Font size of the trigger label and the option rows; `null` = the
    /// theme's `typography.body_medium` (size and line height).
    font_size: ?f32 = null,
    disabled: bool = false,
    /// Accessible name (aria-label). Without it the trigger's UIA Name is
    /// empty: its role, "dropdown", is not in `accessibility.nameFromContents`
    /// (a combobox's displayed text is a *value*, not a name a screen reader
    /// should read as the control's label — same reasoning as TextInput, which
    /// sources its own Name from `placeholder` rather than the typed value).
    /// Found empty over UI Automation with a real client (NVDA/Narrator read
    /// nothing when landing on the control) while every sibling widget in the
    /// same form (Button, Checkbox, Edit) had a name.
    aria_label: []const u8 = "",

    // State (auto-created in onMount; preserved across rebuilds).
    is_open: signals.Signal(bool) = undefined,
    /// Fallback when the caller passes no `selected` signal.
    selected_state: signals.Signal(usize) = undefined,
    hovered: signals.Signal(bool) = undefined,
    scope: signals.Scope = undefined,
    /// Row node ids for the current build (index ↔ option); repopulated each build.
    item_ids: std.array_list.Managed(reg.NodeId) = undefined,

    // Captured during build().
    store: ?*props.PropertyStore = null,
    root_id: reg.NodeId = reg.NULL_NODE,
    trigger_id: reg.NodeId = reg.NULL_NODE,
    label_id: reg.NodeId = reg.NULL_NODE,
    arrow_id: reg.NodeId = reg.NULL_NODE,
    menu_id: reg.NodeId = reg.NULL_NODE,
    backdrop_id: reg.NodeId = reg.NULL_NODE,
    theme: theme_mod.Theme = .{},
    bound: bool = false,
    /// The selection signal the visuals effect subscribed to. A rebuild that
    /// passes a different `.selected` recreates the effect (`bindVisuals`
    /// re-applies untracked, so it would keep following the old one).
    bound_sel: ?*signals.Signal(usize) = null,
    allocator: std.mem.Allocator = undefined,

    /// Text style of the label and rows: `font_size` over the theme's
    /// `body_medium` (whose line height is kept either way).
    fn textStyle(self: *const Dropdown) theme_mod.TextStyle {
        var st = self.theme.typography.body_medium;
        if (self.font_size) |s| st.size = s;
        return st;
    }

    pub fn onMount(self: *Dropdown, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        self.is_open = signals.Signal(bool).init(allocator, false);
        self.selected_state = signals.Signal(usize).init(allocator, self.initial_selected);
        self.hovered = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
        self.item_ids = std.array_list.Managed(reg.NodeId).init(allocator);
    }

    /// The selection signal: caller-owned if provided, else the internal one.
    pub fn selectedSig(self: *Dropdown) *signals.Signal(usize) {
        return self.selected orelse &self.selected_state;
    }

    /// The index actually shown: the signal's value clamped to `options`.
    fn effective(self: *const Dropdown, raw: usize) usize {
        if (self.options.len == 0) return 0;
        return @min(raw, self.options.len - 1);
    }

    /// `width = null`: widest option + the trigger's chrome (10 px padding each
    /// side, 8 px gap, arrow, 1 px borders). `measure` is `b.measure`; headless
    /// builds fall back to a per-character estimate.
    fn fitWidth(self: *const Dropdown, measure: ?builder_mod.TextMeasure) f32 {
        const size = self.textStyle().size;
        var widest: f32 = 0;
        for (self.options) |opt| {
            const w = if (measure) |m| m.width(opt, size) else @as(f32, @floatFromInt(opt.len)) * size * 0.6;
            widest = @max(widest, w);
        }
        const arrow = if (measure) |m| m.width("v", 12) else 7;
        return @ceil(widest + arrow + 10 * 2 + 8 + 2);
    }

    fn rowH(self: *const Dropdown) f32 {
        return @max(self.height, MIN_ROW_H);
    }

    /// Writes a user pick and notifies `on_change` (only if it changed).
    fn pick(self: *Dropdown, i: usize) void {
        const sig = self.selectedSig();
        if (sig.peek() == i) return;
        sig.set(i);
        if (self.on_change) |h| h.call(h.ptr, .{ .name = "change", .id = "", .item_id = i, .node_id = self.trigger_id });
    }

    pub fn deinit(self: *Dropdown) void {
        self.scope.deinit();
        self.is_open.deinit();
        self.selected_state.deinit();
        self.hovered.deinit();
        self.item_ids.deinit();
    }

    fn onTriggerClick(self: *Dropdown, ev: events.Event) void {
        _ = ev;
        if (self.disabled) return;
        self.is_open.set(!self.is_open.peek());
    }

    fn onDismiss(self: *Dropdown, ev: events.Event) void {
        _ = ev;
        self.is_open.set(false);
    }

    /// Keyboard on the focused trigger. ↑/↓ open the menu, then move the
    /// selection (clamped, notifying on change); Escape closes. Enter/Space are
    /// the engine's click synthesis → they toggle via onTriggerClick.
    fn onKey(self: *Dropdown, ev: events.Event) void {
        if (self.disabled) return;
        switch (events.Key.fromCode(ev.key_code) orelse return) {
            .escape => self.is_open.set(false), // Escape
            .up, .down => { // ↑ / ↓
                if (!self.is_open.peek()) {
                    self.is_open.set(true);
                    return;
                }
                const n = self.options.len;
                if (n == 0) return;
                const cur = self.effective(self.selectedSig().peek());
                const next = if (events.Key.fromCode(ev.key_code) == .up)
                    (if (cur == 0) 0 else cur - 1)
                else
                    @min(cur + 1, n - 1);
                self.pick(next);
            },
            else => {},
        }
    }

    /// One handler for every option row: resolves the picked index by matching the
    /// event's node against the captured row ids, then selects + closes + notifies.
    fn onOptionClick(self: *Dropdown, ev: events.Event) void {
        for (self.item_ids.items, 0..) |it, i| {
            if (it == ev.node_id) {
                self.is_open.set(false);
                self.pick(i);
                return;
            }
        }
    }

    pub fn build(self: *Dropdown, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = b.theme;
        self.theme = t;
        self.store = b.store;
        self.item_ids.clearRetainingCapacity();

        self.root_id = try b.openNodeKeyed(.box, null);
        try b.width(self.root_id, self.width orelse self.fitWidth(b.measure), .px);

        // Backdrop: full-window catcher below the menu; sized to 0 when closed.
        self.backdrop_id = try ctx.boxNode(.{
            .on_click = ctx.handler(self, onDismiss),
        }, .{});
        try b.positionAbsolute(self.backdrop_id, -10000, -10000);
        try b.backgroundAlpha(self.backdrop_id, 0, 0, 0, 0.0);
        try b.zIndex(self.backdrop_id, 50);

        // Trigger.
        self.trigger_id = try ctx.boxNode(.{
            .height = self.height,
            .padding = EdgeInsets.symmetric(10, 0),
            .gap = 8,
            .direction = .row,
            .@"align" = .center,
            .justify = .space_between,
            .border_width = 1,
            .radius = 4,
            .focusable = !self.disabled,
            .on_click = if (self.disabled) null else ctx.handler(self, onTriggerClick),
            .on_key = if (self.disabled) null else ctx.handler(self, onKey),
            .on_hover = if (self.disabled) null else ctx.signalSetter(&self.hovered),
        }, .{
            TriggerLabel{ .dd = self },
        });
        try b.store.setLayout(self.trigger_id, .width, .{ .dimension = .{ .value = 100, .unit = .percent } });
        try b.borderColorAlpha(self.trigger_id, 80, 80, 80, 255);
        // The combobox role + expand/collapse state live on the trigger, which is
        // the node that actually carries the click handler — so UIA's
        // ExpandCollapse.Expand/Collapse (a synthetic click) lands on a clickable
        // element instead of the outer wrapper.
        try b.role(self.trigger_id, "dropdown");
        if (self.aria_label.len > 0) try b.ariaLabel(self.trigger_id, self.aria_label);

        // Menu (always present, clipped to height 0 when closed).
        self.menu_id = try ctx.boxNode(.{
            .width = component.pct(100),
            .direction = .column,
            .border_width = 1,
            .radius = 4,
            .background = component.rgb(t.surface_high.r, t.surface_high.g, t.surface_high.b),
        }, .{
            Options{ .dd = self },
        });
        try b.positionAbsolute(self.menu_id, 0, self.height + MENU_GAP);
        try b.borderColorAlpha(self.menu_id, 80, 80, 80, 255);
        try b.overflowHidden(self.menu_id);
        try b.zIndex(self.menu_id, 100); // above the backdrop so options win the hit-test

        b.close(); // root

        if (self.bound and self.bound_sel != self.selectedSig()) {
            self.scope.deinit();
            self.scope = signals.Scope.init(self.allocator);
            self.bound = false;
        }
        self.bound_sel = self.selectedSig();
        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn updateVisuals(self: *Dropdown) void {
        const store = self.store orelse return;
        if (self.trigger_id == reg.NULL_NODE) return;
        const t = self.theme;
        const open = self.is_open.get();
        const hovered = self.hovered.get();
        const sel = self.effective(self.selectedSig().get());

        // Surface the open state for accessibility (UIA ExpandCollapsePattern reads
        // `.expanded` on the combobox node — the trigger, which also holds the role).
        store.setModifier(self.trigger_id, .expanded, .{ .boolean = open }) catch {};

        const trig_bg = if (hovered) t.bg_input else t.bg_surface;
        store.setStyle(self.trigger_id, .background, props.PropValue.rgbA(trig_bg.r, trig_bg.g, trig_bg.b, 1.0)) catch {};

        if (store.stringAllocator().dupe(u8, if (open) "^" else "v")) |arrow_str| {
            store.setTextContent(self.arrow_id, arrow_str);
        } else |_| {}
        if (self.options.len > 0) {
            const cur = self.options[sel];
            if (store.stringAllocator().dupe(u8, cur)) |label_str| {
                store.setTextContent(self.label_id, label_str);
            } else |_| {}
        }

        const h: f32 = if (open) @as(f32, @floatFromInt(self.options.len)) * self.rowH() else 0;
        store.setLayout(self.menu_id, .height, .{ .dimension = .{ .value = h, .unit = .px } }) catch {};

        const bd: f32 = if (open) 20000 else 0;
        store.setLayout(self.backdrop_id, .width, .{ .dimension = .{ .value = bd, .unit = .px } }) catch {};
        store.setLayout(self.backdrop_id, .height, .{ .dimension = .{ .value = bd, .unit = .px } }) catch {};

        for (self.item_ids.items, 0..) |item_id, i| {
            const a: f32 = if (i == sel) 100.0 / 255.0 else 0.0;
            store.setStyle(item_id, .background, props.PropValue.rgbA(t.accent.r, t.accent.g, t.accent.b, a)) catch {};
        }
    }
};

/// The trigger's current-selection label + arrow glyph. Built as a slot so the
/// trigger box can use the declarative props path; captures the label/arrow ids.
const TriggerLabel = struct {
    dd: *Dropdown,
    pub fn build(self: *TriggerLabel, ctx: *BuildContext) !void {
        const b = ctx.builder;
        const t = self.dd.theme;
        const sel0 = self.dd.effective(self.dd.selectedSig().peek());
        const cur = if (self.dd.options.len > 0) self.dd.options[sel0] else "Select...";
        self.dd.label_id = try b.addText(cur);
        const st = self.dd.textStyle();
        try b.fontSize(self.dd.label_id, st.size);
        if (st.line_height) |lh| try b.store.setStyle(self.dd.label_id, .line_height, .{ .number = lh });
        try b.textColor(self.dd.label_id, t.text.r, t.text.g, t.text.b);
        self.dd.arrow_id = try b.addText("v");
        try b.fontSize(self.dd.arrow_id, 12);
        try b.textColor(self.dd.arrow_id, t.text.r, t.text.g, t.text.b);
    }
    pub fn deinit(_: *TriggerLabel) void {}
};

/// The option rows. Each row is clickable and shares one typed handler; the row ids
/// are captured for the selection-highlight effect and index resolution on click.
const Options = struct {
    dd: *Dropdown,
    pub fn build(self: *Options, ctx: *BuildContext) !void {
        const dd = self.dd;
        const t = dd.theme;
        for (dd.options) |opt| {
            const item = try ctx.boxNode(.{
                .width = component.pct(100),
                .height = dd.rowH(),
                .padding = EdgeInsets.symmetric(10, 0),
                .direction = .row,
                .@"align" = .center,
                .on_click = ctx.handler(dd, Dropdown.onOptionClick),
            }, .{
                Text{ .content = opt, .color = component.rgb(t.text.r, t.text.g, t.text.b), .style = dd.textStyle() },
            });
            try dd.item_ids.append(item);
        }
    }
    pub fn deinit(_: *Options) void {}
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const dark = theme_mod.Theme.dark();

const OPTS = [_][]const u8{ "One", "Two", "Three" };

fn mountDropdown(
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    router: *events.EventRouter,
    mounts: *component.MountTable,
    init_props: anytype,
) !*Dropdown {
    var b = component.UIBuilder.init(registry, store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = router, .mounts = mounts };
    _ = try b.openNodeKeyed(.box, null); // root
    try ctx.mountOwned(Dropdown, init_props);
    b.close();
    const anchor = registry.getNode(0).?.first_child;
    return @ptrCast(@alignCast(mounts.get(anchor).?.component_ptr));
}

test "Dropdown (mountOwned) open toggles menu height; closed menu has zero height" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    const dd = try mountDropdown(&registry, &store, &router, &mounts, .{ .options = &OPTS });
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getLayout(dd.menu_id, .height).?.dimension.value, 0.001);

    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.trigger_id });
    try testing.expect(dd.is_open.peek());
    try testing.expectApproxEqAbs(@as(f32, 96.0), store.getLayout(dd.menu_id, .height).?.dimension.value, 0.001);
}

test "Dropdown selecting an option updates label, closes menu, highlights row" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    const Sink = struct {
        var changes: u32 = 0;
        fn onChange(_: ?*anyopaque, _: events.Event) void {
            changes += 1;
        }
    };
    Sink.changes = 0;

    const dd = try mountDropdown(&registry, &store, &router, &mounts, .{
        .options = &OPTS,
        .on_change = events.Handler{ .ptr = null, .call = Sink.onChange },
    });

    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.trigger_id }); // open
    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.item_ids.items[2] }); // pick "Three"

    try testing.expectEqual(@as(usize, 2), dd.selectedSig().peek());
    try testing.expect(!dd.is_open.peek());
    try testing.expectEqualStrings("Three", store.getTextContent(dd.label_id).?);
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 255.0), store.getStyle(dd.item_ids.items[2], .background).?.color.a, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getStyle(dd.item_ids.items[0], .background).?.color.a, 0.001);
    try testing.expectEqual(@as(u32, 1), Sink.changes);
}

test "Dropdown arrows open then move the selection; Escape closes" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    const dd = try mountDropdown(&registry, &store, &router, &mounts, .{ .options = &OPTS });

    // ↓ on the closed trigger opens without moving the selection.
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = events.Key.down.code() });
    try testing.expect(dd.is_open.peek());
    try testing.expectEqual(@as(usize, 0), dd.selectedSig().peek());

    // ↓↓ move down (clamped at the end); ↑ moves back up.
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = events.Key.down.code() });
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = events.Key.down.code() });
    try testing.expectEqual(@as(usize, 2), dd.selectedSig().peek());
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = events.Key.up.code() });
    try testing.expectEqual(@as(usize, 1), dd.selectedSig().peek());

    // Escape closes, keeping the selection.
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = events.Key.escape.code() });
    try testing.expect(!dd.is_open.peek());
    try testing.expectEqual(@as(usize, 1), dd.selectedSig().peek());
}

test "Dropdown closes on backdrop click without changing the selection" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    const dd = try mountDropdown(&registry, &store, &router, &mounts, .{ .options = &OPTS });

    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.trigger_id });
    try testing.expect(dd.is_open.peek());
    try testing.expectApproxEqAbs(@as(f32, 20000.0), store.getLayout(dd.backdrop_id, .width).?.dimension.value, 0.001);

    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.backdrop_id });
    try testing.expect(!dd.is_open.peek());
    try testing.expectEqual(@as(usize, 0), dd.selectedSig().peek());
    try testing.expectApproxEqAbs(@as(f32, 0.0), store.getLayout(dd.backdrop_id, .width).?.dimension.value, 0.001);
}

test "BUG: Dropdown's UIA Name was empty — role \"dropdown\" isn't in nameFromContents, and there was no way to set one" {
    // Found by driving a real windowed app through a UI Automation client: the
    // Button, Checkbox and Edit in the same form all had a Name (from their own
    // text, or from `.label`/`placeholder`), the ComboBox reported none — a
    // screen reader landing on it announces nothing. `accessibleName` only
    // pulls descendant text for roles in the name-from-contents allowlist, and
    // "dropdown" is correctly excluded (its shown text is a *value*, like
    // TextInput's typed text) — so it needed an explicit aria_label prop, the
    // same shape Checkbox and TextInput already use.
    const a11y = @import("../core/accessibility.zig");
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    const unlabeled = try mountDropdown(&registry, &store, &router, &mounts, .{ .options = &OPTS });
    try testing.expectEqualStrings("", a11y.accessibleName(&registry, &store, unlabeled.trigger_id));

    var registry2 = reg.UIRegistry.init(a);
    defer registry2.deinit();
    var store2 = props.PropertyStore.init(a);
    defer store2.deinit();
    store2.setRegistry(&registry2);
    var router2 = events.EventRouter.init(a);
    defer router2.deinit();
    var mounts2 = component.MountTable.init(a);
    defer mounts2.deinit();
    registry2.addNodeRemovedListener(&mounts2, component.MountTable.nodeRemovedListener);

    const labeled = try mountDropdown(&registry2, &store2, &router2, &mounts2, .{
        .options = &OPTS,
        .aria_label = "Render mode",
    });
    try testing.expectEqualStrings("Render mode", a11y.accessibleName(&registry2, &store2, labeled.trigger_id));
}

test "Dropdown lifted `selected`: app writes drive the label live; a pick writes back and reports its index" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    const Sink = struct {
        var calls: u32 = 0;
        var last: ?usize = null;
        fn onChange(_: ?*anyopaque, ev: events.Event) void {
            calls += 1;
            last = ev.item_id;
        }
    };
    Sink.calls = 0;
    Sink.last = null;

    var sel = signals.Signal(usize).init(a, 2);
    defer sel.deinit();
    const dd = try mountDropdown(&registry, &store, &router, &mounts, .{
        .options = &OPTS,
        .selected = &sel,
        .on_change = events.Handler{ .ptr = null, .call = Sink.onChange },
    });
    try testing.expectEqualStrings("Three", store.getTextContent(dd.label_id).?);

    // A programmatic write repaints with no rebuild — and is not a user change.
    sel.set(0);
    try testing.expectEqualStrings("One", store.getTextContent(dd.label_id).?);
    try testing.expectEqual(@as(u32, 0), Sink.calls);

    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.trigger_id });
    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.item_ids.items[1] });
    try testing.expectEqual(@as(usize, 1), sel.peek());
    try testing.expectEqual(@as(u32, 1), Sink.calls);
    try testing.expectEqual(@as(?usize, 1), Sink.last);
    try testing.expectEqualStrings("Two", store.getTextContent(dd.label_id).?);

    // Re-picking the current option is not a change.
    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.trigger_id });
    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.item_ids.items[1] });
    try testing.expectEqual(@as(u32, 1), Sink.calls);

    // ↓ reports through the same channel with the new index.
    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.trigger_id });
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = events.Key.down.code() });
    try testing.expectEqual(@as(?usize, 2), Sink.last);
}

test "Dropdown shows the last option when `selected` is past the end (options reloaded shorter)" {
    const a = testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);
    var router = events.EventRouter.init(a);
    defer router.deinit();
    var mounts = component.MountTable.init(a);
    defer mounts.deinit();
    registry.addNodeRemovedListener(&mounts, component.MountTable.nodeRemovedListener);

    var sel = signals.Signal(usize).init(a, 7);
    defer sel.deinit();
    const dd = try mountDropdown(&registry, &store, &router, &mounts, .{ .options = &OPTS, .selected = &sel });
    try testing.expectEqualStrings("Three", store.getTextContent(dd.label_id).?);
    // ↑ from the clamped position moves to "Two", not to index 6.
    _ = router.route(.{ .name = "click", .id = "", .node_id = dd.trigger_id });
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = events.Key.up.code() });
    try testing.expectEqual(@as(usize, 1), sel.peek());
}

const ts = @import("test_support.zig");

fn mountInRow(e: *ts.Harness, init_props: anytype) !struct { root: reg.NodeId, dd: *Dropdown } {
    var b = component.UIBuilder.init(&e.registry, &e.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &e.router, .mounts = &e.mounts };
    const root = try b.openNodeKeyed(.box, null);
    try b.flexRow(root);
    try b.alignItems(root, .flex_start);
    try ctx.mountOwned(Dropdown, init_props);
    b.close();
    const anchor = e.registry.getNode(root).?.first_child;
    return .{ .root = root, .dd = @ptrCast(@alignCast(e.mounts.get(anchor).?.component_ptr)) };
}

test "Dropdown height/width are real geometry: 26 px toolbar trigger, menu docked under it" {
    var e = ts.Harness.init(testing.allocator);
    defer e.deinit();
    e.wire();
    const m = try mountInRow(&e, .{ .options = &OPTS, .height = 26, .width = 120, .font_size = 12 });
    e.solve(m.root, 800, 600);
    try testing.expectApproxEqAbs(@as(f32, 26), e.geom(m.dd.trigger_id).height, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 120), e.geom(m.dd.trigger_id).width, 0.5);

    _ = e.router.route(.{ .name = "click", .id = "", .node_id = m.dd.trigger_id });
    e.solve(m.root, 800, 600);
    const menu = e.geom(m.dd.menu_id);
    try testing.expectApproxEqAbs(e.geom(m.dd.trigger_id).y + 26 + MENU_GAP, menu.y, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 3 * 26), menu.height, 0.5);
}

test "Dropdown width = null fits the WIDEST option, so menu rows fit and the trigger never jumps" {
    // Found in the selector_actions example: hugging the *current* label made
    // the menu (100% of the trigger) narrower than "ReleaseSafe" while
    // "Debug" was selected.
    var e = ts.Harness.init(testing.allocator);
    defer e.deinit();
    e.wire();
    const opts = [_][]const u8{ "Go", "A much longer option" };
    var sel = signals.Signal(usize).init(testing.allocator, 0);
    defer sel.deinit();
    const m = try mountInRow(&e, .{ .options = &opts, .selected = &sel, .width = null });
    e.solve(m.root, 800, 600);
    const w0 = e.geom(m.dd.trigger_id).width;
    try testing.expectApproxEqAbs(m.dd.fitWidth(null), w0, 0.5);

    sel.set(1);
    _ = e.router.route(.{ .name = "click", .id = "", .node_id = m.dd.trigger_id });
    e.solve(m.root, 800, 600);
    try testing.expectApproxEqAbs(w0, e.geom(m.dd.trigger_id).width, 0.5);
    try testing.expectApproxEqAbs(w0, e.geom(m.dd.menu_id).width, 0.5);
}

test "Dropdown text follows the theme's body_medium unless font_size is set" {
    var e = ts.Harness.init(testing.allocator);
    defer e.deinit();
    e.wire();
    const m = try mountInRow(&e, .{ .options = &OPTS });
    const want = dark.typography.body_medium;
    try testing.expectApproxEqAbs(want.size, e.store.getStyle(m.dd.label_id, .font_size).?.dimension.value, 0.001);
    const row_text = e.registry.getNode(m.dd.item_ids.items[0]).?.first_child;
    try testing.expectApproxEqAbs(want.size, e.store.getStyle(row_text, .font_size).?.dimension.value, 0.001);
    if (want.line_height) |lh| try testing.expectApproxEqAbs(lh, e.store.getStyle(row_text, .line_height).?.number, 0.001);

    var e2 = ts.Harness.init(testing.allocator);
    defer e2.deinit();
    e2.wire();
    const m2 = try mountInRow(&e2, .{ .options = &OPTS, .font_size = 11 });
    try testing.expectApproxEqAbs(@as(f32, 11), e2.store.getStyle(m2.dd.label_id, .font_size).?.dimension.value, 0.001);
}

test "BUG: a rebuild that swaps the `selected` signal kept following the old one" {
    // Review finding: `bindVisuals` re-applies untracked on rebuild, so the
    // effect stayed subscribed to the first signal.
    const a = testing.allocator;
    var e = ts.Harness.init(a);
    defer e.deinit();
    e.wire();
    var first = signals.Signal(usize).init(a, 0);
    defer first.deinit();
    var second = signals.Signal(usize).init(a, 1);
    defer second.deinit();

    const dd = try mountDropdown(&e.registry, &e.store, &e.router, &e.mounts, .{ .options = &OPTS, .selected = &first });
    try testing.expectEqualStrings("One", e.store.getTextContent(dd.label_id).?);

    // Simulate the host's re-mount with new props: same instance, new pointer.
    dd.selected = &second;
    var b = component.UIBuilder.init(&e.registry, &e.store);
    b.theme = dark;
    var ctx = BuildContext{ .builder = &b, .router = &e.router, .mounts = &e.mounts };
    _ = try b.openNodeKeyed(.box, null);
    try dd.build(&ctx);
    b.close();
    try testing.expectEqualStrings("Two", e.store.getTextContent(dd.label_id).?);

    second.set(2);
    try testing.expectEqualStrings("Three", e.store.getTextContent(dd.label_id).?);
    first.set(0); // the old signal no longer drives it
    try testing.expectEqualStrings("Three", e.store.getTextContent(dd.label_id).?);
}
