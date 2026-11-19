//! XKB keysym → engine key code (Windows virtual-key numbering, named by
//! `framework/events.zig` `Key`). Pure and platform-independent so the mapping is
//! unit-tested on every OS; `linux.zig` feeds it the keysym from xkbcommon and
//! checks at compile time that the constants below match `<xkbcommon/...>`.
//!
//! Keysym values are the stable X11 numbering (keysymdef.h).

const std = @import("std");
const Key = @import("../framework/events.zig").Key;

pub const BackSpace: u32 = 0xff08;
pub const Tab: u32 = 0xff09;
pub const ISO_Left_Tab: u32 = 0xfe20; // Shift+Tab on most layouts
pub const Return: u32 = 0xff0d;
pub const Escape: u32 = 0xff1b;
pub const Home: u32 = 0xff50;
pub const Left: u32 = 0xff51;
pub const Up: u32 = 0xff52;
pub const Right: u32 = 0xff53;
pub const Down: u32 = 0xff54;
pub const Page_Up: u32 = 0xff55;
pub const Page_Down: u32 = 0xff56;
pub const End: u32 = 0xff57;
pub const Insert: u32 = 0xff63;
pub const Delete: u32 = 0xffff;
pub const KP_Enter: u32 = 0xff8d;
pub const KP_Home: u32 = 0xff95;
pub const KP_Left: u32 = 0xff96;
pub const KP_Up: u32 = 0xff97;
pub const KP_Right: u32 = 0xff98;
pub const KP_Down: u32 = 0xff99;
pub const KP_Page_Up: u32 = 0xff9a;
pub const KP_Page_Down: u32 = 0xff9b;
pub const KP_End: u32 = 0xff9c;
pub const KP_Insert: u32 = 0xff9e;
pub const KP_Delete: u32 = 0xff9f;
pub const F1: u32 = 0xffbe;
pub const F12: u32 = 0xffc9;
pub const space: u32 = 0x20;
pub const Shift_L: u32 = 0xffe1;
pub const Shift_R: u32 = 0xffe2;
pub const Control_L: u32 = 0xffe3;
pub const Control_R: u32 = 0xffe4;
pub const Alt_L: u32 = 0xffe9;
pub const Alt_R: u32 = 0xffea;
pub const Super_L: u32 = 0xffeb;
pub const Super_R: u32 = 0xffec;
pub const Menu: u32 = 0xff67;

/// Engine key code for an XKB keysym; 0 when the key has no mapping.
pub fn toVk(sym: u32) u32 {
    const k: ?Key = switch (sym) {
        BackSpace => .backspace,
        Tab, ISO_Left_Tab => .tab,
        Return, KP_Enter => .enter,
        Escape => .escape,
        space => .space,
        // Bare modifier presses fold onto the generic VKs Win32 sends.
        Shift_L, Shift_R => .shift,
        Control_L, Control_R => .ctrl,
        Alt_L, Alt_R => .alt,
        Super_L, Super_R => .meta,
        Menu => .apps,
        Home, KP_Home => .home,
        End, KP_End => .end,
        Page_Up, KP_Page_Up => .page_up,
        Page_Down, KP_Page_Down => .page_down,
        Left, KP_Left => .left,
        Up, KP_Up => .up,
        Right, KP_Right => .right,
        Down, KP_Down => .down,
        Insert, KP_Insert => .insert,
        Delete, KP_Delete => .delete,
        // Letters: keysyms 'A'..'Z' already equal the VK codes; 'a'..'z' fold onto them.
        'A'...'Z', '0'...'9' => @fromBackingInt(@intCast(sym)),
        'a'...'z' => @fromBackingInt(@intCast(sym - 0x20)),
        F1...F12 => @fromBackingInt(@intCast(Key.f1.code() + (sym - F1))),
        // Punctuation: US keysym and its shifted form (Latin-1 keysyms equal ASCII).
        '`', '~' => .backquote,
        '-', '_' => .minus,
        '=', '+' => .equal,
        '[', '{' => .bracket_left,
        ']', '}' => .bracket_right,
        '\\', '|' => .backslash,
        ';', ':' => .semicolon,
        '\'', '"' => .quote,
        ',', '<' => .comma,
        '.', '>' => .period,
        '/', '?' => .slash,
        else => null,
    };
    return if (k) |key| key.code() else 0;
}

