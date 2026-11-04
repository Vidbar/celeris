const std = @import("std");
const celeris = @import("celeris");
const fw = celeris.framework;

fn buildWrapper(b: *fw.builder.UIBuilder) anyerror!void {
    const root = try b.openBox();
    try b.width(root, 200, .px);
    try b.height(root, 60, .px);
    try b.background(root, 37, 99, 235);
    try b.radius(root, 8);
    try b.clickable(root, "btn_hello_headless");
    try b.focusable(root, "input_1");

    _ = try b.addText("Hello World");

    b.close();
}

fn myCallback(ev: *const celeris.c_api.CelerisEvent) callconv(.c) void {
    std.debug.print(">>> HEADLESS HOST RECEIVED EVENT: type={d} id={s} key={d}\n", .{ ev.event_type, ev.action_id, ev.key_code });
}

pub fn main() !void {
    const config = celeris.c_api.CelerisConfig{ .is_headless = true };
    const engine_id = celeris.c_api.celeris_create_engine(&config);
    if (engine_id <= 0) {
        std.debug.print("Failed to init engine\n", .{});
        return;
    }
    // Tear the engine down on exit: frees everything it owns and releases its slot.
    defer celeris.c_api.celeris_deinit(engine_id);

    celeris.c_api.rebuildUI(engine_id, buildWrapper) catch |err| {
        std.debug.print("Failed to rebuild UI: {}\n", .{err});
        return;
    };

    celeris.c_api.celeris_register_event_callback(engine_id, &myCallback);
    std.debug.print("Headless Engine started.\n", .{});

    // No celeris_start_loop() here: that runs the blocking windowed event loop,
    // which never returns without an OS window. In headless mode the layout is
    // already solved by rebuildUI, so we drive the engine directly:
    // dispatch synthetic input and read a DevTools snapshot, then exit.

    // Simulate a click on the box (it is placed at 0,0 since c_api solve starts at 0,0)
    // This will trigger 'click' AND set 'focused_node'.
    _ = celeris.c_api.celeris_dispatch_mouse_click(engine_id, 100.0, 30.0);

    // Simulate keyboard typing 'A' (char code 65). 2 = char_input
    _ = celeris.c_api.celeris_dispatch_keyboard_event(engine_id, 2, 65);

    // Test DevTools Snapshot
    if (celeris.c_api.celeris_get_devtools_snapshot(engine_id)) |json_ptr| {
        const json_str = std.mem.span(json_ptr);
        std.debug.print(">>> DEVTOOLS SNAPSHOT: {s}\n", .{json_str});
    }

    std.debug.print("Headless Frame Rendered Successfully.\n", .{});
}
