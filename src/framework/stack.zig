//! Stack — migrated to the declarative component model.
//!
//! Overlay layout helper: the first child lays out in normal flow as the base
//! layer; each subsequent child is wrapped in an absolutely-positioned box so it
//! overlaps, with an increasing z-index. Children are a comptime tuple of
//! components, so there are no vtables and no per-child allocation.
//!
//!     try stack(&ctx, .{ Background{}, Overlay{}, Badge{} });

const std = @import("std");
const component = @import("component.zig");

pub fn stack(ctx: *component.BuildContext, children: anytype) !void {
    const b = ctx.builder;
    const container = try b.openNodeKeyed(.box, null);
    try b.width(container, 100, .percent);
    try b.height(container, 100, .percent);

    inline for (std.meta.fields(@TypeOf(children)), 0..) |f, i| {
        const child = @field(children, f.name);
        if (i == 0) {
            try component.buildChild(ctx, child);
        } else {
            const wrap = try b.openNodeKeyed(.box, null);
            try b.store.setLayout(wrap, .position, .{ .keyword = .absolute });
            try b.store.setLayout(wrap, .left, .{ .dimension = .{ .value = 0, .unit = .px } });
            try b.store.setLayout(wrap, .top, .{ .dimension = .{ .value = 0, .unit = .px } });
            try b.store.setStyle(wrap, .z_index, .{ .number = @floatFromInt(i) });
            try component.buildChild(ctx, child);
            b.close(); // wrap
        }
    }

    b.close(); // container
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const std_testing = std.testing;
const reg = @import("../core/registry.zig");
const props = @import("../core/properties.zig");

test "stack overlays children: first in flow, rest absolute with z-index" {
    var registry = reg.UIRegistry.init(std_testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std_testing.allocator);
    defer store.deinit();
    var bld = component.UIBuilder.init(&registry, &store);
    var ctx = component.BuildContext.init(&bld);

    const Layer = struct {
        tag: []const u8,
        pub fn build(self: *@This(), c: *component.BuildContext) !void {
            try c.boxLeaf(.{ .id = self.tag });
        }
    };

    try stack(&ctx, .{
        Layer{ .tag = "base" },
        Layer{ .tag = "mid" },
        Layer{ .tag = "top" },
    });

    // container + base + (wrap+mid) + (wrap+top) = 1 + 1 + 2 + 2 = 6 nodes
    try std_testing.expectEqual(@as(usize, 6), registry.nodes.items.len);

    // The container's children: base (flow), wrap1 (abs), wrap2 (abs).
    const container = registry.getNode(0).?;
    const base = container.first_child;
    try std_testing.expectEqual(@as(?props.PropValue, null), store.getLayout(base, .position));

    const wrap1 = registry.getNode(base).?.next_sibling;
    try std_testing.expectEqual(props.Keyword.absolute, store.getLayout(wrap1, .position).?.keyword);
    try std_testing.expectEqual(@as(f32, 1), store.getStyle(wrap1, .z_index).?.number);

    const wrap2 = registry.getNode(wrap1).?.next_sibling;
    try std_testing.expectEqual(@as(f32, 2), store.getStyle(wrap2, .z_index).?.number);
}
