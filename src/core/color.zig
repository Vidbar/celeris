//! Color science utilities: sRGB/XYZ/L*, CAM16 and HCT.
//!
//! Ported from Google's material-color-utilities (typescript/utils/color_utils.ts,
//! typescript/hct/{viewing_conditions,cam16,hct}.ts).
//! Copyright 2021 Google LLC. Licensed under the Apache License, Version 2.0.
//! All math stays in f64 end-to-end (the upstream reference uses doubles; f32
//! drifts enough to fail the reference vectors). Colors cross this API as ARGB
//! packed u32 (0xAARRGGBB).

const std = @import("std");
const hct_solver = @import("hct_solver.zig");

// ── math utils ──────────────────────────────────────────────────────────────

pub fn signum(x: f64) f64 {
    if (x < 0) return -1.0;
    if (x > 0) return 1.0;
    return 0.0;
}

pub fn lerp(start: f64, stop: f64, amount: f64) f64 {
    return (1.0 - amount) * start + amount * stop;
}

/// Sanitizes a degree measure to the interval [0, 360).
pub fn sanitizeDegrees(degrees: f64) f64 {
    var d = @mod(degrees, 360.0);
    if (d < 0) d += 360.0;
    return d;
}

/// Matrix-vector product `row · matrix` (upstream matrixMultiply).
pub fn matrixMultiply(row: [3]f64, matrix: [3][3]f64) [3]f64 {
    return .{
        row[0] * matrix[0][0] + row[1] * matrix[0][1] + row[2] * matrix[0][2],
        row[0] * matrix[1][0] + row[1] * matrix[1][1] + row[2] * matrix[1][2],
        row[0] * matrix[2][0] + row[1] * matrix[2][1] + row[2] * matrix[2][2],
    };
}

// ── color utils ─────────────────────────────────────────────────────────────

pub const SRGB_TO_XYZ = [3][3]f64{
    .{ 0.41233895, 0.35762064, 0.18051042 },
    .{ 0.2126, 0.7152, 0.0722 },
    .{ 0.01932141, 0.11916382, 0.95034478 },
};

pub const XYZ_TO_SRGB = [3][3]f64{
    .{ 3.2413774792388685, -1.5376652402851851, -0.49885366846268053 },
    .{ -0.9691452513005321, 1.8758853451067872, 0.04156585616912061 },
    .{ 0.05562093689691305, -0.20395524564742123, 1.0571799111220335 },
};

pub const WHITE_POINT_D65 = [3]f64{ 95.047, 100.0, 108.883 };

