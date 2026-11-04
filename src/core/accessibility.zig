//! Accessibility tree extraction.
//!
//! Derives a semantic accessibility tree (role / accessible name / focused state /
//! bounds) from the retained UI tree, so a platform provider can expose it to a
//! screen reader (Win32 UI Automation / Linux AT-SPI). This module is the
//! platform-agnostic, headless-testable core — it does the genuinely tricky part
//! (mapping boxes/text/modifiers to ARIA-ish roles and computing accessible names);
//! the OS providers are a thin, mechanical layer on top that has to be verified
//! with a real screen reader.
//!
//! Roles map the widgets' `role` modifier (button/checkbox/radio/slider/…) to ARIA
//! role names where they differ, and infer a role for un-annotated nodes (a node
//! with the I-beam cursor is a textbox; a clickable box is a button; text/image
//! nodes get text/img).

const std = @import("std");
const reg = @import("registry.zig");
const props = @import("properties.zig");

/// Maps an explicit `role` modifier string to a standard ARIA role name. Strings
/// that are already valid ARIA roles (button/checkbox/radio/slider) pass through.
fn mapAriaRole(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "textarea")) return "textbox";
    if (std.mem.eql(u8, s, "dropdown")) return "combobox";
    if (std.mem.eql(u8, s, "icon_button")) return "button";
    if (std.mem.eql(u8, s, "app_bar")) return "toolbar";
    if (std.mem.eql(u8, s, "resizer_h") or std.mem.eql(u8, s, "resizer_v")) return "separator";
    return s; // button / checkbox / radio / slider — already ARIA
}

/// The accessible role for a node: explicit `role` wins; otherwise inferred from
/// the cursor (text → textbox), the `clickable` modifier, and node type.
/// `clickable` wins regardless of node type — a glyph-as-button (`addText("+")`
/// + `.clickable`) is a real activatable control, not static text, and must
/// expose `InvokePattern` exactly like a clickable box does.
pub fn accessibleRole(store: *const props.PropertyStore, node_id: reg.NodeId, node_type: reg.NodeType) []const u8 {
    if (store.getModifier(node_id, .role)) |r| {
        if (r == .string) return mapAriaRole(r.string);
    }
    if (store.getModifier(node_id, .cursor)) |cur| {
        if (cur == .string and std.mem.eql(u8, cur.string, "text")) return "textbox";
    }
    if (store.getModifier(node_id, .clickable) != null) return "button";
    return switch (node_type) {
        .text => "text",
        .image => "img",
        .path => "graphic",
        .box => "group",
    };
}

fn findDescendantText(registry: *reg.UIRegistry, store: *const props.PropertyStore, node_id: reg.NodeId, depth: usize) ?[]const u8 {
    if (depth >= reg.MAX_TREE_DEPTH) return null;
    if (store.getTextContent(node_id)) |t| {
        if (t.len > 0) return t;
    }
    const node = registry.getNode(node_id) orelse return null;
    var child = node.first_child;
    while (child != reg.NULL_NODE) {
        if (findDescendantText(registry, store, child, depth + 1)) |t| return t;
        const cn = registry.getNode(child) orelse break;
        child = cn.next_sibling;
    }
    return null;
}

/// Whether a role takes its name from its contents (ARIA "name from author or
/// contents"). Controls do — a button box is named by its label child. Generic
/// containers do NOT: letting a `group` absorb the first text in its subtree
/// makes every ancestor up to the window report the same string, which drowns
/// out real names for a UIA client walking the tree.
fn nameFromContents(role: []const u8) bool {
    const allowed = [_][]const u8{
        "button", "checkbox", "radio",  "link",     "heading",
        "tab",    "menuitem", "option", "treeitem", "switch",
        "cell",   "text",
    };
    for (allowed) |r| {
        if (std.mem.eql(u8, role, r)) return true;
    }
    return false;
}