/// Engine key code for a key press, naming the physical key the way Windows'
/// layout VKs do rather than the character Shift produced. `sym` is the
/// effective keysym; `level0`/`level1` are the key's unshifted and shifted
/// keysyms in the active layout (0 if none).
///  - Printable keys are named by their unshifted symbol, so Shift+/ (`?`) is
///    `slash` and German Shift+7 (`/`) stays `7`.
///  - A number-row key whose unshifted symbol is punctuation and shifted symbol
///    a digit (AZERTY `-`/`6`) is that digit, as Windows assigns it.
///  - Non-printable syms (navigation, keypad, F-keys) keep the effective keysym,
///    so NumLock still decides KP_7 vs KP_Home.
pub fn keyVk(sym: u32, level0: u32, level1: u32) u32 {
    if (sym < 0x20 or sym > 0x7e) return toVk(sym);
    if (level1 >= '0' and level1 <= '9' and !(level0 >= '0' and level0 <= '9') and
        !((level0 >= 'a' and level0 <= 'z') or (level0 >= 'A' and level0 <= 'Z'))) return toVk(level1);
    const base = toVk(level0);
    return if (base != 0) base else toVk(sym);
}

test "keyVk names the physical key, not the shifted character" {
    // US: Shift+/ types '?', still slash; Shift+; types ':', still semicolon.
    try std.testing.expectEqual(Key.slash.code(), keyVk('?', '/', '?'));
    try std.testing.expectEqual(Key.semicolon.code(), keyVk(':', ';', ':'));
    try std.testing.expectEqual(Key.a.code(), keyVk('A', 'a', 'A'));
    // German: Shift+7 types '/', but the key is 7; Shift+0 types '=', key is 0.
    try std.testing.expectEqual(Key.@"7".code(), keyVk('/', '7', '/'));
    try std.testing.expectEqual(Key.@"0".code(), keyVk('=', '0', '='));
    // German '+' key (Windows VK_OEM_PLUS).
    try std.testing.expectEqual(Key.equal.code(), keyVk('+', '+', '*'));
    // AZERTY: the 6 key types '-' unshifted and '6' shifted; Windows calls it 6.
    try std.testing.expectEqual(Key.@"6".code(), keyVk('-', '-', '6'));
    try std.testing.expectEqual(Key.@"6".code(), keyVk('6', '-', '6'));
    // AZERTY '1' key: '&' unshifted (unmapped punctuation) and '1' shifted.
    try std.testing.expectEqual(Key.@"1".code(), keyVk('&', '&', '1'));
    // Spanish Ñ: ntilde is not US punctuation, stays unnamed.
    try std.testing.expectEqual(@as(u32, 0), keyVk(0xf1, 0xf1, 0xd1));
    // Non-printable: effective keysym wins (NumLock state), levels ignored.
    try std.testing.expectEqual(Key.home.code(), keyVk(KP_Home, KP_Home, '7'));
    try std.testing.expectEqual(Key.left.code(), keyVk(Left, Left, 0));
    // No level info (0s) falls back to the effective keysym.
    try std.testing.expectEqual(Key.minus.code(), keyVk('-', 0, 0));
}

test "keysym navigation maps to the same Key as Windows VK codes" {
    const cases = [_]struct { sym: u32, key: Key }{
        .{ .sym = Left, .key = .left },       .{ .sym = Right, .key = .right },
        .{ .sym = Up, .key = .up },           .{ .sym = Down, .key = .down },
        .{ .sym = Home, .key = .home },       .{ .sym = End, .key = .end },
        .{ .sym = Page_Up, .key = .page_up }, .{ .sym = Page_Down, .key = .page_down },
        .{ .sym = KP_Left, .key = .left },    .{ .sym = KP_End, .key = .end },
    };
    for (cases) |cs| try std.testing.expectEqual(@as(?Key, cs.key), Key.fromCode(toVk(cs.sym)));
    // Pin the Windows VK numbers themselves so the enum can't drift.
    try std.testing.expectEqual(@as(u32, 0x25), Key.left.code());
    try std.testing.expectEqual(@as(u32, 0x24), Key.home.code());
    try std.testing.expectEqual(@as(u32, 0x21), Key.page_up.code());
}

