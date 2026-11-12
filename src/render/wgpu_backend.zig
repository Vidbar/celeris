const std = @import("std");
const log = @import("../core/log.zig");
const builtin = @import("builtin");

extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.c) c_int;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.c) c_int;
var g_qpc_freq: i64 = 0;

/// Chooses the surface present mode. Default is Fifo (vsync): its blocking
/// `GetCurrentTexture` is the loop's frame pacing — without it, any source of
/// sustained dirty makes the on-demand loop spin at thousands of FPS (100% of a
/// core, saturated GPU, input jank). Mailbox was preferred historically because
/// the blocking acquire stalled input, but the root cause of those multi-ms
/// stalls was the software fallback adapter (forceFallbackAdapter, fixed in
/// 4a8919b); on a real GPU the acquire block is just vsync. Mailbox/Immediate
/// remain available for A/B via CELERIS_PRESENT.
var g_present_logged: bool = false;
fn pickPresentMode(caps: wgpu.WGPUSurfaceCapabilities) wgpu.WGPUPresentMode {
    var has_mailbox = false;
    var has_immediate = false;
    var i: usize = 0;
    while (i < caps.presentModeCount) : (i += 1) {
        if (caps.presentModes[i] == wgpu.WGPUPresentMode_Mailbox) has_mailbox = true;
        if (caps.presentModes[i] == wgpu.WGPUPresentMode_Immediate) has_immediate = true;
    }
    // Optional override for A/B testing the acquire stall: CELERIS_PRESENT=
    // immediate | fifo | mailbox. Ignored when unset or the mode isn't offered.
    var forced: ?wgpu.WGPUPresentMode = null;
    if (std.c.getenv("CELERIS_PRESENT")) |env| {
        const s = std.mem.span(env);
        if (std.ascii.eqlIgnoreCase(s, "immediate") and has_immediate) {
            forced = wgpu.WGPUPresentMode_Immediate;
        } else if (std.ascii.eqlIgnoreCase(s, "fifo")) {
            forced = wgpu.WGPUPresentMode_Fifo;
        } else if (std.ascii.eqlIgnoreCase(s, "mailbox") and has_mailbox) {
            forced = wgpu.WGPUPresentMode_Mailbox;
        }
    }
    const pick: wgpu.WGPUPresentMode = forced orelse wgpu.WGPUPresentMode_Fifo;
    if (!g_present_logged) {
        g_present_logged = true;
        log.info("present modes: count={d} mailbox={} immediate={} forced={} -> picked={d} (Fifo={d} Immediate={d} Mailbox={d})\n", .{
            caps.presentModeCount,     has_mailbox,                    has_immediate,                forced != null, pick,
            wgpu.WGPUPresentMode_Fifo, wgpu.WGPUPresentMode_Immediate, wgpu.WGPUPresentMode_Mailbox,
        });
    }
    return pick;
}

/// High-resolution monotonic ns for the frame profiler (Windows QPC). Returns 0
/// off Windows — the profiler is a Windows-only dev aid, and 0 keeps the build
/// portable without pulling an Io into the render backend.
fn profNowNs() i64 {
    if (builtin.os.tag != .windows) return 0;
    if (g_qpc_freq == 0) _ = QueryPerformanceFrequency(&g_qpc_freq);
    var ctr: i64 = 0;
    _ = QueryPerformanceCounter(&ctr);
    // Split the conversion so `ctr * 1e9` can't overflow i64 over a long uptime.
    return @divFloor(ctr, g_qpc_freq) * std.time.ns_per_s +
        @divFloor(@mod(ctr, g_qpc_freq) * std.time.ns_per_s, g_qpc_freq);
}
const wgpu = @cImport({
    @cInclude("webgpu.h");
    @cInclude("wgpu.h");
});
const renderer_mod = @import("renderer.zig");
const text = @import("text.zig");
const reg = @import("../core/registry.zig");
const props = @import("../core/properties.zig");
const prof = @import("../core/profiler.zig");
const platform = @import("../platform/platform.zig");

const stbi = @cImport({
    @cInclude("stb_image.h");
});

/// Rounded clipping, shared by all four pipelines (prepended to each shader).
/// `clips` is the per-frame table built by `renderer.internClip` — one storage
/// buffer bound at @group(1) for every pipeline; a primitive's `clip_id` indexes
/// it (0 = no rounded clip). `ClipEntry` must match `renderer.ClipEntry`, and
/// `round_cov` must match `renderer.roundCoverage` (the CPU mirror the tests and
/// hit-testing use).
const WGSL_CLIP =
    \\struct RoundClip { x: f32, y: f32, w: f32, h: f32, r: f32 }
    \\struct ClipEntry { a: RoundClip, b: RoundClip, _p0: f32, _p1: f32 }
    \\@group(1) @binding(0) var<storage, read> clips: array<ClipEntry>;
    \\fn round_cov(c: RoundClip, p: vec2<f32>) -> f32 {
    \\    if (c.r <= 0.0) { return 1.0; }
    \\    let r = min(c.r, min(c.w, c.h) * 0.5);
    \\    let half = vec2(c.w, c.h) * 0.5;
    \\    let q = abs(p - vec2(c.x, c.y) - half) - half + r;
    \\    let d = length(max(q, vec2(0.))) + min(max(q.x, q.y), 0.) - r;
    \\    return clamp(0.5 - d, 0.0, 1.0);
    \\}
    \\fn clip_cov(id: f32, p: vec2<f32>) -> f32 {
    \\    let i = u32(id + 0.5);
    \\    if (i == 0u) { return 1.0; }
    \\    let e = clips[i];
    \\    return min(round_cov(e.a, p), round_cov(e.b, p));
    \\}
    \\
;

const WGSL = WGSL_CLIP ++
    \\struct InstanceData {
    \\    rect_x: f32, rect_y: f32, rect_w: f32, rect_h: f32,
    \\    cr: f32, cg: f32, cb: f32, ca: f32,
    \\    radius: f32, bt: f32, br: f32, bb: f32,
    \\    bl: f32, b_cr: f32, b_cg: f32, b_cb: f32,
    \\    b_ca: f32, clip_x: f32, clip_y: f32, clip_w: f32,
    \\    clip_h: f32, shadow_blur: f32, shadow_offset_x: f32, shadow_offset_y: f32,
    \\    shadow_color_r: f32, shadow_color_g: f32, shadow_color_b: f32, shadow_color_a: f32,
    \\    grad_type: f32, c2_r: f32, c2_g: f32, c2_b: f32,
    \\    c2_a: f32, border_style: f32, z_index: f32, _pad2: f32,
    \\    shadow_spread: f32, is_shadow: f32, clip_id: f32, _pad4: f32,
    \\}
    \\@group(0) @binding(0) var<storage, read> instances: array<InstanceData>;
    \\struct U { vp_w: f32, vp_h: f32, _pad1: f32, _pad2: f32 }
    \\@group(0) @binding(1) var<uniform> u: U;
    \\struct VOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) local: vec2<f32>,
    \\    @location(1) @interpolate(flat) inst_idx: u32,
    \\    @location(2) px: vec2<f32>,
    \\}
    \\@vertex fn vs(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> VOut {
    \\    let inst = instances[ii];
    \\    // Room for the blur's falloff — ONLY on a shadow prim. It reaches zero at
    \\    // half the blur radius past the shadow's edge (see the fragment stage), plus
    \\    // a pixel of slack for the edge antialias. A body must draw at its exact rect:
    \\    // growing it even 1px pushes `in.local` past `half`, and the square per-side
    \\    // border test then paints a spurious 1px skirt on the zero-width sides.
    \\    var expand = 0.0;
    \\    if (inst.is_shadow > 0.5) { expand = inst.shadow_blur * 0.5 + 1.0; }
    \\    let quad_w = inst.rect_w + expand * 2.0;
    \\    let quad_h = inst.rect_h + expand * 2.0;
    \\    var off: vec2<f32>;
    \\    switch (vi) {
    \\        case 0u: { off = vec2(0., 0.); }
    \\        case 1u: { off = vec2(quad_w, 0.); }
    \\        case 2u: { off = vec2(0., quad_h); }
    \\        case 3u: { off = vec2(0., quad_h); }
    \\        case 4u: { off = vec2(quad_w, 0.); }
    \\        case 5u: { off = vec2(quad_w, quad_h); }
    \\        default: { off = vec2(0., 0.); }
    \\    }
    \\    let px  = vec2(inst.rect_x - expand, inst.rect_y - expand) + off;
    \\    let ndc = vec2(px.x/u.vp_w*2.-1., 1.-px.y/u.vp_h*2.);
    \\    var o: VOut;
    \\    o.pos   = vec4(ndc, 0., 1.);
    \\    o.local = off - vec2(expand + inst.rect_w * 0.5, expand + inst.rect_h * 0.5);
    \\    o.inst_idx = ii;
    \\    o.px = px;
    \\    return o;
    \\}
    \\fn sdf_rrect(p: vec2<f32>, b: vec2<f32>, r: f32) -> f32 {
    \\    let q = abs(p) - b + r;
    \\    return length(max(q, vec2(0.))) + min(max(q.x, q.y), 0.) - r;
    \\}
    \\@fragment fn fs(in: VOut) -> @location(0) vec4<f32> {
    \\    let inst = instances[in.inst_idx];
    \\    let half = vec2(inst.rect_w, inst.rect_h) * .5;
    \\    let is_shadow = inst.is_shadow > 0.5;
    \\    var a: f32 = 1.0;
    \\    var d: f32 = 0.0;
    \\    // A shadow needs the signed distance at any radius — including 0, where a
    \\    // body would take the cheap unrounded path — because the blur is a function
    \\    // of that distance.
    \\    if (inst.radius > 0.001 || is_shadow) {
    \\        d = sdf_rrect(in.local, half, inst.radius);
    \\        if (!is_shadow) {
    \\            a = 1. - smoothstep(-0.5, 0.5, d);
    \\            if (a < .001) { discard; }
    \\        }
    \\    }
    \\    
    \\    // Per-side borders. A square rect gets exact per-edge widths (and optional
    \\    // dashes); a rounded one falls back to a uniform ring using the widest side,
    \\    // since per-side widths meeting inside a corner arc need full CSS corner math.
    \\    let bmax = max(max(inst.bt, inst.br), max(inst.bb, inst.bl));
    \\    var b_a: f32 = 0.0;
    \\    if (bmax > 0.0) {
    \\        if (inst.radius <= 0.001) {
    \\            // Require width > 0 per side: a zero-width side must never paint,
    \\            // even if the quad overhangs its rect (its threshold would be exactly
    \\            // half, so any overhang would light it up). Defence in depth alongside
    \\            // the exact-rect body above.
    \\            let on_l = inst.bl > 0.0 && in.local.x < -half.x + inst.bl;
    \\            let on_r = inst.br > 0.0 && in.local.x >  half.x - inst.br;
    \\            let on_t = inst.bt > 0.0 && in.local.y < -half.y + inst.bt;
    \\            let on_b = inst.bb > 0.0 && in.local.y >  half.y - inst.bb;
    \\            if (on_l || on_r || on_t || on_b) {
    \\                b_a = 1.0;
    \\                if (inst.border_style == 1.0) {
    \\                    // Dash along the edge: horizontal edges run in x, vertical in y.
    \\                    var tpos = in.local.y;
    \\                    if (on_t || on_b) { tpos = in.local.x; }
    \\                    let period = 10.0;
    \\                    let on_len = 6.0;
    \\                    if (tpos - floor(tpos / period) * period > on_len) { b_a = 0.0; }
    \\                }
    \\            }
    \\        } else {
    \\            let b_d = sdf_rrect(in.local, half - vec2(bmax), max(0., inst.radius - bmax));
    \\            b_a = smoothstep(-0.5, 0.5, b_d);
    \\        }
    \\    }
    \\    
    \\    // Clipping logic
    \\    if (in.px.x < inst.clip_x || in.px.y < inst.clip_y || 
    \\        in.px.x > inst.clip_x + inst.clip_w || in.px.y > inst.clip_y + inst.clip_h) {
    \\        discard;
    \\    }
    \\    // Rounded clip of the overflow_hidden ancestors (antialiased).
    \\    let cov = clip_cov(inst.clip_id, in.px);
    \\    if (cov < .001) { discard; }
    \\
    \\    // Shadow: fade the alpha out across the blur radius instead of painting a
    \\    // displaced copy of the rect. `d` is the signed distance to the (already
    \\    // spread-inflated) shadow edge, so the falloff is centred on that edge and
    \\    // spans `blur` px — half inside, half outside — which is what a CSS/Figma
    \\    // blur radius means. smoothstep is a cheap stand-in for the gaussian; over a
    \\    // rounded box the difference is not visible, and it has compact support, so
    \\    // the quad above only has to grow by blur/2.
    \\    if (is_shadow) {
    \\        var sa: f32 = 1.0;
    \\        if (inst.shadow_blur > 0.0) {
    \\            sa = 1. - smoothstep(-inst.shadow_blur * 0.5, inst.shadow_blur * 0.5, d);
    \\        } else {
    \\            sa = 1. - smoothstep(-0.5, 0.5, d); // blur 0 → hard edge, antialiased
    \\        }
    \\        if (sa < .002) { discard; }
    \\        return vec4(inst.cr, inst.cg, inst.cb, inst.ca * sa * cov);
    \\    }
    \\    
    \\    var final_color = vec4(inst.cr, inst.cg, inst.cb, inst.ca);
    \\    
    \\    // Gradient Logic
    \\    if (inst.grad_type > 0.0) {
    \\        let c2 = vec4(inst.c2_r, inst.c2_g, inst.c2_b, inst.c2_a);
    \\        var t = 0.0;
    \\        if (inst.grad_type == 1.0) { // Horizontal
    \\            t = (in.local.x + half.x) / inst.rect_w;
    \\        } else if (inst.grad_type == 2.0) { // Vertical
    \\            t = (in.local.y + half.y) / inst.rect_h;
    \\        } else if (inst.grad_type == 3.0) { // Radial
    \\            t = length(in.local) / max(half.x, half.y);
    \\        }
    \\        final_color = mix(final_color, c2, clamp(t, 0.0, 1.0));
    \\    }
    \\    
    \\    // Border Logic: the border composites OVER the fill ("over" on straight
    \\    // colors), so a partly covered border pixel is a blend toward the fill —
    \\    // never brighter than the border, and not faded twice over a transparent
    \\    // fill (mixing straight colors scaled rgb AND alpha by coverage, and the
    \\    // SrcAlpha blend then applied it again). Mirrored by `renderer.shadeRect`.
    \\    if (bmax > 0.0) {
    \\        let ba = inst.b_ca * b_a;
    \\        let out_a = ba + final_color.a * (1.0 - ba);
    \\        if (out_a > 0.0) {
    \\            let rgb = (vec3(inst.b_cr, inst.b_cg, inst.b_cb) * ba + final_color.rgb * final_color.a * (1.0 - ba)) / out_a;
    \\            final_color = vec4(rgb, out_a);
    \\        } else {
    \\            final_color = vec4(final_color.rgb, 0.0);
    \\        }
    \\    }
    \\    
    \\    return vec4(final_color.rgb, final_color.a * a * cov);
    \\}
;

const WGSL_TEXT = WGSL_CLIP ++
    \\struct U {
    \\    vp_w: f32, vp_h: f32, cr: f32, cg: f32,
    \\    cb: f32, ca: f32, clip_x: f32, clip_y: f32,
    \\    clip_w: f32, clip_h: f32, _pad1: f32, _pad2: f32,
    \\}
    \\@group(0) @binding(0) var<uniform> u: U;
    \\@group(0) @binding(1) var s: sampler;
    \\@group(0) @binding(2) var t: texture_2d<f32>;
    \\
    \\struct VIn {
    \\    @location(0) pos: vec2<f32>,
    \\    @location(1) uv: vec2<f32>,
    \\    @location(2) clip: vec4<f32>,
    \\    @location(3) color: vec4<f32>,
    \\    @location(4) clip_id: f32,
    \\}
    \\struct VOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) px: vec2<f32>,
    \\    @location(2) clip: vec4<f32>,
    \\    @location(3) color: vec4<f32>,
    \\    @location(4) @interpolate(flat) clip_id: f32,
    \\}
    \\@vertex fn vs(in: VIn) -> VOut {
    \\    let ndc = vec2(in.pos.x/u.vp_w*2.-1., 1.-in.pos.y/u.vp_h*2.);
    \\    var o: VOut; o.pos = vec4(ndc, 0., 1.); o.uv = in.uv; o.px = in.pos; o.clip = in.clip; o.color = in.color; o.clip_id = in.clip_id; return o;
    \\}
    \\@fragment fn fs(in: VOut) -> @location(0) vec4<f32> {
    \\    if (in.px.x < in.clip.x || in.px.y < in.clip.y ||
    \\        in.px.x > in.clip.x + in.clip.z || in.px.y > in.clip.y + in.clip.w) {
    \\        discard;
    \\    }
    \\    let alpha = textureSample(t, s, in.uv).r;
    \\    return vec4(in.color.rgb, in.color.a * alpha * clip_cov(in.clip_id, in.px));
    \\}
