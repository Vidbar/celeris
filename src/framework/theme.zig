const std = @import("std");
const color_scheme = @import("color_scheme.zig");
const color_util = @import("../core/color.zig");

/// Re-exported so consumers can write `theme.Brightness` without knowing
/// about color_scheme.zig.
pub const Brightness = color_scheme.Brightness;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn transparent() Color {
        return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }

    /// The same hue at a different opacity (0..1). The idiomatic way to express a
    /// tonal text palette — `t.text.withAlpha(0.87)` / `0.60` / `0.38` — instead of
    /// approximating it with hand-picked greys.
    pub fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = @intFromFloat(@round(std.math.clamp(a, 0, 1) * 255.0)) };
    }
};

pub const TextStyle = struct {
    size: f32,
    weight: enum { regular, medium, bold } = .regular,
    /// Line-height multiplier applied by `component.Text` (the node's
    /// `line_height` style). Null = engine default (`fw.text.default_line_height`,
    /// 1.55), so an ad-hoc `.{ .size = 13 }` keeps the default spacing.
    line_height: ?f32 = null,
};

pub const Typography = struct {
    display_large: TextStyle = .{ .size = 57, .line_height = 1.12 },
    display_medium: TextStyle = .{ .size = 45, .line_height = 1.15 },
    display_small: TextStyle = .{ .size = 36, .line_height = 1.22 },

    headline_large: TextStyle = .{ .size = 32, .line_height = 1.25 },
    headline_medium: TextStyle = .{ .size = 28, .line_height = 1.28 },
    headline_small: TextStyle = .{ .size = 24, .line_height = 1.33 },

    title_large: TextStyle = .{ .size = 22, .line_height = 1.27 },
    title_medium: TextStyle = .{ .size = 16, .weight = .medium, .line_height = 1.5 },
    title_small: TextStyle = .{ .size = 14, .weight = .medium, .line_height = 1.42 },

    body_large: TextStyle = .{ .size = 16, .line_height = 1.5 },
    body_medium: TextStyle = .{ .size = 14, .line_height = 1.42 },
    body_small: TextStyle = .{ .size = 12, .line_height = 1.33 },

    label_large: TextStyle = .{ .size = 14, .weight = .medium, .line_height = 1.42 },
    label_medium: TextStyle = .{ .size = 12, .weight = .medium, .line_height = 1.33 },
    label_small: TextStyle = .{ .size = 11, .weight = .medium, .line_height = 1.45 },
};

