//! Tonal palettes: a hue/chroma pair from which any tone (0..100) can be
//! materialized, plus the Material 3 CorePalette derivation rules from a seed.
//!
//! Ported from Google's material-color-utilities
//! (typescript/palettes/{tonal_palette,core_palette}.ts).
//! Copyright 2021 Google LLC. Licensed under the Apache License, Version 2.0.

const std = @import("std");
const color = @import("color.zig");

/// A convenience class for retrieving colors that are constant in hue and
/// chroma, but vary in tone. No caching: a full Material scheme costs ~40
/// solver calls, generated once per theme swap.
pub const TonalPalette = struct {
    hue: f64,
    chroma: f64,

    pub fn fromHueAndChroma(hue: f64, chroma: f64) TonalPalette {
        return .{ .hue = hue, .chroma = chroma };
    }

    pub fn fromInt(argb: u32) TonalPalette {
        const hct = color.Hct.fromInt(argb);
        return .{ .hue = hct.hue, .chroma = hct.chroma };
    }

    /// ARGB of the palette color at the given tone (0..100).
    pub fn tone(self: TonalPalette, t: f64) u32 {
        return color.Hct.from(self.hue, self.chroma, t).toInt();
    }
};

/// The five key palettes (plus error) Material 3 derives from a seed color.
pub const CorePalette = struct {
    primary: TonalPalette,
    secondary: TonalPalette,
    tertiary: TonalPalette,
    neutral: TonalPalette,
    neutral_variant: TonalPalette,
    err: TonalPalette,

    pub fn of(seed_argb: u32) CorePalette {
        const hct = color.Hct.fromInt(seed_argb);
        return .{
            .primary = TonalPalette.fromHueAndChroma(hct.hue, @max(48.0, hct.chroma)),
            .secondary = TonalPalette.fromHueAndChroma(hct.hue, 16.0),
            .tertiary = TonalPalette.fromHueAndChroma(hct.hue + 60.0, 24.0),
            .neutral = TonalPalette.fromHueAndChroma(hct.hue, 4.0),
            .neutral_variant = TonalPalette.fromHueAndChroma(hct.hue, 8.0),
            .err = TonalPalette.fromHueAndChroma(25.0, 84.0),
        };
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "TonalPalette: tone 0 is black, tone 100 is white" {
    const p = TonalPalette.fromHueAndChroma(270.0, 36.0);
    try testing.expectEqual(@as(u32, 0xff000000), p.tone(0.0));
    try testing.expectEqual(@as(u32, 0xffffffff), p.tone(100.0));
}

test "TonalPalette: L* is monotonically non-decreasing in tone" {
    const p = TonalPalette.fromHueAndChroma(210.0, 48.0);
    var prev: f64 = -1.0;
    var t: f64 = 0.0;
    while (t <= 100.0) : (t += 10.0) {
        const lstar = color.lstarFromArgb(p.tone(t));
        try testing.expect(lstar >= prev);
        prev = lstar;
    }
}

test "CorePalette.of: derivation rules from seed" {
    // Google blue 0xff4285f4.
    const seed_hct = color.Hct.fromInt(0xff4285f4);
    const cp = CorePalette.of(0xff4285f4);
    try testing.expectApproxEqAbs(seed_hct.hue, cp.primary.hue, 1e-9);
    try testing.expectApproxEqAbs(@max(48.0, seed_hct.chroma), cp.primary.chroma, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 16.0), cp.secondary.chroma, 1e-9);
    try testing.expectApproxEqAbs(seed_hct.hue + 60.0, cp.tertiary.hue, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 24.0), cp.tertiary.chroma, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.0), cp.neutral.chroma, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8.0), cp.neutral_variant.chroma, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 25.0), cp.err.hue, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 84.0), cp.err.chroma, 1e-9);
}
