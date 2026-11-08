const std = @import("std");
const reg = @import("../core/registry.zig");
const layout = @import("../layout/flexbox.zig");
const core_events = @import("../core/events.zig");
const path_mod = @import("../core/path.zig");

/// Renderer state. In the full implementation, this will contain
/// the WGPUDevice, WGPUQueue, WGPUSwapChain, and instantiated shader pipelines.
pub const RendererState = struct {
    width: u32,
    height: u32,
    is_ready: bool,

    pub fn init(width: u32, height: u32) RendererState {
        return .{
            .width = width,
            .height = height,
            .is_ready = false,
        };
    }
};

/// Primitive that is sent to the GPU's vertex buffer.
/// Contains all the necessary information for the Fragment Shader
/// to calculate the SDF of a rounded rectangle.
pub const RectPrimitive = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color_r: f32 = 1.0,
    color_g: f32 = 1.0,
    color_b: f32 = 1.0,
    color_a: f32 = 1.0,
    border_radius: f32 = 0.0,
    // Per-side border widths (px). A uniform border sets all four equal.
    border_top: f32 = 0.0,
    border_right: f32 = 0.0,
    border_bottom: f32 = 0.0,
    border_left: f32 = 0.0,
    border_color_r: f32 = 0.0,
    border_color_g: f32 = 0.0,
    border_color_b: f32 = 0.0,
    border_color_a: f32 = 0.0,
    clip_rect_x: f32 = -10000.0,
    clip_rect_y: f32 = -10000.0,
    clip_rect_w: f32 = 20000.0,
    clip_rect_h: f32 = 20000.0,
    shadow_blur: f32 = 0.0,
    shadow_offset_x: f32 = 0.0,
    shadow_offset_y: f32 = 0.0,
    shadow_color_r: f32 = 0.0,
    shadow_color_g: f32 = 0.0,
    shadow_color_b: f32 = 0.0,
    shadow_color_a: f32 = 0.0,
    grad_type: f32 = 0.0,
    c2_r: f32 = 0.0,
    c2_g: f32 = 0.0,
    c2_b: f32 = 0.0,
    c2_a: f32 = 0.0,
    // 0 = solid, 1 = dashed (applies to straight/per-side borders).
    border_style: f32 = 0.0,
    z_index: f32 = 0.0,
    _pad2: f32 = 0.0,
    // Field order must match the WGSL `InstanceData` struct — these bytes are
    // uploaded straight into the instance storage buffer.
    /// Inflation of the shadow rect before blurring (CSS box-shadow's spread).
    shadow_spread: f32 = 0.0,
    /// 1 on the prim that *is* a shadow, 0 on a body. The shader needs this stated
    /// rather than inferred from `shadow_blur > 0`: a shadow with `blur = 0` is a
    /// legitimate hard-edged shadow, so blur can't double as the marker.
    is_shadow: f32 = 0.0,
    _pad3: f32 = 0.0,
    _pad4: f32 = 0.0,
};

pub const ImagePrimitive = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    z_index: f32 = 0.0,
    clip_rect_x: f32 = -10000.0,
    clip_rect_y: f32 = -10000.0,
    clip_rect_w: f32 = 20000.0,
    clip_rect_h: f32 = 20000.0,
    opacity: f32 = 1.0,
    src_path: []const u8,
};

/// One flattened stroke segment of a `NodeType.path` node, ready for the GPU.
/// The backend draws it as a capsule (segment inflated by `half_width`, round
/// ends) via an SDF fragment shader. `extern` + all-`f32`: uploaded byte-for-
/// byte into the path pipeline's instance storage buffer. Field order must
/// match the WGSL `PathInstance` struct.
pub const PathSegPrim = extern struct {
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
    half_width: f32,
    color_r: f32 = 0.0,
    color_g: f32 = 0.0,
    color_b: f32 = 0.0,
    color_a: f32 = 1.0,
    clip_rect_x: f32 = -10000.0,
    clip_rect_y: f32 = -10000.0,
    clip_rect_w: f32 = 20000.0,
    clip_rect_h: f32 = 20000.0,
    z_index: f32 = 0.0,
    _pad0: f32 = 0.0,
    _pad1: f32 = 0.0,
};

const props = @import("../core/properties.zig");

/// Fallback focus-ring color (RGBA, 0..1) for a bake with no theme behind it —
/// unit tests, and any host that never sets one. The real color is per engine
/// (`EngineState.focus_ring_color`) and travels through `BakeContext`: it used to
/// be a mutable global, which meant two windows with different themes fought over
/// it and the last one to build won.
pub const default_focus_ring_color: [4]f32 = .{ 0.0, 0.47, 1.0, 1.0 };

/// Focus-ring thickness in px (also how far the ring is inflated past the node).
pub const focus_ring_width: f32 = 2.0;

pub const HitNode = struct {
    id: reg.NodeId,
    z_index: f32,
    draw_order: u32,
    clip_rect: ClipRect,
};

pub const ClipRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

fn intersectRect(a: ClipRect, b: ClipRect) ClipRect {
    const ax1 = a.x;
    const ay1 = a.y;
    const ax2 = a.x + a.w;
    const ay2 = a.y + a.h;

    const bx1 = b.x;
    const by1 = b.y;
    const bx2 = b.x + b.w;
    const by2 = b.y + b.h;

    const rx1 = @max(ax1, bx1);
    const ry1 = @max(ay1, by1);
    const rx2 = @min(ax2, bx2);
    const ry2 = @min(ay2, by2);

    if (rx2 <= rx1 or ry2 <= ry1) {
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }
    return .{ .x = rx1, .y = ry1, .w = rx2 - rx1, .h = ry2 - ry1 };
}

pub const SortableRect = struct {
    prim: RectPrimitive,
    z_index: f32,
    draw_order: u32,
};

pub const SortableImage = struct {
    prim: ImagePrimitive,
    z_index: f32,
    draw_order: u32,
};

pub const SortablePath = struct {
    prim: PathSegPrim,
    z_index: f32,
    draw_order: u32,
};

const BakeContext = struct {
    registry: *reg.UIRegistry,
    store: *const props.PropertyStore,
    allocator: std.mem.Allocator,
    sortable_rects: *std.array_list.Managed(SortableRect),
    sortable_imgs: *std.array_list.Managed(SortableImage),
    sortable_paths: *std.array_list.Managed(SortablePath),
    hit_list: *std.array_list.Managed(HitNode),
    focused_node: ?reg.NodeId,
    /// The focus ring's color for THIS window's bake.
    focus_ring_color: [4]f32,
    /// Focus-visible: the ring only actually paints when this is
    /// `.keyboard` — see `core_events.FocusHighlightMode`. `focused_node`
    /// itself is untouched by this (still drives UIA/hit-testing/etc.);
    /// this field ONLY gates the visual.
    focus_highlight_mode: core_events.FocusHighlightMode,
    draw_counter: *u32,
};

