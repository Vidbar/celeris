//! Material 3 color scheme: semantic color roles generated from a seed color
//! via tonal palettes, plus the mapping onto Celeris' `Theme` tokens.
//!
//! Role/tone assignments follow the Material 3 spec (m3.material.io). Palette
//! derivation is ported from Google's material-color-utilities (Apache 2.0).

const std = @import("std");
const color = @import("../core/color.zig");
const tonal = @import("../core/tonal_palette.zig");
const theme_mod = @import("theme.zig");

const Color = theme_mod.Color;
const Theme = theme_mod.Theme;

pub const Brightness = enum { light, dark };

fn colorFromArgb(argb: u32) Color {
    return .{
        .r = color.redFromArgb(argb),
        .g = color.greenFromArgb(argb),
        .b = color.blueFromArgb(argb),
    };
}

fn argbFromColor(c: Color) u32 {
    return color.argbFromRgb(c.r, c.g, c.b);
}

/// The Material 3 color roles. Every color is opaque (a=255).
pub const ColorScheme = struct {
    primary: Color,
    on_primary: Color,
    primary_container: Color,
    on_primary_container: Color,
    inverse_primary: Color,

    secondary: Color,
    on_secondary: Color,
    secondary_container: Color,
    on_secondary_container: Color,

    tertiary: Color,
    on_tertiary: Color,
    tertiary_container: Color,
    on_tertiary_container: Color,

    err: Color,
    on_error: Color,
    error_container: Color,
    on_error_container: Color,

    surface: Color,
    on_surface: Color,
    surface_variant: Color,
    on_surface_variant: Color,
    surface_dim: Color,
    surface_bright: Color,
    surface_container_lowest: Color,
    surface_container_low: Color,
    surface_container: Color,
    surface_container_high: Color,
    surface_container_highest: Color,
    inverse_surface: Color,
    inverse_on_surface: Color,

    outline: Color,
    outline_variant: Color,
    shadow: Color,
    scrim: Color,
    surface_tint: Color,

    pub fn fromSeed(seed: Color, brightness: Brightness) ColorScheme {
        return fromCorePalette(tonal.CorePalette.of(argbFromColor(seed)), brightness);
    }

    pub fn fromCorePalette(cp: tonal.CorePalette, brightness: Brightness) ColorScheme {
        const p = cp.primary;
        const s = cp.secondary;
        const t = cp.tertiary;
        const n = cp.neutral;
        const nv = cp.neutral_variant;
        const e = cp.err;
        // Each tone() call is a full HCT solve and is not cached — hoist the
        // tones that back more than one role so they solve once.
        const black = colorFromArgb(n.tone(0));
        return switch (brightness) {
            .light => blk: {
                const primary = colorFromArgb(p.tone(40));
                const surface = colorFromArgb(n.tone(98));
                break :blk .{
                    .primary = primary,
                    .on_primary = colorFromArgb(p.tone(100)),
                    .primary_container = colorFromArgb(p.tone(90)),
                    .on_primary_container = colorFromArgb(p.tone(10)),
                    .inverse_primary = colorFromArgb(p.tone(80)),

                    .secondary = colorFromArgb(s.tone(40)),
                    .on_secondary = colorFromArgb(s.tone(100)),
                    .secondary_container = colorFromArgb(s.tone(90)),
                    .on_secondary_container = colorFromArgb(s.tone(10)),

                    .tertiary = colorFromArgb(t.tone(40)),
                    .on_tertiary = colorFromArgb(t.tone(100)),
                    .tertiary_container = colorFromArgb(t.tone(90)),
                    .on_tertiary_container = colorFromArgb(t.tone(10)),

                    .err = colorFromArgb(e.tone(40)),
                    .on_error = colorFromArgb(e.tone(100)),
                    .error_container = colorFromArgb(e.tone(90)),
                    .on_error_container = colorFromArgb(e.tone(10)),

                    .surface = surface,
                    .on_surface = colorFromArgb(n.tone(10)),
                    .surface_variant = colorFromArgb(nv.tone(90)),
                    .on_surface_variant = colorFromArgb(nv.tone(30)),
                    .surface_dim = colorFromArgb(n.tone(87)),
                    .surface_bright = surface,
                    .surface_container_lowest = colorFromArgb(n.tone(100)),
                    .surface_container_low = colorFromArgb(n.tone(96)),
                    .surface_container = colorFromArgb(n.tone(94)),
                    .surface_container_high = colorFromArgb(n.tone(92)),
                    .surface_container_highest = colorFromArgb(n.tone(90)),
                    .inverse_surface = colorFromArgb(n.tone(20)),
                    .inverse_on_surface = colorFromArgb(n.tone(95)),

                    .outline = colorFromArgb(nv.tone(50)),
                    .outline_variant = colorFromArgb(nv.tone(80)),
                    .shadow = black,
                    .scrim = black,
                    .surface_tint = primary,
                };
            },
            .dark => blk: {
                const primary = colorFromArgb(p.tone(80));
                const surface = colorFromArgb(n.tone(6));
                break :blk .{
                    .primary = primary,
                    .on_primary = colorFromArgb(p.tone(20)),
                    .primary_container = colorFromArgb(p.tone(30)),
                    .on_primary_container = colorFromArgb(p.tone(90)),
                    .inverse_primary = colorFromArgb(p.tone(40)),

                    .secondary = colorFromArgb(s.tone(80)),
                    .on_secondary = colorFromArgb(s.tone(20)),
                    .secondary_container = colorFromArgb(s.tone(30)),
                    .on_secondary_container = colorFromArgb(s.tone(90)),

                    .tertiary = colorFromArgb(t.tone(80)),
                    .on_tertiary = colorFromArgb(t.tone(20)),
                    .tertiary_container = colorFromArgb(t.tone(30)),
                    .on_tertiary_container = colorFromArgb(t.tone(90)),

                    .err = colorFromArgb(e.tone(80)),
                    .on_error = colorFromArgb(e.tone(20)),
                    .error_container = colorFromArgb(e.tone(30)),
                    .on_error_container = colorFromArgb(e.tone(90)),

                    .surface = surface,
                    .on_surface = colorFromArgb(n.tone(90)),
                    .surface_variant = colorFromArgb(nv.tone(30)),
                    .on_surface_variant = colorFromArgb(nv.tone(80)),
                    .surface_dim = surface,
                    .surface_bright = colorFromArgb(n.tone(24)),
                    .surface_container_lowest = colorFromArgb(n.tone(4)),
                    .surface_container_low = colorFromArgb(n.tone(10)),
                    .surface_container = colorFromArgb(n.tone(12)),
                    .surface_container_high = colorFromArgb(n.tone(17)),
                    .surface_container_highest = colorFromArgb(n.tone(22)),
                    .inverse_surface = colorFromArgb(n.tone(90)),
                    .inverse_on_surface = colorFromArgb(n.tone(20)),

                    .outline = colorFromArgb(nv.tone(60)),
                    .outline_variant = colorFromArgb(nv.tone(30)),
                    .shadow = black,
                    .scrim = black,
                    .surface_tint = primary,
                };
            },
        };
    }
};

