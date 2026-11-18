//! Codicons — the bundled icon set (VS Code's icon font, CC BY 4.0).
//!
//! The TTF (`vendor/codicons/codicon.ttf`, ~120 KB) is embedded into the engine
//! binary and registered as a font-stack fallback at atlas load (c_api.zig), so
//! icons need no runtime asset and render through the ordinary text pipeline:
//! they tint with `color`, scale with `font_size`/DPI, and share the glyph atlas.
//!
//! Every icon is a Private Use Area codepoint (U+EA60+), so it never collides
//! with glyphs from the primary/system fonts. Use the constants as the `icon`
//! prop (they are UTF-8 string literals):
//!
//!     try ctx.mountOwned(IconButton, .{ .icon = icons.close, .on_click = h });
//!
//! Curated subset of the ~600 icons; the full name→codepoint table lives in
//! `vendor/codicons/codicon.csv`. Add constants here as widgets need them.

/// Comptime UTF-8 encoding of a codepoint, so constants stay one-liner strings.
fn cp(comptime c: u21) *const [3:0]u8 {
    comptime {
        var buf: [3:0]u8 = undefined;
        _ = @import("std").unicode.utf8Encode(c, &buf) catch unreachable;
        const frozen = buf;
        return &frozen;
    }
}

// ── Window chrome (AppBar) ────────────────────────────────────────────────────
pub const chrome_close = cp(0xEAB8);
pub const chrome_maximize = cp(0xEAB9);
pub const chrome_minimize = cp(0xEABA);
pub const chrome_restore = cp(0xEABB);
pub const menu = cp(0xEB94);

// ── Navigation ────────────────────────────────────────────────────────────────
pub const chevron_down = cp(0xEAB4);
pub const chevron_left = cp(0xEAB5);
pub const chevron_right = cp(0xEAB6);
pub const chevron_up = cp(0xEAB7);
pub const arrow_left = cp(0xEA9B);
pub const arrow_right = cp(0xEA9C);
pub const home = cp(0xEB06);

// ── Actions ───────────────────────────────────────────────────────────────────
pub const add = cp(0xEA60);
pub const remove = cp(0xEB3B);
pub const close = cp(0xEA76);
pub const check = cp(0xEAB2);
pub const edit = cp(0xEA73);
pub const trash = cp(0xEA81);
pub const save = cp(0xEB4B);
pub const copy = cp(0xEBCC);
pub const refresh = cp(0xEB37);
pub const sync = cp(0xEA77);
pub const search = cp(0xEA6D);
pub const filter = cp(0xEAF1);
pub const play = cp(0xEB2C);
pub const pause = cp(0xEAD1);
pub const stop_circle = cp(0xEBA5);
pub const record = cp(0xEBA7);
pub const pin = cp(0xEB2B);
pub const pinned = cp(0xEBA0);
pub const eye = cp(0xEA70);
pub const eye_closed = cp(0xEAE7);
pub const ellipsis = cp(0xEA7C);

// ── Objects / status ──────────────────────────────────────────────────────────
pub const file = cp(0xEA7B);
pub const folder = cp(0xEA83);
pub const folder_opened = cp(0xEAF7);
pub const files = cp(0xEAF0);
pub const settings_gear = cp(0xEB51);
pub const account = cp(0xEB99);
pub const bell = cp(0xEAA2);
pub const terminal = cp(0xEA85);
pub const extensions = cp(0xEAE6);
pub const list_tree = cp(0xEB86);
pub const layout = cp(0xEBEB);
pub const circle_filled = cp(0xEA71);
pub const info = cp(0xEA74);
pub const warning = cp(0xEA6C);
pub const question = cp(0xEB32);
pub const @"error" = cp(0xEA87);

// ── Run and debug ─────────────────────────────────────────────────────────────
pub const debug = cp(0xEAD8);
pub const debug_start = cp(0xEAD3);
pub const debug_stop = cp(0xEAD7);
pub const debug_alt = cp(0xEB91);
pub const debug_alt_small = cp(0xEBA8);

