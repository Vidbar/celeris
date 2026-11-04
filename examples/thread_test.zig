const std = @import("std");
const celeris = @import("celeris");

const App = struct {
    counter: usize = 0,
    thread_running: bool = false,

    pub fn build(self: *App, b: anytype) !void {
        const root = try b.openBox();
        try b.flexColumn(root);
        try b.alignItems(root, .center);
        try b.justifyContent(root, .center);
        try b.width(root, 100, .percent);
        try b.height(root, 100, .percent);

        const title = try b.addText(if (self.thread_running) "Thread is running..." else "Thread is idle");
        try b.fontSize(title, 24);
        try b.marginBottom(title, 20);

        var buf: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&buf, "Count: {d}", .{self.counter});
        const count_text = try b.addText(count_str);
        try b.fontSize(count_text, 18);
        try b.marginBottom(count_text, 20);

        const btn = try b.openBox();
        try b.padding(btn, 10, 10, 10, 10);
        try b.background(btn, 50, 150, 250);
        try b.radius(btn, 4);
        try b.clickable(btn, "btn1");
        const btn_text = try b.addText("Start Thread");
        try b.textColor(btn_text, 255, 255, 255);
        b.close(); // btn

        b.close(); // root
    }
};

fn updateCountFromThread(app: *App) void {
    app.counter += 1;
    app.thread_running = false;
    celeris.framework.application.triggerRebuild();
}

fn backgroundTask(app: *App) void {
    // Simulate work
    var i: usize = 0;
    while (i < 500_000_000) : (i += 1) {
        std.atomic.spinLoopHint();
    }

    // Safely update UI from main thread
    celeris.framework.application.postTask(updateCountFromThread, app);
}

pub fn main() !void {
    var app = App{};
    var router = celeris.framework.events.EventRouter.init(std.heap.page_allocator);
    defer router.deinit();

    try router.on("btn1", &app, struct {
        fn cb(ctx: *App, ev: celeris.framework.events.Event) void {
            if (std.mem.eql(u8, ev.name, "mouse_down")) {
                if (!ctx.thread_running) {
                    ctx.thread_running = true;
                    celeris.framework.application.triggerRebuild();
                    _ = std.Thread.spawn(.{}, backgroundTask, .{ctx}) catch {};
                }
            }
        }
    }.cb);

    try celeris.framework.application.runApp(&app, &router, .{
        .title = "Celeris Thread Test",
        .width = 400,
        .height = 300,
        .theme = celeris.framework.theme.Theme.fromSeed(.{ .r = 0x67, .g = 0x50, .b = 0xa4 }, .dark),
    });
}
