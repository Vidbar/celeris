//! Line-break opportunities — a pragmatic subset of UAX #14.
//!
//! The wrap pass used to break only at ASCII spaces, which (a) never wrapped CJK
//! (no spaces) except as a hard overflow break and (b) could place closing
//! punctuation at the start of a line or break right after an opening bracket.
//! This classifies each codepoint into a small set of break classes and decides
//! whether a break is allowed *before* a given codepoint, covering the rules that
//! matter most for mixed Latin/CJK text:
//!   • break after spaces and hyphens,
//!   • break between ideographs (and between an ideograph and adjacent text),
//!   • never break before closing punctuation / a space,
//!   • never break right after opening punctuation.
//! Full UAX #14 (pair table, numeric/quotation context, etc.) is intentionally
//! not implemented; this is the high-value core and is unit-tested without a font.

const std = @import("std");

pub const Class = enum {
    sp, // space / tab
    op, // opening punctuation: ( [ { （ 〔 「 …
    cl, // closing punctuation + nonstarters: ) ] } , . ; : ! ? 。 、 ） ！ ？ …
    id, // ideographic (CJK / Kana / Hangul) — breakable on both sides
    hy, // hyphen / hyphen-minus
    al, // everything else (alphabetic, digits, symbols)
};

/// True for codepoints treated as ideographic (each is a break opportunity).
fn isIdeographic(cp: u21) bool {
    return (cp >= 0x3040 and cp <= 0x30FF) // Hiragana + Katakana
    or (cp >= 0x3400 and cp <= 0x4DBF) // CJK Ext A
    or (cp >= 0x4E00 and cp <= 0x9FFF) // CJK Unified
    or (cp >= 0xAC00 and cp <= 0xD7A3) // Hangul syllables
    or (cp >= 0xF900 and cp <= 0xFAFF) // CJK compatibility
    or (cp >= 0xFF00 and cp <= 0xFF60); // fullwidth forms (sans the brackets handled below)
}

pub fn classOf(cp: u21) Class {
    switch (cp) {
        ' ', '\t' => return .sp,
        '(', '[', '{', 0x300C, 0x3014, 0xFF08 => return .op, // ( [ { 「 〔 （
        ')', ']', '}', ',', '.', ';', ':', '!', '?', 0x3001, 0x3002, 0x300D, 0x3015, 0xFF09, 0xFF01, 0xFF1F, 0xFF0C => return .cl, // ) ] } , . ; : ! ? 、 。 」 〕 ） ！ ？ ，
        '-', 0x2010 => return .hy,
        else => {},
    }
    if (isIdeographic(cp)) return .id;
    return .al;
}

/// True if a line break is permitted *before* `cur` given the preceding `prev`
/// (i.e. `cur` may start a new line). The wrap pass records the most recent such
/// position and breaks there when a line overflows.
pub fn canBreakBefore(prev: Class, cur: Class) bool {
    if (cur == .cl or cur == .sp) return false; // never start a line with close punct / space
    if (prev == .op) return false; // never break right after open punct
    if (prev == .sp or prev == .hy) return true; // break after a space or hyphen
    if (prev == .id or cur == .id) return true; // break around ideographs
    return false; // e.g. inside a Latin word (al–al)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "classOf categorizes the common cases" {
    try testing.expectEqual(Class.sp, classOf(' '));
    try testing.expectEqual(Class.al, classOf('A'));
    try testing.expectEqual(Class.al, classOf('5'));
    try testing.expectEqual(Class.id, classOf('\u{65E5}')); // 日 (ideograph)
    try testing.expectEqual(Class.id, classOf('\u{3042}')); // あ (hiragana)
    try testing.expectEqual(Class.op, classOf('('));
    try testing.expectEqual(Class.cl, classOf(')'));
    try testing.expectEqual(Class.cl, classOf(','));
    try testing.expectEqual(Class.cl, classOf('\u{3002}')); // 。
    try testing.expectEqual(Class.hy, classOf('-'));
}

test "canBreakBefore follows the UAX#14 subset rules" {
    // No break inside a Latin word.
    try testing.expect(!canBreakBefore(.al, .al));
    // Break after a space, but not before one, and not before closing punct.
    try testing.expect(canBreakBefore(.sp, .al));
    try testing.expect(!canBreakBefore(.al, .sp));
    try testing.expect(!canBreakBefore(.al, .cl));
    // Ideographs break on both sides…
    try testing.expect(canBreakBefore(.id, .id));
    try testing.expect(canBreakBefore(.al, .id));
    try testing.expect(canBreakBefore(.id, .al));
    // …but never before closing punctuation (e.g. 日。 keeps 。 with 日).
    try testing.expect(!canBreakBefore(.id, .cl));
    // Never break right after opening punctuation.
    try testing.expect(!canBreakBefore(.op, .al));
    // Break after a hyphen.
    try testing.expect(canBreakBefore(.hy, .al));
}