/// Converts the UIRegistry (layout-resolved tree) into a flat list
/// of RectPrimitives to make the instanced draw call.
/// This is the "Primitive Baking" step of the specified pipeline.
fn bakeNodeRecursive(
    ctx: BakeContext,
    node_id: reg.NodeId,
    current_clip: ClipRect,
    current_z: f32,
    depth: usize,
) !void {
    const node_opt = ctx.registry.getNode(node_id);
    if (node_opt == null) return;
    const node = node_opt.?;
    const g = node.geometry;

    var next_clip = current_clip;
    // If the node has overflow_hidden, it becomes the new clip rect for its children
    if (ctx.store.modifierFlag(node_id, .overflow_hidden)) {
        next_clip = intersectRect(current_clip, .{
            .x = g.x,
            .y = g.y,
            .w = g.width,
            .h = g.height,
        });
    }

    var prim = RectPrimitive{
        .x = g.x,
        .y = g.y,
        .width = g.width,
        .height = g.height,
        .clip_rect_x = current_clip.x,
        .clip_rect_y = current_clip.y,
        .clip_rect_w = current_clip.w,
        .clip_rect_h = current_clip.h,
    };

    const z_val = if (ctx.store.getStyle(node_id, .z_index)) |val| val.number else current_z;

    ctx.draw_counter.* += 1;
    const my_order = ctx.draw_counter.*;

    try ctx.hit_list.append(.{
        .id = node_id,
        .z_index = z_val,
        .draw_order = my_order,
        .clip_rect = current_clip,
    });

    switch (node.node_type) {
        .box => {
            if (ctx.store.getStyle(node_id, .background)) |bg| {
                prim.color_r = bg.color.r;
                prim.color_g = bg.color.g;
                prim.color_b = bg.color.b;
                prim.color_a = bg.color.a;
            } else {
                // No background means TRANSPARENT — the parent shows through.
                // This used to paint an opaque near-black slab, which turned every
                // unstyled wrapper into a visible tile over a card (and, with a
                // radius on the child, into four dark corners peeking out behind it),
                // forcing `backgroundAlpha(id, 0,0,0, 0)` on every layout-only box.
                prim.color_a = 0.0;
            }

            if (ctx.store.getStyle(node_id, .radius)) |r| {
                prim.border_radius = r.dimension.value;
            }
            // Uniform border_width seeds all four sides; per-side keys override.
            if (ctx.store.getStyle(node_id, .border_width)) |bw| {
                prim.border_top = bw.dimension.value;
                prim.border_right = bw.dimension.value;
                prim.border_bottom = bw.dimension.value;
                prim.border_left = bw.dimension.value;
            }
            if (ctx.store.getStyle(node_id, .border_top)) |v| prim.border_top = v.dimension.value;
            if (ctx.store.getStyle(node_id, .border_right)) |v| prim.border_right = v.dimension.value;
            if (ctx.store.getStyle(node_id, .border_bottom)) |v| prim.border_bottom = v.dimension.value;
            if (ctx.store.getStyle(node_id, .border_left)) |v| prim.border_left = v.dimension.value;
            if (ctx.store.getStyle(node_id, .border_style)) |v| prim.border_style = v.number;
            if (ctx.store.getStyle(node_id, .border_color)) |bc| {
                prim.border_color_r = bc.color.r;
                prim.border_color_g = bc.color.g;
                prim.border_color_b = bc.color.b;
                prim.border_color_a = bc.color.a;
            }

            if (ctx.store.getStyle(node_id, .shadow_blur)) |sb| prim.shadow_blur = sb.dimension.value;
            if (ctx.store.getStyle(node_id, .shadow_offset_x)) |sx| prim.shadow_offset_x = sx.dimension.value;
            if (ctx.store.getStyle(node_id, .shadow_offset_y)) |sy| prim.shadow_offset_y = sy.dimension.value;
            if (ctx.store.getStyle(node_id, .shadow_spread)) |sp| prim.shadow_spread = sp.dimension.value;
            if (ctx.store.getStyle(node_id, .shadow_color)) |sc| {
                prim.shadow_color_r = sc.color.r;
                prim.shadow_color_g = sc.color.g;
                prim.shadow_color_b = sc.color.b;
                prim.shadow_color_a = sc.color.a;
            }

            if (ctx.store.getStyle(node_id, .gradient_type)) |gt| prim.grad_type = gt.number;
            if (ctx.store.getStyle(node_id, .gradient_color2)) |c2| {
                prim.c2_r = c2.color.r;
                prim.c2_g = c2.color.g;
                prim.c2_b = c2.color.b;
                prim.c2_a = c2.color.a;
            }

            // Box opacity multiplies into every alpha so opacity=0 hides the box
            // entirely (drives the text-input caret blink, which toggles .opacity).
            if (ctx.store.getStyle(node_id, .opacity)) |op| {
                prim.color_a *= op.number;
                prim.border_color_a *= op.number;
                prim.shadow_color_a *= op.number;
                prim.c2_a *= op.number;
            }
        },
        .text => {
            prim.color_a = 0.0;
        },
        .image => {
            // The texture IS the content, so the box behind it is transparent by
            // default — exactly like `.text`. Leaving it at the opaque near-white
            // default painted a solid slab under every image, and (drawn first,
            // then the texture blended on top) that slab showed straight through
            // any transparent pixel of the PNG. An explicit `.background` still
            // wins: it letterboxes / stands in while a slow or missing src loads.
            if (ctx.store.getStyle(node_id, .background)) |bg| {
                prim.color_r = bg.color.r;
                prim.color_g = bg.color.g;
                prim.color_b = bg.color.b;
                prim.color_a = bg.color.a;
            } else {
                prim.color_a = 0.0;
            }

            if (ctx.store.getModifier(node_id, .src)) |src| {
                if (src == .string) {
                    var opacity: f32 = 1.0;
                    if (ctx.store.getStyle(node_id, .opacity)) |op| {
                        opacity = op.number;
                    }

                    var img = ImagePrimitive{
                        .x = g.x,
                        .y = g.y,
                        .width = g.width,
                        .height = g.height,
                        .clip_rect_x = current_clip.x,
                        .clip_rect_y = current_clip.y,
                        .clip_rect_w = current_clip.w,
                        .clip_rect_h = current_clip.h,
                        .opacity = opacity,
                        .src_path = src.string,
                    };
                    img.z_index = z_val;
                    try ctx.sortable_imgs.append(.{ .prim = img, .z_index = z_val, .draw_order = my_order });
                }
            }
        },
        .path => {
            if (ctx.store.getPath(node_id)) |verts| {
                const segs = path_mod.flatten(verts, 0, ctx.allocator) catch &[_]path_mod.PathSegment{};
                defer if (segs.len > 0) ctx.allocator.free(segs);

                // Stroke style reuses existing keys: border_color / border_width /
                // opacity. Defaults: 1px, opaque black (visible without styling).
                var col = props.PropValue{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 1 } };
                if (ctx.store.getStyle(node_id, .border_color)) |bc| col = bc;
                var stroke_w: f32 = 1.0;
                if (ctx.store.getStyle(node_id, .border_width)) |bw| {
                    if (bw == .dimension) stroke_w = bw.dimension.value;
                }
                var op: f32 = 1.0;
                if (ctx.store.getStyle(node_id, .opacity)) |o| {
                    if (o == .number) op = o.number;
                }
                const half = @max(stroke_w, 0.01) * 0.5;

                for (segs) |s| {
                    try ctx.sortable_paths.append(.{
                        .prim = .{
                            .ax = g.x + s.ax,
                            .ay = g.y + s.ay,
                            .bx = g.x + s.bx,
                            .by = g.y + s.by,
                            .half_width = half,
                            .color_r = col.color.r,
                            .color_g = col.color.g,
                            .color_b = col.color.b,
                            .color_a = col.color.a * op,
                            .clip_rect_x = current_clip.x,
                            .clip_rect_y = current_clip.y,
                            .clip_rect_w = current_clip.w,
                            .clip_rect_h = current_clip.h,
                            .z_index = z_val,
                        },
                        .z_index = z_val,
                        .draw_order = my_order,
                    });
                }
            }
        },
    }

    // A shadow is worth drawing when it has a color and lands anywhere other than
    // exactly under its body: blurred, spread, or offset. `blur = 0` with an offset
    // is a hard-edged shadow, which some designs use on purpose.
    const has_shadow = prim.shadow_color_a > 0.0 and
        (prim.shadow_blur > 0.0 or prim.shadow_spread != 0.0 or
            prim.shadow_offset_x != 0.0 or prim.shadow_offset_y != 0.0);
    if (has_shadow) {
        var shadow_prim = prim;
        shadow_prim.is_shadow = 1.0;
        shadow_prim.x += shadow_prim.shadow_offset_x;
        shadow_prim.y += shadow_prim.shadow_offset_y;
        // Spread inflates the rect (and its corners) before the blur, exactly like
        // CSS: the blur then runs from the inflated edge.
        const sp = shadow_prim.shadow_spread;
        if (sp != 0.0) {
            shadow_prim.x -= sp;
            shadow_prim.y -= sp;
            shadow_prim.width = @max(0.0, shadow_prim.width + sp * 2.0);
            shadow_prim.height = @max(0.0, shadow_prim.height + sp * 2.0);
            shadow_prim.border_radius = @max(0.0, shadow_prim.border_radius + sp);
        }
        shadow_prim.color_r = shadow_prim.shadow_color_r;
        shadow_prim.color_g = shadow_prim.shadow_color_g;
        shadow_prim.color_b = shadow_prim.shadow_color_b;
        shadow_prim.color_a = shadow_prim.shadow_color_a;
        shadow_prim.border_top = 0.0;
        shadow_prim.border_right = 0.0;
        shadow_prim.border_bottom = 0.0;
        shadow_prim.border_left = 0.0;
        shadow_prim.border_color_a = 0.0;
        ctx.draw_counter.* += 1;
        shadow_prim.z_index = z_val;
        try ctx.sortable_rects.append(.{ .prim = shadow_prim, .z_index = z_val, .draw_order = ctx.draw_counter.* });
    }
    prim.shadow_blur = 0.0;

    ctx.draw_counter.* += 1;
    prim.z_index = z_val;
    // A path node emits its own stroke instances above; it has no rect body.
    if (node.node_type != .path) {
        try ctx.sortable_rects.append(.{ .prim = prim, .z_index = z_val, .draw_order = ctx.draw_counter.* });
    }

    // Focus ring. A focused, focusable node gets a 2px accent border
    // drawn just outside it (transparent fill), on top of its own rect (same
    // z, later draw order) and under its children — but ONLY when the current
    // `FocusHighlightMode` is `.keyboard` (focus-visible): a mouse click that
    // sets `focused_node` does not paint the ring. `focused_node` itself is
    // unaffected either way — UIA/hit-testing/etc. never gate on this. Zero
    // pipeline changes — the shader already does border + radius + alpha-0 fill.
    //
    // Roving focus (`.virtual_focus_target`): when the real focused node
    // (`fid`) is a roving-selection container (a `Menu` panel tracking its
    // highlighted row via arrow keys — the `aria-activedescendant` pattern),
    // the ring paints on the redirected target instead of the whole
    // container. Falls back to `fid` itself when absent, or when the target
    // doesn't resolve to a live, positive-area node (e.g. the menu just
    // opened and nothing is highlighted yet).
    if (ctx.focused_node) |fid| {
        var effective = fid;
        if (ctx.store.getModifier(fid, .virtual_focus_target) != null) {
            // Negative = "no current target" (Menu clears it this way instead
            // of removing the modifier — there's no per-modifier unset API).
            if (ctx.store.modifierNodeRef(fid, .virtual_focus_target)) |target_id| {
                if (ctx.registry.getNode(target_id)) |tn| {
                    if (tn.geometry.width > 0 and tn.geometry.height > 0) effective = target_id;
                }
            }
        }
        // `.no_focus_ring` (outline:none) on the focus holder or on the
        // painted target suppresses ONLY this primitive — focus itself is
        // untouched (see ModifierKey.no_focus_ring). Checked last so the
        // lookups run only for the one node that would get the ring.
        if (effective == node_id and ctx.focus_highlight_mode == .keyboard and
            ctx.store.getModifier(fid, .focusable) != null and
            !ctx.store.modifierFlag(fid, .no_focus_ring) and
            !ctx.store.modifierFlag(effective, .no_focus_ring))
        {
            const rw = focus_ring_width;
            var ring = RectPrimitive{
                .x = g.x - rw,
                .y = g.y - rw,
                .width = g.width + 2 * rw,
                .height = g.height + 2 * rw,
                .clip_rect_x = current_clip.x,
                .clip_rect_y = current_clip.y,
                .clip_rect_w = current_clip.w,
                .clip_rect_h = current_clip.h,
                .color_a = 0.0, // transparent fill: only the border shows
                .border_top = rw,
                .border_right = rw,
                .border_bottom = rw,
                .border_left = rw,
                .border_color_r = ctx.focus_ring_color[0],
                .border_color_g = ctx.focus_ring_color[1],
                .border_color_b = ctx.focus_ring_color[2],
                .border_color_a = ctx.focus_ring_color[3],
            };
            if (ctx.store.getStyle(node_id, .radius)) |r| ring.border_radius = r.dimension.value + rw;
            ctx.draw_counter.* += 1;
            ring.z_index = z_val;
            try ctx.sortable_rects.append(.{ .prim = ring, .z_index = z_val, .draw_order = ctx.draw_counter.* });
        }
    }

    // Bound the descent exactly like every other tree walk (parser, layout,
    // removal, focus) so a pathologically deep tree — buildable via the unbounded
    // celeris_node_append_child C-API — cannot overflow the native stack. Past the
    // cap the deepest descendants are simply not baked; the process stays alive.
    if (depth < reg.MAX_TREE_DEPTH) {
        var child_id = node.first_child;
        while (child_id != reg.NULL_NODE) {
            try bakeNodeRecursive(ctx, child_id, next_clip, z_val, depth + 1);
            const child_node = ctx.registry.getNode(child_id) orelse break;
            child_id = child_node.next_sibling;
        }
    }
}

