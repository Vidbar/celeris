//! String → property parsing for the C-ABI's string-keyed setters
//! (`celeris_node_add_style` / `_layout` / `_modifier`, `celeris_signal_bind_*`,
//! `celeris_animate_*`).
//!
//! Zig code sets typed `PropValue`s through the builder; hosts on the other side
//! of the C-ABI only have strings. This module is the single translation point:
//! the key names are the enum field names in `properties.zig` (`-` and `_` are
//! interchangeable, so `"font-size"` == `"font_size"`), and the value is parsed
//! into the type that key is read as by the layout solver and the renderer —
//! never guessed from the string alone, so `"1"` is a number for `opacity` but
//! a 1px dimension for `radius`.
//!
//! Value syntax:
//!   colors      `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)`, `rgba(r, g, b, a)`
//!               (channels 0–255, alpha 0–1), `transparent`
//!   lengths     `12`, `12px`; `50%` where the reader resolves percentages (sizes,
//!               flex_basis, min/max); `auto` / `fill` for width and height only
//!   numbers     `0.5`, `2`
//!   keywords    `row`, `column`, `center`, `flex-start`, `space-between`, …
//!   booleans    `true` / `false` (also `1` / `0`)
//!   strings     anything, taken verbatim (action ids, roles, cursors, labels)

const std = @import("std");
const props = @import("properties.zig");

pub const ParseError = error{ UnknownKey, InvalidValue, OutOfMemory };

/// Resolves a key name to its enum, accepting `-` or `_` as the word separator.
pub fn parseKey(comptime E: type, name: []const u8) ?E {
    var buf: [64]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = if (c == '-') '_' else c;
    return std.meta.stringToEnum(E, buf[0..name.len]);
}

/// How a key's value is read by the layout solver / renderer — and therefore the
/// only shape it may be stored in. Every path that writes a property from outside
/// Zig (string setters, signal bindings, animations) goes through this table, so a
/// host can never store, say, a keyword where the renderer reads a dimension.
pub const Kind = enum {
    color,
    /// A length the reader takes as px only (style lengths, margins, padding, gaps,
    /// offsets). `%` / `pt` / keywords are refused rather than silently ignored.
    px,
    /// A length resolved against the parent: px or `%` (flex_basis, min/max sizes).
    length,
    /// width / height: a length, or `auto` (size from content) / `fill` (100%).
    size,
    number,
    keyword,
    boolean,
    /// On/off modifier read by value (`PropertyStore.modifierFlag`).
    flag,
    /// A node id (`virtual_focus_target`): a non-negative integer that fits NodeId,
    /// or any negative number for "no target". Read via `modifierNodeRef`.
    node_ref,
    string,
};

pub fn styleKind(key: props.StyleKey) Kind {
    return switch (key) {
        .background, .color, .border_color, .shadow_color, .gradient_color2 => .color,
        .opacity, .font_role, .letter_spacing, .line_height, .border_style, .gradient_type, .z_index => .number,
        .text_align => .keyword,
        .radius, .font_size, .border_width, .border_top, .border_right, .border_bottom, .border_left => .px,
        .shadow_blur, .shadow_offset_x, .shadow_offset_y, .shadow_spread => .px,
    };
}

pub fn layoutKind(key: props.LayoutKey) Kind {
    return switch (key) {
        .width, .height => .size,
        .flex_basis, .min_width, .min_height, .max_width, .max_height => .length,
        .margin_top, .margin_bottom, .margin_left, .margin_right => .px,
        .padding_top, .padding_bottom, .padding_left, .padding_right => .px,
        .left, .top, .gap, .row_gap, .column_gap, .scroll_offset_x, .scroll_offset_y => .px,
        .justify_content, .align_items, .align_self, .flex_direction, .position => .keyword,
        .flex_grow, .flex_shrink => .number,
        .flex_wrap => .boolean,
    };
}

pub fn modifierKind(key: props.ModifierKey) Kind {
    return switch (key) {
        .disabled, .checked, .expanded, .readonly => .boolean,
        .overflow_hidden, .pointer_events_none, .no_drag, .captures_tab, .no_focus_ring => .flag,
        .virtual_focus_target => .node_ref,
        else => .string,
    };
}

pub fn parseStyle(store: *props.PropertyStore, key: props.StyleKey, text: []const u8) ParseError!props.PropValue {
    return parseAs(store, styleKind(key), text);
}

pub fn parseLayout(store: *props.PropertyStore, key: props.LayoutKey, text: []const u8) ParseError!props.PropValue {
    return parseAs(store, layoutKind(key), text);
}

