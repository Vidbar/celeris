//! Grid — migrated to the declarative component model.
//!
//! Lays a comptime tuple of child components into rows of `columns` equal-width
//! cells. `columns` is comptime so the row structure is generated statically.
//!
//!     try grid(&ctx, 3, .{ A{}, B{}, C{}, D{} }); // 2 rows: [A B C] [D]

const std = @import("std");
const component = @import("component.zig");

pub fn grid(ctx: *component.BuildContext, comptime columns: usize, children: anytype) !void {
    const b = ctx.builder;
    const container = try b.openNodeKeyed(.box, null);
    try b.flexColumn(container);
    try b.width(container, 100, .percent);

    const fields = std.meta.fields(@TypeOf(children));
    if (fields.len > 0 and columns > 0) {
        comptime var i: usize = 0;
        inline while (i < fields.len) : (i += columns) {
            const row = try b.openNodeKeyed(.box, null);
            try b.flexRow(row);
            try b.width(row, 100, .percent);

            comptime var c: usize = 0;
            inline while (c < columns and i + c < fields.len) : (c += 1) {
                const cell = try b.openNodeKeyed(.box, null);
                try b.flexGrow(cell, 1);
                try component.buildChild(ctx, @field(children, fields[i + c].name));
                b.close(); // cell
            }

            b.close(); // row
        }
    }

    b.close(); // container
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const std_testing = std.testing;
const reg = @import("../core/registry.zig");
const props = @import("../core/properties.zig");

test "grid arranges children into rows of N cells" {
    var registry = reg.UIRegistry.init(std_testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(std_testing.allocator);
    defer store.deinit();
    var bld = component.UIBuilder.init(&registry, &store);
    var ctx = component.BuildContext.init(&bld);

    const Cell = struct {
        tag: []const u8,
        pub fn build(self: *@This(), c: *component.BuildContext) !void {
            _ = try c.text(self.tag);
        }
    };

    // 4 children, 3 columns → 2 rows.
    try grid(&ctx, 3, .{
        Cell{ .tag = "a" },
        Cell{ .tag = "b" },
        Cell{ .tag = "c" },
        Cell{ .tag = "d" },
    });

    // container + 2 rows + (3 cells + 3 texts) + (1 cell + 1 text)
    // = 1 + 2 + 6 + 2 = 11 nodes
    try std_testing.expectEqual(@as(usize, 11), registry.nodes.items.len);

    const container = registry.getNode(0).?;
    const row1 = registry.getNode(container.first_child).?;
    // row1 should have 3 cells
    var cell_count: usize = 0;
    var cid = row1.first_child;
    while (cid != reg.NULL_NODE) : (cid = registry.getNode(cid).?.next_sibling) cell_count += 1;
    try std_testing.expectEqual(@as(usize, 3), cell_count);

    // row2 has 1 cell
    const row2 = registry.getNode(row1.id).?.next_sibling;
    var cell_count2: usize = 0;
    var cid2 = registry.getNode(row2).?.first_child;
    while (cid2 != reg.NULL_NODE) : (cid2 = registry.getNode(cid2).?.next_sibling) cell_count2 += 1;
    try std_testing.expectEqual(@as(usize, 1), cell_count2);
}