;

const WGSL_IMAGE = WGSL_CLIP ++
    \\struct U {
    \\    vp_w: f32, vp_h: f32, _pad1: f32, _pad2: f32,
    \\}
    \\@group(0) @binding(0) var<uniform> u: U;
    \\@group(0) @binding(1) var s: sampler;
    \\@group(0) @binding(2) var t: texture_2d<f32>;
    \\
    \\struct VIn {
    \\    @location(0) pos: vec2<f32>,
    \\    @location(1) uv: vec2<f32>,
    \\    @location(2) clip: vec4<f32>,
    \\    @location(3) opacity: f32,
    \\    @location(4) clip_id: f32,
    \\}
    \\struct VOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) px: vec2<f32>,
    \\    @location(2) clip: vec4<f32>,
    \\    @location(3) opacity: f32,
    \\    @location(4) @interpolate(flat) clip_id: f32,
    \\}
    \\@vertex fn vs(in: VIn) -> VOut {
    \\    let ndc = vec2(in.pos.x/u.vp_w*2.-1., 1.-in.pos.y/u.vp_h*2.);
    \\    var o: VOut; o.pos = vec4(ndc, 0., 1.); o.uv = in.uv; o.px = in.pos; o.clip = in.clip; o.opacity = in.opacity; o.clip_id = in.clip_id; return o;
    \\}
    \\@fragment fn fs(in: VOut) -> @location(0) vec4<f32> {
    \\    if (in.px.x < in.clip.x || in.px.y < in.clip.y || 
    \\        in.px.x > in.clip.x + in.clip.z || in.px.y > in.clip.y + in.clip.w) {
    \\        discard;
    \\    }
    \\    let tex_col = textureSample(t, s, in.uv);
    \\    return vec4(tex_col.rgb, tex_col.a * in.opacity * clip_cov(in.clip_id, in.px));
    \\}
;

// Path pipeline. One instance per flattened stroke segment; the fragment
// stage evaluates a capsule SDF (segment inflated by `half_width`, round ends →
// round caps and joins fall out for free). Field order of `PathInstance` MUST
// match `renderer.PathSegPrim` — the bytes are uploaded straight in.
const WGSL_PATH = WGSL_CLIP ++
    \\struct PathInstance {
    \\    ax: f32, ay: f32, bx: f32, by: f32,
    \\    half_width: f32,
    \\    cr: f32, cg: f32, cb: f32, ca: f32,
    \\    clip_x: f32, clip_y: f32, clip_w: f32, clip_h: f32,
    \\    z_index: f32, clip_id: f32, _p1: f32,
    \\}
    \\@group(0) @binding(0) var<storage, read> insts: array<PathInstance>;
    \\struct U { vp_w: f32, vp_h: f32, _a: f32, _b: f32 }
    \\@group(0) @binding(1) var<uniform> u: U;
    \\struct VOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) @interpolate(flat) idx: u32,
    \\    @location(1) px: vec2<f32>,
    \\}
    \\@vertex fn vs(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> VOut {
    \\    let it = insts[ii];
    \\    let pad = it.half_width + 1.5;
    \\    let lo = vec2(min(it.ax, it.bx) - pad, min(it.ay, it.by) - pad);
    \\    let hi = vec2(max(it.ax, it.bx) + pad, max(it.ay, it.by) + pad);
    \\    var c: vec2<f32>;
    \\    switch (vi) {
    \\        case 0u: { c = vec2(lo.x, lo.y); }
    \\        case 1u: { c = vec2(hi.x, lo.y); }
    \\        case 2u: { c = vec2(lo.x, hi.y); }
    \\        case 3u: { c = vec2(lo.x, hi.y); }
    \\        case 4u: { c = vec2(hi.x, lo.y); }
    \\        case 5u: { c = vec2(hi.x, hi.y); }
    \\        default: { c = lo; }
    \\    }
    \\    let ndc = vec2(c.x / u.vp_w * 2. - 1., 1. - c.y / u.vp_h * 2.);
    \\    var o: VOut;
    \\    o.pos = vec4(ndc, 0., 1.);
    \\    o.idx = ii;
    \\    o.px = c;
    \\    return o;
    \\}
    \\fn sd_seg(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    \\    let pa = p - a;
    \\    let ba = b - a;
    \\    let h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    \\    return length(pa - ba * h);
    \\}
    \\@fragment fn fs(in: VOut) -> @location(0) vec4<f32> {
    \\    let it = insts[in.idx];
    \\    if (in.px.x < it.clip_x || in.px.y < it.clip_y ||
    \\        in.px.x > it.clip_x + it.clip_w || in.px.y > it.clip_y + it.clip_h) { discard; }
    \\    let d = sd_seg(in.px, vec2(it.ax, it.ay), vec2(it.bx, it.by)) - it.half_width;
    \\    let a = it.ca * (1.0 - smoothstep(-0.7, 0.7, d)) * clip_cov(it.clip_id, in.px);
    \\    if (a < 0.002) { discard; }
    \\    return vec4(it.cr, it.cg, it.cb, a);
    \\}
;

const TextUniforms = extern struct {
    vp_w: f32,
    vp_h: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
    clip_x: f32,
    clip_y: f32,
    clip_w: f32,
    clip_h: f32,
    _pad1: f32,
    _pad2: f32,
};
const TextVertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    clip: [4]f32,
    color: [4]f32,
    /// Index into the rounded-clip table (0 = none).
    clip_id: f32 = 0,
};

const ImageUniforms = extern struct {
    vp_w: f32,
    vp_h: f32,
    _pad1: f32,
    _pad2: f32,
};
const ImageVertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    clip: [4]f32,
    opacity: f32,
    /// Index into the rounded-clip table (0 = none).
    clip_id: f32 = 0,
};

const CachedTexture = struct {
    texture: wgpu.WGPUTexture,
    view: wgpu.WGPUTextureView,
    bind_group: wgpu.WGPUBindGroup,
};

const DrawBatchType = enum { rect, image, text, path };
const DrawBatch = struct {
    batch_type: DrawBatchType,
    z_index: f32,
    order: u32,
    start_idx: u32,
    count: u32,
    img_path: ?[]const u8 = null,
};

var g_instance: wgpu.WGPUInstance = null;
var g_adapter: wgpu.WGPUAdapter = null;
var g_device: wgpu.WGPUDevice = null;

// ── WGPU init helpers ─────────────────────────────────────────────────────────
// init() builds three near-identical pipelines (rect / text / image); these
// collapse the per-pipeline boilerplate that was copy-pasted three times. Each
// holds its descriptor in a local that lives across the synchronous wgpu create
// call, exactly as the inline code did.

fn createShaderModuleWGSL(device: wgpu.WGPUDevice, code: [*c]const u8) wgpu.WGPUShaderModule {
    var wgsl_desc = wgpu.WGPUShaderModuleWGSLDescriptor{
        .chain = .{ .next = null, .sType = wgpu.WGPUSType_ShaderModuleWGSLDescriptor },
        .code = code,
    };
    return wgpu.wgpuDeviceCreateShaderModule(device, &.{
        .nextInChain = &wgsl_desc.chain,
        .label = null,
        .hintCount = 0,
        .hints = null,
    });
}

fn createUniformBuffer(device: wgpu.WGPUDevice, label: [*c]const u8, size: u64) wgpu.WGPUBuffer {
    return wgpu.wgpuDeviceCreateBuffer(device, &.{
        .nextInChain = null,
        .label = label,
        .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
        .size = size,
        .mappedAtCreation = 0,
    });
}

fn createVertexBuffer(device: wgpu.WGPUDevice, size: u64) wgpu.WGPUBuffer {
    return wgpu.wgpuDeviceCreateBuffer(device, &.{
        .nextInChain = null,
        .label = null,
        .usage = wgpu.WGPUBufferUsage_Vertex | wgpu.WGPUBufferUsage_CopyDst,
        .size = size,
        .mappedAtCreation = 0,
    });
}

/// Pipeline layout = the pipeline's own group 0 + the shared clip table at group 1.
fn createPipelineLayout(device: wgpu.WGPUDevice, bgl: wgpu.WGPUBindGroupLayout, clip_bgl: wgpu.WGPUBindGroupLayout) wgpu.WGPUPipelineLayout {
    const layouts = [_]wgpu.WGPUBindGroupLayout{ bgl, clip_bgl };
    return wgpu.wgpuDeviceCreatePipelineLayout(device, &.{
        .nextInChain = null,
        .label = null,
        .bindGroupLayoutCount = 2,
        .bindGroupLayouts = &layouts,
    });
}