/// Whether a role's own child text is *purely* a visual label, never the
/// control's live value — the set of roles whose descendant text a UIA
/// client must never mistake for `ValuePattern` content. This is
/// `nameFromContents` plus `textbox`: a textbox is intentionally excluded
/// from `nameFromContents` itself (digging into its child would make the
/// Name track whatever the user is typing, colliding with Value), but its
/// placeholder child is still purely decorative and must not present as an
/// independent control either.
fn demotesTextChildren(role: []const u8) bool {
    return nameFromContents(role) or std.mem.eql(u8, role, "textbox");
}

/// Whether `node_id` should be exposed to UI Automation as a real control
/// element. A plain `text` node nested under a control that treats its label
/// as decorative (a button's label, an Edit's placeholder) is the *reason*
/// that ancestor has a name, not an independent control — carrying its own
/// control identity makes every such control show up twice under any name
/// search. Win32 and WPF avoid exactly this by marking the label
/// `IsControlElement=false`; this mirrors that instead of pruning the node
/// from the tree outright, so content-view walkers (and this module's own
/// JSON tree) still see it. Walks the full ancestor chain, not just the
/// immediate parent, since a label can sit behind an intermediate wrapper box
/// (e.g. a Checkbox's indicator glyph).
pub fn isControlElement(registry: *reg.UIRegistry, store: *const props.PropertyStore, node_id: reg.NodeId) bool {
    const node = registry.getNode(node_id) orelse return true;
    if (node.node_type != .text) return true;
    // A text node that is itself an independent activatable control (its own
    // `clickable`, e.g. a TreeView row's expand/collapse chevron sitting next
    // to a `clickable` treeitem row) is never somebody else's decorative
    // label, no matter what ancestor it sits under — it must stay visible in
    // ControlView or its own InvokePattern becomes unreachable by a client
    // walking the control tree.
    if (std.mem.eql(u8, accessibleRole(store, node_id, node.node_type), "button")) return true;
    var ancestor_id = node.parent;
    var depth: usize = 0;
    while (ancestor_id != reg.NULL_NODE and depth < reg.MAX_TREE_DEPTH) : (depth += 1) {
        const ancestor = registry.getNode(ancestor_id) orelse return true;
        const role = accessibleRole(store, ancestor_id, ancestor.node_type);
        if (demotesTextChildren(role)) return false;
        // A bare, non-interactive wrapper box ("group") is transparent — the
        // text keeps climbing past it to look for the control it labels.
        // Any other role (a distinct button/textbox/slider/…) is itself a
        // control boundary: stop here, this text belongs to *that* control,
        // not to some further ancestor.
        if (!std.mem.eql(u8, role, "group")) return true;
        ancestor_id = ancestor.parent;
    }
    return true;
}

/// The accessible name: an explicit `label` (aria-label) wins; else the node's
/// own text; for roles that are named by their contents, the first text found in
/// the subtree (so a button box reports its text child's label); otherwise "".
pub fn accessibleName(registry: *reg.UIRegistry, store: *const props.PropertyStore, node_id: reg.NodeId) []const u8 {
    if (store.getModifier(node_id, .label)) |l| {
        if (l == .string and l.string.len > 0) return l.string;
    }
    if (store.getTextContent(node_id)) |t| {
        if (t.len > 0) return t;
    }
    const node = registry.getNode(node_id) orelse return "";
    if (!nameFromContents(accessibleRole(store, node_id, node.node_type))) return "";
    return findDescendantText(registry, store, node_id, 0) orelse "";
}

/// The displayed value of an editable control: its own text if any, else the
/// first text found in its subtree (a TextInput keeps the shown string on a child
/// text node). Best-effort — for an empty field this is the placeholder, and for
/// a password it is the bullet mask, which is the correct thing to expose anyway.
pub fn editableValue(registry: *reg.UIRegistry, store: *const props.PropertyStore, node_id: reg.NodeId) []const u8 {
    if (store.getTextContent(node_id)) |t| {
        if (t.len > 0) return t;
    }
    return findDescendantText(registry, store, node_id, 0) orelse "";
}

