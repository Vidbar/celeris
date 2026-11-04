//! OS-native font discovery — finds the system's preferred UI font and an
//! ordered fallback chain so the FontAtlas stack covers CJK/symbols without
//! hardcoded paths.
//!
//! Linux: queries **fontconfig** via `dlopen("libfontconfig.so.1")` (no build-time
//! link, no header). `FcFontSort` returns fonts ordered by how well they match a
//! "sans-serif" pattern, trimmed to those that add coverage — exactly a primary +
//! fallback chain. Degrades gracefully: if fontconfig is absent or returns nothing,
//! `discover` is null and the caller uses its hardcoded candidate list.
//!
//! Windows: returns null. The hardcoded candidate list already resolves
//! `C:/Windows/Fonts/segoeui.ttf` + CJK reliably (fixed paths), so DirectWrite COM
//! interop would add complexity for no practical gain. Deferred by design.

const std = @import("std");
const builtin = @import("builtin");

/// Caps the discovered chain: a primary plus a handful of fallbacks is enough for
/// Latin + CJK + symbol coverage; more just bloats the atlas warm-up.
const MAX_FONTS: usize = 8;

/// Returns an owned list of absolute font-file paths (primary first), or null to
/// signal "use your own fallback list". The caller owns and frees each path and
/// the outer slice.
pub fn discover(allocator: std.mem.Allocator) ?[][]u8 {
    return switch (builtin.os.tag) {
        .linux => discoverFontconfig(allocator),
        else => null,
    };
}

// ── fontconfig (Linux) via dlopen ──────────────────────────────────────────────

const FcPattern = anyopaque;
const FcConfig = anyopaque;
const FcFontSet = extern struct {
    nfont: c_int,
    sfont: c_int,
    fonts: [*]?*FcPattern,
};

// FcMatchPattern = 0, FcResultMatch = 0, FcTrue = 1.
const FcInitFn = *const fn () callconv(.c) ?*FcConfig;
const FcPatternCreateFn = *const fn () callconv(.c) ?*FcPattern;
const FcPatternAddStringFn = *const fn (?*FcPattern, [*:0]const u8, [*:0]const u8) callconv(.c) c_int;
const FcConfigSubstituteFn = *const fn (?*FcConfig, ?*FcPattern, c_int) callconv(.c) c_int;
const FcDefaultSubstituteFn = *const fn (?*FcPattern) callconv(.c) void;
const FcFontSortFn = *const fn (?*FcConfig, ?*FcPattern, c_int, ?*anyopaque, *c_int) callconv(.c) ?*FcFontSet;
const FcPatternGetStringFn = *const fn (?*FcPattern, [*:0]const u8, c_int, *[*:0]u8) callconv(.c) c_int;
const FcFontSetDestroyFn = *const fn (?*FcFontSet) callconv(.c) void;
const FcPatternDestroyFn = *const fn (?*FcPattern) callconv(.c) void;

fn discoverFontconfig(allocator: std.mem.Allocator) ?[][]u8 {
    var lib = std.DynLib.open("libfontconfig.so.1") catch return null;
    defer lib.close();

    const FcInit = lib.lookup(FcInitFn, "FcInitLoadConfigAndFonts") orelse return null;
    const FcPatternCreate = lib.lookup(FcPatternCreateFn, "FcPatternCreate") orelse return null;
    const FcPatternAddString = lib.lookup(FcPatternAddStringFn, "FcPatternAddString") orelse return null;
    const FcConfigSubstitute = lib.lookup(FcConfigSubstituteFn, "FcConfigSubstitute") orelse return null;
    const FcDefaultSubstitute = lib.lookup(FcDefaultSubstituteFn, "FcDefaultSubstitute") orelse return null;
    const FcFontSort = lib.lookup(FcFontSortFn, "FcFontSort") orelse return null;
    const FcPatternGetString = lib.lookup(FcPatternGetStringFn, "FcPatternGetString") orelse return null;
    const FcFontSetDestroy = lib.lookup(FcFontSetDestroyFn, "FcFontSetDestroy") orelse return null;
    const FcPatternDestroy = lib.lookup(FcPatternDestroyFn, "FcPatternDestroy") orelse return null;

    const config = FcInit() orelse return null;
    // The config is process-global state; intentionally not destroyed (one-time).

    const pat = FcPatternCreate() orelse return null;
    defer FcPatternDestroy(pat);
    _ = FcPatternAddString(pat, "family", "sans-serif");
    _ = FcConfigSubstitute(config, pat, 0); // FcMatchPattern
    FcDefaultSubstitute(pat);

    var result: c_int = 0;
    const set = FcFontSort(config, pat, 1, null, &result) orelse return null; // trim = FcTrue
    defer FcFontSetDestroy(set);

    var paths = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit();
    }

    const n: usize = @intCast(@max(0, set.nfont));
    var i: usize = 0;
    while (i < n and paths.items.len < MAX_FONTS) : (i += 1) {
        const fpat = set.fonts[i] orelse continue;
        var file: [*:0]u8 = undefined;
        if (FcPatternGetString(fpat, "file", 0, &file) != 0) continue; // not FcResultMatch
        const slice = std.mem.span(file);
        if (!hasFontExt(slice)) continue; // stb/HB read TTF/OTF/TTC only
        const dup = allocator.dupe(u8, slice) catch continue;
        paths.append(dup) catch {
            allocator.free(dup);
            continue;
        };
    }

    if (paths.items.len == 0) return null;
    return paths.toOwnedSlice() catch null;
}

fn hasFontExt(path: []const u8) bool {
    const exts = [_][]const u8{ ".ttf", ".otf", ".ttc", ".TTF", ".OTF", ".TTC" };
    for (exts) |e| {
        if (std.mem.endsWith(u8, path, e)) return true;
    }
    return false;
}