/// Group 1, shared by every pipeline: the read-only rounded-clip table.
fn createClipBGL(device: wgpu.WGPUDevice) wgpu.WGPUBindGroupLayout {
    const entries = [_]wgpu.WGPUBindGroupLayoutEntry{.{
        .nextInChain = null,
        .binding = 0,
        .visibility = wgpu.WGPUShaderStage_Fragment,
        .buffer = .{ .nextInChain = null, .type = wgpu.WGPUBufferBindingType_ReadOnlyStorage, .hasDynamicOffset = 0, .minBindingSize = 0 },
        .sampler = .{ .nextInChain = null, .type = wgpu.WGPUSamplerBindingType_Undefined },
        .texture = .{ .nextInChain = null, .sampleType = wgpu.WGPUTextureSampleType_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined, .multisampled = 0 },
        .storageTexture = .{ .nextInChain = null, .access = wgpu.WGPUStorageTextureAccess_Undefined, .format = wgpu.WGPUTextureFormat_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined },
    }};
    return wgpu.wgpuDeviceCreateBindGroupLayout(device, &.{
        .nextInChain = null,
        .label = null,
        .entryCount = 1,
        .entries = &entries,
    });
}

/// Initial capacity (entries) of the rounded-clip table buffer; grows on demand.
const INIT_CLIP_CAP: usize = 64;

fn createClipBuffer(device: wgpu.WGPUDevice, cap: usize) wgpu.WGPUBuffer {
    return wgpu.wgpuDeviceCreateBuffer(device, &.{
        .nextInChain = null,
        .label = "Clip Table",
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
        .size = @sizeOf(renderer_mod.ClipEntry) * cap,
        .mappedAtCreation = 0,
    });
}

fn createClipBindGroup(device: wgpu.WGPUDevice, layout: wgpu.WGPUBindGroupLayout, buf: wgpu.WGPUBuffer) wgpu.WGPUBindGroup {
    const entries = [_]wgpu.WGPUBindGroupEntry{.{ .nextInChain = null, .binding = 0, .buffer = buf, .offset = 0, .size = wgpu.WGPU_WHOLE_SIZE, .sampler = null, .textureView = null }};
    return wgpu.wgpuDeviceCreateBindGroup(device, &.{
        .nextInChain = null,
        .label = null,
        .layout = layout,
        .entryCount = 1,
        .entries = &entries,
    });
}

/// The text/image bind group layout: a vertex+fragment uniform at binding 0, a
/// filtering sampler at 1, and a float 2D texture at 2. `min_binding_size` (the
/// uniform struct size) is the only difference between the text and image layouts.
fn createSampledTextureBGL(device: wgpu.WGPUDevice, min_binding_size: u64) wgpu.WGPUBindGroupLayout {
    const entries = [_]wgpu.WGPUBindGroupLayoutEntry{
        .{
            .nextInChain = null,
            .binding = 0,
            .visibility = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
            .buffer = .{ .nextInChain = null, .type = wgpu.WGPUBufferBindingType_Uniform, .hasDynamicOffset = 0, .minBindingSize = min_binding_size },
            .sampler = .{ .nextInChain = null, .type = wgpu.WGPUSamplerBindingType_Undefined },
            .texture = .{ .nextInChain = null, .sampleType = wgpu.WGPUTextureSampleType_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined, .multisampled = 0 },
            .storageTexture = .{ .nextInChain = null, .access = wgpu.WGPUStorageTextureAccess_Undefined, .format = wgpu.WGPUTextureFormat_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined },
        },
        .{
            .nextInChain = null,
            .binding = 1,
            .visibility = wgpu.WGPUShaderStage_Fragment,
            .buffer = .{ .nextInChain = null, .type = wgpu.WGPUBufferBindingType_Undefined, .hasDynamicOffset = 0, .minBindingSize = 0 },
            .sampler = .{ .nextInChain = null, .type = wgpu.WGPUSamplerBindingType_Filtering },
            .texture = .{ .nextInChain = null, .sampleType = wgpu.WGPUTextureSampleType_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined, .multisampled = 0 },
            .storageTexture = .{ .nextInChain = null, .access = wgpu.WGPUStorageTextureAccess_Undefined, .format = wgpu.WGPUTextureFormat_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined },
        },
        .{
            .nextInChain = null,
            .binding = 2,
            .visibility = wgpu.WGPUShaderStage_Fragment,
            .buffer = .{ .nextInChain = null, .type = wgpu.WGPUBufferBindingType_Undefined, .hasDynamicOffset = 0, .minBindingSize = 0 },
            .sampler = .{ .nextInChain = null, .type = wgpu.WGPUSamplerBindingType_Undefined },
            .texture = .{ .nextInChain = null, .sampleType = wgpu.WGPUTextureSampleType_Float, .viewDimension = wgpu.WGPUTextureViewDimension_2D, .multisampled = 0 },
            .storageTexture = .{ .nextInChain = null, .access = wgpu.WGPUStorageTextureAccess_Undefined, .format = wgpu.WGPUTextureFormat_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined },
        },
    };
    return wgpu.wgpuDeviceCreateBindGroupLayout(device, &.{
        .nextInChain = null,
        .label = null,
        .entryCount = 3,
        .entries = &entries,
    });
}

/// Creates a render pipeline with the engine's standard primitive (triangle list,
/// CCW, no cull) and multisample (1×) state, and a fragment stage wired to
/// `target`. `vbl` is the vertex buffer layout, or null for a vertexless pipeline
/// (the rect pass pulls instance data from a storage buffer).
fn createPipeline(
    device: wgpu.WGPUDevice,
    layout: wgpu.WGPUPipelineLayout,
    shader: wgpu.WGPUShaderModule,
    vbl: ?*const wgpu.WGPUVertexBufferLayout,
    target: *const wgpu.WGPUColorTargetState,
) wgpu.WGPURenderPipeline {
    const frag = wgpu.WGPUFragmentState{
        .nextInChain = null,
        .module = shader,
        .entryPoint = "fs",
        .constantCount = 0,
        .constants = null,
        .targetCount = 1,
        .targets = target,
    };
    return wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
        .nextInChain = null,
        .label = null,
        .layout = layout,
        .vertex = .{ .nextInChain = null, .module = shader, .entryPoint = "vs", .constantCount = 0, .constants = null, .bufferCount = if (vbl == null) 0 else 1, .buffers = vbl },
        .primitive = .{ .nextInChain = null, .topology = wgpu.WGPUPrimitiveTopology_TriangleList, .stripIndexFormat = wgpu.WGPUIndexFormat_Undefined, .frontFace = wgpu.WGPUFrontFace_CCW, .cullMode = wgpu.WGPUCullMode_None },
        .depthStencil = null,
        .multisample = .{ .nextInChain = null, .count = 1, .mask = 0xFFFFFFFF, .alphaToCoverageEnabled = 0 },
        .fragment = &frag,
    });
}

fn onAdapter(status: wgpu.WGPURequestAdapterStatus, adapter: wgpu.WGPUAdapter, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (status == wgpu.WGPURequestAdapterStatus_Success) g_adapter = adapter;
}
fn onDevice(status: wgpu.WGPURequestDeviceStatus, device: wgpu.WGPUDevice, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (status == wgpu.WGPURequestDeviceStatus_Success) g_device = device;
}

/// Initial capacity (in rects) of the instance storage buffer. The buffer grows
/// on demand in `renderFrame` (see `ensureInstBuf`) — nothing is ever dropped.
const INIT_RECT_CAP: usize = 1024;
/// Initial byte capacity of the text/image vertex buffers; both grow on demand.
const INIT_VBUF_BYTES: usize = 1024 * 512;