pub fn argbFromRgb(r: u8, g: u8, b: u8) u32 {
    return 0xff000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

pub fn redFromArgb(argb: u32) u8 {
    return @truncate(argb >> 16);
}

pub fn greenFromArgb(argb: u32) u8 {
    return @truncate(argb >> 8);
}

pub fn blueFromArgb(argb: u32) u8 {
    return @truncate(argb);
}

pub fn argbFromLinrgb(linrgb: [3]f64) u32 {
    return argbFromRgb(delinearized(linrgb[0]), delinearized(linrgb[1]), delinearized(linrgb[2]));
}

/// Linearizes an sRGB component (0..255) into linear-RGB space (0.0..100.0).
pub fn linearized(rgb_component: u8) f64 {
    const normalized = @as(f64, @floatFromInt(rgb_component)) / 255.0;
    if (normalized <= 0.040449936) {
        return normalized / 12.92 * 100.0;
    }
    return std.math.pow(f64, (normalized + 0.055) / 1.055, 2.4) * 100.0;
}

/// Delinearizes a linear-RGB component (0.0..100.0) into sRGB (0..255).
pub fn delinearized(rgb_component: f64) u8 {
    const normalized = rgb_component / 100.0;
    const d = if (normalized <= 0.0031308)
        normalized * 12.92
    else
        1.055 * std.math.pow(f64, normalized, 1.0 / 2.4) - 0.055;
    // Clamp in float domain: @intFromFloat on NaN/inf/out-of-range is illegal behavior.
    const scaled = @round(d * 255.0);
    if (std.math.isNan(scaled)) return 0;
    return @intFromFloat(std.math.clamp(scaled, 0.0, 255.0));
}

pub fn argbFromXyz(x: f64, y: f64, z: f64) u32 {
    const m = XYZ_TO_SRGB;
    const linear_r = m[0][0] * x + m[0][1] * y + m[0][2] * z;
    const linear_g = m[1][0] * x + m[1][1] * y + m[1][2] * z;
    const linear_b = m[2][0] * x + m[2][1] * y + m[2][2] * z;
    return argbFromRgb(delinearized(linear_r), delinearized(linear_g), delinearized(linear_b));
}

pub fn xyzFromArgb(argb: u32) [3]f64 {
    const r = linearized(redFromArgb(argb));
    const g = linearized(greenFromArgb(argb));
    const b = linearized(blueFromArgb(argb));
    return matrixMultiply(.{ r, g, b }, SRGB_TO_XYZ);
}

/// Grayscale ARGB whose lightness matches L*.
pub fn argbFromLstar(lstar: f64) u32 {
    const component = delinearized(yFromLstar(lstar));
    return argbFromRgb(component, component, component);
}

/// L* (from L*a*b*) of an ARGB color.
pub fn lstarFromArgb(argb: u32) f64 {
    const y = xyzFromArgb(argb)[1];
    return 116.0 * labF(y / 100.0) - 16.0;
}

/// Converts L* (perceptual luminance) to Y in XYZ (relative luminance).
pub fn yFromLstar(lstar: f64) f64 {
    return 100.0 * labInvf((lstar + 16.0) / 116.0);
}

/// Converts Y in XYZ to L*.
pub fn lstarFromY(y: f64) f64 {
    return labF(y / 100.0) * 116.0 - 16.0;
}

fn labF(t: f64) f64 {
    const e = 216.0 / 24389.0;
    const kappa = 24389.0 / 27.0;
    if (t > e) return std.math.cbrt(t);
    return (kappa * t + 16.0) / 116.0;
}

fn labInvf(ft: f64) f64 {
    const e = 216.0 / 24389.0;
    const kappa = 24389.0 / 27.0;
    const ft3 = ft * ft * ft;
    if (ft3 > e) return ft3;
    return (116.0 * ft - 16.0) / kappa;
}

/// WCAG contrast ratio between two ARGB colors (1.0..21.0).
pub fn contrastRatio(a: u32, b: u32) f64 {
    const ya = xyzFromArgb(a)[1] / 100.0;
    const yb = xyzFromArgb(b)[1] / 100.0;
    const lighter = @max(ya, yb);
    const darker = @min(ya, yb);
    return (lighter + 0.05) / (darker + 0.05);
}

// ── viewing conditions ──────────────────────────────────────────────────────

/// Environment parameters for CAM16; caches intermediates that depend only on
/// the viewing environment. `default()` matches sRGB-like conditions.
pub const ViewingConditions = struct {
    n: f64,
    aw: f64,
    nbb: f64,
    ncb: f64,
    c: f64,
    nc: f64,
    rgb_d: [3]f64,
    fl: f64,
    fl_root: f64,
    z: f64,

    pub fn make(
        white_point: [3]f64,
        adapting_luminance: f64,
        background_lstar: f64,
        surround: f64,
        discounting_illuminant: bool,
    ) ViewingConditions {
        const xyz = white_point;
        const r_w = xyz[0] * 0.401288 + xyz[1] * 0.650173 + xyz[2] * -0.051461;
        const g_w = xyz[0] * -0.250268 + xyz[1] * 1.204414 + xyz[2] * 0.045854;
        const b_w = xyz[0] * -0.002079 + xyz[1] * 0.048952 + xyz[2] * 0.953127;
        const f = 0.8 + surround / 10.0;
        const c = if (f >= 0.9)
            lerp(0.59, 0.69, (f - 0.9) * 10.0)
        else
            lerp(0.525, 0.59, (f - 0.8) * 10.0);
        var d = if (discounting_illuminant)
            1.0
        else
            f * (1.0 - (1.0 / 3.6) * @exp((-adapting_luminance - 42.0) / 92.0));
        d = std.math.clamp(d, 0.0, 1.0);
        const nc = f;
        const rgb_d = [3]f64{
            d * (100.0 / r_w) + 1.0 - d,
            d * (100.0 / g_w) + 1.0 - d,
            d * (100.0 / b_w) + 1.0 - d,
        };
        const k = 1.0 / (5.0 * adapting_luminance + 1.0);
        const k4 = k * k * k * k;
        const k4f = 1.0 - k4;
        const fl = k4 * adapting_luminance +
            0.1 * k4f * k4f * std.math.cbrt(5.0 * adapting_luminance);
        const n = yFromLstar(background_lstar) / white_point[1];
        const z = 1.48 + @sqrt(n);
        const nbb = 0.725 / std.math.pow(f64, n, 0.2);
        const ncb = nbb;
        const rgb_a_factors = [3]f64{
            std.math.pow(f64, fl * rgb_d[0] * r_w / 100.0, 0.42),
            std.math.pow(f64, fl * rgb_d[1] * g_w / 100.0, 0.42),
            std.math.pow(f64, fl * rgb_d[2] * b_w / 100.0, 0.42),
        };
        const rgb_a = [3]f64{
            400.0 * rgb_a_factors[0] / (rgb_a_factors[0] + 27.13),
            400.0 * rgb_a_factors[1] / (rgb_a_factors[1] + 27.13),
            400.0 * rgb_a_factors[2] / (rgb_a_factors[2] + 27.13),
        };
        const aw = (2.0 * rgb_a[0] + rgb_a[1] + 0.05 * rgb_a[2]) * nbb;
        return .{
            .n = n,
            .aw = aw,
            .nbb = nbb,
            .ncb = ncb,
            .c = c,
            .nc = nc,
            .rgb_d = rgb_d,
            .fl = fl,
            .fl_root = std.math.pow(f64, fl, 0.25),
            .z = z,
        };
    }

    /// sRGB-like viewing conditions (D65, ~200 lux, background L* 50),
    /// precomputed at comptime — `make` costs a cbrt, an exp and ~6 pows,
    /// and these parameters never change.
    pub const DEFAULT: ViewingConditions = blk: {
        @setEvalBranchQuota(100_000);
        break :blk make(
            WHITE_POINT_D65,
            200.0 / std.math.pi * yFromLstar(50.0) / 100.0,
            50.0,
            2.0,
            false,
        );
    };

    /// sRGB-like viewing conditions (D65, ~200 lux, background L* 50).
    pub fn default() ViewingConditions {
        return DEFAULT;
    }
};

// ── CAM16 ───────────────────────────────────────────────────────────────────

/// CAM16 color appearance model coordinates, plus CAM16-UCS (jstar/astar/bstar).
pub const Cam16 = struct {
    hue: f64,
    chroma: f64,
    j: f64,
    q: f64,
    m: f64,
    s: f64,
    jstar: f64,
    astar: f64,
    bstar: f64,

    pub fn fromInt(argb: u32) Cam16 {
        return fromIntInViewingConditions(argb, ViewingConditions.default());
    }

    pub fn fromIntInViewingConditions(argb: u32, vc: ViewingConditions) Cam16 {
        const red_l = linearized(redFromArgb(argb));
        const green_l = linearized(greenFromArgb(argb));
        const blue_l = linearized(blueFromArgb(argb));
        const xyz = matrixMultiply(.{ red_l, green_l, blue_l }, SRGB_TO_XYZ);
        const x = xyz[0];
        const y = xyz[1];
        const z = xyz[2];

        const r_c = 0.401288 * x + 0.650173 * y - 0.051461 * z;
        const g_c = -0.250268 * x + 1.204414 * y + 0.045854 * z;
        const b_c = -0.002079 * x + 0.048952 * y + 0.953127 * z;

        const r_d = vc.rgb_d[0] * r_c;
        const g_d = vc.rgb_d[1] * g_c;
        const b_d = vc.rgb_d[2] * b_c;

        const r_af = std.math.pow(f64, vc.fl * @abs(r_d) / 100.0, 0.42);
        const g_af = std.math.pow(f64, vc.fl * @abs(g_d) / 100.0, 0.42);
        const b_af = std.math.pow(f64, vc.fl * @abs(b_d) / 100.0, 0.42);

        const r_a = signum(r_d) * 400.0 * r_af / (r_af + 27.13);
        const g_a = signum(g_d) * 400.0 * g_af / (g_af + 27.13);
        const b_a = signum(b_d) * 400.0 * b_af / (b_af + 27.13);

        const a = (11.0 * r_a + -12.0 * g_a + b_a) / 11.0;
        const b = (r_a + g_a - 2.0 * b_a) / 9.0;
        const u = (20.0 * r_a + 20.0 * g_a + 21.0 * b_a) / 20.0;
        const p2 = (40.0 * r_a + 20.0 * g_a + b_a) / 20.0;
        const atan_degrees = std.math.atan2(b, a) * 180.0 / std.math.pi;
        const hue = sanitizeDegrees(atan_degrees);
        const hue_radians = hue * std.math.pi / 180.0;

        const ac = p2 * vc.nbb;
        const j = 100.0 * std.math.pow(f64, ac / vc.aw, vc.c * vc.z);
        const q = (4.0 / vc.c) * @sqrt(j / 100.0) * (vc.aw + 4.0) * vc.fl_root;
        const hue_prime = if (hue < 20.14) hue + 360.0 else hue;
        const e_hue = 0.25 * (@cos(hue_prime * std.math.pi / 180.0 + 2.0) + 3.8);
        const p1 = 50000.0 / 13.0 * e_hue * vc.nc * vc.ncb;
        const t = p1 * @sqrt(a * a + b * b) / (u + 0.305);
        const alpha = std.math.pow(f64, t, 0.9) *
            std.math.pow(f64, 1.64 - std.math.pow(f64, 0.29, vc.n), 0.73);
        const c = alpha * @sqrt(j / 100.0);
        const m = c * vc.fl_root;
        const s = 50.0 * @sqrt(alpha * vc.c / (vc.aw + 4.0));
        const jstar = (1.0 + 100.0 * 0.007) * j / (1.0 + 0.007 * j);
        const mstar = (1.0 / 0.0228) * @log(1.0 + 0.0228 * m);
        return .{
            .hue = hue,
            .chroma = c,
            .j = j,
            .q = q,
            .m = m,
            .s = s,
            .jstar = jstar,
            .astar = mstar * @cos(hue_radians),
            .bstar = mstar * @sin(hue_radians),
        };
    }

    pub fn fromJch(j: f64, c: f64, h: f64) Cam16 {
        return fromJchInViewingConditions(j, c, h, ViewingConditions.default());
    }

    pub fn fromJchInViewingConditions(j: f64, c: f64, h: f64, vc: ViewingConditions) Cam16 {
        const q = (4.0 / vc.c) * @sqrt(j / 100.0) * (vc.aw + 4.0) * vc.fl_root;
        const m = c * vc.fl_root;
        const alpha = if (c == 0.0 or j == 0.0) 0.0 else c / @sqrt(j / 100.0);
        const s = 50.0 * @sqrt(alpha * vc.c / (vc.aw + 4.0));
        const hue_radians = h * std.math.pi / 180.0;
        const jstar = (1.0 + 100.0 * 0.007) * j / (1.0 + 0.007 * j);
        const mstar = (1.0 / 0.0228) * @log(1.0 + 0.0228 * m);
        return .{
            .hue = h,
            .chroma = c,
            .j = j,
            .q = q,
            .m = m,
            .s = s,
            .jstar = jstar,
            .astar = mstar * @cos(hue_radians),
            .bstar = mstar * @sin(hue_radians),
        };
    }

    pub fn toInt(self: Cam16) u32 {
        return self.viewed(ViewingConditions.default());
    }

    pub fn viewed(self: Cam16, vc: ViewingConditions) u32 {
        const alpha = if (self.chroma == 0.0 or self.j == 0.0)
            0.0
        else
            self.chroma / @sqrt(self.j / 100.0);

        const t = std.math.pow(
            f64,
            alpha / std.math.pow(f64, 1.64 - std.math.pow(f64, 0.29, vc.n), 0.73),
            1.0 / 0.9,
        );
        const h_rad = self.hue * std.math.pi / 180.0;

        const e_hue = 0.25 * (@cos(h_rad + 2.0) + 3.8);
        const ac = vc.aw * std.math.pow(f64, self.j / 100.0, 1.0 / vc.c / vc.z);
        const p1 = e_hue * (50000.0 / 13.0) * vc.nc * vc.ncb;
        const p2 = ac / vc.nbb;

        const h_sin = @sin(h_rad);
        const h_cos = @cos(h_rad);

        const gamma = 23.0 * (p2 + 0.305) * t /
            (23.0 * p1 + 11.0 * t * h_cos + 108.0 * t * h_sin);
        const a = gamma * h_cos;
        const b = gamma * h_sin;
        const r_a = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0;
        const g_a = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0;
        const b_a = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0;

        const r_c_base = @max(0.0, 27.13 * @abs(r_a) / (400.0 - @abs(r_a)));
        const r_c = signum(r_a) * (100.0 / vc.fl) * std.math.pow(f64, r_c_base, 1.0 / 0.42);
        const g_c_base = @max(0.0, 27.13 * @abs(g_a) / (400.0 - @abs(g_a)));
        const g_c = signum(g_a) * (100.0 / vc.fl) * std.math.pow(f64, g_c_base, 1.0 / 0.42);
        const b_c_base = @max(0.0, 27.13 * @abs(b_a) / (400.0 - @abs(b_a)));
        const b_c = signum(b_a) * (100.0 / vc.fl) * std.math.pow(f64, b_c_base, 1.0 / 0.42);
        const r_f = r_c / vc.rgb_d[0];
        const g_f = g_c / vc.rgb_d[1];
        const b_f = b_c / vc.rgb_d[2];

        const x = 1.86206786 * r_f - 1.01125463 * g_f + 0.14918677 * b_f;
        const y = 0.38752654 * r_f + 0.62144744 * g_f - 0.00897398 * b_f;
        const z = -0.01584150 * r_f - 0.03412294 * g_f + 1.04996444 * b_f;

        return argbFromXyz(x, y, z);
    }
};

// ── HCT ─────────────────────────────────────────────────────────────────────

/// HCT: hue (CAM16), chroma (CAM16), tone (L*). The color system Material 3
/// palettes are built on. `from` clamps chroma to the sRGB gamut boundary.
pub const Hct = struct {
    hue: f64,
    chroma: f64,
    tone: f64,
    argb: u32,

    pub fn from(hue: f64, chroma: f64, tone: f64) Hct {
        return fromInt(hct_solver.solveToInt(hue, chroma, tone));
    }

    pub fn fromInt(argb: u32) Hct {
        const cam = Cam16.fromInt(argb);
        return .{
            .hue = cam.hue,
            .chroma = cam.chroma,
            .tone = lstarFromArgb(argb),
            .argb = argb,
        };
    }

    pub fn toInt(self: Hct) u32 {
        return self.argb;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────
// Reference values from material-color-utilities' own test suites
// (typescript/hct/hct_test.ts).

const testing = std.testing;

test "L* round-trips: white, black, mid gray" {
    try testing.expectApproxEqAbs(@as(f64, 100.0), lstarFromArgb(0xffffffff), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), lstarFromArgb(0xff000000), 1e-6);
    const gray50 = argbFromLstar(50.0);
    try testing.expectApproxEqAbs(@as(f64, 50.0), lstarFromArgb(gray50), 0.3);
}

test "delinearized: non-finite and out-of-range inputs clamp instead of UB" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try testing.expectEqual(@as(u8, 0), delinearized(nan));
    try testing.expectEqual(@as(u8, 255), delinearized(inf));
    try testing.expectEqual(@as(u8, 0), delinearized(-inf));
    try testing.expectEqual(@as(u8, 255), delinearized(1e300));
    try testing.expectEqual(@as(u8, 0), delinearized(-1e300));
}

test "Cam16.fromJch: j = 0 stays finite" {
    const cam = Cam16.fromJch(0.0, 10.0, 40.0);
    try testing.expect(std.math.isFinite(cam.s));
    try testing.expectEqual(@as(u32, 0xff000000), cam.toInt());
}

test "ViewingConditions.default matches reference intermediates" {
    const vc = ViewingConditions.default();
    try testing.expectApproxEqAbs(@as(f64, 0.184), vc.n, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 29.981), vc.aw, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 1.017), vc.nbb, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.69), vc.c, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 1.0), vc.nc, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 1.021), vc.rgb_d[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.986), vc.rgb_d[1], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.934), vc.rgb_d[2], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.388), vc.fl, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.789), vc.fl_root, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 1.909), vc.z, 1e-3);
}