pub fn bakeRegistry(
    registry: *reg.UIRegistry,
    store: *const props.PropertyStore,
    out: *std.array_list.Managed(RectPrimitive),
    img_out: *std.array_list.Managed(ImagePrimitive),
    path_out: *std.array_list.Managed(PathSegPrim),
    hit_out: *std.array_list.Managed(HitNode),
    focused_node: ?reg.NodeId,
    /// Focus-ring color for this window; null uses `default_focus_ring_color`.
    ring_color: ?[4]f32,
    /// Focus-visible: whether the ring paints at all right now — see
    /// `BakeContext.focus_highlight_mode`.
    focus_highlight_mode: core_events.FocusHighlightMode,
    allocator: std.mem.Allocator,
) !void {
    const initial_clip = ClipRect{ .x = -10000.0, .y = -10000.0, .w = 20000.0, .h = 20000.0 };

    var sortable_rects = std.array_list.Managed(SortableRect).init(allocator);
    defer sortable_rects.deinit();

    var sortable_imgs = std.array_list.Managed(SortableImage).init(allocator);
    defer sortable_imgs.deinit();

    var sortable_paths = std.array_list.Managed(SortablePath).init(allocator);
    defer sortable_paths.deinit();

    var hit_list_nodes = std.array_list.Managed(HitNode).init(allocator);
    defer hit_list_nodes.deinit();

    var d_counter: u32 = 0;

    const ctx = BakeContext{
        .registry = registry,
        .store = store,
        .allocator = allocator,
        .sortable_rects = &sortable_rects,
        .sortable_imgs = &sortable_imgs,
        .sortable_paths = &sortable_paths,
        .hit_list = &hit_list_nodes,
        .focused_node = focused_node,
        .focus_ring_color = ring_color orelse default_focus_ring_color,
        .focus_highlight_mode = focus_highlight_mode,
        .draw_counter = &d_counter,
    };

    // Find roots
    for (registry.nodes.items) |node| {
        if (node.parent == reg.NULL_NODE) {
            try bakeNodeRecursive(ctx, node.id, initial_clip, 0.0, 0);
        }
    }

    // Sort prims by Z-Index ascending, then draw_order ascending
    std.mem.sort(SortableRect, sortable_rects.items, {}, sortRectsAscending);
    std.mem.sort(SortableImage, sortable_imgs.items, {}, sortImagesAscending);
    std.mem.sort(SortablePath, sortable_paths.items, {}, sortPathsAscending);

    // Sort hit list by Z-Index descending, then draw_order descending (highest Z first for hit testing)
    std.mem.sort(HitNode, hit_list_nodes.items, {}, sortHitNodesDescending);

    // Populate outputs
    for (sortable_rects.items) |sr| {
        try out.append(sr.prim);
    }
    for (sortable_imgs.items) |si| {
        try img_out.append(si.prim);
    }
    for (sortable_paths.items) |sp| {
        try path_out.append(sp.prim);
    }
    for (hit_list_nodes.items) |hn| {
        try hit_out.append(hn);
    }
}