/// Whether `node_id` is currently exposed to automation/hit-testing: it has a
/// resolved on-screen size, and — walking every ancestor — is not fully
/// clipped away by an `overflow_hidden` box sized/positioned to hide it. A
/// closed `Menu`/`Dropdown` panel collapses to height 0 specifically to hide
/// its rows via clipping, but the rows themselves keep their own fixed
/// geometry (e.g. a 28px-tall row) — checking `node_id`'s own geometry alone
/// misses that they're hidden, so a UIA client (or a screen reader) sees a
/// closed menu's rows as present, named, and invocable. Shared by the UIA
/// tree walker (`platform/uia.zig`) and focus/tab traversal (`c_api.zig`'s
/// `isTabbable`) so both channels agree on what's actually visible.
pub fn isVisible(registry: *reg.UIRegistry, store: *const props.PropertyStore, node_id: reg.NodeId) bool {
    const node = registry.getNode(node_id) orelse return false;
    const g = node.geometry;
    if (g.width <= 0 or g.height <= 0) return false;
    var anc = node.parent;
    var depth: usize = 0;
    while (anc != reg.NULL_NODE and depth < reg.MAX_TREE_DEPTH) : (depth += 1) {
        const a = registry.getNode(anc) orelse break;
        if (store.modifierFlag(anc, .overflow_hidden)) {
            const c = a.geometry;
            const outside = g.x >= c.x + c.width or g.x + g.width <= c.x or
                g.y >= c.y + c.height or g.y + g.height <= c.y;
            if (outside) return false;
        }
        anc = a.parent;
    }
    return true;
}

/// A boolean accessibility state from a modifier (true only if present + truthy).
pub fn stateFlag(store: *const props.PropertyStore, node_id: reg.NodeId, key: props.ModifierKey) bool {
    return store.modifierFlag(node_id, key);
}

/// Escapes the few JSON-significant characters in an accessible name (names are
/// arbitrary user text). Writes into `out`, returning the written slice.
fn jsonEscape(out: []u8, s: []const u8) []const u8 {
    var i: usize = 0;
    for (s) |ch| {
        if (i + 2 > out.len) break;
        switch (ch) {
            '"', '\\' => {
                out[i] = '\\';
                i += 1;
                out[i] = ch;
                i += 1;
            },
            '\n' => {
                out[i] = ' ';
                i += 1;
            },
            else => {
                out[i] = ch;
                i += 1;
            },
        }
    }
    return out[0..i];
}

/// Serializes the accessibility subtree at `node_id` to JSON: role, accessible
/// name, focused state and bounds, recursively. Bounded by MAX_TREE_DEPTH.
pub fn serializeNode(
    registry: *reg.UIRegistry,
    store: *const props.PropertyStore,
    focused: ?reg.NodeId,
    allocator: std.mem.Allocator,
    node_id: reg.NodeId,
    depth: usize,
) ![]const u8 {
    const node = registry.getNode(node_id) orelse return allocator.dupe(u8, "null");
    if (depth >= reg.MAX_TREE_DEPTH) {
        return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"truncated\":true}}", .{node_id});
    }

    var children_json = std.array_list.Managed([]const u8).init(allocator);
    defer children_json.deinit();
    var child_id = node.first_child;
    while (child_id != reg.NULL_NODE) {
        try children_json.append(try serializeNode(registry, store, focused, allocator, child_id, depth + 1));
        const cn = registry.getNode(child_id) orelse break;
        child_id = cn.next_sibling;
    }
    const children_joined = try std.mem.join(allocator, ",", children_json.items);

    const role = accessibleRole(store, node_id, node.node_type);
    const name = accessibleName(registry, store, node_id);
    var name_buf: [512]u8 = undefined;
    const name_esc = jsonEscape(&name_buf, name);
    const is_focused = if (focused) |f| f == node_id else false;
    const disabled = stateFlag(store, node_id, .disabled);
    const checked = stateFlag(store, node_id, .checked);
    const expanded = stateFlag(store, node_id, .expanded);

    return std.fmt.allocPrint(
        allocator,
        "{{\"id\":{d},\"role\":\"{s}\",\"name\":\"{s}\",\"focused\":{},\"disabled\":{},\"checked\":{},\"expanded\":{},\"x\":{d:.1},\"y\":{d:.1},\"width\":{d:.1},\"height\":{d:.1},\"children\":[{s}]}}",
        .{ node_id, role, name_esc, is_focused, disabled, checked, expanded, node.geometry.x, node.geometry.y, node.geometry.width, node.geometry.height, children_joined },
    );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const ts = @import("../framework/test_support.zig");