pub const Theme = struct {
    // ── Backgrounds ─────────────────────────────────────────────────────────
    bg_base: Color = Color.transparent(),
    bg_surface: Color = Color.transparent(),
    bg_surface_hover: Color = Color.transparent(),
    bg_input: Color = Color.transparent(),

    // ── Surface elevation containers (M3) ───────────────────────────────────
    surface_lowest: Color = Color.transparent(),
    surface_low: Color = Color.transparent(),
    surface_mid: Color = Color.transparent(),
    surface_high: Color = Color.transparent(),
    surface_highest: Color = Color.transparent(),
    inverse_surface: Color = Color.transparent(),
    inverse_on_surface: Color = Color.transparent(),

    // ── Scrollbar ───────────────────────────────────────────────────────────
    scrollbar_track: Color = Color.transparent(),
    scrollbar_thumb: Color = Color.transparent(),

    // ── Accents & Text ──────────────────────────────────────────────────────
    accent: Color = Color.transparent(),
    accent_hover: Color = Color.transparent(),
    accent_pressed: Color = Color.transparent(),
    accent_container: Color = Color.transparent(),

    // ── Text ────────────────────────────────────────────────────────────────
    text: Color = Color.transparent(),
    text_secondary: Color = Color.transparent(),
    text_disabled: Color = Color.transparent(),
    text_on_accent: Color = Color.transparent(),
    text_on_accent_container: Color = Color.transparent(),

    // ── Interaction / overlay tokens ──────────────────────────────────────────
    bg_disabled: Color = Color.transparent(),
    focus_ring: Color = Color.transparent(),
    /// Semi-transparent scrim painted behind modal overlays (Dialog).
    overlay_scrim: Color = Color.transparent(),

    // ── Semantic feedback (foreground) ────────────────────────────────────────
    success: Color = Color.transparent(),
    warning: Color = Color.transparent(),
    danger: Color = Color.transparent(),

    // ── Status indicators ─────────────────────────────────────────────────────
    // Consumed by StatusBar dots. Left transparent (a=0) means "unset"; the widget
    // falls back to its built-in standard palette for any kind the theme omits.
    status_ok: Color = Color.transparent(),
    status_neutral: Color = Color.transparent(),
    status_warn: Color = Color.transparent(),
    status_err: Color = Color.transparent(),
    status_busy: Color = Color.transparent(),

    // ── Borders ─────────────────────────────────────────────────────────────
    border_color: Color = Color.transparent(),
    border_width: f32 = 0.0,

    // ── Radii ───────────────────────────────────────────────────────────────
    radius_base: f32 = 0.0,

    /// Whether this is a dark theme. Widgets deriving hover/pressed shades from
    /// arbitrary base colors use it to pick the direction (lighten on dark,
    /// darken on light), matching the M3 policy in themeFromSeed.
    is_dark: bool = true,

    // ── Typography ──────────────────────────────────────────────────────────
    typography: Typography = .{},

    // ── M3 State Layers ─────────────────────────────────────────────────────

    /// Material 3 interaction states with canonical overlay opacities.
    pub const StateLayer = enum {
        hover,
        focus,
        pressed,

        /// M3-specified overlay opacities per state.
        fn opacity(self: StateLayer) f32 {
            return switch (self) {
                .hover => 0.08,
                .focus => 0.10,
                .pressed => 0.12,
            };
        }
    };

    /// Composes the content color `on` over `base` with the M3 opacity for the
    /// given interaction state. sRGB alpha-over in u8 space (sufficient for
    /// subtle overlays — sub-perceptual error vs linear compositing at ≤12%).
    pub fn stateLayer(base: Color, on: Color, state: StateLayer) Color {
        const a = state.opacity();
        return .{
            .r = alphaOver(base.r, on.r, a),
            .g = alphaOver(base.g, on.g, a),
            .b = alphaOver(base.b, on.b, a),
            .a = base.a,
        };
    }

    /// Perceptual lightness (L*, 0..100) of a color.
    pub fn lightness(c: Color) f32 {
        return @floatCast(color_util.lstarFromArgb(color_util.argbFromRgb(c.r, c.g, c.b)));
    }

    /// A legible foreground for an ARBITRARY background: dark text over a light
    /// surface and light text over a dark one, decided by the background's L* rather
    /// than by which prop the caller happened to set. Prefers the theme's own text
    /// tokens when they point the right way, so a themed button keeps its palette;
    /// falls back to plain black/white. This is what keeps a secondary button on
    /// `surface_low` from getting near-black `text_on_accent` on a near-black fill.
    pub fn onColorFor(self: Theme, bg: Color) Color {
        const want_dark_ink = lightness(bg) > 60.0;
        for ([_]Color{ self.text, self.inverse_on_surface, self.text_on_accent }) |cand| {
            if (cand.a == 0) continue; // unset token
            if ((lightness(cand) < 50.0) == want_dark_ink) return cand;
        }
        return if (want_dark_ink) Color{ .r = 0, .g = 0, .b = 0 } else Color{ .r = 255, .g = 255, .b = 255 };
    }

    /// sRGB alpha-over for a single u8 channel.
    fn alphaOver(base: u8, over: u8, alpha: f32) u8 {
        return @intFromFloat(std.math.clamp(
            @as(f32, @floatFromInt(base)) * (1.0 - alpha) + @as(f32, @floatFromInt(over)) * alpha,
            0,
            255,
        ));
    }

    /// Returns a completely unstyled, transparent theme.
    pub fn empty() Theme {
        return .{};
    }

    /// Generates a full theme from a Material 3 seed color: tonal palettes are
    /// derived in HCT space and mapped onto the token vocabulary. See
    /// color_scheme.zig for the M3 roles and the mapping.
    pub fn fromSeed(seed: Color, brightness: Brightness) Theme {
        return color_scheme.themeFromSeed(seed, brightness);
    }

    /// Curated dark preset (default). Text on surfaces meets WCAG AA for normal text.
    pub fn dark() Theme {
        return .{
            .bg_base = .{ .r = 18, .g = 18, .b = 22 },
            .bg_surface = .{ .r = 30, .g = 30, .b = 38 },
            .bg_surface_hover = .{ .r = 42, .g = 42, .b = 52 },
            .bg_input = .{ .r = 24, .g = 24, .b = 30 },
            .bg_disabled = .{ .r = 40, .g = 40, .b = 46 },

            .surface_lowest = .{ .r = 14, .g = 14, .b = 18 },
            .surface_low = .{ .r = 24, .g = 24, .b = 30 },
            .surface_mid = .{ .r = 30, .g = 30, .b = 38 },
            .surface_high = .{ .r = 36, .g = 36, .b = 44 },
            .surface_highest = .{ .r = 44, .g = 44, .b = 54 },
            .inverse_surface = .{ .r = 228, .g = 230, .b = 236 },
            .inverse_on_surface = .{ .r = 44, .g = 44, .b = 54 },

            .scrollbar_track = .{ .r = 24, .g = 24, .b = 30 },
            .scrollbar_thumb = .{ .r = 70, .g = 70, .b = 82 },

            .accent = .{ .r = 60, .g = 130, .b = 246 },
            .accent_hover = .{ .r = 82, .g = 148, .b = 250 },
            .accent_pressed = .{ .r = 42, .g = 108, .b = 220 },
            .accent_container = .{ .r = 15, .g = 41, .b = 89 },

            .text = .{ .r = 236, .g = 237, .b = 240 },
            .text_secondary = .{ .r = 168, .g = 170, .b = 178 },
            .text_disabled = .{ .r = 110, .g = 112, .b = 120 },
            .text_on_accent = .{ .r = 255, .g = 255, .b = 255 },
            .text_on_accent_container = .{ .r = 191, .g = 219, .b = 254 },

            .focus_ring = .{ .r = 96, .g = 165, .b = 250 },
            .overlay_scrim = .{ .r = 0, .g = 0, .b = 0, .a = 140 },

            .success = .{ .r = 74, .g = 194, .b = 122 },
            .warning = .{ .r = 232, .g = 176, .b = 74 },
            .danger = .{ .r = 232, .g = 92, .b = 92 },

            .status_ok = .{ .r = 74, .g = 194, .b = 122 },
            .status_neutral = .{ .r = 130, .g = 132, .b = 140 },
            .status_warn = .{ .r = 232, .g = 176, .b = 74 },
            .status_err = .{ .r = 232, .g = 92, .b = 92 },
            .status_busy = .{ .r = 60, .g = 130, .b = 246 },

            .border_color = .{ .r = 58, .g = 58, .b = 68 },
            .border_width = 1.0,
            .radius_base = 6.0,
            .is_dark = true,
        };
    }

    /// Curated light preset. Text on surfaces meets WCAG AA for normal text.
    pub fn light() Theme {
        return .{
            .bg_base = .{ .r = 248, .g = 249, .b = 251 },
            .bg_surface = .{ .r = 255, .g = 255, .b = 255 },
            .bg_surface_hover = .{ .r = 238, .g = 240, .b = 244 },
            .bg_input = .{ .r = 255, .g = 255, .b = 255 },
            .bg_disabled = .{ .r = 232, .g = 233, .b = 237 },

            .surface_lowest = .{ .r = 255, .g = 255, .b = 255 },
            .surface_low = .{ .r = 248, .g = 249, .b = 251 },
            .surface_mid = .{ .r = 242, .g = 243, .b = 246 },
            .surface_high = .{ .r = 236, .g = 238, .b = 242 },
            .surface_highest = .{ .r = 228, .g = 230, .b = 236 },
            .inverse_surface = .{ .r = 44, .g = 44, .b = 54 },
            .inverse_on_surface = .{ .r = 242, .g = 243, .b = 246 },

            .scrollbar_track = .{ .r = 238, .g = 240, .b = 244 },
            .scrollbar_thumb = .{ .r = 190, .g = 193, .b = 200 },

            .accent = .{ .r = 37, .g = 99, .b = 235 },
            .accent_hover = .{ .r = 29, .g = 78, .b = 216 },
            .accent_pressed = .{ .r = 30, .g = 64, .b = 175 },
            .accent_container = .{ .r = 219, .g = 234, .b = 254 },

            .text = .{ .r = 26, .g = 26, .b = 30 },
            .text_secondary = .{ .r = 102, .g = 105, .b = 112 },
            .text_disabled = .{ .r = 142, .g = 145, .b = 152 },
            .text_on_accent = .{ .r = 255, .g = 255, .b = 255 },
            .text_on_accent_container = .{ .r = 30, .g = 58, .b = 138 },

            .focus_ring = .{ .r = 37, .g = 99, .b = 235 },
            .overlay_scrim = .{ .r = 0, .g = 0, .b = 0, .a = 96 },

            .success = .{ .r = 22, .g = 148, .b = 88 },
            .warning = .{ .r = 176, .g = 120, .b = 16 },
            .danger = .{ .r = 200, .g = 48, .b = 48 },

            .status_ok = .{ .r = 22, .g = 148, .b = 88 },
            .status_neutral = .{ .r = 120, .g = 124, .b = 132 },
            .status_warn = .{ .r = 176, .g = 120, .b = 16 },
            .status_err = .{ .r = 200, .g = 48, .b = 48 },
            .status_busy = .{ .r = 37, .g = 99, .b = 235 },

            .border_color = .{ .r = 214, .g = 216, .b = 222 },
            .border_width = 1.0,
            .radius_base = 6.0,
            .is_dark = false,
        };
    }
};

