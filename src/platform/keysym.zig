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
        'A'...'Z', '0'...'9' => @enumFromInt(sym),
        'a'...'z' => @enumFromInt(sym - 0x20),
        F1...F12 => @enumFromInt(Key.f1.code() + (sym - F1)),
        else => null,
    };
    return if (k) |key| key.code() else 0;
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
        .{ .sym = F1 + 4, .key = .f5 },
    };
    for (cases) |cs| try std.testing.expectEqual(@as(?Key, cs.key), Key.fromCode(toVk(cs.sym)));
    try std.testing.expectEqual(@as(u32, 0), toVk('!'));
    try std.testing.expectEqual(@as(u32, 0), toVk(';'));
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