test "accessibleRole maps explicit roles to ARIA and infers the rest" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const btn = try env.registry.createNode(.box);
    try env.store.registerNode(btn);
    try env.store.setModifier(btn, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "button") });
    try testing.expectEqualStrings("button", accessibleRole(&env.store, btn, .box));

    const ta = try env.registry.createNode(.box);
    try env.store.registerNode(ta);
    try env.store.setModifier(ta, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "textarea") });
    try testing.expectEqualStrings("textbox", accessibleRole(&env.store, ta, .box)); // mapped to ARIA

    // No role, but the I-beam cursor → textbox (TextInput's marker).
    const input = try env.registry.createNode(.box);
    try env.store.registerNode(input);
    try env.store.setModifier(input, .cursor, .{ .string = try env.store.stringAllocator().dupe(u8, "text") });
    try testing.expectEqualStrings("textbox", accessibleRole(&env.store, input, .box));

    // Plain text / image / clickable-box / bare-box inference.
    const txt = try env.registry.createNode(.text);
    try env.store.registerNode(txt);
    try testing.expectEqualStrings("text", accessibleRole(&env.store, txt, .text));

    const clickable = try env.registry.createNode(.box);
    try env.store.registerNode(clickable);
    try env.store.setModifier(clickable, .clickable, .{ .string = try env.store.stringAllocator().dupe(u8, "go") });
    try testing.expectEqualStrings("button", accessibleRole(&env.store, clickable, .box));

    const bare = try env.registry.createNode(.box);
    try env.store.registerNode(bare);
    try testing.expectEqualStrings("group", accessibleRole(&env.store, bare, .box));

    // A clickable `text` node (a glyph-as-button, e.g. addText("+") + .clickable)
    // is a real control regardless of node type — it must ascend to "button"
    // exactly like a clickable box does, or it never gets InvokePattern.
    const clickable_text = try env.registry.createNode(.text);
    try env.store.registerNode(clickable_text);
    try env.store.setModifier(clickable_text, .clickable, .{ .string = try env.store.stringAllocator().dupe(u8, "new_rec") });
    try testing.expectEqualStrings("button", accessibleRole(&env.store, clickable_text, .text));

    // Same for a clickable `image` (an icon-only button drawn as an image).
    const clickable_image = try env.registry.createNode(.image);
    try env.store.registerNode(clickable_image);
    try env.store.setModifier(clickable_image, .clickable, .{ .string = try env.store.stringAllocator().dupe(u8, "go") });
    try testing.expectEqualStrings("button", accessibleRole(&env.store, clickable_image, .image));
}

test "accessibleName reports own text, else a descendant's, else empty" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    // A button box whose label is a text child → the button's name is "OK".
    // `clickable` is what makes accessibleRole infer "button" (the modifier a
    // real Button carries); without it this is a plain group, which is not
    // named by its contents.
    const btn = try env.registry.createNode(.box);
    try env.store.registerNode(btn);
    try env.store.setModifier(btn, .clickable, .{ .string = try env.store.stringAllocator().dupe(u8, "go") });
    const label = try env.registry.createNode(.text);
    try env.store.registerNode(label);
    env.registry.appendChild(btn, label);
    env.store.setTextContent(label, try env.store.stringAllocator().dupe(u8, "OK"));

    try testing.expectEqualStrings("OK", accessibleName(&env.registry, &env.store, btn));
    try testing.expectEqualStrings("OK", accessibleName(&env.registry, &env.store, label));

    // A bare box with no text anywhere → empty name.
    const empty = try env.registry.createNode(.box);
    try env.store.registerNode(empty);
    try testing.expectEqualStrings("", accessibleName(&env.registry, &env.store, empty));
}