pub fn parseModifier(store: *props.PropertyStore, key: props.ModifierKey, text: []const u8) ParseError!props.PropValue {
    return parseAs(store, modifierKind(key), text);
}

fn kindIsNumeric(kind: Kind) bool {
    return switch (kind) {
        .number, .px, .length, .size => true,
        else => false,
    };
}

/// Style keys `celeris_animate_style` can interpolate (numbers and px lengths).
pub fn styleIsAnimatable(key: props.StyleKey) bool {
    return kindIsNumeric(styleKind(key));
}

pub fn layoutIsAnimatable(key: props.LayoutKey) bool {
    return kindIsNumeric(layoutKind(key));
}

/// The stored value for an animation frame of `value` on a numeric key of `kind`.
pub fn animatedValue(kind: Kind, value: f32, unit: props.DimUnit) props.PropValue {
    return switch (kind) {
        .number => .{ .number = value },
        .px => .{ .dimension = .{ .value = value, .unit = .px } },
        else => .{ .dimension = .{ .value = value, .unit = unit } },
    };
}

/// Converts a host-supplied value (a signal's current value) into the shape
/// `kind` is stored in, or null when it has no meaning for that key. Numbers and px
/// lengths convert into each other; nothing converts into a color, keyword or
/// string; non-finite numbers are refused.
pub fn coerce(kind: Kind, v: props.PropValue) ?props.PropValue {
    switch (v) {
        .number => |n| if (!std.math.isFinite(n)) return null,
        .dimension => |d| if (!std.math.isFinite(d.value)) return null,
        else => {},
    }
    return switch (kind) {
        .color => if (v == .color) v else null,
        .px => switch (v) {
            .number => |n| .{ .dimension = .{ .value = n, .unit = .px } },
            .dimension => |d| if (d.unit == .px) v else null,
            else => null,
        },
        .length, .size => switch (v) {
            .number => |n| .{ .dimension = .{ .value = n, .unit = .px } },
            .dimension => |d| if (d.unit == .pt) null else v,
            .keyword => |k| if (kind == .size and (k == .auto or k == .fill_parent)) v else null,
            else => null,
        },
        .number => switch (v) {
            .number => v,
            .dimension => |d| if (d.unit == .px) .{ .number = d.value } else null,
            else => null,
        },
        .keyword => if (v == .keyword) v else null,
        .boolean, .flag => switch (v) {
            .boolean => v,
            .number => |n| .{ .boolean = n != 0 },
            else => null,
        },
        .string, .node_ref => null,
    };
}

fn parseAs(store: *props.PropertyStore, kind: Kind, raw: []const u8) ParseError!props.PropValue {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    return switch (kind) {
        .color => parseColor(text) orelse error.InvalidValue,
        .number => .{ .number = parseFloat(text) orelse return error.InvalidValue },
        .px => parseLength(text, .px_only) orelse error.InvalidValue,
        .length => parseLength(text, .px_or_percent) orelse error.InvalidValue,
        .size => parseSize(text) orelse error.InvalidValue,
        .keyword => .{ .keyword = parseKeyword(text) orelse return error.InvalidValue },
        .boolean, .flag => .{ .boolean = parseBool(text) orelse return error.InvalidValue },
        .node_ref => blk: {
            const n = parseFloat(text) orelse return error.InvalidValue;
            if (n < 0) break :blk .{ .number = -1 };
            _ = props.nodeIdFromNumber(n) orelse return error.InvalidValue;
            break :blk .{ .number = n };
        },
        // The store takes ownership of string values (see `PropValue.string`).
        .string => .{ .string = try store.stringAllocator().dupe(u8, text) },
    };
}

fn parseFloat(text: []const u8) ?f32 {
    if (text.len == 0) return null;
    const v = std.fmt.parseFloat(f32, text) catch return null;
    if (!std.math.isFinite(v)) return null;
    return v;
}

fn parseBool(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) return true;
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) return false;
    return null;
}

fn parseKeyword(text: []const u8) ?props.Keyword {
    if (std.mem.eql(u8, text, "fill")) return .fill_parent;
    return parseKey(props.Keyword, text);
}

/// width / height: `auto` (from content), `fill` (100%), or a px / `%` length.
fn parseSize(text: []const u8) ?props.PropValue {
    if (std.mem.eql(u8, text, "auto")) return .{ .keyword = .auto };
    if (std.mem.eql(u8, text, "fill") or std.mem.eql(u8, text, "fill_parent")) return .{ .keyword = .fill_parent };
    return parseLength(text, .px_or_percent);
}