test "Theme presets — dark and light have every token set (alpha > 0)" {
    inline for (.{ Theme.dark(), Theme.light() }) |t| {
        inline for (std.meta.fields(Theme)) |f| {
            if (f.type == Color) {
                const c = @field(t, f.name);
                try std.testing.expect(c.a > 0); // no "unset" (transparent) token
            }
        }
    }
}

test "stateLayer — black base + white overlay at hover (8%) = (20, 20, 20)" {
    const black = Color{ .r = 0, .g = 0, .b = 0 };
    const white = Color{ .r = 255, .g = 255, .b = 255 };
    const result = Theme.stateLayer(black, white, .hover);
    // 0 * 0.92 + 255 * 0.08 = 20.4 → 20
    try std.testing.expectEqual(@as(u8, 20), result.r);
    try std.testing.expectEqual(@as(u8, 20), result.g);
    try std.testing.expectEqual(@as(u8, 20), result.b);
    try std.testing.expectEqual(@as(u8, 255), result.a); // alpha preserved from base
}

test "stateLayer — focus and pressed use 10% and 12% respectively" {
    const base = Color{ .r = 100, .g = 100, .b = 100 };
    const on = Color{ .r = 200, .g = 200, .b = 200 };
    // focus: 100 * 0.90 + 200 * 0.10 = 90 + 20 = 110
    const focus = Theme.stateLayer(base, on, .focus);
    try std.testing.expectEqual(@as(u8, 110), focus.r);
    // pressed: 100 * 0.88 + 200 * 0.12 = 88 + 24 = 112
    const pressed = Theme.stateLayer(base, on, .pressed);
    try std.testing.expectEqual(@as(u8, 112), pressed.r);
}

test "stateLayer — preserves base alpha (semi-transparent base)" {
    const base = Color{ .r = 50, .g = 50, .b = 50, .a = 128 };
    const on = Color{ .r = 255, .g = 255, .b = 255 };
    const result = Theme.stateLayer(base, on, .hover);
    try std.testing.expectEqual(@as(u8, 128), result.a);
}