pub const WgpuBackend = struct {
    allocator: std.mem.Allocator,
    /// Logical (DPI-independent) size. The surface/framebuffer is configured at
    /// physical = logical × scale; the projection uses logical, so logical content
    /// fills the physical framebuffer crisply (HiDPI).
    width: u32,
    height: u32,
    scale: f32,
    is_headless: bool,

    instance: wgpu.WGPUInstance,
    surface: wgpu.WGPUSurface,
    device: wgpu.WGPUDevice,
    queue: wgpu.WGPUQueue,

    pipeline: wgpu.WGPURenderPipeline,
    bgl: wgpu.WGPUBindGroupLayout, // layout for `bind_group`; kept so it can be rebuilt when inst_buf grows
    bind_group: wgpu.WGPUBindGroup,
    inst_buf: wgpu.WGPUBuffer,
    inst_cap: usize, // current capacity of inst_buf, in rects
    uni_buf: wgpu.WGPUBuffer,

    atlas: *text.FontAtlas,
    atlas_tex: wgpu.WGPUTexture, // re-uploaded when the glyph cache grows (atlas.dirty)
    sampler: wgpu.WGPUSampler, // one linear-clamp sampler shared by text + all images

    t_pipeline: wgpu.WGPURenderPipeline,
    t_bind_group: wgpu.WGPUBindGroup,
    t_uni_buf: wgpu.WGPUBuffer,
    t_vbuf: wgpu.WGPUBuffer,
    t_vbuf_cap: usize, // current byte capacity of t_vbuf

    i_pipeline: wgpu.WGPURenderPipeline,
    i_bgl: wgpu.WGPUBindGroupLayout,
    i_uni_buf: wgpu.WGPUBuffer,
    i_vbuf: wgpu.WGPUBuffer,
    i_vbuf_cap: usize, // current byte capacity of i_vbuf

    // Path pipeline: vertexless-instanced capsule SDF, one instance per
    // flattened stroke segment. Shape mirrors the rect pipeline (storage buffer
    // of instances + the shared viewport uniform).
    p_pipeline: wgpu.WGPURenderPipeline,
    p_bind_group: wgpu.WGPUBindGroup, // references p_inst_buf + the shared uni_buf, via self.bgl
    p_inst_buf: wgpu.WGPUBuffer,
    p_inst_cap: usize, // capacity of p_inst_buf, in segments

    // Rounded-clip table (group 1 of every pipeline), rebuilt each frame.
    clip_bgl: wgpu.WGPUBindGroupLayout,
    clip_buf: wgpu.WGPUBuffer,
    clip_cap: usize, // entries
    clip_bind_group: wgpu.WGPUBindGroup,
    texture_cache: std.StringHashMap(CachedTexture),
    surface_format: wgpu.WGPUTextureFormat,

    // Headless target
    render_target: wgpu.WGPUTexture,
    render_view: wgpu.WGPUTextureView,

    // ── Frame profiler (opt-in; set by the host from CELERIS_PROFILE) ──────────
    // Per-renderFrame phase timings in ns, overwritten each call. Lets the host
    // see whether a render spike is CPU vert/upload work, command encoding,
    // queue submit, or (most often) the blocking present/vsync.
    prof_on: bool = false,
    prof_surface_ns: i64 = 0,
    prof_build_ns: i64 = 0,
    prof_encode_ns: i64 = 0,
    prof_submit_ns: i64 = 0,
    prof_present_ns: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, native_handle: ?platform.NativeWindowHandle, width: u32, height: u32, scale: f32, is_headless: bool, atlas_ptr: ?*text.FontAtlas) !WgpuBackend {
        // instance/adapter/device are a process-wide singleton (see deinit()'s doc
        // comment): every engine must resolve to the SAME instance, or a surface
        // created on one engine's instance ends up paired with an adapter/device
        // from a different engine's instance, which wgpu-core rejects (previously
        // caused a hard panic/abort when maximizing a window after a second engine
        // had been created and destroyed). Only the first engine creates these;
        // every later engine just reuses them.
        if (g_instance == null) g_instance = wgpu.wgpuCreateInstance(&.{ .nextInChain = null });
        const inst = g_instance;
        // Physical framebuffer dimensions (logical × DPI scale).
        const pw: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) * scale));
        const ph: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * scale));

        var surface: wgpu.WGPUSurface = null;
        if (!is_headless and native_handle != null) {
            switch (native_handle.?) {
                .win32 => |w32| {
                    var hwnd_desc = wgpu.WGPUSurfaceDescriptorFromWindowsHWND{
                        .chain = .{ .next = null, .sType = wgpu.WGPUSType_SurfaceDescriptorFromWindowsHWND },
                        .hinstance = w32.hinst,
                        .hwnd = w32.hwnd,
                    };
                    surface = wgpu.wgpuInstanceCreateSurface(inst, &.{
                        .nextInChain = &hwnd_desc.chain,
                        .label = null,
                    });
                },
                .macos => {
                    // Stub for macOS
                },
                .linux => |lin| {
                    var wl_desc = wgpu.WGPUSurfaceDescriptorFromWaylandSurface{
                        .chain = .{ .next = null, .sType = wgpu.WGPUSType_SurfaceDescriptorFromWaylandSurface },
                        .display = lin.display,
                        .surface = lin.surface,
                    };
                    surface = wgpu.wgpuInstanceCreateSurface(inst, &.{
                        .nextInChain = &wl_desc.chain,
                        .label = null,
                    });
                },
            }
        }

        if (g_adapter == null) {
            wgpu.wgpuInstanceRequestAdapter(inst, &.{
                .nextInChain = null,
                .compatibleSurface = surface,
                .powerPreference = wgpu.WGPUPowerPreference_HighPerformance,
                .forceFallbackAdapter = 0, // use the real GPU (was 1 = software fallback)
            }, onAdapter, null);
        }
        if (g_adapter == null) return error.NoAdapter;

        if (g_device == null) wgpu.wgpuAdapterRequestDevice(g_adapter, &.{
            .nextInChain = null,
            .label = null,
            .requiredFeatureCount = 0,
            .requiredFeatures = null,
            .requiredLimits = null,
            .defaultQueue = .{ .nextInChain = null, .label = null },
            .deviceLostCallback = null,
            .deviceLostUserdata = null,
            .uncapturedErrorCallbackInfo = .{ .nextInChain = null, .callback = null, .userdata = null },
        }, onDevice, null);
        if (g_device == null) return error.NoDevice;
        const queue = wgpu.wgpuDeviceGetQueue(g_device);

        var render_target: wgpu.WGPUTexture = null;
        var render_view: wgpu.WGPUTextureView = null;

        const surface_format: wgpu.WGPUTextureFormat = if (is_headless)
            wgpu.WGPUTextureFormat_BGRA8Unorm
        else blk: {
            var caps: wgpu.WGPUSurfaceCapabilities = std.mem.zeroes(wgpu.WGPUSurfaceCapabilities);
            wgpu.wgpuSurfaceGetCapabilities(surface, g_adapter, &caps);
            defer wgpu.wgpuSurfaceCapabilitiesFreeMembers(caps);
            var best_format = if (caps.formatCount > 0) caps.formats[0] else wgpu.WGPUTextureFormat_BGRA8Unorm;
            if (caps.formatCount > 0) {
                var i: usize = 0;
                while (i < caps.formatCount) : (i += 1) {
                    const fmt = caps.formats[i];
                    if (fmt == wgpu.WGPUTextureFormat_BGRA8Unorm or fmt == wgpu.WGPUTextureFormat_RGBA8Unorm) {
                        best_format = fmt;
                        break;
                    }
                }
            }
            break :blk best_format;
        };

        if (is_headless) {
            render_target = wgpu.wgpuDeviceCreateTexture(g_device, &.{
                .nextInChain = null,
                .label = "Headless Render Target",
                .usage = wgpu.WGPUTextureUsage_RenderAttachment | wgpu.WGPUTextureUsage_CopySrc,
                .dimension = wgpu.WGPUTextureDimension_2D,
                .size = .{ .width = pw, .height = ph, .depthOrArrayLayers = 1 },
                .format = surface_format,
                .mipLevelCount = 1,
                .sampleCount = 1,
                .viewFormatCount = 0,
                .viewFormats = null,
            });
            render_view = wgpu.wgpuTextureCreateView(render_target, &.{
                .nextInChain = null,
                .label = null,
                .format = surface_format,
                .dimension = wgpu.WGPUTextureViewDimension_2D,
                .baseMipLevel = 0,
                .mipLevelCount = 1,
                .baseArrayLayer = 0,
                .arrayLayerCount = 1,
                .aspect = wgpu.WGPUTextureAspect_All,
            });
        } else {
            var caps: wgpu.WGPUSurfaceCapabilities = std.mem.zeroes(wgpu.WGPUSurfaceCapabilities);
            wgpu.wgpuSurfaceGetCapabilities(surface, g_adapter, &caps);
            defer wgpu.wgpuSurfaceCapabilitiesFreeMembers(caps);

            const alpha = if (caps.alphaModeCount > 0) caps.alphaModes[0] else wgpu.WGPUCompositeAlphaMode_Auto;
            const present = pickPresentMode(caps);

            wgpu.wgpuSurfaceConfigure(surface, &wgpu.WGPUSurfaceConfiguration{
                .nextInChain = null,
                .device = g_device,
                .format = surface_format,
                .usage = wgpu.WGPUTextureUsage_RenderAttachment,
                .viewFormatCount = 0,
                .viewFormats = null,
                .alphaMode = alpha,
                .width = pw,
                .height = ph,
                .presentMode = present,
            });
        }

        // --- Shader and Pipeline for Rects ---
        const shader = createShaderModuleWGSL(g_device, WGSL.ptr);

        const bgl_entries = [_]wgpu.WGPUBindGroupLayoutEntry{
            .{
                .nextInChain = null,
                .binding = 0,
                .visibility = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
                .buffer = .{
                    .nextInChain = null,
                    .type = wgpu.WGPUBufferBindingType_ReadOnlyStorage,
                    .hasDynamicOffset = 0,
                    .minBindingSize = 0,
                },
                .sampler = .{ .nextInChain = null, .type = wgpu.WGPUSamplerBindingType_Undefined },
                .texture = .{ .nextInChain = null, .sampleType = wgpu.WGPUTextureSampleType_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined, .multisampled = 0 },
                .storageTexture = .{ .nextInChain = null, .access = wgpu.WGPUStorageTextureAccess_Undefined, .format = wgpu.WGPUTextureFormat_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined },
            },
            .{
                .nextInChain = null,
                .binding = 1,
                .visibility = wgpu.WGPUShaderStage_Vertex,
                .buffer = .{
                    .nextInChain = null,
                    .type = wgpu.WGPUBufferBindingType_Uniform,
                    .hasDynamicOffset = 0,
                    .minBindingSize = 16, // 4 f32s
                },
                .sampler = .{ .nextInChain = null, .type = wgpu.WGPUSamplerBindingType_Undefined },
                .texture = .{ .nextInChain = null, .sampleType = wgpu.WGPUTextureSampleType_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined, .multisampled = 0 },
                .storageTexture = .{ .nextInChain = null, .access = wgpu.WGPUStorageTextureAccess_Undefined, .format = wgpu.WGPUTextureFormat_Undefined, .viewDimension = wgpu.WGPUTextureViewDimension_Undefined },
            },
        };
        const bgl = wgpu.wgpuDeviceCreateBindGroupLayout(g_device, &.{
            .nextInChain = null,
            .label = null,
            .entryCount = 2,
            .entries = &bgl_entries,
        });
        const clip_bgl = createClipBGL(g_device);
        const clip_buf = createClipBuffer(g_device, INIT_CLIP_CAP);
        const clip_bind_group = createClipBindGroup(g_device, clip_bgl, clip_buf);
        const pl = createPipelineLayout(g_device, bgl, clip_bgl);

        const color_target = wgpu.WGPUColorTargetState{
            .nextInChain = null,
            .format = surface_format,
            .blend = &.{
                .color = .{
                    .operation = wgpu.WGPUBlendOperation_Add,
                    .srcFactor = wgpu.WGPUBlendFactor_SrcAlpha,
                    .dstFactor = wgpu.WGPUBlendFactor_OneMinusSrcAlpha,
                },
                // Alpha accumulates ("over"), it is not replaced: with One/Zero
                // every antialiased edge (alpha < 1) punched a hole in the
                // target's alpha, and a compositor or capture that un-premultiplies
                // by it showed that pixel up to twice as bright as drawn.
                .alpha = .{
                    .operation = wgpu.WGPUBlendOperation_Add,
                    .srcFactor = wgpu.WGPUBlendFactor_One,
                    .dstFactor = wgpu.WGPUBlendFactor_OneMinusSrcAlpha,
                },
            },
            .writeMask = wgpu.WGPUColorWriteMask_All,
        };
        const pipeline = createPipeline(g_device, pl, shader, null, &color_target);

        const inst_buf = wgpu.wgpuDeviceCreateBuffer(g_device, &.{
            .nextInChain = null,
            .label = "Instance Buffer",
            .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(renderer_mod.RectPrimitive) * INIT_RECT_CAP,
            .mappedAtCreation = 0,
        });
        const uni_buf = createUniformBuffer(g_device, "Rect Uniform Buffer", 16);
        const bg_entries = [_]wgpu.WGPUBindGroupEntry{ .{
            .nextInChain = null,
            .binding = 0,
            .buffer = inst_buf,
            .offset = 0,
            .size = wgpu.WGPU_WHOLE_SIZE,
            .sampler = null,
            .textureView = null,
        }, .{
            .nextInChain = null,
            .binding = 1,
            .buffer = uni_buf,
            .offset = 0,
            .size = 16,
            .sampler = null,
            .textureView = null,
        } };
        const bind_group = wgpu.wgpuDeviceCreateBindGroup(g_device, &.{
            .nextInChain = null,
            .label = null,
            .layout = bgl,
            .entryCount = 2,
            .entries = &bg_entries,
        });

        // --- Path pipeline --- same bind layout as rect (storage@0 +
        // viewport uniform@1), so it reuses `bgl`/`pl`/`uni_buf`; only the
        // shader and instance buffer are its own.
        const p_shader = createShaderModuleWGSL(g_device, WGSL_PATH.ptr);
        const p_pipeline = createPipeline(g_device, pl, p_shader, null, &color_target);
        const p_inst_buf = wgpu.wgpuDeviceCreateBuffer(g_device, &.{
            .nextInChain = null,
            .label = "Path Instance Buffer",
            .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(renderer_mod.PathSegPrim) * INIT_RECT_CAP,
            .mappedAtCreation = 0,
        });
        const p_bg_entries = [_]wgpu.WGPUBindGroupEntry{ .{
            .nextInChain = null,
            .binding = 0,
            .buffer = p_inst_buf,
            .offset = 0,
            .size = wgpu.WGPU_WHOLE_SIZE,
            .sampler = null,
            .textureView = null,
        }, .{
            .nextInChain = null,
            .binding = 1,
            .buffer = uni_buf,
            .offset = 0,
            .size = 16,
            .sampler = null,
            .textureView = null,
        } };
        const p_bind_group = wgpu.wgpuDeviceCreateBindGroup(g_device, &.{
            .nextInChain = null,
            .label = null,
            .layout = bgl,
            .entryCount = 2,
            .entries = &p_bg_entries,
        });

        // --- Font Atlas and Text Rendering ---
        if (atlas_ptr == null) return error.NoFontAtlas;
        const atlas = atlas_ptr.?;

        const atlas_tex = wgpu.wgpuDeviceCreateTexture(g_device, &.{
            .nextInChain = null,
            .label = "Font Atlas",
            .usage = wgpu.WGPUTextureUsage_CopyDst | wgpu.WGPUTextureUsage_TextureBinding,
            .dimension = wgpu.WGPUTextureDimension_2D,
            .size = .{ .width = text.ATLAS_WIDTH, .height = text.ATLAS_HEIGHT, .depthOrArrayLayers = 1 },
            .format = wgpu.WGPUTextureFormat_R8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = 0,
            .viewFormats = null,
        });
        wgpu.wgpuQueueWriteTexture(queue, &.{ .nextInChain = null, .texture = atlas_tex, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = 0 }, .aspect = wgpu.WGPUTextureAspect_All }, atlas.pixels.ptr, atlas.pixels.len, &.{ .nextInChain = null, .offset = 0, .bytesPerRow = text.ATLAS_WIDTH, .rowsPerImage = text.ATLAS_HEIGHT }, &.{ .width = text.ATLAS_WIDTH, .height = text.ATLAS_HEIGHT, .depthOrArrayLayers = 1 });
        const atlas_view = wgpu.wgpuTextureCreateView(atlas_tex, &.{
            .nextInChain = null,
            .label = null,
            .format = wgpu.WGPUTextureFormat_R8Unorm,
            .dimension = wgpu.WGPUTextureViewDimension_2D,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
            .aspect = wgpu.WGPUTextureAspect_All,
        });
        const sampler = wgpu.wgpuDeviceCreateSampler(g_device, &.{
            .nextInChain = null,
            .label = null,
            .addressModeU = wgpu.WGPUAddressMode_ClampToEdge,
            .addressModeV = wgpu.WGPUAddressMode_ClampToEdge,
            .addressModeW = wgpu.WGPUAddressMode_ClampToEdge,
            .magFilter = wgpu.WGPUFilterMode_Linear,
            .minFilter = wgpu.WGPUFilterMode_Linear,
            .mipmapFilter = wgpu.WGPUMipmapFilterMode_Linear,
            .lodMinClamp = 0,
            .lodMaxClamp = 32,
            .compare = wgpu.WGPUCompareFunction_Undefined,
            .maxAnisotropy = 1,
        });

        const t_bgl = createSampledTextureBGL(g_device, @sizeOf(TextUniforms));
        const t_pl = createPipelineLayout(g_device, t_bgl, clip_bgl);
        const t_shader = createShaderModuleWGSL(g_device, WGSL_TEXT.ptr);

        const t_vbl_attrs = [_]wgpu.WGPUVertexAttribute{
            .{ .format = wgpu.WGPUVertexFormat_Float32x2, .offset = @offsetOf(TextVertex, "pos"), .shaderLocation = 0 },
            .{ .format = wgpu.WGPUVertexFormat_Float32x2, .offset = @offsetOf(TextVertex, "uv"), .shaderLocation = 1 },
            .{ .format = wgpu.WGPUVertexFormat_Float32x4, .offset = @offsetOf(TextVertex, "clip"), .shaderLocation = 2 },
            .{ .format = wgpu.WGPUVertexFormat_Float32x4, .offset = @offsetOf(TextVertex, "color"), .shaderLocation = 3 },
            .{ .format = wgpu.WGPUVertexFormat_Float32, .offset = @offsetOf(TextVertex, "clip_id"), .shaderLocation = 4 },
        };
        const t_vbl = wgpu.WGPUVertexBufferLayout{
            .arrayStride = @sizeOf(TextVertex),
            .stepMode = wgpu.WGPUVertexStepMode_Vertex,
            .attributeCount = 5,
            .attributes = &t_vbl_attrs,
        };

        const t_pipeline = createPipeline(g_device, t_pl, t_shader, &t_vbl, &color_target);

        const t_uni_buf = createUniformBuffer(g_device, null, @sizeOf(TextUniforms));
        const t_bg_entries = [_]wgpu.WGPUBindGroupEntry{
            .{ .nextInChain = null, .binding = 0, .buffer = t_uni_buf, .offset = 0, .size = @sizeOf(TextUniforms), .sampler = null, .textureView = null },
            .{ .nextInChain = null, .binding = 1, .buffer = null, .offset = 0, .size = 0, .sampler = sampler, .textureView = null },
            .{ .nextInChain = null, .binding = 2, .buffer = null, .offset = 0, .size = 0, .sampler = null, .textureView = atlas_view },
        };
        const t_bind_group = wgpu.wgpuDeviceCreateBindGroup(g_device, &.{
            .nextInChain = null,
            .label = null,
            .layout = t_bgl,
            .entryCount = 3,
            .entries = &t_bg_entries,
        });

        const t_vbuf = createVertexBuffer(g_device, INIT_VBUF_BYTES);

        const i_bgl = createSampledTextureBGL(g_device, @sizeOf(ImageUniforms));
        const i_pl = createPipelineLayout(g_device, i_bgl, clip_bgl);
        const i_shader = createShaderModuleWGSL(g_device, WGSL_IMAGE.ptr);

        const i_vbl_attrs = [_]wgpu.WGPUVertexAttribute{
            .{ .format = wgpu.WGPUVertexFormat_Float32x2, .offset = @offsetOf(ImageVertex, "pos"), .shaderLocation = 0 },
            .{ .format = wgpu.WGPUVertexFormat_Float32x2, .offset = @offsetOf(ImageVertex, "uv"), .shaderLocation = 1 },
            .{ .format = wgpu.WGPUVertexFormat_Float32x4, .offset = @offsetOf(ImageVertex, "clip"), .shaderLocation = 2 },
            .{ .format = wgpu.WGPUVertexFormat_Float32, .offset = @offsetOf(ImageVertex, "opacity"), .shaderLocation = 3 },
            .{ .format = wgpu.WGPUVertexFormat_Float32, .offset = @offsetOf(ImageVertex, "clip_id"), .shaderLocation = 4 },
        };
        const i_vbl = wgpu.WGPUVertexBufferLayout{
            .arrayStride = @sizeOf(ImageVertex),
            .stepMode = wgpu.WGPUVertexStepMode_Vertex,
            .attributeCount = 5,
            .attributes = &i_vbl_attrs,
        };

        const i_pipeline = createPipeline(g_device, i_pl, i_shader, &i_vbl, &color_target);

        const i_uni_buf = createUniformBuffer(g_device, null, @sizeOf(ImageUniforms));

        const i_vbuf = createVertexBuffer(g_device, INIT_VBUF_BYTES);

        return WgpuBackend{
            .allocator = allocator,
            .width = width,
            .height = height,
            .scale = scale,
            .is_headless = is_headless,
            .instance = inst,
            .surface = surface,
            .device = g_device,
            .queue = queue,
            .pipeline = pipeline,
            .bgl = bgl,
            .bind_group = bind_group,
            .inst_buf = inst_buf,
            .inst_cap = INIT_RECT_CAP,
            .uni_buf = uni_buf,
            .atlas = atlas,
            .atlas_tex = atlas_tex,
            .sampler = sampler,
            .t_pipeline = t_pipeline,
            .t_bind_group = t_bind_group,
            .t_uni_buf = t_uni_buf,
            .t_vbuf = t_vbuf,
            .t_vbuf_cap = INIT_VBUF_BYTES,
            .i_pipeline = i_pipeline,
            .i_bgl = i_bgl,
            .i_uni_buf = i_uni_buf,
            .i_vbuf = i_vbuf,
            .i_vbuf_cap = INIT_VBUF_BYTES,
            .p_pipeline = p_pipeline,
            .p_bind_group = p_bind_group,
            .p_inst_buf = p_inst_buf,
            .p_inst_cap = INIT_RECT_CAP,
            .clip_bgl = clip_bgl,
            .clip_buf = clip_buf,
            .clip_cap = INIT_CLIP_CAP,
            .clip_bind_group = clip_bind_group,
            .texture_cache = std.StringHashMap(CachedTexture).init(allocator),
            .surface_format = surface_format,
            .render_target = render_target,
            .render_view = render_view,
        };
    }

    fn appendTextRecursive(
        self: *WgpuBackend,
        registry: *reg.UIRegistry,
        store: *const props.PropertyStore,
        node_id: reg.NodeId,
        clip_in: renderer_mod.Clip,
        current_z: f32,
        global_order: *u32,
        t_verts: *std.array_list.Managed(TextVertex),
        batches: *std.array_list.Managed(DrawBatch),
        clips: *renderer_mod.ClipTable,
    ) void {
        const node_opt = registry.getNode(node_id);
        if (node_opt == null) return;
        const node = node_opt.?;
        const g = node.geometry;

        // Same clip computation as the box bake (renderer.clipForChildren): it
        // intersects with the inherited clip — never widens it — and interns the
        // rounded part into the same table, so glyphs and boxes clip identically.
        const next_clip = renderer_mod.clipForChildren(store, node_id, renderer_mod.snapGeometry(g, self.scale), clip_in);
        const glyph_clip = [4]f32{ next_clip.rect.x, next_clip.rect.y, next_clip.rect.w, next_clip.rect.h };
        const glyph_clip_id = renderer_mod.internClip(clips, next_clip);

        const z_val = if (store.getStyle(node_id, .z_index)) |val| val.number else current_z;

        if (node.node_type == .text) {
            const start_verts = t_verts.items.len;
            if (store.getTextContent(node_id)) |content| {
                const target_size = if (store.getStyle(node_id, .font_size)) |fs| fs.dimension.value else 16.0;

                var cr: f32 = 1.0;
                var cg: f32 = 1.0;
                var cb: f32 = 1.0;
                var ca: f32 = 1.0;
                if (store.getStyle(node_id, .color)) |c| {
                    cr = c.color.r;
                    cg = c.color.g;
                    cb = c.color.b;
                    ca = c.color.a;
                }
                const c_arr = [4]f32{ cr, cg, cb, ca };

                var text_align: enum { left, center, right } = .left;
                if (store.getStyle(node_id, .text_align)) |ta| {
                    if (ta == .keyword) {
                        if (ta.keyword == .center) text_align = .center;
                        if (ta.keyword == .right) text_align = .right;
                    }
                }

                const physical_size = @round(target_size * self.scale);

                // Every vertical decision comes from one place (text.verticalLayout):
                // the block's offset in the box and the baseline that centers the cap
                // band in its slot, for the face the layout actually measured with —
                // a bold or mono label has its own cap height.
                const num_lines: usize = if (node.text_layout) |tl| tl.lines.items.len else 1;
                const face: u32 = if (node.text_layout) |tl| tl.preferred_font else 0;
                const lh_factor: f32 = if (node.text_layout) |tl|
                    tl.line_height_factor
                else if (store.getStyle(node_id, .line_height)) |v|
                    (if (v == .number) text.sanitizeLineHeight(v.number) else text.LINE_HEIGHT_FACTOR)
                else
                    text.LINE_HEIGHT_FACTOR;
                const vl = self.atlas.verticalLayoutWith(face, target_size, g.height, num_lines, lh_factor);
                const line_height = vl.line_height;
                var current_y = g.y + vl.baseline;
                var icon_baseline_y = g.y + vl.icon_baseline;

                // Emits quads for an already-shaped run at the pen (origin_x, baseline_y).
                // Shaping is done once and cached on the layout (ensureShaped) — this
                // hot path only looks up rasterized glyphs and appends vertices.
                const Draw = struct {
                    fn run(be: *WgpuBackend, verts: anytype, glyphs: []const text.ShapedGlyph, physical_sz: f32, origin_x: f32, baseline_y: f32, icon_baseline: f32, clip: anytype, clip_id: f32, col: anytype) void {
                        // The pen advances in exact physical px and only *snaps* when a
                        // quad is emitted. Rounding each advance instead (the obvious
                        // way to keep glyphs on whole pixels) accumulates: over a label
                        // the run drifts several px wide of the width the layout
                        // measured, so the box hugs too tight and the tail is clipped.
                        var pen_x_phys = origin_x * be.scale;
                        const baseline_y_phys = @round(baseline_y * be.scale);
                        const icon_baseline_phys = @round(icon_baseline * be.scale);
                        for (glyphs) |sg| {
                            const gl = be.atlas.getGlyph(sg.font_index, sg.glyph_id, physical_sz) orelse {
                                pen_x_phys += sg.x_advance * be.scale;
                                continue;
                            };
                            if (gl.w != 0 and gl.h != 0) {
                                const inv_scale = 1.0 / be.scale;
                                const is_icon = if (be.atlas.icon_font_index) |ifi| sg.font_index == ifi else false;
                                const x0_phys = @round(pen_x_phys) + @round(sg.x_offset * be.scale) + gl.ox;
                                // Icons sit on a baseline shifted so the em-box midline
                                // lands on the slot center; text uses the text baseline.
                                const base = if (is_icon) icon_baseline_phys else baseline_y_phys;
                                const y0_phys = base - @round(sg.y_offset * be.scale) + gl.oy;
                                const x1_phys = x0_phys + @as(f32, @floatFromInt(gl.w));
                                const y1_phys = y0_phys + @as(f32, @floatFromInt(gl.h));

                                const x0 = x0_phys * inv_scale;
                                const y0 = y0_phys * inv_scale;
                                const x1 = x1_phys * inv_scale;
                                const y1 = y1_phys * inv_scale;
                                verts.appendSlice(&.{
                                    .{ .pos = .{ x0, y0 }, .uv = .{ gl.s0, gl.t0 }, .clip = clip, .color = col, .clip_id = clip_id },
                                    .{ .pos = .{ x1, y0 }, .uv = .{ gl.s1, gl.t0 }, .clip = clip, .color = col, .clip_id = clip_id },
                                    .{ .pos = .{ x0, y1 }, .uv = .{ gl.s0, gl.t1 }, .clip = clip, .color = col, .clip_id = clip_id },
                                    .{ .pos = .{ x0, y1 }, .uv = .{ gl.s0, gl.t1 }, .clip = clip, .color = col, .clip_id = clip_id },
                                    .{ .pos = .{ x1, y0 }, .uv = .{ gl.s1, gl.t0 }, .clip = clip, .color = col, .clip_id = clip_id },
                                    .{ .pos = .{ x1, y1 }, .uv = .{ gl.s1, gl.t1 }, .clip = clip, .color = col, .clip_id = clip_id },
                                }) catch {};
                            }
                            pen_x_phys += sg.x_advance * be.scale;
                        }
                    }
                };

                if (node.text_layout) |layout| {
                    self.atlas.ensureShaped(layout, content); // shapes once; no-op afterwards
                    for (layout.lines.items) |line| {
                        var t_x: f32 = g.x;
                        // A line wider than its box (no-wrap text with min-width:0
                        // or max-width) overflows towards the END, as in CSS: the
                        // alignment slack never goes negative, so the start of the
                        // text stays inside the box.
                        const slack = @max(g.width - line.width, 0);
                        if (text_align == .center) {
                            t_x += slack / 2.0;
                        } else if (text_align == .right) {
                            t_x += slack;
                        }
                        const glyphs = layout.shaped.items[line.glyph_start .. line.glyph_start + line.glyph_count];
                        Draw.run(self, t_verts, glyphs, physical_size, t_x, current_y, icon_baseline_y, glyph_clip, glyph_clip_id, c_arr);
                        current_y += line_height;
                        icon_baseline_y += line_height;
                    }
                } else {
                    // No cached layout (e.g. the atlas was absent during measurement):
                    // shape inline this frame as a fallback.
                    var shaped = std.array_list.Managed(text.ShapedGlyph).init(self.allocator);
                    defer shaped.deinit();
                    const pref = if (store.getStyle(node_id, .font_role)) |v|
                        (if (v == .number) self.atlas.fontIndexForRole(text.roleFromOrdinal(v.number)) else 0)
                    else
                        0;
                    const ls: f32 = if (store.getStyle(node_id, .letter_spacing)) |v|
                        (if (v == .number) v.number else 0)
                    else
                        0;
                    self.atlas.shapePref(content, target_size, pref, ls, &shaped) catch {};
                    Draw.run(self, t_verts, shaped.items, physical_size, g.x, current_y, icon_baseline_y, glyph_clip, glyph_clip_id, c_arr);
                }
            }

            const added = t_verts.items.len - start_verts;
            if (added > 0) {
                batches.append(.{
                    .batch_type = .text,
                    .z_index = z_val,
                    .order = global_order.*,
                    .start_idx = @intCast(start_verts),
                    .count = @intCast(added),
                }) catch {};
                global_order.* += 1;
            }
        }

        var child_id = node.first_child;
        while (child_id != reg.NULL_NODE) {
            self.appendTextRecursive(registry, store, child_id, next_clip, z_val, global_order, t_verts, batches, clips);
            const child_node = registry.getNode(child_id) orelse break;
            child_id = child_node.next_sibling;
        }
    }

    fn getOrLoadTexture(self: *WgpuBackend, path: []const u8) ?wgpu.WGPUBindGroup {
        if (self.texture_cache.get(path)) |cached| {
            return cached.bind_group;
        }

        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;

        // C-style string required by stbi_load
        const c_path = self.allocator.dupeZ(u8, path) catch return null;
        defer self.allocator.free(c_path);

        const img_data = stbi.stbi_load(c_path.ptr, &width, &height, &channels, 4);
        if (img_data == null) return null;
        defer stbi.stbi_image_free(img_data);

        // Reject before any of the size arithmetic below, which is done in
        // `c_int` (i32): `width * height * 4` overflows for any decoded image
        // around ~23000x23000 or larger (2.1B / 4), and a wraparound value then
        // goes straight into `wgpuQueueWriteTexture`'s byte-size argument — a
        // GPU-visible OOB read of `img_data`, not just a corrupt-looking
        // texture. stb_image will actually decode something that large given
        // enough RAM, so `path` pointing at a crafted image (anywhere the app
        // shows user- or network-supplied images) reaches this. 8192 is below
        // every GPU backend's default `maxTextureDimension2D`, so a legitimate
        // image is never affected; this only turns "corrupt upload" into
        // "image fails to load", the same outward behavior as any other
        // decode failure a few lines up.
        const MAX_TEXTURE_DIM: c_int = 8192;
        if (width <= 0 or height <= 0 or width > MAX_TEXTURE_DIM or height > MAX_TEXTURE_DIM) {
            log.warn("getOrLoadTexture: rejecting {d}x{d} image (path={s}) — outside the [1, {d}] bound\n", .{ width, height, path, MAX_TEXTURE_DIM });
            return null;
        }

        // Upload to WGPU Texture
        const tex_desc = wgpu.WGPUTextureDescriptor{
            .nextInChain = null,
            .label = null,
            .usage = wgpu.WGPUTextureUsage_TextureBinding | wgpu.WGPUTextureUsage_CopyDst,
            .dimension = wgpu.WGPUTextureDimension_2D,
            .size = .{ .width = @intCast(width), .height = @intCast(height), .depthOrArrayLayers = 1 },
            .format = wgpu.WGPUTextureFormat_RGBA8Unorm, // stbi returns RGBA by default with 4 channels
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = 0,
            .viewFormats = null,
        };
        const tex = wgpu.wgpuDeviceCreateTexture(self.device, &tex_desc);

        const data_layout = wgpu.WGPUTextureDataLayout{
            .nextInChain = null,
            .offset = 0,
            .bytesPerRow = @intCast(width * 4),
            .rowsPerImage = @intCast(height),
        };
        const write_size = wgpu.WGPUExtent3D{ .width = @intCast(width), .height = @intCast(height), .depthOrArrayLayers = 1 };
        const image_copy_tex = wgpu.WGPUImageCopyTexture{
            .nextInChain = null,
            .texture = tex,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = wgpu.WGPUTextureAspect_All,
        };

        wgpu.wgpuQueueWriteTexture(self.queue, &image_copy_tex, img_data, @intCast(width * height * 4), &data_layout, &write_size);

        const view = wgpu.wgpuTextureCreateView(tex, &.{
            .nextInChain = null,
            .label = null,
            .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
            .dimension = wgpu.WGPUTextureViewDimension_2D,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
            .aspect = wgpu.WGPUTextureAspect_All,
        });

        // Reuse the engine's shared linear-clamp sampler (created once at init).
        // Previously this created a fresh sampler per image and never released it.
        const bg_entries = [_]wgpu.WGPUBindGroupEntry{
            .{ .nextInChain = null, .binding = 0, .buffer = self.i_uni_buf, .offset = 0, .size = @sizeOf(ImageUniforms), .sampler = null, .textureView = null },
            .{ .nextInChain = null, .binding = 1, .buffer = null, .offset = 0, .size = 0, .sampler = self.sampler, .textureView = null },
            .{ .nextInChain = null, .binding = 2, .buffer = null, .offset = 0, .size = 0, .sampler = null, .textureView = view },
        };
        const bind_group = wgpu.wgpuDeviceCreateBindGroup(self.device, &.{
            .nextInChain = null,
            .label = null,
            .layout = self.i_bgl,
            .entryCount = 3,
            .entries = &bg_entries,
        });

        const path_owned = self.allocator.dupe(u8, path) catch return null;
        self.texture_cache.put(path_owned, .{ .texture = tex, .view = view, .bind_group = bind_group }) catch return null;

        return bind_group;
    }

    fn safeRelease(ptr: anytype, releaseFn: anytype) void {
        if (ptr) |p| releaseFn(p);
    }

    /// Releases the per-backend GPU resources. The wgpu `instance`/`device`/`queue`
    /// are process-global singletons (shared across engines via g_device) and are
    /// intentionally left alive for reuse — releasing them here would break a second
    /// engine. Everything created per-backend (surface, pipelines, buffers, bind
    /// groups, textures/views, and the image texture cache) is released so repeated
    /// engine create/destroy doesn't leak GPU memory.
    pub fn deinit(self: *WgpuBackend) void {
        var it = self.texture_cache.iterator();
        while (it.next()) |e| {
            wgpu.wgpuBindGroupRelease(e.value_ptr.bind_group);
            wgpu.wgpuTextureViewRelease(e.value_ptr.view);
            wgpu.wgpuTextureRelease(e.value_ptr.texture);
            self.allocator.free(e.key_ptr.*);
        }
        self.texture_cache.deinit();

        safeRelease(self.render_view, wgpu.wgpuTextureViewRelease);
        safeRelease(self.render_target, wgpu.wgpuTextureRelease);

        safeRelease(self.i_vbuf, wgpu.wgpuBufferRelease);
        safeRelease(self.i_uni_buf, wgpu.wgpuBufferRelease);
        safeRelease(self.i_bgl, wgpu.wgpuBindGroupLayoutRelease);
        safeRelease(self.i_pipeline, wgpu.wgpuRenderPipelineRelease);

        safeRelease(self.t_vbuf, wgpu.wgpuBufferRelease);
        safeRelease(self.t_uni_buf, wgpu.wgpuBufferRelease);
        safeRelease(self.t_bind_group, wgpu.wgpuBindGroupRelease);
        safeRelease(self.t_pipeline, wgpu.wgpuRenderPipelineRelease);

        safeRelease(self.atlas_tex, wgpu.wgpuTextureRelease);
        safeRelease(self.sampler, wgpu.wgpuSamplerRelease);

        safeRelease(self.p_bind_group, wgpu.wgpuBindGroupRelease);
        safeRelease(self.clip_bind_group, wgpu.wgpuBindGroupRelease);
        safeRelease(self.clip_buf, wgpu.wgpuBufferRelease);
        safeRelease(self.clip_bgl, wgpu.wgpuBindGroupLayoutRelease);
        safeRelease(self.p_inst_buf, wgpu.wgpuBufferRelease);
        safeRelease(self.p_pipeline, wgpu.wgpuRenderPipelineRelease);

        safeRelease(self.uni_buf, wgpu.wgpuBufferRelease);
        safeRelease(self.inst_buf, wgpu.wgpuBufferRelease);
        safeRelease(self.bind_group, wgpu.wgpuBindGroupRelease);
        safeRelease(self.bgl, wgpu.wgpuBindGroupLayoutRelease);
        safeRelease(self.pipeline, wgpu.wgpuRenderPipelineRelease);

        safeRelease(self.surface, wgpu.wgpuSurfaceRelease);
    }

    pub fn resize(self: *WgpuBackend, width: u32, height: u32, scale: f32) void {
        if (self.is_headless) return;
        self.width = width;
        self.height = height;
        self.scale = scale;
        const pw: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) * scale));
        const ph: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * scale));

        var caps: wgpu.WGPUSurfaceCapabilities = std.mem.zeroes(wgpu.WGPUSurfaceCapabilities);
        wgpu.wgpuSurfaceGetCapabilities(self.surface, g_adapter, &caps);
        defer wgpu.wgpuSurfaceCapabilitiesFreeMembers(caps);

        const alpha = if (caps.alphaModeCount > 0) caps.alphaModes[0] else wgpu.WGPUCompositeAlphaMode_Auto;
        const present = pickPresentMode(caps);

        wgpu.wgpuSurfaceConfigure(self.surface, &wgpu.WGPUSurfaceConfiguration{
            .nextInChain = null,
            .device = self.device,
            .format = self.surface_format,
            .usage = wgpu.WGPUTextureUsage_RenderAttachment,
            .viewFormatCount = 0,
            .viewFormats = null,
            .alphaMode = alpha,
            .width = pw,
            .height = ph,
            .presentMode = present,
        });
    }

    /// Grows the instance storage buffer to hold at least `needed_rects`, doubling
    /// capacity until it fits. Because `bind_group` references `inst_buf`, the bind
    /// group is rebuilt against the new buffer. No-op when the current buffer fits.
    fn ensureInstBuf(self: *WgpuBackend, needed_rects: usize) void {
        if (needed_rects <= self.inst_cap) return;
        var new_cap = if (self.inst_cap == 0) needed_rects else self.inst_cap;
        while (new_cap < needed_rects) new_cap *= 2;

        if (self.inst_buf != null) wgpu.wgpuBufferRelease(self.inst_buf);
        self.inst_buf = wgpu.wgpuDeviceCreateBuffer(self.device, &.{
            .nextInChain = null,
            .label = "Instance Buffer",
            .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(renderer_mod.RectPrimitive) * new_cap,
            .mappedAtCreation = 0,
        });

        if (self.bind_group != null) wgpu.wgpuBindGroupRelease(self.bind_group);
        const bg_entries = [_]wgpu.WGPUBindGroupEntry{
            .{ .nextInChain = null, .binding = 0, .buffer = self.inst_buf, .offset = 0, .size = wgpu.WGPU_WHOLE_SIZE, .sampler = null, .textureView = null },
            .{ .nextInChain = null, .binding = 1, .buffer = self.uni_buf, .offset = 0, .size = 16, .sampler = null, .textureView = null },
        };
        self.bind_group = wgpu.wgpuDeviceCreateBindGroup(self.device, &.{
            .nextInChain = null,
            .label = null,
            .layout = self.bgl,
            .entryCount = 2,
            .entries = &bg_entries,
        });
        self.inst_cap = new_cap;
    }

    /// Grows the rounded-clip table buffer (and rebuilds its bind group).
    fn ensureClipBuf(self: *WgpuBackend, needed: usize) void {
        if (needed <= self.clip_cap) return;
        var new_cap = if (self.clip_cap == 0) needed else self.clip_cap;
        while (new_cap < needed) new_cap *= 2;
        if (self.clip_buf != null) wgpu.wgpuBufferRelease(self.clip_buf);
        self.clip_buf = createClipBuffer(self.device, new_cap);
        if (self.clip_bind_group != null) wgpu.wgpuBindGroupRelease(self.clip_bind_group);
        self.clip_bind_group = createClipBindGroup(self.device, self.clip_bgl, self.clip_buf);
        self.clip_cap = new_cap;
    }

    /// `ensureInstBuf` for the path pipeline's segment storage buffer.
    fn ensurePathBuf(self: *WgpuBackend, needed_segs: usize) void {
        if (needed_segs <= self.p_inst_cap) return;
        var new_cap = if (self.p_inst_cap == 0) needed_segs else self.p_inst_cap;
        while (new_cap < needed_segs) new_cap *= 2;

        if (self.p_inst_buf != null) wgpu.wgpuBufferRelease(self.p_inst_buf);
        self.p_inst_buf = wgpu.wgpuDeviceCreateBuffer(self.device, &.{
            .nextInChain = null,
            .label = "Path Instance Buffer",
            .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(renderer_mod.PathSegPrim) * new_cap,
            .mappedAtCreation = 0,
        });

        if (self.p_bind_group != null) wgpu.wgpuBindGroupRelease(self.p_bind_group);
        const bg_entries = [_]wgpu.WGPUBindGroupEntry{
            .{ .nextInChain = null, .binding = 0, .buffer = self.p_inst_buf, .offset = 0, .size = wgpu.WGPU_WHOLE_SIZE, .sampler = null, .textureView = null },
            .{ .nextInChain = null, .binding = 1, .buffer = self.uni_buf, .offset = 0, .size = 16, .sampler = null, .textureView = null },
        };
        self.p_bind_group = wgpu.wgpuDeviceCreateBindGroup(self.device, &.{
            .nextInChain = null,
            .label = null,
            .layout = self.bgl,
            .entryCount = 2,
            .entries = &bg_entries,
        });
        self.p_inst_cap = new_cap;
    }

    /// Grows a plain vertex buffer (no bind group references it) to hold at least
    /// `needed_bytes`, doubling capacity until it fits. No-op when it already fits.
    fn ensureVertexBuffer(self: *WgpuBackend, buf: *wgpu.WGPUBuffer, cap_bytes: *usize, needed_bytes: usize) void {
        if (needed_bytes <= cap_bytes.*) return;
        var new_cap = if (cap_bytes.* == 0) needed_bytes else cap_bytes.*;
        while (new_cap < needed_bytes) new_cap *= 2;
        if (buf.* != null) wgpu.wgpuBufferRelease(buf.*);
        buf.* = wgpu.wgpuDeviceCreateBuffer(self.device, &.{
            .nextInChain = null,
            .label = null,
            .usage = wgpu.WGPUBufferUsage_Vertex | wgpu.WGPUBufferUsage_CopyDst,
            .size = new_cap,
            .mappedAtCreation = 0,
        });
        cap_bytes.* = new_cap;
    }

    pub fn renderFrame(
        self: *WgpuBackend,
        registry: *reg.UIRegistry,
        store: *const props.PropertyStore,
        prims: []const renderer_mod.RectPrimitive,
        image_prims: []const renderer_mod.ImagePrimitive,
        path_prims: []const renderer_mod.PathSegPrim,
        /// The bake's rounded-clip table (`renderer.bakeRegistry`'s `clip_out`).
        clips: []const renderer_mod.ClipEntry,
    ) !void {
        // Draw all primitives in the inst_buf
        const fz = prof.zone(@src());
        defer fz.end();
        const P = self.prof_on;
        var mark: i64 = if (P) profNowNs() else 0;

        var view: wgpu.WGPUTextureView = null;
        var surface_tex: wgpu.WGPUSurfaceTexture = undefined;

        const sz = prof.zoneNamed("surface.acquire");
        if (self.is_headless) {
            view = self.render_view;
        } else {
            wgpu.wgpuSurfaceGetCurrentTexture(self.surface, &surface_tex);
            if (surface_tex.status != wgpu.WGPUSurfaceGetCurrentTextureStatus_Success) {
                sz.end();
                return;
            }
            view = wgpu.wgpuTextureCreateView(surface_tex.texture, &.{
                .nextInChain = null,
                .label = null,
                .format = self.surface_format,
                .dimension = wgpu.WGPUTextureViewDimension_2D,
                .baseMipLevel = 0,
                .mipLevelCount = 1,
                .baseArrayLayer = 0,
                .arrayLayerCount = 1,
                .aspect = wgpu.WGPUTextureAspect_All,
            });
        }
        sz.end();

        if (P) {
            const n = profNowNs();
            self.prof_surface_ns = n - mark;
            mark = n;
        }

        // --- Upload Instances for Rects ---
        // Guard widened for path nodes: a frame with no rects but with images/paths/text
        // still has to run the encode below (a real app always has the root box,
        // but a headless path-only bake does not).
        if (prims.len > 0 or image_prims.len > 0 or path_prims.len > 0) {
            // Grow the instance storage buffer if this frame has more rects than it
            // can hold (each node may emit body + shadow + focus rects). Nothing is
            // dropped — the buffer (and its bind group) is resized on demand.
            self.ensureInstBuf(prims.len);
            const rect_count: usize = prims.len;
            // Upload to storage buffer
            const rect_bytes: usize = @as(usize, rect_count) * @as(usize, @sizeOf(renderer_mod.RectPrimitive));
            if (rect_bytes > 0) wgpu.wgpuQueueWriteBuffer(self.queue, self.inst_buf, 0, prims.ptr, rect_bytes);

            // Upload the flattened path segments (shared viewport uniform below).
            self.ensurePathBuf(path_prims.len);
            const path_bytes: usize = @as(usize, path_prims.len) * @as(usize, @sizeOf(renderer_mod.PathSegPrim));
            if (path_bytes > 0) wgpu.wgpuQueueWriteBuffer(self.queue, self.p_inst_buf, 0, path_prims.ptr, path_bytes);

            // Upload viewport sizes
            const vp = [_]f32{ @floatFromInt(self.width), @floatFromInt(self.height), 0.0, 0.0 };
            wgpu.wgpuQueueWriteBuffer(self.queue, self.uni_buf, 0, &vp, @sizeOf(f32) * 4);

            var batches = std.array_list.Managed(DrawBatch).init(self.allocator);
            defer batches.deinit();
            var global_order: u32 = 0;

            // Generate rect batches
            var r_start: u32 = 0;
            if (prims.len > 0) {
                var current_z = prims[0].z_index;
                for (prims, 0..) |p, i| {
                    if (p.z_index != current_z) {
                        batches.append(.{ .batch_type = .rect, .z_index = current_z, .order = global_order, .start_idx = r_start, .count = @as(u32, @intCast(i)) - r_start }) catch {};
                        r_start = @as(u32, @intCast(i));
                        current_z = p.z_index;
                        global_order += 1;
                    }
                }
                batches.append(.{ .batch_type = .rect, .z_index = current_z, .order = global_order, .start_idx = r_start, .count = @as(u32, @intCast(prims.len)) - r_start }) catch {};
                global_order += 1;
            }

            // Generate image batches
            for (image_prims, 0..) |img, i| {
                batches.append(.{ .batch_type = .image, .z_index = img.z_index, .order = global_order, .start_idx = @intCast(i), .count = 1, .img_path = img.src_path }) catch {};
                global_order += 1;
            }

            // Generate path batches — segments arrive z-sorted from the bake, so
            // split on z change exactly like rects (one instanced draw per run).
            if (path_prims.len > 0) {
                var p_start: u32 = 0;
                var p_z = path_prims[0].z_index;
                for (path_prims, 0..) |p, i| {
                    if (p.z_index != p_z) {
                        batches.append(.{ .batch_type = .path, .z_index = p_z, .order = global_order, .start_idx = p_start, .count = @as(u32, @intCast(i)) - p_start }) catch {};
                        p_start = @as(u32, @intCast(i));
                        p_z = p.z_index;
                        global_order += 1;
                    }
                }
                batches.append(.{ .batch_type = .path, .z_index = p_z, .order = global_order, .start_idx = p_start, .count = @as(u32, @intCast(path_prims.len)) - p_start }) catch {};
                global_order += 1;
            }

            // --- Upload Text Verts ---
            var t_verts = std.array_list.Managed(TextVertex).init(self.allocator);
            defer t_verts.deinit();

            // Iterate over registry nodes to render text nodes recursively
            // The rounded-clip table: the box bake's entries, plus any the text pass
            // adds (interning by value keeps the bake's ids valid).
            var clip_table = renderer_mod.ClipTable.init(self.allocator);
            defer clip_table.deinit();
            clip_table.appendSlice(clips) catch {};
            if (clip_table.items.len == 0) clip_table.append(.{}) catch {};
            const initial_clip = renderer_mod.unclipped;
            for (registry.nodes.items) |node| {
                if (node.parent == reg.NULL_NODE) {
                    self.appendTextRecursive(registry, store, node.id, initial_clip, 0.0, &global_order, &t_verts, &batches, &clip_table);
                }
            }
            // Upload the finished clip table (group 1 of every pipeline).
            self.ensureClipBuf(clip_table.items.len);
            wgpu.wgpuQueueWriteBuffer(self.queue, self.clip_buf, 0, clip_table.items.ptr, clip_table.items.len * @sizeOf(renderer_mod.ClipEntry));
            // Building the text verts may have rasterized new glyphs into the atlas;
            // re-upload it to the GPU before this frame samples it.
            if (self.atlas.dirty) {
                wgpu.wgpuQueueWriteTexture(self.queue, &.{ .nextInChain = null, .texture = self.atlas_tex, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = 0 }, .aspect = wgpu.WGPUTextureAspect_All }, self.atlas.pixels.ptr, self.atlas.pixels.len, &.{ .nextInChain = null, .offset = 0, .bytesPerRow = text.ATLAS_WIDTH, .rowsPerImage = text.ATLAS_HEIGHT }, &.{ .width = text.ATLAS_WIDTH, .height = text.ATLAS_HEIGHT, .depthOrArrayLayers = 1 });
                self.atlas.dirty = false;
            }
            if (t_verts.items.len > 0) {
                const t_bytes: usize = @as(usize, t_verts.items.len) * @as(usize, @sizeOf(TextVertex));
                self.ensureVertexBuffer(&self.t_vbuf, &self.t_vbuf_cap, t_bytes);
                wgpu.wgpuQueueWriteBuffer(self.queue, self.t_vbuf, 0, t_verts.items.ptr, t_bytes);
            }
            const t_uniforms = TextUniforms{
                .vp_w = @floatFromInt(self.width),
                .vp_h = @floatFromInt(self.height),
                .cr = 1.0,
                .cg = 1.0,
                .cb = 1.0,
                .ca = 1.0,
                .clip_x = -10000.0,
                .clip_y = -10000.0,
                .clip_w = 20000.0,
                .clip_h = 20000.0,
                ._pad1 = 0.0,
                ._pad2 = 0.0,
            };
            wgpu.wgpuQueueWriteBuffer(self.queue, self.t_uni_buf, 0, &t_uniforms, @sizeOf(TextUniforms));

            // --- Upload Image Data ---
            var i_verts = std.array_list.Managed(ImageVertex).init(self.allocator);
            defer i_verts.deinit();

            for (image_prims) |img| {
                const clip = [_]f32{ img.clip_rect_x, img.clip_rect_y, img.clip_rect_w, img.clip_rect_h };
                const op = img.opacity;
                i_verts.appendSlice(&.{
                    .{ .pos = .{ img.x, img.y }, .uv = .{ 0.0, 0.0 }, .clip = clip, .opacity = op, .clip_id = img.clip_id },
                    .{ .pos = .{ img.x + img.width, img.y }, .uv = .{ 1.0, 0.0 }, .clip = clip, .opacity = op, .clip_id = img.clip_id },
                    .{ .pos = .{ img.x, img.y + img.height }, .uv = .{ 0.0, 1.0 }, .clip = clip, .opacity = op, .clip_id = img.clip_id },
                    .{ .pos = .{ img.x, img.y + img.height }, .uv = .{ 0.0, 1.0 }, .clip = clip, .opacity = op, .clip_id = img.clip_id },
                    .{ .pos = .{ img.x + img.width, img.y }, .uv = .{ 1.0, 0.0 }, .clip = clip, .opacity = op, .clip_id = img.clip_id },
                    .{ .pos = .{ img.x + img.width, img.y + img.height }, .uv = .{ 1.0, 1.0 }, .clip = clip, .opacity = op, .clip_id = img.clip_id },
                }) catch continue;
            }

            if (i_verts.items.len > 0) {
                const i_bytes: usize = @as(usize, i_verts.items.len) * @as(usize, @sizeOf(ImageVertex));
                self.ensureVertexBuffer(&self.i_vbuf, &self.i_vbuf_cap, i_bytes);
                wgpu.wgpuQueueWriteBuffer(self.queue, self.i_vbuf, 0, i_verts.items.ptr, i_bytes);
            }

            const i_uniforms = ImageUniforms{
                .vp_w = @floatFromInt(self.width),
                .vp_h = @floatFromInt(self.height),
                ._pad1 = 0.0,
                ._pad2 = 0.0,
            };
            wgpu.wgpuQueueWriteBuffer(self.queue, self.i_uni_buf, 0, &i_uniforms, @sizeOf(ImageUniforms));

            // Warm the texture cache BEFORE the render pass: a cache miss does a
            // blocking stbi_load + texture create/upload, which must not happen
            // between begin/endRenderPass. After this, the in-pass lookups are hits.
            for (image_prims) |img| {
                if (img.src_path.len > 0) _ = self.getOrLoadTexture(img.src_path);
            }

            // Sort batches by z_index, then by original order
            const SortFn = struct {
                fn lessThan(ctx: void, a: DrawBatch, b: DrawBatch) bool {
                    _ = ctx;
                    if (a.z_index != b.z_index) return a.z_index < b.z_index;
                    return a.order < b.order;
                }
            };
            std.mem.sort(DrawBatch, batches.items, {}, SortFn.lessThan);

            if (P) {
                const n = profNowNs();
                self.prof_build_ns = n - mark;
                mark = n;
            }

            // --- Render Pass ---
            const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, &.{ .nextInChain = null, .label = null });
            var att = wgpu.WGPURenderPassColorAttachment{
                .nextInChain = null,
                .view = view,
                .resolveTarget = null,
                .loadOp = wgpu.WGPULoadOp_Clear,
                .storeOp = wgpu.WGPUStoreOp_Store,
                .clearValue = .{ .r = 1.0, .g = 0.0, .b = 1.0, .a = 1.0 },
                .depthSlice = wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
            };
            const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &.{
                .nextInChain = null,
                .label = null,
                .colorAttachmentCount = 1,
                .colorAttachments = &att,
                .depthStencilAttachment = null,
                .occlusionQuerySet = null,
                .timestampWrites = null,
            });

            // Initialize buffer bindings (they stay bound unless changed, but since we switch pipelines, we must rebind as needed)
            var current_pipeline: ?DrawBatchType = null;

            for (batches.items) |batch| {
                switch (batch.batch_type) {
                    .rect => {
                        if (current_pipeline == null or current_pipeline.? != .rect) {
                            wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
                            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, self.clip_bind_group, 0, null);
                            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group, 0, null);
                            current_pipeline = .rect;
                        }
                        wgpu.wgpuRenderPassEncoderDraw(pass, 6, batch.count, 0, batch.start_idx);
                    },
                    .text => {
                        if (current_pipeline == null or current_pipeline.? != .text) {
                            wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.t_pipeline);
                            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, self.clip_bind_group, 0, null);
                            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.t_bind_group, 0, null);
                            wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.t_vbuf, 0, @as(usize, t_verts.items.len) * @as(usize, @sizeOf(TextVertex)));
                            current_pipeline = .text;
                        }
                        wgpu.wgpuRenderPassEncoderDraw(pass, batch.count, 1, batch.start_idx, 0);
                    },
                    .image => {
                        if (current_pipeline == null or current_pipeline.? != .image) {
                            wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.i_pipeline);
                            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, self.clip_bind_group, 0, null);
                            wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.i_vbuf, 0, @as(usize, i_verts.items.len) * @as(usize, @sizeOf(ImageVertex)));
                            current_pipeline = .image;
                        }
                        if (batch.img_path) |path| {
                            if (self.getOrLoadTexture(path)) |bg| {
                                wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, bg, 0, null);
                                wgpu.wgpuRenderPassEncoderDraw(pass, 6, 1, batch.start_idx * 6, 0);
                            }
                        }
                    },
                    .path => {
                        if (current_pipeline == null or current_pipeline.? != .path) {
                            wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.p_pipeline);
                            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, self.clip_bind_group, 0, null);
                            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.p_bind_group, 0, null);
                            current_pipeline = .path;
                        }
                        // 6 verts (a quad) per instance, one instance per segment.
                        wgpu.wgpuRenderPassEncoderDraw(pass, 6, batch.count, 0, batch.start_idx);
                    },
                }
            }

            wgpu.wgpuRenderPassEncoderEnd(pass);
            wgpu.wgpuRenderPassEncoderRelease(pass);
            const cmd = wgpu.wgpuCommandEncoderFinish(encoder, &.{ .nextInChain = null, .label = null });
            wgpu.wgpuCommandEncoderRelease(encoder);
            if (P) {
                const n = profNowNs();
                self.prof_encode_ns = n - mark;
                mark = n;
            }
            wgpu.wgpuQueueSubmit(self.queue, 1, &cmd);
            wgpu.wgpuCommandBufferRelease(cmd);
            if (P) {
                const n = profNowNs();
                self.prof_submit_ns = n - mark;
                mark = n;
            }
        } else if (P) {
            self.prof_build_ns = 0;
            self.prof_encode_ns = 0;
            self.prof_submit_ns = 0;
        }

        if (!self.is_headless) {
            const pz = prof.zoneNamed("present");
            defer pz.end();
            wgpu.wgpuSurfacePresent(self.surface);
            wgpu.wgpuTextureViewRelease(view);
            wgpu.wgpuTextureRelease(surface_tex.texture);
        }
        if (P) self.prof_present_ns = profNowNs() - mark;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

