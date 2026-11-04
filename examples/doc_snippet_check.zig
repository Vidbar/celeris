//! Build-time guard for docs/FRAMEWORK_API.md: the Quick Start snippet must be
//! `examples/counter.zig` exactly (minus the file's leading `//!` header). Run by
//! `zig build test`. Without it the docs claimed "cannot drift" and had drifted.
//!
//! Usage: doc_snippet_check <docs/FRAMEWORK_API.md> <examples/counter.zig>

const std = @import("std");

const marker = "This is `examples/counter.zig` verbatim";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: doc_snippet_check <doc.md> <example.zig>\n", .{});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();
    // Normalize line endings: a Windows checkout with core.autocrlf=true (GitHub's
    // windows runners) has CRLF files, and the fence/newline matching below is LF.
    const doc = try toLf(arena, try cwd.readFileAlloc(init.io, args[1], arena, .limited(4 << 20)));
    const src = try toLf(arena, try cwd.readFileAlloc(init.io, args[2], arena, .limited(1 << 20)));

    const at = std.mem.indexOf(u8, doc, marker) orelse {
        std.debug.print("doc_snippet_check: marker not found in {s}\n", .{args[1]});
        return 1;
    };
    const fence = "```zig\n";
    const start = (std.mem.indexOfPos(u8, doc, at, fence) orelse return fail(args)) + fence.len;
    const end = std.mem.indexOfPos(u8, doc, start, "```") orelse return fail(args);
    const snippet = doc[start..end];

    // Drop the example's leading `//!` doc comment and the blank line after it.
    var body: []const u8 = src;
    while (std.mem.startsWith(u8, body, "//!")) {
        const nl = std.mem.indexOfScalar(u8, body, '\n') orelse break;
        body = body[nl + 1 ..];
    }
    body = std.mem.trimStart(u8, body, "\n");

    if (!std.mem.eql(u8, std.mem.trimEnd(u8, snippet, "\n"), std.mem.trimEnd(u8, body, "\n"))) {
        std.debug.print("doc_snippet_check: the Quick Start snippet in {s} no longer matches {s}; paste the file (without its //! header) into the doc.\n", .{ args[1], args[2] });
        return 1;
    }
    return 0;
}

fn toLf(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, s, "\r\n", "\n");
}

fn fail(args: []const [:0]const u8) u8 {
    std.debug.print("doc_snippet_check: no ```zig block after the marker in {s}\n", .{args[1]});
    return 1;
}