test "accessibleName prefers an explicit label (aria-label) over text" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    // An icon-only close button: no text child, but an explicit label. Without
    // the label it would report "" (a screen reader announces an unlabeled
    // button); with it, "Close".
    const close = try env.registry.createNode(.box);
    try env.store.registerNode(close);
    try env.store.setModifier(close, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "icon_button") });
    try testing.expectEqualStrings("", accessibleName(&env.registry, &env.store, close));

    try env.store.setModifier(close, .label, .{ .string = try env.store.stringAllocator().dupe(u8, "Close") });
    try testing.expectEqualStrings("Close", accessibleName(&env.registry, &env.store, close));

    // The label also wins over own text content.
    const btn = try env.registry.createNode(.box);
    try env.store.registerNode(btn);
    env.store.setTextContent(btn, try env.store.stringAllocator().dupe(u8, "raw"));
    try env.store.setModifier(btn, .label, .{ .string = try env.store.stringAllocator().dupe(u8, "Etiqueta") });
    try testing.expectEqualStrings("Etiqueta", accessibleName(&env.registry, &env.store, btn));
}

test "accessibleName does not leak descendant text into generic containers" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    // group > group > button > text("Welcome"). Only the button (a role named
    // by its contents) and the text itself may report "Welcome"; the wrapping
    // groups must stay unnamed, or every ancestor up to the window reports the
    // same string and a UIA client can't tell elements apart.
    const outer = try env.registry.createNode(.box);
    try env.store.registerNode(outer);
    const inner = try env.registry.createNode(.box);
    try env.store.registerNode(inner);
    const btn = try env.registry.createNode(.box);
    try env.store.registerNode(btn);
    try env.store.setModifier(btn, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "button") });
    const label = try env.registry.createNode(.text);
    try env.store.registerNode(label);
    env.store.setTextContent(label, try env.store.stringAllocator().dupe(u8, "Welcome"));

    env.registry.appendChild(outer, inner);
    env.registry.appendChild(inner, btn);
    env.registry.appendChild(btn, label);

    try testing.expectEqualStrings("", accessibleName(&env.registry, &env.store, outer));
    try testing.expectEqualStrings("", accessibleName(&env.registry, &env.store, inner));
    try testing.expectEqualStrings("Welcome", accessibleName(&env.registry, &env.store, btn));
    try testing.expectEqualStrings("Welcome", accessibleName(&env.registry, &env.store, label));

    // A toolbar (the title bar's role) is not named by contents either.
    const bar = try env.registry.createNode(.box);
    try env.store.registerNode(bar);
    try env.store.setModifier(bar, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "app_bar") });
    const title = try env.registry.createNode(.text);
    try env.store.registerNode(title);
    env.store.setTextContent(title, try env.store.stringAllocator().dupe(u8, "UI Inspector"));
    env.registry.appendChild(bar, title);

    try testing.expectEqualStrings("", accessibleName(&env.registry, &env.store, bar));

    // An explicit own text still wins regardless of role.
    env.store.setTextContent(outer, try env.store.stringAllocator().dupe(u8, "Explicit"));
    try testing.expectEqualStrings("Explicit", accessibleName(&env.registry, &env.store, outer));
}

