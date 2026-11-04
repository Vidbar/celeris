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

const std = @import("std");
const component = @import("component.zig");
const signals = @import("../core/signals.zig");
const events = @import("events.zig");
const props = @import("../core/properties.zig");
const reg = @import("../core/registry.zig");
const theme_mod = @import("theme.zig");

const BuildContext = component.BuildContext;
const Text = component.Text;
const EdgeInsets = component.EdgeInsets;

const ROW_H: f32 = 32;

pub const Dropdown = struct {
    // Props (set from mountOwned's init_props; re-applied on rebuild).
    options: []const []const u8 = &.{},
    on_change: ?events.Handler = null,
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
    selected: signals.Signal(usize) = undefined,
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

    pub fn onMount(self: *Dropdown, allocator: std.mem.Allocator) void {
        self.is_open = signals.Signal(bool).init(allocator, false);
        self.selected = signals.Signal(usize).init(allocator, 0);
        self.hovered = signals.Signal(bool).init(allocator, false);
        self.scope = signals.Scope.init(allocator);
        self.item_ids = std.array_list.Managed(reg.NodeId).init(allocator);
    }

    pub fn deinit(self: *Dropdown) void {
        self.scope.deinit();
        self.is_open.deinit();
        self.selected.deinit();
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
        switch (ev.key_code) {
            27 => self.is_open.set(false), // Escape
            38, 40 => { // ↑ / ↓
                if (!self.is_open.peek()) {
                    self.is_open.set(true);
                    return;
                }
                const n = self.options.len;
                if (n == 0) return;
                const cur = self.selected.peek();
                const next = if (ev.key_code == 38)
                    (if (cur == 0) 0 else cur - 1)
                else
                    @min(cur + 1, n - 1);
                if (next != cur) {
                    self.selected.set(next);
                    if (self.on_change) |h| h.call(h.ptr, ev);
                }
            },
            else => {},
        }
    }

    /// One handler for every option row: resolves the picked index by matching the
    /// event's node against the captured row ids, then selects + closes + notifies.
    fn onOptionClick(self: *Dropdown, ev: events.Event) void {
        for (self.item_ids.items, 0..) |it, i| {
            if (it == ev.node_id) {
                self.selected.set(i);
                self.is_open.set(false);
                if (self.on_change) |h| h.call(h.ptr, ev);
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
        try b.width(self.root_id, 150, .px);

        // Backdrop: full-window catcher below the menu; sized to 0 when closed.
        self.backdrop_id = try ctx.boxNode(.{
            .on_click = ctx.handler(self, onDismiss),
        }, .{});
        try b.positionAbsolute(self.backdrop_id, -10000, -10000);
        try b.backgroundAlpha(self.backdrop_id, 0, 0, 0, 0.0);
        try b.zIndex(self.backdrop_id, 50);

        // Trigger.
        self.trigger_id = try ctx.boxNode(.{
            .width = component.pct(100),
            .height = 32,
            .padding = EdgeInsets.symmetric(10, 0),
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
        try b.positionAbsolute(self.menu_id, 0, 36);
        try b.borderColorAlpha(self.menu_id, 80, 80, 80, 255);
        try b.overflowHidden(self.menu_id);
        try b.zIndex(self.menu_id, 100); // above the backdrop so options win the hit-test

        b.close(); // root

        try component.bindVisuals(self, &self.scope, &self.bound, updateVisuals);
    }

    fn updateVisuals(self: *Dropdown) void {
        const store = self.store orelse return;
        if (self.trigger_id == reg.NULL_NODE) return;
        const t = self.theme;
        const open = self.is_open.get();
        const hovered = self.hovered.get();
        const sel = self.selected.get();

        // Surface the open state for accessibility (UIA ExpandCollapsePattern reads
        // `.expanded` on the combobox node — the trigger, which also holds the role).
        store.setModifier(self.trigger_id, .expanded, .{ .boolean = open }) catch {};

        const trig_bg = if (hovered) t.bg_input else t.bg_surface;
        store.setStyle(self.trigger_id, .background, props.PropValue.rgbA(trig_bg.r, trig_bg.g, trig_bg.b, 1.0)) catch {};

        if (store.stringAllocator().dupe(u8, if (open) "^" else "v")) |arrow_str| {
            store.setTextContent(self.arrow_id, arrow_str);
        } else |_| {}
        if (self.options.len > 0) {
            const cur = self.options[@min(sel, self.options.len - 1)];
            if (store.stringAllocator().dupe(u8, cur)) |label_str| {
                store.setTextContent(self.label_id, label_str);
            } else |_| {}
        }

        const h: f32 = if (open) @as(f32, @floatFromInt(self.options.len)) * ROW_H else 0;
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
        const sel0 = self.dd.selected.peek();
        const cur = if (self.dd.options.len > 0) self.dd.options[@min(sel0, self.dd.options.len - 1)] else "Select...";
        self.dd.label_id = try b.addText(cur);
        try b.fontSize(self.dd.label_id, 14);
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
                .height = ROW_H,
                .padding = EdgeInsets.symmetric(10, 0),
                .direction = .row,
                .@"align" = .center,
                .on_click = ctx.handler(dd, Dropdown.onOptionClick),
            }, .{
                Text{ .content = opt, .color = component.rgb(t.text.r, t.text.g, t.text.b), .style = t.typography.body_medium },
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

    try testing.expectEqual(@as(usize, 2), dd.selected.peek());
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
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = 40 });
    try testing.expect(dd.is_open.peek());
    try testing.expectEqual(@as(usize, 0), dd.selected.peek());

    // ↓↓ move down (clamped at the end); ↑ moves back up.
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = 40 });
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = 40 });
    try testing.expectEqual(@as(usize, 2), dd.selected.peek());
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = 38 });
    try testing.expectEqual(@as(usize, 1), dd.selected.peek());

    // Escape closes, keeping the selection.
    _ = router.route(.{ .name = "key_down", .id = "", .node_id = dd.trigger_id, .key_code = 27 });
    try testing.expect(!dd.is_open.peek());
    try testing.expectEqual(@as(usize, 1), dd.selected.peek());
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
    try testing.expectEqual(@as(usize, 0), dd.selected.peek());
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