/// Test-only mirror of the shader's square-path per-side border decision, run over
/// the geometry the vertex stage actually produces. It reproduces both halves of the
/// Regression path — the quad's `expand` and the fragment's on-side test — so a
/// change to either in the WGSL that reopens the bug shows up here. Must track the
/// `vs`/`fs` source above; it is short on purpose so drift is easy to spot.
fn borderAlphaAt(prim: renderer_mod.RectPrimitive, sx: f32, sy: f32) f32 {
    const is_shadow = prim.is_shadow > 0.5;
    const expand: f32 = if (is_shadow) prim.shadow_blur * 0.5 + 1.0 else 0.0;
    const quad_w = prim.width + expand * 2.0;
    const quad_h = prim.height + expand * 2.0;
    // sx/sy in [0,1] across the quad → the same `local` the fragment sees.
    const local_x = sx * quad_w - (expand + prim.width * 0.5);
    const local_y = sy * quad_h - (expand + prim.height * 0.5);
    const half_x = prim.width * 0.5;
    const half_y = prim.height * 0.5;
    const on_l = prim.border_left > 0.0 and local_x < -half_x + prim.border_left;
    const on_r = prim.border_right > 0.0 and local_x > half_x - prim.border_right;
    const on_t = prim.border_top > 0.0 and local_y < -half_y + prim.border_top;
    const on_b = prim.border_bottom > 0.0 and local_y > half_y - prim.border_bottom;
    return if (on_l or on_r or on_t or on_b) 1.0 else 0.0;
}