/// `12`, `12px`, and (when allowed) `50%`. `pt` is not accepted anywhere: no
/// reader converts it, so it would silently behave as px.
fn parseLength(text: []const u8, units: enum { px_only, px_or_percent }) ?props.PropValue {
    if (std.mem.endsWith(u8, text, "%")) {
        if (units == .px_only) return null;
        const v = parseFloat(std.mem.trimEnd(u8, text[0 .. text.len - 1], " ")) orelse return null;
        return .{ .dimension = .{ .value = v, .unit = .percent } };
    }
    const num = if (std.mem.endsWith(u8, text, "px")) std.mem.trimEnd(u8, text[0 .. text.len - 2], " ") else text;
    const v = parseFloat(num) orelse return null;
    return .{ .dimension = .{ .value = v, .unit = .px } };
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexByte(hi: u8, lo: u8) ?u8 {
    return (hexNibble(hi) orelse return null) * 16 + (hexNibble(lo) orelse return null);
}

fn parseColor(text: []const u8) ?props.PropValue {
    if (std.mem.eql(u8, text, "transparent")) return props.PropValue.rgbA(0, 0, 0, 0);
    if (text.len > 0 and text[0] == '#') {
        const h = text[1..];
        switch (h.len) {
            3 => {
                const r = hexNibble(h[0]) orelse return null;
                const g = hexNibble(h[1]) orelse return null;
                const b = hexNibble(h[2]) orelse return null;
                return props.PropValue.rgbA(r * 17, g * 17, b * 17, 1);
            },
            6, 8 => {
                const r = hexByte(h[0], h[1]) orelse return null;
                const g = hexByte(h[2], h[3]) orelse return null;
                const b = hexByte(h[4], h[5]) orelse return null;
                const a: f32 = if (h.len == 8) @as(f32, @floatFromInt(hexByte(h[6], h[7]) orelse return null)) / 255.0 else 1;
                return props.PropValue.rgbA(r, g, b, a);
            },
            else => return null,
        }
    }
    const has_alpha = std.mem.startsWith(u8, text, "rgba(");
    if (!has_alpha and !std.mem.startsWith(u8, text, "rgb(")) return null;
    if (text[text.len - 1] != ')') return null;
    const inner = text[(if (has_alpha) "rgba(".len else "rgb(".len) .. text.len - 1];
    var it = std.mem.splitScalar(u8, inner, ',');
    var ch: [4]f32 = .{ 0, 0, 0, 1 };
    const want: usize = if (has_alpha) 4 else 3;
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n >= want) return null;
        ch[n] = parseFloat(std.mem.trim(u8, part, " ")) orelse return null;
    }
    if (n != want) return null;
    for (ch[0..3]) |c| if (c < 0 or c > 255) return null;
    if (ch[3] < 0 or ch[3] > 1) return null;
    return .{ .color = .{ .r = ch[0] / 255.0, .g = ch[1] / 255.0, .b = ch[2] / 255.0, .a = ch[3] } };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseKey accepts dash or underscore and rejects unknown names" {
    try testing.expectEqual(props.StyleKey.font_size, parseKey(props.StyleKey, "font-size").?);
    try testing.expectEqual(props.StyleKey.font_size, parseKey(props.StyleKey, "font_size").?);
    try testing.expectEqual(props.LayoutKey.flex_direction, parseKey(props.LayoutKey, "flex-direction").?);
    try testing.expect(parseKey(props.StyleKey, "nope") == null);
    try testing.expect(parseKey(props.StyleKey, "") == null);
}

test "colors: hex short/long/alpha, rgb(), rgba(), transparent; bad input rejected" {
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    const c = (try parseStyle(&store, .background, "#ff8000")).color;
    try testing.expectApproxEqAbs(@as(f32, 1), c.r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), c.g, 1e-6);
    try testing.expectEqual(@as(f32, 1), c.a);
    try testing.expectApproxEqAbs(@as(f32, 1), (try parseStyle(&store, .color, "#fff")).color.b, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), (try parseStyle(&store, .color, "#00000080")).color.a, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.25), (try parseStyle(&store, .color, "rgba(10, 20, 30, 0.25)")).color.a, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 20.0 / 255.0), (try parseStyle(&store, .color, "rgb(10,20,30)")).color.g, 1e-6);
    try testing.expectEqual(@as(f32, 0), (try parseStyle(&store, .color, "transparent")).color.a);
    try testing.expectError(error.InvalidValue, parseStyle(&store, .background, "#12"));
    try testing.expectError(error.InvalidValue, parseStyle(&store, .background, "#gggggg"));
    try testing.expectError(error.InvalidValue, parseStyle(&store, .background, "rgb(1,2)"));
    try testing.expectError(error.InvalidValue, parseStyle(&store, .background, "rgb(1,2,300)"));
    try testing.expectError(error.InvalidValue, parseStyle(&store, .background, "red"));
}