fn sortPathsAscending(context: void, a: SortablePath, b: SortablePath) bool {
    _ = context;
    if (a.z_index != b.z_index) return a.z_index < b.z_index;
    return a.draw_order < b.draw_order;
}

fn sortRectsAscending(context: void, a: SortableRect, b: SortableRect) bool {
    _ = context;
    if (a.z_index != b.z_index) return a.z_index < b.z_index;
    return a.draw_order < b.draw_order;
}

fn sortImagesAscending(context: void, a: SortableImage, b: SortableImage) bool {
    _ = context;
    if (a.z_index != b.z_index) return a.z_index < b.z_index;
    return a.draw_order < b.draw_order;
}

fn sortHitNodesDescending(context: void, a: HitNode, b: HitNode) bool {
    _ = context;
    if (a.z_index != b.z_index) return a.z_index > b.z_index;
    return a.draw_order > b.draw_order;
}

test "Primitive baking" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const box_id = try registry.createNode(.box);
    const btn_id = try registry.createNode(.box);
    registry.appendChild(box_id, btn_id);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(box_id);
    try store.registerNode(btn_id);

    try store.setStyle(btn_id, .radius, .{ .dimension = .{ .value = 6.0, .unit = .px } });

    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(box_id, 0, 0, 800, 600);

    var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
    defer prims.deinit();

    var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
    defer images.deinit();
    var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
    defer paths.deinit();

    var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
    defer hits.deinit();

    try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, null, null, .pointer, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), prims.items.len);
    try std.testing.expectEqual(@as(f32, 6.0), prims.items[1].border_radius); // second box has border-radius
}