test "accessibleName keeps a clickable text glyph's own content as its name" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    // addText("+") + .clickable: ascends to role "button" (InvokePattern), but
    // must still report "+" as its name — own text wins before any
    // nameFromContents digging even runs, so promoting the role must not
    // change what a screen reader announces.
    const plus = try env.registry.createNode(.text);
    try env.store.registerNode(plus);
    try env.store.setModifier(plus, .clickable, .{ .string = try env.store.stringAllocator().dupe(u8, "new_rec") });
    env.store.setTextContent(plus, try env.store.stringAllocator().dupe(u8, "+"));

    try testing.expectEqualStrings("button", accessibleRole(&env.store, plus, .text));
    try testing.expectEqualStrings("+", accessibleName(&env.registry, &env.store, plus));
}

test "accessibleName does not dig into a textbox's child (that would make Name track Value)" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    // Edit > Text("Filter..."), no explicit label: the textbox has no stable
    // name to report from its own state alone. A live-typed child (TextInput
    // reuses one node for placeholder *and* buffer) must never leak into
    // Name, or the Name would change on every keystroke and collide with
    // Value. Widgets are responsible for giving the field a real name (see
    // TextInput, which sets an explicit aria-label from its placeholder).
    const edit = try env.registry.createNode(.box);
    try env.store.registerNode(edit);
    try env.store.setModifier(edit, .cursor, .{ .string = try env.store.stringAllocator().dupe(u8, "text") });
    const placeholder = try env.registry.createNode(.text);
    try env.store.registerNode(placeholder);
    env.registry.appendChild(edit, placeholder);
    env.store.setTextContent(placeholder, try env.store.stringAllocator().dupe(u8, "Filter..."));

    try testing.expectEqualStrings("", accessibleName(&env.registry, &env.store, edit));

    // With an explicit aria-label (what TextInput actually does), the Name is
    // stable and independent of the child's live content.
    try env.store.setModifier(edit, .label, .{ .string = try env.store.stringAllocator().dupe(u8, "Filter...") });
    try testing.expectEqualStrings("Filter...", accessibleName(&env.registry, &env.store, edit));
    env.store.setTextContent(placeholder, try env.store.stringAllocator().dupe(u8, "something the user typed"));
    try testing.expectEqualStrings("Filter...", accessibleName(&env.registry, &env.store, edit));
}

test "isControlElement demotes a control's own label but leaves independent text alone" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const btn = try env.registry.createNode(.box);
    try env.store.registerNode(btn);
    try env.store.setModifier(btn, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "button") });
    const label = try env.registry.createNode(.text);
    try env.store.registerNode(label);
    env.registry.appendChild(btn, label);
    env.store.setTextContent(label, try env.store.stringAllocator().dupe(u8, "Create..."));

    try testing.expect(isControlElement(&env.registry, &env.store, btn));
    try testing.expect(!isControlElement(&env.registry, &env.store, label));

    // A title inside a toolbar (not named-from-contents) is real content, not
    // a label riding along on the toolbar's name, so it stays a control.
    const bar = try env.registry.createNode(.box);
    try env.store.registerNode(bar);
    try env.store.setModifier(bar, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "app_bar") });
    const title = try env.registry.createNode(.text);
    try env.store.registerNode(title);
    env.registry.appendChild(bar, title);
    env.store.setTextContent(title, try env.store.stringAllocator().dupe(u8, "UI Inspector"));

    try testing.expect(isControlElement(&env.registry, &env.store, title));
}