test "Cam16 of pure red/green/blue matches reference" {
    const red = Cam16.fromInt(0xffff0000);
    try testing.expectApproxEqAbs(@as(f64, 27.408), red.hue, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 113.358), red.chroma, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 46.445), red.j, 1e-3);

    const green = Cam16.fromInt(0xff00ff00);
    try testing.expectApproxEqAbs(@as(f64, 142.140), green.hue, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 108.410), green.chroma, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 79.332), green.j, 1e-3);

    const blue = Cam16.fromInt(0xff0000ff);
    try testing.expectApproxEqAbs(@as(f64, 282.788), blue.hue, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 87.231), blue.chroma, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 25.466), blue.j, 1e-3);
}

test "Cam16 round-trip: fromInt -> toInt is identity for primaries" {
    inline for (.{ 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff, 0xff000000 }) |argb| {
        try testing.expectEqual(@as(u32, argb), Cam16.fromInt(argb).toInt());
    }
}

test "Hct.fromInt matches reference (green, blue)" {
    const green = Hct.fromInt(0xff00ff00);
    try testing.expectApproxEqAbs(@as(f64, 142.139), green.hue, 1e-2);
    try testing.expectApproxEqAbs(@as(f64, 108.410), green.chroma, 1e-2);
    try testing.expectApproxEqAbs(@as(f64, 87.737), green.tone, 1e-2);

    const blue = Hct.fromInt(0xff0000ff);
    try testing.expectApproxEqAbs(@as(f64, 282.788), blue.hue, 1e-2);
    try testing.expectApproxEqAbs(@as(f64, 87.230), blue.chroma, 1e-2);
    try testing.expectApproxEqAbs(@as(f64, 32.302), blue.tone, 1e-2);
}