test "A path node emits stroke segments at its z, styled, offset by geometry; no rect body" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    // rect (z 0) | path (z 1) | rect (z 2) — the connection-over-node guard.
    const root = try registry.createNode(.box);
    const under = try registry.createNode(.box);
    const p = try registry.createNode(.path);
    const over = try registry.createNode(.box);
    registry.appendChild(root, under);
    registry.appendChild(root, p);
    registry.appendChild(root, over);
    for ([_]reg.NodeId{ root, under, p, over }) |id| try store.registerNode(id);

    try store.setStyle(under, .z_index, .{ .number = 0 });
    try store.setStyle(p, .z_index, .{ .number = 1 });
    try store.setStyle(over, .z_index, .{ .number = 2 });
    try store.setStyle(p, .border_color, .{ .color = .{ .r = 0.2, .g = 0.4, .b = 0.6, .a = 1 } });
    try store.setStyle(p, .border_width, .{ .dimension = .{ .value = 4, .unit = .px } });

    var verts = [_]path_mod.PathVertex{
        .{ .x = 0, .y = 0 },
        .{ .x = 60, .y = 20 }, // one straight segment
    };
    try store.setPath(p, &verts);

    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 800, 600);
    // Put the path node somewhere non-zero so the origin offset is observable.
    registry.getNode(p).?.geometry.x = 100;
    registry.getNode(p).?.geometry.y = 50;

    var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
    defer prims.deinit();
    var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
    defer images.deinit();
    var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
    defer paths.deinit();
    var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
    defer hits.deinit();

    try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, null, null, .pointer, std.testing.allocator);

    // Exactly one stroke segment, no rect body for the path node (root + 2 boxes = 3).
    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqual(@as(usize, 3), prims.items.len);

    const s = paths.items[0];
    try std.testing.expectEqual(@as(f32, 100), s.ax); // 100 + 0
    try std.testing.expectEqual(@as(f32, 50), s.ay);
    try std.testing.expectEqual(@as(f32, 160), s.bx); // 100 + 60
    try std.testing.expectEqual(@as(f32, 70), s.by); // 50 + 20
    try std.testing.expectEqual(@as(f32, 2), s.half_width); // 4px / 2
    try std.testing.expectEqual(@as(f32, 0.2), s.color_r);
    try std.testing.expectEqual(@as(f32, 1), s.z_index);
}

test "Flatten failure or empty path emits nothing, and unstyled path defaults to 1px black" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const p = try registry.createNode(.path);
    try store.registerNode(p);
    var verts = [_]path_mod.PathVertex{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } };
    try store.setPath(p, &verts);

    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(p, 0, 0, 800, 600);

    var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
    defer prims.deinit();
    var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
    defer images.deinit();
    var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
    defer paths.deinit();
    var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
    defer hits.deinit();
    try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, null, null, .pointer, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqual(@as(f32, 0.5), paths.items[0].half_width); // 1px default
    try std.testing.expectEqual(@as(f32, 0), paths.items[0].color_r); // black default
    try std.testing.expectEqual(@as(f32, 1), paths.items[0].color_a);
    try std.testing.expectEqual(@as(usize, 0), prims.items.len); // no rect body
}

test "Uniform border_width seeds all sides; per-side keys override just their edge" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const root = try registry.createNode(.box);
    const uniform = try registry.createNode(.box);
    const underline = try registry.createNode(.box);
    registry.appendChild(root, uniform);
    registry.appendChild(root, underline);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root);
    try store.registerNode(uniform);
    try store.registerNode(underline);

    // A uniform 1px border, and a tab-style 2px bottom rule with no uniform border.
    try store.setStyle(uniform, .border_width, .{ .dimension = .{ .value = 1.0, .unit = .px } });
    try store.setStyle(underline, .border_bottom, .{ .dimension = .{ .value = 2.0, .unit = .px } });
    try store.setStyle(underline, .border_style, .{ .number = 1.0 }); // dashed

    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 800, 600);

    var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
    defer prims.deinit();
    var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
    defer images.deinit();
    var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
    defer paths.deinit();
    var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
    defer hits.deinit();
    try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, null, null, .pointer, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), prims.items.len);

    // prims are baked root-first, then children in order.
    const u = prims.items[1];
    try std.testing.expectEqual(@as(f32, 1.0), u.border_top);
    try std.testing.expectEqual(@as(f32, 1.0), u.border_right);
    try std.testing.expectEqual(@as(f32, 1.0), u.border_bottom);
    try std.testing.expectEqual(@as(f32, 1.0), u.border_left);
    try std.testing.expectEqual(@as(f32, 0.0), u.border_style); // solid by default

    const d = prims.items[2];
    try std.testing.expectEqual(@as(f32, 2.0), d.border_bottom);
    try std.testing.expectEqual(@as(f32, 0.0), d.border_top);
    try std.testing.expectEqual(@as(f32, 0.0), d.border_left);
    try std.testing.expectEqual(@as(f32, 0.0), d.border_right);
    try std.testing.expectEqual(@as(f32, 1.0), d.border_style); // dashed
}

test "A box with no background bakes transparent, not an opaque slab" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const card = try registry.createNode(.box);
    const wrapper = try registry.createNode(.box); // layout-only, no background
    registry.appendChild(card, wrapper);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(card);
    try store.registerNode(wrapper);
    try store.setStyle(card, .background, .{ .color = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1 } });

    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(card, 0, 0, 800, 600);

    var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
    defer prims.deinit();
    var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
    defer images.deinit();
    var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
    defer paths.deinit();
    var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
    defer hits.deinit();
    try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, null, null, .pointer, std.testing.allocator);

    // The card keeps its explicit fill; the unstyled wrapper lets it show through
    // instead of tiling the theme's base color over it.
    try std.testing.expectEqual(@as(f32, 1.0), prims.items[0].color_a);
    try std.testing.expectEqual(@as(f32, 0.0), prims.items[1].color_a);
}

test "an image node bakes a transparent box behind the texture, unless it has an explicit background" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const root = try registry.createNode(.box);
    const bare = try registry.createNode(.image); // src only — texture is the content
    const boxed = try registry.createNode(.image); // src + a placeholder background
    registry.appendChild(root, bare);
    registry.appendChild(root, boxed);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root);
    try store.registerNode(bare);
    try store.registerNode(boxed);
    try store.setModifier(bare, .src, .{ .string = try store.stringAllocator().dupe(u8, "logo.png") });
    try store.setModifier(boxed, .src, .{ .string = try store.stringAllocator().dupe(u8, "logo.png") });
    try store.setStyle(boxed, .background, .{ .color = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1 } });

    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 800, 600);

    var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
    defer prims.deinit();
    var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
    defer images.deinit();
    var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
    defer paths.deinit();
    var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
    defer hits.deinit();
    try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, null, null, .pointer, std.testing.allocator);

    // prims[0] = root, prims[1] = bare image's box, prims[2] = boxed image's box.
    // A bare image would otherwise paint an opaque near-white slab that shows
    // straight through every transparent pixel of the PNG.
    try std.testing.expectEqual(@as(f32, 0.0), prims.items[1].color_a);
    try std.testing.expectEqual(@as(f32, 1.0), prims.items[2].color_a);
    try std.testing.expectEqual(@as(f32, 0.1), prims.items[2].color_r);
    try std.testing.expectEqual(@as(usize, 2), images.items.len);
}