test "A body with only border_top paints no skirt on the zero-width sides" {
    // The regression: expand grew every quad by 1px, so `local` overhung `half` and
    // the zero-width sides lit up a 1px border. Sample the whole quad and assert the
    // only lit fragments are the intended top band.
    const prim = renderer_mod.RectPrimitive{
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 40,
        .border_top = 4,
        .border_color_a = 1,
    };
    const H: f32 = 40;
    const steps = 200;
    var iy: usize = 0;
    while (iy <= steps) : (iy += 1) {
        const sy = @as(f32, @floatFromInt(iy)) / steps;
        var ix: usize = 0;
        while (ix <= steps) : (ix += 1) {
            const sx = @as(f32, @floatFromInt(ix)) / steps;
            const b_a = borderAlphaAt(prim, sx, sy);
            // local_y for this sample (no expand on a body).
            const local_y = sy * H - H * 0.5;
            const in_top_band = local_y < -H * 0.5 + 4;
            if (in_top_band) {
                try std.testing.expectEqual(@as(f32, 1.0), b_a);
            } else {
                try std.testing.expectEqual(@as(f32, 0.0), b_a); // no skirt anywhere else
            }
        }
    }
}

test "A uniform border still paints all four sides at the exact width, no +1px" {
    const prim = renderer_mod.RectPrimitive{
        .x = 0,
        .y = 0,
        .width = 60,
        .height = 60,
        .border_top = 2,
        .border_right = 2,
        .border_bottom = 2,
        .border_left = 2,
        .border_color_a = 1,
    };
    // Just inside each edge (< 2px) is border; the interior (> 2px in) is not.
    try std.testing.expectEqual(@as(f32, 1.0), borderAlphaAt(prim, 0.0, 0.5)); // left edge
    try std.testing.expectEqual(@as(f32, 1.0), borderAlphaAt(prim, 1.0, 0.5)); // right edge
    try std.testing.expectEqual(@as(f32, 1.0), borderAlphaAt(prim, 0.5, 0.0)); // top edge
    try std.testing.expectEqual(@as(f32, 1.0), borderAlphaAt(prim, 0.5, 1.0)); // bottom edge
    try std.testing.expectEqual(@as(f32, 0.0), borderAlphaAt(prim, 0.5, 0.5)); // interior
    // A sample 3px inside the left edge (x = 3/60 = 0.05) is past the 2px border.
    try std.testing.expectEqual(@as(f32, 0.0), borderAlphaAt(prim, 3.0 / 60.0, 0.5));
    // …and 1px in (x = 1/60) is still border — the width is exactly 2, not 3.
    try std.testing.expectEqual(@as(f32, 1.0), borderAlphaAt(prim, 1.0 / 60.0, 0.5));
}

