const std = @import("std");
const celeris = @import("celeris");
const framework = celeris.framework;
const builder_mod = framework.builder;
const component = framework.component;
const events = framework.events;
const scroll_view = framework.scroll_view;
const tree_list = framework.tree_list;
const text_input = framework.text_input;

// ── Global widget instances ───────────────────────────────────────────────────

var g_allocator: std.mem.Allocator = undefined;
var g_tree_list: *tree_list.TreeList = undefined;
var g_router: events.EventRouter = undefined;
/// Owns framework-mounted components (the ScrollView is `mountOwned` now).
var g_mounts: component.MountTable = undefined;
var g_mounts_wired: bool = false;
/// Content height last applied to the ScrollView; a change triggers a rebuild so
/// the (framework-owned) instance picks up the fresh prop.
var g_content_height: f32 = 0;

var g_target_engine_id: i32 = -1;
var g_inspector_engine_id: i32 = -1;

extern "c" fn celeris_set_overlay_rect(
    engine_id: i32,
    visible: bool,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
) void;

// ── buildApp ──────────────────────────────────────────────────────────────────
//
// This function directly populates the UIBuilder.
// It is the 100% Zig host path for the inspector app.
//
// Structure:
//   Root (column, full screen, dark background)
//     Title text
//     Separator
//     TextInput widget
//     Separator
//     ScrollView widget (contains TreeList)

fn buildApp(b: *builder_mod.UIBuilder) anyerror!void {
    // Inject the DevTools Theme (bg_surface_hover removed — derived via stateLayer)
    b.theme = framework.theme.Theme{
        .bg_base = .{ .r = 20, .g = 20, .b = 22 },
        .bg_surface = .{ .r = 40, .g = 40, .b = 45 },
        .bg_input = .{ .r = 25, .g = 25, .b = 30 },
        .scrollbar_track = .{ .r = 25, .g = 25, .b = 28 },
        .scrollbar_thumb = .{ .r = 100, .g = 100, .b = 110 },
        .accent = .{ .r = 100, .g = 150, .b = 255 },
        .text = .{ .r = 240, .g = 240, .b = 240 },
        .border_color = .{ .r = 60, .g = 60, .b = 65 },
        .border_width = 1.0,
        .radius_base = 0.0,
    };

    // Wire the mount table and router to this engine's registry once (unmount
    // teardown + node-handler pruning). The router listener is load-bearing now
    // that TreeList registers real per-(node,kind) handlers via onNode instead of
    // the old prefix channel (which needed no per-node bookkeeping): without it,
    // every expand/collapse leaks 3 node_handlers entries per stale row.
    if (!g_mounts_wired) {
        b.registry.addNodeRemovedListener(&g_mounts, component.MountTable.nodeRemovedListener);
        b.registry.addNodeRemovedListener(&g_router, events.EventRouter.nodeRemovedListener);
        g_mounts_wired = true;
    }
    g_content_height = g_tree_list.getContentHeight();
    // ── Root container ────────────────────────────────────────────────────────
    const root = try b.openBox();
    try b.width(root, 100, .percent);
    try b.height(root, 100, .percent);
    try b.padding(root, 20, 20, 0, 20);
    try b.flexColumn(root);
    // Stretch children on the cross axis so mountOwned anchors (TextInput,
    // ScrollView) fill the column width.
    try b.alignItems(root, .stretch);
    try b.background(root, b.theme.bg_base.r, b.theme.bg_base.g, b.theme.bg_base.b);

    // ── Title ─────────────────────────────────────────────────────────────────
    const title = try b.addText("Celeris DevTools Inspector");
    try b.fontSize(title, 24);
    try b.textColor(title, b.theme.text.r, b.theme.text.g, b.theme.text.b);

    // ── Flex Wrap & Gap Demo ──────────────────────────────────────────────────
    const flex_demo = try b.openBox();
    try b.width(flex_demo, 100, .percent);
    try b.flexRow(flex_demo);
    try b.flexWrap(flex_demo, true);
    try b.gap(flex_demo, 10.0);
    try b.marginTop(flex_demo, 15);
    try b.marginBottom(flex_demo, 15);

    // Fixed box with gradient and shadow
    const box1 = try b.openBox();
    try b.width(box1, 100, .px);
    try b.height(box1, 50, .px);
    try b.radius(box1, 12.0);
    try b.linearGradient(box1, 255, 100, 100, 1.0, 100, 100, 255, 1.0, false);
    try b.shadow(box1, 15.0, 0.0, 5.0, 0, 0, 0, 0.5);
    b.close();

    // Growing box with radial gradient
    const box2 = try b.openBox();
    try b.height(box2, 50, .px);
    try b.flexGrow(box2, 1.0);
    try b.radius(box2, 12.0);
    try b.radialGradient(box2, 100, 255, 100, 1.0, 50, 150, 50, 1.0);
    try b.shadow(box2, 20.0, 0.0, 10.0, 0, 0, 0, 0.3);
    b.close();

    // Wrapping box
    const box3 = try b.openBox();
    try b.width(box3, 200, .px);
    try b.height(box3, 50, .px);
    try b.radius(box3, 12.0);
    try b.linearGradient(box3, 100, 100, 255, 1.0, 200, 100, 255, 1.0, true);
    try b.shadow(box3, 10.0, 2.0, 2.0, 0, 0, 0, 0.8);
    b.close();

    b.close(); // flex_demo

    // ── Separator ─────────────────────────────────────────────────────────────
    const sep1 = try b.openBox();
    try b.width(sep1, 100, .percent);
    try b.height(sep1, 2, .px);
    try b.marginTop(sep1, 10);
    try b.marginBottom(sep1, 20);
    try b.background(sep1, 100, 100, 200);
    b.close();

    // ── TextInput (framework-owned) ─────────────────────────────────────
    var ti_ctx = component.BuildContext{ .builder = b, .router = &g_router, .mounts = &g_mounts };
    try ti_ctx.mountOwned(text_input.TextInput, .{});

    // ── Separator ─────────────────────────────────────────────────────────────
    const sep2 = try b.openBox();
    try b.width(sep2, 100, .percent);
    try b.height(sep2, 2, .px);
    try b.marginTop(sep2, 20);
    try b.marginBottom(sep2, 20);
    try b.background(sep2, 100, 100, 200);
    b.close();

    // ── ScrollView (framework-owned, wraps TreeList) ──────────────────────────
    var sv_ctx = component.BuildContext{ .builder = b, .router = &g_router, .mounts = &g_mounts };
    try sv_ctx.mountOwned(scroll_view.ScrollView, .{
        .fill = true,
        .content = component.childOf(tree_list.TreeList, g_tree_list),
        .content_height = g_content_height,
    });

    b.close(); // root
}