test "Focus ring is baked only for the focused focusable node" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const root = try registry.createNode(.box);
    const btn = try registry.createNode(.box);
    registry.appendChild(root, btn);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root);
    try store.registerNode(btn);
    try store.setStyle(btn, .radius, .{ .dimension = .{ .value = 6.0, .unit = .px } });
    // The button is focusable (the modifier value is irrelevant to the ring).
    try store.setModifier(btn, .focusable, .{ .string = try store.stringAllocator().dupe(u8, "n1") });

    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 800, 600);

    // No focus → no ring: exactly the two node rects.
    {
        var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
        defer prims.deinit();
        var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
        defer images.deinit();
        var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
        defer paths.deinit();
        var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
        defer hits.deinit();
        try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, null, null, .pointer, std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), prims.items.len);
    }

    // Focus the button → one extra rect: the ring. It has the accent border, a
    // transparent fill, bounds inflated by the ring width, and radius = node + width.
    {
        var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
        defer prims.deinit();
        var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
        defer images.deinit();
        var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
        defer paths.deinit();
        var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
        defer hits.deinit();
        try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, btn, null, .keyboard, std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 3), prims.items.len);
        const btn_geo = registry.getNode(btn).?.geometry;
        // Find the ring: transparent fill + non-zero border alpha.
        var ring: ?RectPrimitive = null;
        for (prims.items) |p| {
            if (p.color_a == 0.0 and p.border_color_a > 0.0 and p.border_top == focus_ring_width) ring = p;
        }
        const r = ring orelse return error.RingNotBaked;
        try std.testing.expectEqual(btn_geo.x - focus_ring_width, r.x);
        try std.testing.expectEqual(btn_geo.width + 2 * focus_ring_width, r.width);
        try std.testing.expectEqual(@as(f32, 6.0 + focus_ring_width), r.border_radius);
        try std.testing.expectEqual(default_focus_ring_color[0], r.border_color_r);
    }

    // The ring's color is per bake, not global. Two windows with different
    // themes each get their own — which is exactly what a mutable global could not
    // do (whichever window built last set the color for both).
    {
        var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
        defer prims.deinit();
        var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
        defer images.deinit();
        var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
        defer paths.deinit();
        var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
        defer hits.deinit();
        const magenta = [4]f32{ 1.0, 0.0, 1.0, 1.0 };
        try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, btn, magenta, .keyboard, std.testing.allocator);

        var ring: ?RectPrimitive = null;
        for (prims.items) |p| {
            if (p.color_a == 0.0 and p.border_color_a > 0.0 and p.border_top == focus_ring_width) ring = p;
        }
        const r = ring orelse return error.RingNotBaked;
        try std.testing.expectEqual(magenta[0], r.border_color_r);
        try std.testing.expectEqual(magenta[2], r.border_color_b);
    }
}

test "Focus ring only paints in .keyboard highlight mode, never .pointer" {
    // `focused_node` alone is not enough to paint the ring (focus-visible):
    // a mouse click sets `focused_node` too, but must NOT show it. This is
    // the framework-wide counterpart to the focus-ring test above, which only
    // ever exercised the (implicit) keyboard case.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const root = try registry.createNode(.box);
    const btn = try registry.createNode(.box);
    registry.appendChild(root, btn);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root);
    try store.registerNode(btn);
    try store.setModifier(btn, .focusable, .{ .string = try store.stringAllocator().dupe(u8, "n1") });

    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 800, 600);

    const hasRing = struct {
        fn check(prims: []const RectPrimitive) bool {
            for (prims) |p| {
                if (p.color_a == 0.0 and p.border_color_a > 0.0 and p.border_top == focus_ring_width) return true;
            }
            return false;
        }
    }.check;

    // .pointer: focused_node is set (as a real mouse click would leave it),
    // but the ring must not appear — only the 2 plain node rects.
    {
        var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
        defer prims.deinit();
        var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
        defer images.deinit();
        var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
        defer paths.deinit();
        var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
        defer hits.deinit();
        try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, btn, null, .pointer, std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), prims.items.len);
        try std.testing.expect(!hasRing(prims.items));
    }

    // Same focused_node, .keyboard mode: the ring appears.
    {
        var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
        defer prims.deinit();
        var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
        defer images.deinit();
        var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
        defer paths.deinit();
        var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
        defer hits.deinit();
        try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, btn, null, .keyboard, std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 3), prims.items.len);
        try std.testing.expect(hasRing(prims.items));
    }
}

/// Test helper: bakes `registry` with `focused` in `.keyboard` mode and
/// returns how many focus-ring primitives were emitted around `target`.
fn countRingsAround(registry: *reg.UIRegistry, store: *props.PropertyStore, focused: reg.NodeId, target: reg.NodeId) !usize {
    var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
    defer prims.deinit();
    var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
    defer images.deinit();
    var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
    defer paths.deinit();
    var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
    defer hits.deinit();
    try bakeRegistry(registry, store, &prims, &images, &paths, &hits, focused, null, .keyboard, std.testing.allocator);
    const tg = registry.getNode(target).?.geometry;
    var n: usize = 0;
    for (prims.items) |p| {
        if (p.color_a == 0.0 and p.border_color_a > 0.0 and p.border_top == focus_ring_width and
            p.x == tg.x - focus_ring_width and p.width == tg.width + 2 * focus_ring_width) n += 1;
    }
    return n;
}