test "keysym editing keys, letters, digits and F-keys" {
    const cases = [_]struct { sym: u32, key: Key }{
        .{ .sym = BackSpace, .key = .backspace }, .{ .sym = Delete, .key = .delete },
        .{ .sym = Return, .key = .enter },        .{ .sym = KP_Enter, .key = .enter },
        .{ .sym = Tab, .key = .tab },             .{ .sym = ISO_Left_Tab, .key = .tab },
        .{ .sym = Escape, .key = .escape },       .{ .sym = space, .key = .space },
        .{ .sym = Insert, .key = .insert },       .{ .sym = 'a', .key = .a },
        .{ .sym = 'z', .key = .z },               .{ .sym = 'C', .key = .c },
        .{ .sym = '0', .key = .@"0" },            .{ .sym = '9', .key = .@"9" },
        .{ .sym = F1, .key = .f1 },               .{ .sym = F12, .key = .f12 },
        .{ .sym = F1 + 4, .key = .f5 },           .{ .sym = Menu, .key = .apps },
    };
    for (cases) |cs| try std.testing.expectEqual(@as(?Key, cs.key), Key.fromCode(toVk(cs.sym)));
    try std.testing.expectEqual(@as(u32, 0), toVk('!'));
}

test "keysym punctuation maps onto the Windows VK_OEM codes" {
    const cases = [_]struct { sym: u32, key: Key, vk: u32 }{
        .{ .sym = '`', .key = .backquote, .vk = 0xC0 },     .{ .sym = '~', .key = .backquote, .vk = 0xC0 },
        .{ .sym = '-', .key = .minus, .vk = 0xBD },         .{ .sym = '_', .key = .minus, .vk = 0xBD },
        .{ .sym = '=', .key = .equal, .vk = 0xBB },         .{ .sym = '+', .key = .equal, .vk = 0xBB },
        .{ .sym = '[', .key = .bracket_left, .vk = 0xDB },  .{ .sym = '{', .key = .bracket_left, .vk = 0xDB },
        .{ .sym = ']', .key = .bracket_right, .vk = 0xDD }, .{ .sym = '}', .key = .bracket_right, .vk = 0xDD },
        .{ .sym = '\\', .key = .backslash, .vk = 0xDC },    .{ .sym = '|', .key = .backslash, .vk = 0xDC },
        .{ .sym = ';', .key = .semicolon, .vk = 0xBA },     .{ .sym = ':', .key = .semicolon, .vk = 0xBA },
        .{ .sym = '\'', .key = .quote, .vk = 0xDE },        .{ .sym = '"', .key = .quote, .vk = 0xDE },
        .{ .sym = ',', .key = .comma, .vk = 0xBC },         .{ .sym = '<', .key = .comma, .vk = 0xBC },
        .{ .sym = '.', .key = .period, .vk = 0xBE },        .{ .sym = '>', .key = .period, .vk = 0xBE },
        .{ .sym = '/', .key = .slash, .vk = 0xBF },         .{ .sym = '?', .key = .slash, .vk = 0xBF },
    };
    for (cases) |cs| {
        try std.testing.expectEqual(cs.vk, toVk(cs.sym));
        try std.testing.expectEqual(@as(?Key, cs.key), Key.fromCode(cs.vk));
    }
    // Windows reports Spanish Ñ as VK_OEM_3: an accelerator on `backquote` sees it.
    try std.testing.expectEqual(@as(?Key, .backquote), Key.fromCode(0xC0));
}

test "keysym modifiers fold onto the generic Win32 VKs" {
    const cases = [_]struct { sym: u32, code: u32 }{
        .{ .sym = Shift_L, .code = 0x10 },   .{ .sym = Shift_R, .code = 0x10 },
        .{ .sym = Control_L, .code = 0x11 }, .{ .sym = Control_R, .code = 0x11 },
        .{ .sym = Alt_L, .code = 0x12 },     .{ .sym = Alt_R, .code = 0x12 },
        .{ .sym = Super_L, .code = 0x5B },   .{ .sym = Super_R, .code = 0x5B },
    };
    for (cases) |cs| try std.testing.expectEqual(cs.code, toVk(cs.sym));
}