test "the key decides the type: opacity is a number, radius a px dimension" {
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    try testing.expectEqual(@as(f32, 1), (try parseStyle(&store, .opacity, "1")).number);
    try testing.expectApproxEqAbs(@as(f32, 1.2), (try parseStyle(&store, .line_height, "1.2")).number, 0.0001);
    try testing.expectEqual(props.StyleKey.line_height, parseKey(props.StyleKey, "line-height").?);
    const r = (try parseStyle(&store, .radius, "1")).dimension;
    try testing.expectEqual(@as(f32, 1), r.value);
    try testing.expectEqual(props.DimUnit.px, r.unit);
    const w = (try parseLayout(&store, .width, "50%")).dimension;
    try testing.expectEqual(props.DimUnit.percent, w.unit);
    try testing.expectError(error.InvalidValue, parseLayout(&store, .height, "10pt"));
    try testing.expectError(error.InvalidValue, parseLayout(&store, .gap, "10%"));
    try testing.expectError(error.InvalidValue, parseStyle(&store, .radius, "auto"));
    try testing.expectError(error.InvalidValue, parseLayout(&store, .margin_left, "fill"));
    try testing.expectEqual(props.Keyword.auto, (try parseLayout(&store, .width, "auto")).keyword);
    try testing.expectEqual(props.Keyword.fill_parent, (try parseLayout(&store, .width, "fill")).keyword);
    try testing.expectEqual(props.Keyword.space_between, (try parseLayout(&store, .justify_content, "space-between")).keyword);
    try testing.expectEqual(true, (try parseLayout(&store, .flex_wrap, "true")).boolean);
    try testing.expectError(error.InvalidValue, parseStyle(&store, .opacity, "nan"));
    try testing.expectError(error.InvalidValue, parseStyle(&store, .radius, "12em"));
    try testing.expectError(error.InvalidValue, parseLayout(&store, .flex_direction, "diagonal"));
}

test "modifiers: strings are store-owned copies, flags are typed" {
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    var src = [_]u8{ 'b', 't', 'n' };
    const v = try parseModifier(&store, .clickable, &src);
    src[0] = 'X'; // the parsed value must not alias the caller's buffer
    try testing.expectEqualStrings("btn", v.string);
    store.stringAllocator().free(v.string);
    try testing.expectEqual(true, (try parseModifier(&store, .disabled, "1")).boolean);
    try testing.expectEqual(true, (try parseModifier(&store, .overflow_hidden, "1")).boolean);
    try testing.expectEqual(false, (try parseModifier(&store, .pointer_events_none, "0")).boolean);
}

test "coerce: numbers and px lengths convert both ways; nothing becomes a color or keyword" {
    const num: props.PropValue = .{ .number = 4 };
    try testing.expectEqual(@as(f32, 4), coerce(.px, num).?.dimension.value);
    try testing.expectEqual(@as(f32, 4), coerce(.number, .{ .dimension = .{ .value = 4, .unit = .px } }).?.number);
    try testing.expect(coerce(.color, num) == null);
    try testing.expect(coerce(.keyword, num) == null);
    try testing.expect(coerce(.px, .{ .dimension = .{ .value = 50, .unit = .percent } }) == null);
    try testing.expect(coerce(.number, .{ .number = std.math.nan(f32) }) == null);
    try testing.expect(coerce(.px, .{ .number = std.math.inf(f32) }) == null);
    try testing.expectEqual(false, coerce(.flag, .{ .number = 0 }).?.boolean);
    try testing.expectEqual(props.Keyword.auto, coerce(.size, .{ .keyword = .auto }).?.keyword);
    try testing.expect(coerce(.length, .{ .keyword = .auto }) == null);
    try testing.expect(coerce(.size, .{ .dimension = .{ .value = 3, .unit = .pt } }) == null);
}

test "every StyleKey/LayoutKey has a kind its readers accept (exhaustive switch)" {
    // The switches in styleKind/layoutKind have no `else`, so adding a key without
    // deciding how it is read is a compile error. This test just instantiates them.
    inline for (@typeInfo(props.StyleKey).@"enum".fields) |f| _ = styleKind(@enumFromInt(f.value));
    inline for (@typeInfo(props.LayoutKey).@"enum".fields) |f| _ = layoutKind(@enumFromInt(f.value));
}