test ".no_focus_ring: keyboard-focused node gets no ring; without it the ring is drawn; not inherited" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const root = try registry.createNode(.box);
    const editor = try registry.createNode(.box);
    const inner = try registry.createNode(.box); // focusable child of the opted-out node
    registry.appendChild(root, editor);
    registry.appendChild(editor, inner);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    inline for (.{ root, editor, inner }) |id| try store.registerNode(id);
    const sa = store.stringAllocator();
    try store.setModifier(editor, .focusable, .{ .string = try sa.dupe(u8, "e") });
    try store.setModifier(inner, .focusable, .{ .string = try sa.dupe(u8, "i") });
    try store.setLayout(editor, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(editor, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(inner, .width, .{ .dimension = .{ .value = 40, .unit = .px } });
    try store.setLayout(inner, .height, .{ .dimension = .{ .value = 20, .unit = .px } });
    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 800, 600);

    // Baseline: ring drawn as today.
    try std.testing.expectEqual(@as(usize, 1), try countRingsAround(&registry, &store, editor, editor));

    // Opt out: no ring, and the node's own rects are untouched.
    try store.setModifier(editor, .no_focus_ring, .{ .number = 1 });
    try std.testing.expectEqual(@as(usize, 0), try countRingsAround(&registry, &store, editor, editor));

    // Not inherited: a focusable descendant still shows its ring.
    try std.testing.expectEqual(@as(usize, 1), try countRingsAround(&registry, &store, inner, inner));

    // Value 0 turns it back off (there is no per-modifier unset API).
    try store.setModifier(editor, .no_focus_ring, .{ .number = 0 });
    try std.testing.expectEqual(@as(usize, 1), try countRingsAround(&registry, &store, editor, editor));
}

test ".no_focus_ring with .virtual_focus_target: container opt-out hides the redirected ring; target opt-out hides only its own" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const root = try registry.createNode(.box);
    const container = try registry.createNode(.box);
    const row = try registry.createNode(.box);
    registry.appendChild(root, container);
    registry.appendChild(container, row);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    inline for (.{ root, container, row }) |id| try store.registerNode(id);
    try store.setModifier(container, .focusable, .{ .string = try store.stringAllocator().dupe(u8, "c") });
    try store.setLayout(container, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(container, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(row, .width, .{ .dimension = .{ .value = 60, .unit = .px } });
    try store.setLayout(row, .height, .{ .dimension = .{ .value = 20, .unit = .px } });
    try store.setModifier(container, .virtual_focus_target, .{ .number = @floatFromInt(row) });
    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 800, 600);

    try std.testing.expectEqual(@as(usize, 1), try countRingsAround(&registry, &store, container, row));

    try store.setModifier(row, .no_focus_ring, .{ .number = 1 });
    try std.testing.expectEqual(@as(usize, 0), try countRingsAround(&registry, &store, container, row));
    try std.testing.expectEqual(@as(usize, 0), try countRingsAround(&registry, &store, container, container));

    try store.setModifier(row, .no_focus_ring, .{ .number = 0 });
    try store.setModifier(container, .no_focus_ring, .{ .number = 1 });
    try std.testing.expectEqual(@as(usize, 0), try countRingsAround(&registry, &store, container, row));
    try std.testing.expectEqual(@as(usize, 0), try countRingsAround(&registry, &store, container, container));
}

test ".virtual_focus_target redirects the ring to a live descendant (roving/aria-activedescendant)" {
    // Generic mechanism test — Menu is the concrete consumer (updateVisuals
    // sets this on its panel to track the highlighted row), but this only
    // exercises the renderer's redirect, not Menu itself.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const root = try registry.createNode(.box);
    const container = try registry.createNode(.box); // holds real focus
    const row = try registry.createNode(.box); // the "virtually" focused row
    registry.appendChild(root, container);
    registry.appendChild(container, row);

    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(root);
    try store.registerNode(container);
    try store.registerNode(row);
    try store.setModifier(container, .focusable, .{ .string = try store.stringAllocator().dupe(u8, "c") });
    // Container wider than its row so the two geometries are distinguishable
    // (a container that shrinks exactly to fit its only child would give both
    // assertions the same bounding box and prove nothing).
    try store.setLayout(container, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(container, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setLayout(row, .width, .{ .dimension = .{ .value = 60, .unit = .px } });
    try store.setLayout(row, .height, .{ .dimension = .{ .value = 20, .unit = .px } });

    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(root, 0, 0, 800, 600);

    const hasRingAround = struct {
        fn check(prims: []const RectPrimitive, target_geo: reg.Geometry) bool {
            for (prims) |p| {
                if (p.color_a == 0.0 and p.border_color_a > 0.0 and p.border_top == focus_ring_width) {
                    if (p.x == target_geo.x - focus_ring_width and p.width == target_geo.width + 2 * focus_ring_width) return true;
                }
            }
            return false;
        }
    }.check;

    // No redirect set yet: the ring paints around the container itself.
    {
        var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
        defer prims.deinit();
        var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
        defer images.deinit();
        var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
        defer paths.deinit();
        var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
        defer hits.deinit();
        try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, container, null, .keyboard, std.testing.allocator);
        try std.testing.expect(hasRingAround(prims.items, registry.getNode(container).?.geometry));
        try std.testing.expect(!hasRingAround(prims.items, registry.getNode(row).?.geometry));
    }

    // Redirect to `row`: the ring moves there instead, even though real
    // engine focus (`focused_node`) is still the container.
    try store.setModifier(container, .virtual_focus_target, .{ .number = @floatFromInt(row) });
    {
        var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
        defer prims.deinit();
        var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
        defer images.deinit();
        var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
        defer paths.deinit();
        var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
        defer hits.deinit();
        try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, container, null, .keyboard, std.testing.allocator);
        try std.testing.expect(hasRingAround(prims.items, registry.getNode(row).?.geometry));
        try std.testing.expect(!hasRingAround(prims.items, registry.getNode(container).?.geometry));
    }

    // Cleared (-1, "nothing highlighted"): back to the container.
    try store.setModifier(container, .virtual_focus_target, .{ .number = -1 });
    {
        var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
        defer prims.deinit();
        var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
        defer images.deinit();
        var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
        defer paths.deinit();
        var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
        defer hits.deinit();
        try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, container, null, .keyboard, std.testing.allocator);
        try std.testing.expect(hasRingAround(prims.items, registry.getNode(container).?.geometry));
    }
}

test "BUG: bake does not recurse past MAX_TREE_DEPTH (deep tree can't overflow the stack)" {
    // A linear chain far deeper than MAX_TREE_DEPTH — exactly what the unbounded
    // celeris_node_append_child C-API lets a host build. Before the depth bound,
    // bakeNodeRecursive descended the whole chain; at large depths that overflows
    // the native stack (hard crash). The bound makes it stop at the cap instead.
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    const total = reg.MAX_TREE_DEPTH + 200; // 456 > cap, but small enough to not crash pre-fix
    var prev: reg.NodeId = reg.NULL_NODE;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const id = try registry.createNode(.box);
        try store.registerNode(id);
        if (prev != reg.NULL_NODE) registry.appendChild(prev, id);
        prev = id;
    }

    var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
    defer prims.deinit();
    var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
    defer images.deinit();
    var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
    defer paths.deinit();
    var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
    defer hits.deinit();

    try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, null, null, .pointer, std.testing.allocator);

    // Each box bakes one rect prim. With the bound, only nodes at depth ≤ cap are
    // visited, so the count is bounded regardless of how deep the tree goes. Pre-fix
    // all `total` nodes were baked (456), failing this assertion.
    try std.testing.expect(prims.items.len <= reg.MAX_TREE_DEPTH + 1);
}