fn loadTestFontForBackend(allocator: std.mem.Allocator) ![]u8 {
    const candidates = [_][]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "C:/Windows/Fonts/arial.ttf",
    };
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for (candidates) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, allocator, .unlimited)) |data| return data else |_| {}
    }
    return error.SkipZigTest;
}

test "BUG: a second engine's init must not steal the shared wgpu instance/adapter/device from the first" {
    // Regression for the crash where maximizing the main window after opening and
    // closing a second Celeris window aborted the whole process with a wgpu-core
    // panic ("Surface[Id(0,1,_)] does not exist"). Root cause: init() created a
    // fresh wgpu.WGPUInstance per engine but unconditionally overwrote the
    // process-global g_adapter/g_device with adapters/devices requested against
    // that per-engine instance. So engine 1's surface (created on engine 1's
    // instance) ended up being passed alongside engine 2's adapter (from a
    // different instance) into wgpu-core, which is invalid and panics. The whole
    // point of g_adapter/g_device being global is that they're a *shared*
    // singleton (see the deinit() doc comment) — every engine must resolve to the
    // same instance/adapter/device, not clobber them on each init.
    const ttf = try loadTestFontForBackend(std.testing.allocator);
    defer std.testing.allocator.free(ttf);
    var atlas = try text.FontAtlas.init(std.testing.allocator, ttf, 16.0);
    defer atlas.deinit();

    var backend1 = WgpuBackend.init(std.testing.allocator, null, 100, 100, 1.0, true, &atlas) catch return error.SkipZigTest;
    defer backend1.deinit();

    var backend2 = WgpuBackend.init(std.testing.allocator, null, 100, 100, 1.0, true, &atlas) catch return error.SkipZigTest;
    defer backend2.deinit();

    try std.testing.expect(backend1.instance == backend2.instance);
    try std.testing.expect(backend1.device == backend2.device);
}