/// Generates a full Celeris `Theme` from a seed color, mapping the M3 scheme
/// onto the existing token vocabulary. Tokens without an M3 analog (success,
/// warning, status dots) use fixed-hue tonal palettes so their weight matches
/// the scheme's lightness policy.
pub fn themeFromSeed(seed: Color, brightness: Brightness) Theme {
    const cp = tonal.CorePalette.of(argbFromColor(seed));
    const scheme = ColorScheme.fromCorePalette(cp, brightness);

    // Hover moves one step toward higher emphasis, pressed one more:
    // light 40 -> 35 -> 30; dark 80 -> 85 -> 90.
    const accent_hover, const accent_pressed = switch (brightness) {
        .light => .{ cp.primary.tone(35), cp.primary.tone(30) },
        .dark => .{ cp.primary.tone(85), cp.primary.tone(90) },
    };

    const success_palette = tonal.TonalPalette.fromHueAndChroma(140.0, 50.0);
    const warning_palette = tonal.TonalPalette.fromHueAndChroma(85.0, 60.0);
    const accent_tone: f64 = if (brightness == .light) 40 else 80;
    const success = colorFromArgb(success_palette.tone(accent_tone));
    const warning = colorFromArgb(warning_palette.tone(accent_tone));

    // text_disabled: a solid mid tone (never partial alpha — a=0 means "unset").
    const disabled_tone: f64 = if (brightness == .light) 62 else 47;

    return .{
        .bg_base = scheme.surface,
        .bg_surface = scheme.surface_container,
        .bg_surface_hover = scheme.surface_container_high,
        .bg_input = scheme.surface_container_low,
        .bg_disabled = scheme.surface_container_highest,

        .surface_lowest = scheme.surface_container_lowest,
        .surface_low = scheme.surface_container_low,
        .surface_mid = scheme.surface_container,
        .surface_high = scheme.surface_container_high,
        .surface_highest = scheme.surface_container_highest,
        .inverse_surface = scheme.inverse_surface,
        .inverse_on_surface = scheme.inverse_on_surface,

        .scrollbar_track = scheme.surface_container_low,
        .scrollbar_thumb = scheme.outline_variant,
        .scrollbar_thumb_hover = scheme.outline,
        .scrollbar_thumb_active = scheme.on_surface_variant,

        .accent = scheme.primary,
        .accent_hover = colorFromArgb(accent_hover),
        .accent_pressed = colorFromArgb(accent_pressed),
        .accent_container = scheme.primary_container,

        .text = scheme.on_surface,
        .text_secondary = scheme.on_surface_variant,
        .text_disabled = colorFromArgb(cp.neutral_variant.tone(disabled_tone)),
        .text_on_accent = scheme.on_primary,
        .text_on_accent_container = scheme.on_primary_container,

        .focus_ring = scheme.primary,
        .overlay_scrim = .{
            .r = scheme.scrim.r,
            .g = scheme.scrim.g,
            .b = scheme.scrim.b,
            .a = if (brightness == .light) 96 else 140,
        },

        .success = success,
        .warning = warning,
        .danger = scheme.err,

        .status_ok = success,
        .status_neutral = scheme.outline,
        .status_warn = warning,
        .status_err = scheme.err,
        .status_busy = scheme.primary,

        .border_color = scheme.outline_variant,
        .border_width = 1.0,
        .radius_base = 6.0,
        .is_dark = brightness == .dark,
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const SEEDS = [_]Color{
    .{ .r = 0x42, .g = 0x85, .b = 0xf4 }, // Google blue
    .{ .r = 0x67, .g = 0x50, .b = 0xa4 }, // M3 baseline purple
    .{ .r = 0x00, .g = 0x6a, .b = 0x60 }, // teal
    .{ .r = 0xb0, .g = 0x00, .b = 0x20 }, // red
};

test "ColorScheme: on-roles meet WCAG contrast against their surfaces" {
    for (SEEDS) |seed| {
        inline for (.{ Brightness.light, Brightness.dark }) |b| {
            const scheme = ColorScheme.fromSeed(seed, b);
            const on_primary = color.contrastRatio(
                argbFromColor(scheme.primary),
                argbFromColor(scheme.on_primary),
            );
            try testing.expect(on_primary >= 4.5);
            const on_surface = color.contrastRatio(
                argbFromColor(scheme.surface),
                argbFromColor(scheme.on_surface),
            );
            try testing.expect(on_surface >= 4.5);
            const on_surface_variant = color.contrastRatio(
                argbFromColor(scheme.surface),
                argbFromColor(scheme.on_surface_variant),
            );
            try testing.expect(on_surface_variant >= 3.0);
            const on_error = color.contrastRatio(
                argbFromColor(scheme.err),
                argbFromColor(scheme.on_error),
            );
            try testing.expect(on_error >= 4.5);
        }
    }
}

test "ColorScheme: M3 baseline purple seed produces the documented primary" {
    // Seed 0xff6750a4 is the Material 3 baseline; light primary is tone 40 of
    // the primary palette, documented as 0xff6750a4 itself.
    const scheme = ColorScheme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .light);
    try testing.expectEqual(@as(u8, 0x67), scheme.primary.r);
    try testing.expectEqual(@as(u8, 0x50), scheme.primary.g);
    try testing.expectEqual(@as(u8, 0xa4), scheme.primary.b);
}

test "themeFromSeed: every token set (alpha > 0) for both brightnesses" {
    for (SEEDS) |seed| {
        inline for (.{ Brightness.light, Brightness.dark }) |b| {
            const t = themeFromSeed(seed, b);
            inline for (std.meta.fields(Theme)) |f| {
                if (f.type == Color) {
                    try testing.expect(@field(t, f.name).a > 0);
                }
            }
        }
    }
}

test "themeFromSeed: text is readable on every background token" {
    for (SEEDS) |seed| {
        inline for (.{ Brightness.light, Brightness.dark }) |b| {
            const t = themeFromSeed(seed, b);
            inline for (.{ "bg_base", "bg_surface", "bg_surface_hover", "bg_input" }) |bg| {
                const ratio = color.contrastRatio(
                    argbFromColor(@field(t, bg)),
                    argbFromColor(t.text),
                );
                try testing.expect(ratio >= 4.5);
            }
            const on_accent = color.contrastRatio(
                argbFromColor(t.accent),
                argbFromColor(t.text_on_accent),
            );
            try testing.expect(on_accent >= 4.5);
        }
    }
}
