//! Proves testkit.zig's finders/interactions actually resolve through the real
//! widget/event pipeline, not a fiction of their own. Mounts a real `Button`
//! the same way `button.zig`'s own tests do, then drives it entirely through
//! `testkit.Query` instead of manual node-walking.
const std = @import("std");
const testing = std.testing;
const component = @import("component.zig");
const events = @import("events.zig");
const button = @import("button.zig");
const testkit = @import("testkit.zig");

test "testkit.Query finds a mounted Button by role and label, and clicks it for real" {
    var h = testkit.Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();

    var b = component.UIBuilder.init(&h.registry, &h.store);
    var ctx = component.BuildContext{ .builder = &b, .router = &h.router, .mounts = &h.mounts };
    _ = try b.openNodeKeyed(.box, null); // root

    const Sink = struct {
        var clicks: u32 = 0;
        fn onClick(_: ?*anyopaque, _: events.Event) void {
            clicks += 1;
        }
    };
    Sink.clicks = 0;

    try ctx.mountOwned(button.Button, .{
        .label = "Save",
        .on_click = events.Handler{ .ptr = null, .call = Sink.onClick },
    });
    b.close();

    var q = testkit.Query.init(&h);

    // Same node, found two different ways — role is the ARIA-style contract,
    // label is what a user (or a screen reader) actually sees.
    const by_role = q.byRole("button") orelse return error.ButtonNotFound;
    const by_label = q.byLabel("Save") orelse return error.ButtonNotFound;
    try testing.expectEqual(by_role, by_label);

    q.click(by_role);
    try testing.expectEqual(@as(u32, 1), Sink.clicks);
}

test "testkit.Query.expectVisible catches a hugged box that never got measured" {
    // Mirrors the exact TooltipHost/ToastHost class of bug test_support.zig's
    // Harness.solve() doc comment warns about: a node can have every prop set
    // and still be 0x0 on screen. expectVisible must fail for it.
    var h = testkit.Harness.init(testing.allocator);
    defer h.deinit();
    h.wire();

    var b = component.UIBuilder.init(&h.registry, &h.store);
    const root = try b.openBox();
    b.close();

    // No solve() call: the node never gets measured, so its geometry stays
    // the zero-value default.
    var q = testkit.Query.init(&h);
    try testing.expectError(testkit.Query.AssertError.NodeNotVisible, q.expectVisible(root));
}