test "The WGSL instance struct matches RectPrimitive field for field" {
    // These bytes are uploaded straight into the storage buffer, so a field added on
    // one side and not the other silently reinterprets every field after it — the
    // colors and radii shift by one slot and the UI renders nonsense. Cheap guard.
    const start = std.mem.indexOf(u8, WGSL, "struct InstanceData {").?;
    const end = std.mem.indexOfPos(u8, WGSL, start, "\n}").?;
    const body = WGSL[start..end];

    var wgsl_fields: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, ": f32")) |at| : (i = at + 1) wgsl_fields += 1;

    const zig_floats = @sizeOf(renderer_mod.RectPrimitive) / @sizeOf(f32);
    try std.testing.expectEqual(zig_floats, wgsl_fields);
    // All-f32 on both sides: no padding surprises between them.
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(renderer_mod.RectPrimitive) % @sizeOf(f32));
    inline for (std.meta.fields(renderer_mod.RectPrimitive)) |f| {
        try std.testing.expect(f.type == f32);
    }
}

/// Index (in f32 slots) of `name` in a WGSL struct body made only of `x: f32` fields.
fn wgslFieldIndex(body: []const u8, name: []const u8) ?usize {
    var idx: usize = 0;
    var it = std.mem.tokenizeAny(u8, body, " ,\n{}");
    while (it.next()) |tok| {
        if (tok.len > 1 and tok[tok.len - 1] == ':') {
            if (std.mem.eql(u8, tok[0 .. tok.len - 1], name)) return idx;
            idx += 1;
        }
    }
    return null;
}

fn wgslStructBody(src: []const u8, header: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, src, header).?;
    const end = std.mem.indexOfPos(u8, src, start, "}").?;
    return src[start + header.len .. end];
}

test "clip_id sits at the same slot in the WGSL structs as in RectPrimitive / PathSegPrim" {
    const rect_body = wgslStructBody(WGSL, "struct InstanceData {");
    try std.testing.expectEqual(@as(usize, @offsetOf(renderer_mod.RectPrimitive, "clip_id") / 4), wgslFieldIndex(rect_body, "clip_id").?);
    const path_body = wgslStructBody(WGSL_PATH, "struct PathInstance {");
    try std.testing.expectEqual(@as(usize, @sizeOf(renderer_mod.PathSegPrim) / 4), blk: {
        var n: usize = 0;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, path_body, i, ": f32")) |at| : (i = at + 1) n += 1;
        break :blk n;
    });
    try std.testing.expectEqual(@as(usize, @offsetOf(renderer_mod.PathSegPrim, "clip_id") / 4), wgslFieldIndex(path_body, "clip_id").?);
}

test "The WGSL clip table matches renderer.ClipEntry (two RoundClips + 2 pad, all f32)" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(renderer_mod.RoundClip));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(renderer_mod.ClipEntry));
    try std.testing.expect(std.mem.indexOf(u8, WGSL_CLIP, "struct RoundClip { x: f32, y: f32, w: f32, h: f32, r: f32 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, WGSL_CLIP, "struct ClipEntry { a: RoundClip, b: RoundClip, _p0: f32, _p1: f32 }") != null);
    // Every pipeline's shader carries the clip snippet.
    inline for (.{ WGSL, WGSL_TEXT, WGSL_IMAGE, WGSL_PATH }) |src| {
        try std.testing.expect(std.mem.startsWith(u8, src, WGSL_CLIP));
    }
}