// ── Tests ─────────────────────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "icon constants are valid single-codepoint UTF-8 in the PUA" {
    for ([_][]const u8{ chrome_close, close, menu, search, folder_opened, @"error", debug, debug_start, debug_stop, debug_alt, debug_alt_small }) |s| {
        var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
        const c = it.nextCodepoint().?;
        try testing.expect(c >= 0xE000 and c <= 0xF8FF); // Private Use Area
        try testing.expectEqual(@as(?u21, null), it.nextCodepoint()); // exactly one
    }
}

test "embedded codicon.ttf is a valid TrueType blob" {
    const ttf = @embedFile("codicon_ttf");
    try testing.expect(ttf.len > 50_000);
    // TrueType sfnt version 1.0.
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x00, 0x00 }, ttf[0..4]);
}

const run_debug = [_]struct { s: []const u8, c: u21 }{
    .{ .s = debug, .c = 0xEAD8 },
    .{ .s = debug_start, .c = 0xEAD3 },
    .{ .s = debug_stop, .c = 0xEAD7 },
    .{ .s = debug_alt, .c = 0xEB91 },
    .{ .s = debug_alt_small, .c = 0xEBA8 },
};

test "run/debug icons encode their codepoints" {
    for (run_debug) |e| {
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(e.c, &buf);
        try testing.expectEqualSlices(u8, buf[0..n], e.s);
    }
}

/// Minimal cmap lookup (formats 4 and 12) — test-only, to prove a glyph exists.
fn ttfGlyphId(ttf: []const u8, c: u21) ?u32 {
    const be16 = struct {
        fn f(b: []const u8, o: usize) u16 {
            return std.mem.readInt(u16, b[o..][0..2], .big);
        }
    }.f;
    const be32 = struct {
        fn f(b: []const u8, o: usize) u32 {
            return std.mem.readInt(u32, b[o..][0..4], .big);
        }
    }.f;
    const num_tables = be16(ttf, 4);
    var cmap: ?usize = null;
    for (0..num_tables) |i| {
        const rec = 12 + i * 16;
        if (std.mem.eql(u8, ttf[rec..][0..4], "cmap")) cmap = be32(ttf, rec + 8);
    }
    const base = cmap orelse return null;
    const n_sub = be16(ttf, base + 2);
    for (0..n_sub) |i| {
        const sub = base + be32(ttf, base + 4 + i * 8 + 4);
        switch (be16(ttf, sub)) {
            4 => {
                const segx2 = be16(ttf, sub + 6);
                const ends = sub + 14;
                const starts = ends + segx2 + 2;
                const deltas = starts + segx2;
                const ranges = deltas + segx2;
                var s: usize = 0;
                while (s < segx2) : (s += 2) {
                    const end = be16(ttf, ends + s);
                    const start = be16(ttf, starts + s);
                    if (c < start or c > end) continue;
                    const delta = be16(ttf, deltas + s);
                    const ro = be16(ttf, ranges + s);
                    const gid: u16 = if (ro == 0)
                        @truncate(@as(u32, c) +% delta)
                    else blk: {
                        const g = be16(ttf, ranges + s + ro + 2 * (c - start));
                        break :blk if (g == 0) 0 else g +% delta;
                    };
                    if (gid != 0) return gid;
                }
            },
            12 => {
                const groups = be32(ttf, sub + 12);
                for (0..groups) |g| {
                    const o = sub + 16 + g * 12;
                    const lo = be32(ttf, o);
                    const hi = be32(ttf, o + 4);
                    if (c >= lo and c <= hi) return be32(ttf, o + 8) + (c - lo);
                }
            },
            else => {},
        }
    }
    return null;
}

test "run/debug glyphs exist in the embedded codicon.ttf" {
    const ttf = @embedFile("codicon_ttf");
    for (run_debug) |e| try testing.expect(ttfGlyphId(ttf, e.c) != null);
    // Sanity: a codepoint outside the set has no glyph.
    try testing.expect(ttfGlyphId(ttf, 0x41) == null);
    try testing.expect(ttfGlyphId(ttf, 0xF8FF) == null);
}