// ── Event callback ────────────────────────────────────────────────────────────

fn appCallback(ev: *const celeris.c_api.CelerisEvent) callconv(.c) void {
    // All widgets are migrated and routed (TextInput caret blink, ScrollView
    // wheel, TreeList expand/hover). The router updates state in place; only the
    // hover-driven target overlay needs host follow-up here.
    const old_hover = g_tree_list.hovered_node;
    _ = g_router.dispatchEvent(ev);
    if (ev.event_type == @intFromEnum(celeris.c_api.CelerisEventType.tick)) return;

    // A tree expand/collapse (routed) changes the visible row count, so refresh
    // the scroll view's content height — otherwise its scroll range stays clamped
    // to the old size and the newly-revealed rows can't be scrolled into view.
    // The ScrollView is framework-owned now, so a rebuild re-applies the prop
    // (reconciliation reuses the nodes and the mounted instance).
    if (g_tree_list.getContentHeight() != g_content_height) {
        celeris.c_api.rebuildUI(g_inspector_engine_id, buildApp) catch {};
    }

    if (old_hover != g_tree_list.hovered_node) {
        if (g_tree_list.hovered_node >= 0) {
            if (g_tree_list.getNodeGeometry(@intCast(g_tree_list.hovered_node))) |rect| {
                celeris_set_overlay_rect(g_target_engine_id, true, rect[0], rect[1], rect[2], rect[3], 0.2, 0.6, 1.0, 0.4);
            } else {
                celeris_set_overlay_rect(g_target_engine_id, false, 0, 0, 0, 0, 0, 0, 0, 0);
            }
        } else {
            celeris_set_overlay_rect(g_target_engine_id, false, 0, 0, 0, 0, 0, 0, 0, 0);
        }
    }
}

// ── main ──────────────────────────────────────────────────────────────────────

pub fn attach(target_engine_id: i32) !i32 {
    g_target_engine_id = target_engine_id;
    g_allocator = std.heap.c_allocator;

    const config = celeris.c_api.CelerisConfig{ .is_headless = false };
    const inspector_id = celeris.c_api.celeris_create_engine(&config);
    if (inspector_id <= 0) {
        std.debug.print("DevTools: failed to create the inspector engine\n", .{});
        return error.InitFailed;
    }
    g_inspector_engine_id = inspector_id;

    // Create widgets (TextInput + ScrollView are framework-owned: mounted in buildApp).
    g_router = events.EventRouter.init(g_allocator);
    g_mounts = component.MountTable.init(g_allocator);
    g_tree_list = try tree_list.TreeList.init(g_allocator);

    celeris.c_api.celeris_register_event_callback(g_inspector_engine_id, appCallback);

    // Initial empty render
    try celeris.c_api.rebuildUI(g_inspector_engine_id, buildApp);

    // Refresh from target
    refreshTargetSnapshot() catch {};

    return g_inspector_engine_id;
}

pub fn refreshTargetSnapshot() !void {
    if (g_target_engine_id <= 0) return;

    // Capture DOM snapshot from target engine
    const json_ptr = celeris.c_api.celeris_get_dom_json(g_target_engine_id);
    if (json_ptr != null) {
        const json_str = std.mem.span(json_ptr);
        try g_tree_list.setSnapshot(json_str);
        celeris.c_api.celeris_free_string(g_target_engine_id, json_ptr);

        // Rebuild inspector UI
        try celeris.c_api.rebuildUI(g_inspector_engine_id, buildApp);
    }
}

pub fn main() !void {
    // If run directly, run in standalone mode looking at itself.
    g_allocator = std.heap.c_allocator;

    const config = celeris.c_api.CelerisConfig{ .is_headless = false };
    const engine_id = celeris.c_api.celeris_create_engine(&config);
    if (engine_id <= 0) return;

    _ = try attach(engine_id);

    _ = celeris.c_api.celeris_start_loop();
}
