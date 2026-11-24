//! DirectWrite glyph rasterizer (Windows). Produces the same thing stb_truetype
//! does for `FontAtlas.getGlyph` — an 8-bit coverage bitmap plus its offset from
//! the pen baseline, at an exact device-pixel em size — but hinted: DirectWrite
//! runs the font's TrueType instructions (grid fitting), so stems land on whole
//! pixels at UI sizes. This is the rasterizer Chromium/VS Code and most native
//! Windows text use, which is why small text matches their look.
//!
//! Only rasterization moves here. Shaping (HarfBuzz), advances, measuring and
//! layout are untouched, so text widths never depend on which rasterizer drew it.
//! Glyph ids are the same font's ids (same bytes, face index 0), so shaped runs
//! map straight across.
//!
//! Grayscale antialiasing only (no ClearType/LCD): coverage goes through the same
//! atlas and alpha blend as before, and Celeris draws text over transparent and
//! animated layers where subpixel AA is wrong.
//!
//! Driven through hand-laid COM vtables (Zig has no COM bindings), as in
//! platform/win32.zig: only called methods have real signatures, the rest are
//! opaque slots that keep the offsets right. Slot order checked against mingw's
//! dwrite.h / dwrite_3.h. On non-Windows targets `Rasterizer.init` returns null
//! and the atlas stays on stb_truetype.

const std = @import("std");
const builtin = @import("builtin");

pub const available = builtin.os.tag == .windows;

/// How glyph outlines are fitted to the pixel grid. `gdi_classic` hints both
/// axes with the font's instructions (crisp vertical stems, GDI-like shapes);
/// `natural_symmetric` hints vertically only (softer, closer to unhinted).
pub const Mode = enum(u32) {
    gdi_classic = 2, // DWRITE_RENDERING_MODE1_GDI_CLASSIC
    gdi_natural = 3, // DWRITE_RENDERING_MODE1_GDI_NATURAL
    natural_symmetric = 5, // DWRITE_RENDERING_MODE1_NATURAL_SYMMETRIC
};

/// One rasterized glyph's placement: the bitmap's top-left offset from the pen
/// baseline (device px, `top` negative = above), and its size. Empty glyphs
/// (space) have w = h = 0.
pub const Bounds = struct { left: i32, top: i32, w: u32, h: u32 };