test "intersectRect logic" {
    const a = ClipRect{ .x = 10, .y = 10, .w = 100, .h = 100 };
    const b = ClipRect{ .x = 50, .y = 50, .w = 100, .h = 100 };
    const c = intersectRect(a, b);

    try std.testing.expectEqual(@as(f32, 50.0), c.x);
    try std.testing.expectEqual(@as(f32, 50.0), c.y);
    try std.testing.expectEqual(@as(f32, 60.0), c.w);
    try std.testing.expectEqual(@as(f32, 60.0), c.h);

    const d = ClipRect{ .x = 200, .y = 200, .w = 50, .h = 50 };
    const e = intersectRect(a, d);
    try std.testing.expectEqual(@as(f32, 0.0), e.w);
    try std.testing.expectEqual(@as(f32, 0.0), e.h);
}

test "A blurred shadow bakes as its own prim: flagged, offset, spread-inflated" {
    var registry = reg.UIRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const box_id = try registry.createNode(.box);
    var store = props.PropertyStore.init(std.testing.allocator);
    defer store.deinit();
    try store.registerNode(box_id);

    // A design token: 0 18px 40px, spread -4, over a 12px-radius card.
    try store.setLayout(box_id, .width, .{ .dimension = .{ .value = 200, .unit = .px } });
    try store.setLayout(box_id, .height, .{ .dimension = .{ .value = 100, .unit = .px } });
    try store.setStyle(box_id, .radius, .{ .dimension = .{ .value = 12.0, .unit = .px } });
    try store.setStyle(box_id, .shadow_blur, .{ .dimension = .{ .value = 40.0, .unit = .px } });
    try store.setStyle(box_id, .shadow_offset_y, .{ .dimension = .{ .value = 18.0, .unit = .px } });
    try store.setStyle(box_id, .shadow_spread, .{ .dimension = .{ .value = -4.0, .unit = .px } });
    try store.setStyle(box_id, .shadow_color, props.PropValue.rgbA(0, 0, 0, 0.55));

    var engine = layout.LayoutEngine.init(&registry, &store, null);
    engine.solve(box_id, 0, 0, 200, 100);

    var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
    defer prims.deinit();
    var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
    defer images.deinit();
    var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
    defer paths.deinit();
    var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
    defer hits.deinit();
    try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, null, null, .pointer, std.testing.allocator);

    // Shadow first, body second — the shadow must paint underneath.
    try std.testing.expectEqual(@as(usize, 2), prims.items.len);
    const sh = prims.items[0];
    const body = prims.items[1];
    try std.testing.expectEqual(@as(f32, 1.0), sh.is_shadow);
    try std.testing.expectEqual(@as(f32, 0.0), body.is_shadow);
    // The body never carries a blur: only the shadow prim is blurred.
    try std.testing.expectEqual(@as(f32, 0.0), body.shadow_blur);
    try std.testing.expectEqual(@as(f32, 40.0), sh.shadow_blur);

    // Offset applied, then spread inflates the rect and its corners around it.
    try std.testing.expectApproxEqAbs(body.y + 18.0 + 4.0, sh.y, 0.001); // dy, minus a 4px shrink
    try std.testing.expectApproxEqAbs(body.x + 4.0, sh.x, 0.001);
    try std.testing.expectApproxEqAbs(body.width - 8.0, sh.width, 0.001);
    try std.testing.expectApproxEqAbs(body.height - 8.0, sh.height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), sh.border_radius, 0.001); // 12 + (-4)

    // It paints in the shadow color, with no border of its own.
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), sh.color_a, 0.001);
    try std.testing.expectEqual(@as(f32, 0.0), sh.border_color_a);
}

test "Blur 0 with an offset still casts a (hard-edged) shadow; a shadow going nowhere casts none" {
    const Case = struct { blur: f32, dx: f32, dy: f32, alpha: f32, prims: usize };
    const cases = [_]Case{
        .{ .blur = 0, .dx = 0, .dy = 4, .alpha = 0.5, .prims = 2 }, // hard shadow: on purpose
        .{ .blur = 8, .dx = 0, .dy = 0, .alpha = 0.5, .prims = 2 }, // blur, no offset: a halo
        .{ .blur = 0, .dx = 0, .dy = 0, .alpha = 0.5, .prims = 1 }, // exactly under the body
        .{ .blur = 8, .dx = 0, .dy = 4, .alpha = 0.0, .prims = 1 }, // invisible color
    };
    for (cases) |c| {
        var registry = reg.UIRegistry.init(std.testing.allocator);
        defer registry.deinit();
        const box_id = try registry.createNode(.box);
        var store = props.PropertyStore.init(std.testing.allocator);
        defer store.deinit();
        try store.registerNode(box_id);
        try store.setStyle(box_id, .shadow_blur, .{ .dimension = .{ .value = c.blur, .unit = .px } });
        try store.setStyle(box_id, .shadow_offset_x, .{ .dimension = .{ .value = c.dx, .unit = .px } });
        try store.setStyle(box_id, .shadow_offset_y, .{ .dimension = .{ .value = c.dy, .unit = .px } });
        try store.setStyle(box_id, .shadow_color, props.PropValue.rgbA(0, 0, 0, c.alpha));

        var engine = layout.LayoutEngine.init(&registry, &store, null);
        engine.solve(box_id, 0, 0, 200, 100);

        var prims = std.array_list.Managed(RectPrimitive).init(std.testing.allocator);
        defer prims.deinit();
        var images = std.array_list.Managed(ImagePrimitive).init(std.testing.allocator);
        defer images.deinit();
        var paths = std.array_list.Managed(PathSegPrim).init(std.testing.allocator);
        defer paths.deinit();
        var hits = std.array_list.Managed(HitNode).init(std.testing.allocator);
        defer hits.deinit();
        try bakeRegistry(&registry, &store, &prims, &images, &paths, &hits, null, null, .pointer, std.testing.allocator);
        try std.testing.expectEqual(c.prims, prims.items.len);
    }
}