test "Hct.from: tone and hue honored, chroma clamped to gamut" {
    var hue: f64 = 15.0;
    while (hue < 360.0) : (hue += 30.0) {
        inline for (.{ 4.0, 16.0, 48.0, 84.0 }) |chroma| {
            inline for (.{ 20.0, 50.0, 80.0 }) |tone| {
                const hct = Hct.from(hue, chroma, tone);
                if (hct.chroma > 5.0) {
                    // Hue is preserved when the color is not near-gray.
                    var dh = @abs(hct.hue - hue);
                    if (dh > 180.0) dh = 360.0 - dh;
                    try testing.expect(dh <= 4.0);
                }
                try testing.expect(hct.chroma >= 0.0);
                try testing.expect(hct.chroma <= chroma + 2.5);
                try testing.expect(@abs(hct.tone - tone) <= 0.5);
            }
        }
    }
}

test "Hct round-trip: argb -> hct -> argb is identity (sampled)" {
    var r: u32 = 0;
    while (r <= 255) : (r += 51) {
        var g: u32 = 0;
        while (g <= 255) : (g += 51) {
            var b: u32 = 0;
            while (b <= 255) : (b += 51) {
                const argb = argbFromRgb(@intCast(r), @intCast(g), @intCast(b));
                const hct = Hct.fromInt(argb);
                try testing.expectEqual(argb, Hct.from(hct.hue, hct.chroma, hct.tone).toInt());
            }
        }
    }
}