const impl = if (available) struct {
    const WINAPI: std.builtin.CallingConvention = .winapi;
    const HRESULT = i32;
    const GUID = extern struct { Data1: u32, Data2: u16, Data3: u16, Data4: [8]u8 };
    const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

    // IID_IDWriteFactory5 {958DB99A-BE2A-4F09-AF7D-65189803D1D3}
    const IID_IDWriteFactory5 = GUID{ .Data1 = 0x958db99a, .Data2 = 0xbe2a, .Data3 = 0x4f09, .Data4 = .{ 0xaf, 0x7d, 0x65, 0x18, 0x98, 0x03, 0xd1, 0xd3 } };

    const DWRITE_FACTORY_TYPE_ISOLATED: u32 = 1;
    const DWRITE_FONT_SIMULATIONS_NONE: u32 = 0;
    const DWRITE_MEASURING_MODE_NATURAL: u32 = 0;
    const DWRITE_GRID_FIT_MODE_ENABLED: u32 = 2;
    const DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE: u32 = 1;
    const DWRITE_TEXTURE_ALIASED_1x1: u32 = 0;

    extern "dwrite" fn DWriteCreateFactory(factory_type: u32, iid: *const GUID, factory: *?*anyopaque) callconv(WINAPI) HRESULT;

    const Slot = *const anyopaque;

    const IDWriteFontFile = extern struct {
        vtbl: *const extern struct {
            QueryInterface: Slot,
            AddRef: Slot,
            Release: *const fn (*IDWriteFontFile) callconv(WINAPI) u32,
            GetReferenceKey: Slot,
            GetLoader: Slot,
            Analyze: *const fn (*IDWriteFontFile, *i32, *u32, *u32, *u32) callconv(WINAPI) HRESULT,
        },
    };

    const IDWriteFontFace = extern struct {
        vtbl: *const extern struct {
            QueryInterface: Slot,
            AddRef: Slot,
            Release: *const fn (*IDWriteFontFace) callconv(WINAPI) u32,
        },
    };

    const IDWriteGlyphRunAnalysis = extern struct {
        vtbl: *const extern struct {
            QueryInterface: Slot,
            AddRef: Slot,
            Release: *const fn (*IDWriteGlyphRunAnalysis) callconv(WINAPI) u32,
            GetAlphaTextureBounds: *const fn (*IDWriteGlyphRunAnalysis, u32, *RECT) callconv(WINAPI) HRESULT,
            CreateAlphaTexture: *const fn (*IDWriteGlyphRunAnalysis, u32, *const RECT, [*]u8, u32) callconv(WINAPI) HRESULT,
        },
    };

    const IDWriteInMemoryFontFileLoader = extern struct {
        vtbl: *const extern struct {
            QueryInterface: Slot,
            AddRef: Slot,
            Release: *const fn (*IDWriteInMemoryFontFileLoader) callconv(WINAPI) u32,
            CreateStreamFromKey: Slot,
            CreateInMemoryFontFileReference: *const fn (*IDWriteInMemoryFontFileLoader, *IDWriteFactory5, [*]const u8, u32, ?*anyopaque, *?*IDWriteFontFile) callconv(WINAPI) HRESULT,
        },
    };

    const DWRITE_GLYPH_OFFSET = extern struct { advanceOffset: f32, ascenderOffset: f32 };
    const DWRITE_GLYPH_RUN = extern struct {
        fontFace: *IDWriteFontFace,
        fontEmSize: f32,
        glyphCount: u32,
        glyphIndices: [*]const u16,
        glyphAdvances: ?[*]const f32,
        glyphOffsets: ?[*]const DWRITE_GLYPH_OFFSET,
        isSideways: i32,
        bidiLevel: u32,
    };

    // IDWriteFactory5 : 4 : 3 : 2 : 1 : IDWriteFactory : IUnknown (48 slots).
    const IDWriteFactory5 = extern struct {
        vtbl: *const extern struct {
            QueryInterface: Slot, // 0
            AddRef: Slot,
            Release: *const fn (*IDWriteFactory5) callconv(WINAPI) u32,
            GetSystemFontCollection: Slot, // 3
            CreateCustomFontCollection: Slot,
            RegisterFontCollectionLoader: Slot,
            UnregisterFontCollectionLoader: Slot,
            CreateFontFileReference: Slot,
            CreateCustomFontFileReference: Slot,
            CreateFontFace: *const fn (*IDWriteFactory5, u32, u32, *const *IDWriteFontFile, u32, u32, *?*IDWriteFontFace) callconv(WINAPI) HRESULT, // 9
            CreateRenderingParams: Slot,
            CreateMonitorRenderingParams: Slot,
            CreateCustomRenderingParams: Slot,
            RegisterFontFileLoader: *const fn (*IDWriteFactory5, *anyopaque) callconv(WINAPI) HRESULT, // 13
            UnregisterFontFileLoader: *const fn (*IDWriteFactory5, *anyopaque) callconv(WINAPI) HRESULT, // 14
            CreateTextFormat: Slot,
            CreateTypography: Slot,
            GetGdiInterop: Slot,
            CreateTextLayout: Slot,
            CreateGdiCompatibleTextLayout: Slot,
            CreateEllipsisTrimmingSign: Slot,
            CreateTextAnalyzer: Slot,
            CreateNumberSubstitution: Slot,
            CreateGlyphRunAnalysis: Slot, // 23
            GetEudcFontCollection: Slot, // 24
            CreateCustomRenderingParams1: Slot,
            GetSystemFontFallback: Slot, // 26
            CreateFontFallbackBuilder: Slot,
            TranslateColorGlyphRun: Slot,
            CreateCustomRenderingParams2: Slot,
            CreateGlyphRunAnalysis2: Slot, // 30
            CreateGlyphRunAnalysis3: *const fn (*IDWriteFactory5, *const DWRITE_GLYPH_RUN, ?*const anyopaque, u32, u32, u32, u32, f32, f32, *?*IDWriteGlyphRunAnalysis) callconv(WINAPI) HRESULT, // 31
            CreateCustomRenderingParams3: Slot,
            CreateFontFaceReference_: Slot,
            CreateFontFaceReference: Slot,
            GetSystemFontSet: Slot,
            CreateFontSetBuilder: Slot,
            CreateFontCollectionFromFontSet: Slot,
            GetSystemFontCollection3: Slot,
            GetFontDownloadQueue: Slot, // 39
            TranslateColorGlyphRun4: Slot, // 40
            ComputeGlyphOrigins_: Slot,
            ComputeGlyphOrigins: Slot,
            CreateFontSetBuilder5: Slot, // 43
            CreateInMemoryFontFileLoader: *const fn (*IDWriteFactory5, *?*IDWriteInMemoryFontFileLoader) callconv(WINAPI) HRESULT, // 44
        },
    };

    pub const FaceT = IDWriteFontFace;

    pub const RasterizerT = struct {
        factory: *IDWriteFactory5,
        loader: *IDWriteInMemoryFontFileLoader,
        mode: Mode,

        pub fn init(mode: Mode) ?RasterizerT {
            var f: ?*anyopaque = null;
            if (DWriteCreateFactory(DWRITE_FACTORY_TYPE_ISOLATED, &IID_IDWriteFactory5, &f) < 0) return null;
            const factory: *IDWriteFactory5 = @ptrCast(@alignCast(f orelse return null));
            var l: ?*IDWriteInMemoryFontFileLoader = null;
            if (factory.vtbl.CreateInMemoryFontFileLoader(factory, &l) < 0 or l == null) {
                _ = factory.vtbl.Release(factory);
                return null;
            }
            if (factory.vtbl.RegisterFontFileLoader(factory, l.?) < 0) {
                _ = l.?.vtbl.Release(l.?);
                _ = factory.vtbl.Release(factory);
                return null;
            }
            return .{ .factory = factory, .loader = l.?, .mode = mode };
        }

        pub fn deinit(self: *RasterizerT) void {
            _ = self.factory.vtbl.UnregisterFontFileLoader(self.factory, self.loader);
            _ = self.loader.vtbl.Release(self.loader);
            _ = self.factory.vtbl.Release(self.factory);
        }

        /// A DirectWrite face for these TTF/OTF bytes (face index 0, like stb).
        /// The loader copies the bytes. Null if DirectWrite rejects the font —
        /// the caller then keeps rasterizing that font with stb.
        pub fn createFace(self: *RasterizerT, ttf: []const u8) ?*FaceT {
            var file: ?*IDWriteFontFile = null;
            if (self.loader.vtbl.CreateInMemoryFontFileReference(self.loader, self.factory, ttf.ptr, @intCast(ttf.len), null, &file) < 0) return null;
            const ff = file orelse return null;
            defer _ = ff.vtbl.Release(ff);
            var supported: i32 = 0;
            var file_type: u32 = 0;
            var face_type: u32 = 0;
            var n_faces: u32 = 0;
            if (ff.vtbl.Analyze(ff, &supported, &file_type, &face_type, &n_faces) < 0 or supported == 0) return null;
            var face: ?*IDWriteFontFace = null;
            const files = [1]*IDWriteFontFile{ff};
            if (self.factory.vtbl.CreateFontFace(self.factory, face_type, 1, &files[0], 0, DWRITE_FONT_SIMULATIONS_NONE, &face) < 0) return null;
            return face;
        }

        pub fn releaseFace(face: *FaceT) void {
            _ = face.vtbl.Release(face);
        }

        fn analysis(self: *RasterizerT, face: *FaceT, glyph_id: u16, em_px: f32) ?*IDWriteGlyphRunAnalysis {
            const ids = [1]u16{glyph_id};
            const adv = [1]f32{0};
            const run = DWRITE_GLYPH_RUN{
                .fontFace = face,
                .fontEmSize = em_px,
                .glyphCount = 1,
                .glyphIndices = &ids,
                .glyphAdvances = &adv,
                .glyphOffsets = null,
                .isSideways = 0,
                .bidiLevel = 0,
            };
            var a: ?*IDWriteGlyphRunAnalysis = null;
            if (self.factory.vtbl.CreateGlyphRunAnalysis3(self.factory, &run, null, @backingInt(self.mode), DWRITE_MEASURING_MODE_NATURAL, DWRITE_GRID_FIT_MODE_ENABLED, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, 0, 0, &a) < 0) return null;
            return a;
        }

        /// Bounds of `glyph_id` at `em_px` device pixels, origin on the pen
        /// baseline. Null on failure (caller falls back to stb).
        pub fn bounds(self: *RasterizerT, face: *FaceT, glyph_id: u32, em_px: f32) ?Bounds {
            if (glyph_id > std.math.maxInt(u16)) return null;
            const a = self.analysis(face, @intCast(glyph_id), em_px) orelse return null;
            defer _ = a.vtbl.Release(a);
            var r: RECT = undefined;
            if (a.vtbl.GetAlphaTextureBounds(a, DWRITE_TEXTURE_ALIASED_1x1, &r) < 0) return null;
            if (r.right <= r.left or r.bottom <= r.top) return .{ .left = 0, .top = 0, .w = 0, .h = 0 };
            return .{ .left = r.left, .top = r.top, .w = @intCast(r.right - r.left), .h = @intCast(r.bottom - r.top) };
        }

        /// Rasterizes into `dst` (row stride `stride` bytes), `b` from `bounds`
        /// for the same glyph and size. `scratch` must hold `b.w * b.h` bytes.
        pub fn render(self: *RasterizerT, face: *FaceT, glyph_id: u32, em_px: f32, b: Bounds, scratch: []u8, dst: [*]u8, stride: usize) bool {
            if (b.w == 0 or b.h == 0) return true;
            const a = self.analysis(face, @intCast(glyph_id), em_px) orelse return false;
            defer _ = a.vtbl.Release(a);
            const r = RECT{ .left = b.left, .top = b.top, .right = b.left + @as(i32, @intCast(b.w)), .bottom = b.top + @as(i32, @intCast(b.h)) };
            const n = b.w * b.h;
            if (scratch.len < n) return false;
            if (a.vtbl.CreateAlphaTexture(a, DWRITE_TEXTURE_ALIASED_1x1, &r, scratch.ptr, n) < 0) return false;
            for (0..b.h) |y| @memcpy(dst[y * stride ..][0..b.w], scratch[y * b.w ..][0..b.w]);
            return true;
        }
    };
} else struct {
    pub const FaceT = opaque {};
    pub const RasterizerT = struct {
        mode: Mode,
        pub fn init(mode: Mode) ?RasterizerT {
            _ = mode;
            return null;
        }
        pub fn deinit(self: *RasterizerT) void {
            _ = self;
        }
        pub fn createFace(self: *RasterizerT, ttf: []const u8) ?*FaceT {
            _ = self;
            _ = ttf;
            return null;
        }
        pub fn releaseFace(face: *FaceT) void {
            _ = face;
        }
        pub fn bounds(self: *RasterizerT, face: *FaceT, glyph_id: u32, em_px: f32) ?Bounds {
            _ = .{ self, face, glyph_id, em_px };
            return null;
        }
        pub fn render(self: *RasterizerT, face: *FaceT, glyph_id: u32, em_px: f32, b: Bounds, scratch: []u8, dst: [*]u8, stride: usize) bool {
            _ = .{ self, face, glyph_id, em_px, b, scratch, dst, stride };
            return false;
        }
    };
};

pub const Face = impl.FaceT;
pub const Rasterizer = impl.RasterizerT;