test "isControlElement climbs past a plain wrapper box to demote a Checkbox-style nested glyph" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    // checkbox > indicator(bare box, no role/clickable → "group") > text("v").
    // Checkbox's real indicator nests its checkmark glyph one level below the
    // control itself; a one-level-only check would miss this and leave the
    // glyph exposed as its own named control.
    const cb = try env.registry.createNode(.box);
    try env.store.registerNode(cb);
    try env.store.setModifier(cb, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "checkbox") });
    const indicator = try env.registry.createNode(.box);
    try env.store.registerNode(indicator);
    env.registry.appendChild(cb, indicator);
    const glyph = try env.registry.createNode(.text);
    try env.store.registerNode(glyph);
    env.registry.appendChild(indicator, glyph);
    env.store.setTextContent(glyph, try env.store.stringAllocator().dupe(u8, "\u{2713}"));

    try testing.expect(!isControlElement(&env.registry, &env.store, glyph));

    // But climbing must stop at a genuine intervening control: a slider thumb
    // nested inside a bare box inside a checkbox must not have its own label
    // text attributed to the outer checkbox — it's the slider's content, and
    // the slider is a distinct control boundary.
    const wrapper = try env.registry.createNode(.box);
    try env.store.registerNode(wrapper);
    env.registry.appendChild(cb, wrapper);
    const slider = try env.registry.createNode(.box);
    try env.store.registerNode(slider);
    try env.store.setModifier(slider, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "slider") });
    env.registry.appendChild(wrapper, slider);
    const stray = try env.registry.createNode(.text);
    try env.store.registerNode(stray);
    env.registry.appendChild(slider, stray);
    env.store.setTextContent(stray, try env.store.stringAllocator().dupe(u8, "50%"));

    try testing.expect(isControlElement(&env.registry, &env.store, stray));
}

test "isControlElement never demotes a text node that is itself clickable (TreeView chevron pattern)" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    // row(treeitem, clickable) > chevron(text, its own clickable): the row's
    // explicit "treeitem" role is nameFromContents, which would demote a
    // plain label — but the chevron is a distinct hit target with its own
    // InvokePattern (expand/collapse without touching selection), so it must
    // stay a real control or a ControlView-walking client can never reach it.
    const row = try env.registry.createNode(.box);
    try env.store.registerNode(row);
    try env.store.setModifier(row, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "treeitem") });
    try env.store.setModifier(row, .clickable, .{ .string = try env.store.stringAllocator().dupe(u8, "select") });
    const chevron = try env.registry.createNode(.text);
    try env.store.registerNode(chevron);
    env.registry.appendChild(row, chevron);
    try env.store.setModifier(chevron, .clickable, .{ .string = try env.store.stringAllocator().dupe(u8, "toggle") });
    env.store.setTextContent(chevron, try env.store.stringAllocator().dupe(u8, ">"));

    try testing.expectEqualStrings("button", accessibleRole(&env.store, chevron, .text));
    try testing.expect(isControlElement(&env.registry, &env.store, chevron));
}

test "serializeNode emits disabled/checked/expanded states" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const cb = try env.registry.createNode(.box);
    try env.store.registerNode(cb);
    try env.store.setModifier(cb, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "checkbox") });
    try env.store.setModifier(cb, .checked, .{ .boolean = true });
    try env.store.setModifier(cb, .disabled, .{ .boolean = true });
    // `expanded` left unset → must serialize as false.

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json = try serializeNode(&env.registry, &env.store, null, arena.allocator(), cb, 0);
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"checkbox\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"checked\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"disabled\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"expanded\":false") != null);
}

test "serializeNode emits role/name/focused/bounds and nests children" {
    var env = ts.Harness.init(testing.allocator);
    defer env.deinit();
    env.store.setRegistry(&env.registry);

    const btn = try env.registry.createNode(.box);
    try env.store.registerNode(btn);
    try env.store.setModifier(btn, .role, .{ .string = try env.store.stringAllocator().dupe(u8, "button") });
    env.registry.nodes.items[btn].geometry = .{ .x = 1, .y = 2, .width = 30, .height = 10 };
    const label = try env.registry.createNode(.text);
    try env.store.registerNode(label);
    env.registry.appendChild(btn, label);
    env.store.setTextContent(label, try env.store.stringAllocator().dupe(u8, "Go"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json = try serializeNode(&env.registry, &env.store, btn, arena.allocator(), btn, 0);

    // Role + accessible name (from the text child) + focused flag are present.
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"button\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Go\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"focused\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"text\"") != null); // nested child
}
