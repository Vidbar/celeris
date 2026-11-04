//! XDG Desktop Portal FileChooser over D-Bus (Linux file dialogs).
//!
//! Talks to `org.freedesktop.portal.Desktop` via `dlopen("libdbus-1.so.3")` — no
//! build-time link or header. The flow: call FileChooser.OpenFile/SaveFile (which
//! returns a Request object path), subscribe to that Request's `Response` signal,
//! pump the bus until it arrives, and pull the first URI out of the `a{sv}`
//! results. Everything degrades to null (no dialog) if libdbus, the session bus,
//! or a portal backend is missing — so it's a clean no-op where unsupported.

const std = @import("std");

// ── libdbus opaque types ────────────────────────────────────────────────────
const DBusConnection = anyopaque;
const DBusMessage = anyopaque;
// The caller allocates these; we only need correctly-sized, pointer-aligned
// scratch — libdbus uses its own internal fields. Oversize-and-aligned is safe.
const DBusMessageIter = extern struct { _opaque: [16]*anyopaque };
const DBusError = extern struct { _opaque: [8]*anyopaque };

// D-Bus type codes (ASCII).
const TYPE_INVALID: c_int = 0;
const TYPE_STRING: c_int = 's';
const TYPE_OBJECT_PATH: c_int = 'o';
const TYPE_ARRAY: c_int = 'a';
const TYPE_VARIANT: c_int = 'v';
const TYPE_UINT32: c_int = 'u';
const TYPE_BOOLEAN: c_int = 'b';
const TYPE_DICT_ENTRY: c_int = 'e';
const BUS_SESSION: c_int = 0;

const Fns = struct {
    bus_get: *const fn (c_int, *DBusError) callconv(.c) ?*DBusConnection,
    error_init: *const fn (*DBusError) callconv(.c) void,
    error_is_set: *const fn (*DBusError) callconv(.c) c_int,
    error_free: *const fn (*DBusError) callconv(.c) void,
    msg_new_call: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*DBusMessage,
    msg_unref: *const fn (*DBusMessage) callconv(.c) void,
    iter_init_append: *const fn (*DBusMessage, *DBusMessageIter) callconv(.c) void,
    iter_append_basic: *const fn (*DBusMessageIter, c_int, *const anyopaque) callconv(.c) c_int,
    iter_open: *const fn (*DBusMessageIter, c_int, ?[*:0]const u8, *DBusMessageIter) callconv(.c) c_int,
    iter_close: *const fn (*DBusMessageIter, *DBusMessageIter) callconv(.c) c_int,
    send_block: *const fn (*DBusConnection, *DBusMessage, c_int, *DBusError) callconv(.c) ?*DBusMessage,
    iter_init: *const fn (*DBusMessage, *DBusMessageIter) callconv(.c) c_int,
    iter_arg_type: *const fn (*DBusMessageIter) callconv(.c) c_int,
    iter_get_basic: *const fn (*DBusMessageIter, *anyopaque) callconv(.c) void,
    iter_next: *const fn (*DBusMessageIter) callconv(.c) c_int,
    iter_recurse: *const fn (*DBusMessageIter, *DBusMessageIter) callconv(.c) void,
    add_match: *const fn (*DBusConnection, [*:0]const u8, *DBusError) callconv(.c) void,
    read_write: *const fn (*DBusConnection, c_int) callconv(.c) c_int,
    pop_message: *const fn (*DBusConnection) callconv(.c) ?*DBusMessage,
    is_signal: *const fn (*DBusMessage, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    flush: *const fn (*DBusConnection) callconv(.c) void,
};

fn load(lib: *std.DynLib) ?Fns {
    var f: Fns = undefined;
    inline for (@typeInfo(Fns).@"struct".fields) |field| {
        const sym = "dbus_" ++ comptime mapName(field.name);
        @field(f, field.name) = lib.lookup(field.type, sym) orelse return null;
    }
    return f;
}

/// Maps a short field name to the real `dbus_*` symbol suffix.
fn mapName(comptime name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "bus_get")) "bus_get" else if (std.mem.eql(u8, name, "error_init")) "error_init" else if (std.mem.eql(u8, name, "error_is_set")) "error_is_set" else if (std.mem.eql(u8, name, "error_free")) "error_free" else if (std.mem.eql(u8, name, "msg_new_call")) "message_new_method_call" else if (std.mem.eql(u8, name, "msg_unref")) "message_unref" else if (std.mem.eql(u8, name, "iter_init_append")) "message_iter_init_append" else if (std.mem.eql(u8, name, "iter_append_basic")) "message_iter_append_basic" else if (std.mem.eql(u8, name, "iter_open")) "message_iter_open_container" else if (std.mem.eql(u8, name, "iter_close")) "message_iter_close_container" else if (std.mem.eql(u8, name, "send_block")) "connection_send_with_reply_and_block" else if (std.mem.eql(u8, name, "iter_init")) "message_iter_init" else if (std.mem.eql(u8, name, "iter_arg_type")) "message_iter_get_arg_type" else if (std.mem.eql(u8, name, "iter_get_basic")) "message_iter_get_basic" else if (std.mem.eql(u8, name, "iter_next")) "message_iter_next" else if (std.mem.eql(u8, name, "iter_recurse")) "message_iter_recurse" else if (std.mem.eql(u8, name, "add_match")) "bus_add_match" else if (std.mem.eql(u8, name, "read_write")) "connection_read_write" else if (std.mem.eql(u8, name, "pop_message")) "connection_pop_message" else if (std.mem.eql(u8, name, "is_signal")) "message_is_signal" else if (std.mem.eql(u8, name, "flush")) "connection_flush" else unreachable;
}

/// Appends the `a{sv}` options dict at `it`. When `directory` is true it carries a
/// single `{"directory": <true>}` entry, which switches FileChooser.OpenFile into
/// folder-selection mode; otherwise the dict is empty.
fn appendOptions(f: Fns, it: *DBusMessageIter, directory: bool) void {
    var arr: DBusMessageIter = undefined;
    if (f.iter_open(it, TYPE_ARRAY, "{sv}", &arr) == 0) return;
    if (directory) {
        var entry: DBusMessageIter = undefined;
        if (f.iter_open(&arr, TYPE_DICT_ENTRY, null, &entry) != 0) {
            var key: [*:0]const u8 = "directory";
            _ = f.iter_append_basic(&entry, TYPE_STRING, @ptrCast(&key));
            var variant: DBusMessageIter = undefined;
            if (f.iter_open(&entry, TYPE_VARIANT, "b", &variant) != 0) {
                var val: u32 = 1; // D-Bus boolean is 32-bit on the wire.
                _ = f.iter_append_basic(&variant, TYPE_BOOLEAN, @ptrCast(&val));
                _ = f.iter_close(&entry, &variant);
            }
            _ = f.iter_close(&arr, &entry);
        }
    }
    _ = f.iter_close(it, &arr);
}

/// Extracts the first `file://` URI from the `results` `a{sv}` (iterator at the
/// dict), returning a UTF-8 filesystem path owned by `allocator`, or null.
fn extractFirstUri(f: Fns, allocator: std.mem.Allocator, results_it: *DBusMessageIter) ?[]u8 {
    var arr: DBusMessageIter = undefined;
    f.iter_recurse(results_it, &arr); // into the a{sv}
    while (f.iter_arg_type(&arr) != TYPE_INVALID) : (_ = f.iter_next(&arr)) {
        var entry: DBusMessageIter = undefined;
        f.iter_recurse(&arr, &entry); // into the dict entry {sv}
        if (f.iter_arg_type(&entry) != TYPE_STRING) continue;
        var key_ptr: [*:0]const u8 = undefined;
        f.iter_get_basic(&entry, @ptrCast(&key_ptr));
        if (!std.mem.eql(u8, std.mem.span(key_ptr), "uris")) continue;
        _ = f.iter_next(&entry); // → variant
        if (f.iter_arg_type(&entry) != TYPE_VARIANT) return null;
        var variant: DBusMessageIter = undefined;
        f.iter_recurse(&entry, &variant); // into variant → as (array of string)
        if (f.iter_arg_type(&variant) != TYPE_ARRAY) return null;
        var uris: DBusMessageIter = undefined;
        f.iter_recurse(&variant, &uris);
        if (f.iter_arg_type(&uris) != TYPE_STRING) return null;
        var uri_ptr: [*:0]const u8 = undefined;
        f.iter_get_basic(&uris, @ptrCast(&uri_ptr));
        return uriToPath(allocator, std.mem.span(uri_ptr));
    }
    return null;
}

/// "file:///home/a%20b.txt" → "/home/a b.txt" (allocator-owned).
fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return allocator.dupe(u8, uri) catch null;
    // Skip an optional host between "file://" and the leading "/".
    var rest = uri[prefix.len..];
    if (rest.len > 0 and rest[0] != '/') {
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[slash..] else return null;
    }
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < rest.len) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch {
                out.append(rest[i]) catch return null;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch {
                out.append(rest[i]) catch return null;
                i += 1;
                continue;
            };
            out.append(@intCast(hi * 16 + lo)) catch return null;
            i += 3;
        } else {
            out.append(rest[i]) catch return null;
            i += 1;
        }
    }
    return out.toOwnedSlice() catch null;
}

/// Shows the portal file dialog. `save` picks SaveFile vs OpenFile; `directory`
/// (OpenFile only) switches it to folder selection. Returns the chosen path
/// (allocator-owned) or null (cancelled / unsupported).
pub fn fileDialog(allocator: std.mem.Allocator, title: ?[]const u8, save: bool, directory: bool) ?[]u8 {
    var lib = std.DynLib.open("libdbus-1.so.3") catch return null;
    defer lib.close();
    const f = load(&lib) orelse return null;

    var err: DBusError = undefined;
    f.error_init(&err);
    defer f.error_free(&err);

    const conn = f.bus_get(BUS_SESSION, &err) orelse return null;
    if (f.error_is_set(&err) != 0) return null;

    const method: [*:0]const u8 = if (save) "SaveFile" else "OpenFile";
    const msg = f.msg_new_call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.FileChooser",
        method,
    ) orelse return null;

    var ait: DBusMessageIter = undefined;
    f.iter_init_append(msg, &ait);
    var parent: [*:0]const u8 = ""; // no parent window export
    _ = f.iter_append_basic(&ait, TYPE_STRING, @ptrCast(&parent));
    var title_buf: [256]u8 = undefined;
    const title_z = toZ(&title_buf, title orelse (if (save) "Save File" else "Open File"));
    _ = f.iter_append_basic(&ait, TYPE_STRING, @ptrCast(&title_z));
    appendOptions(f, &ait, directory);

    const reply = f.send_block(conn, msg, 30000, &err);
    f.msg_unref(msg);
    if (reply == null or f.error_is_set(&err) != 0) return null;
    const rep = reply.?;

    // Reply = the Request object path.
    var rit: DBusMessageIter = undefined;
    if (f.iter_init(rep, &rit) == 0 or f.iter_arg_type(&rit) != TYPE_OBJECT_PATH) {
        f.msg_unref(rep);
        return null;
    }
    var req_ptr: [*:0]const u8 = undefined;
    f.iter_get_basic(&rit, @ptrCast(&req_ptr));
    var path_buf: [512]u8 = undefined;
    const req_path = std.fmt.bufPrintZ(&path_buf, "{s}", .{std.mem.span(req_ptr)}) catch {
        f.msg_unref(rep);
        return null;
    };
    f.msg_unref(rep);

    // Subscribe to that Request's Response signal and pump until it arrives.
    var rule_buf: [640]u8 = undefined;
    const rule = std.fmt.bufPrintZ(&rule_buf, "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'", .{req_path}) catch return null;
    f.add_match(conn, rule, &err);
    f.flush(conn);

    var spins: u32 = 0;
    while (spins < 6000) : (spins += 1) { // ~10 min safety cap; the user gates this
        _ = f.read_write(conn, 100);
        while (f.pop_message(conn)) |sig| {
            if (f.is_signal(sig, "org.freedesktop.portal.Request", "Response") != 0) {
                const result = parseResponse(f, allocator, sig);
                f.msg_unref(sig);
                return result;
            }
            f.msg_unref(sig);
        }
    }
    return null;
}

/// Response signal args: `(u response, a{sv} results)`. response 0 = success.
fn parseResponse(f: Fns, allocator: std.mem.Allocator, sig: *DBusMessage) ?[]u8 {
    var it: DBusMessageIter = undefined;
    if (f.iter_init(sig, &it) == 0) return null;
    if (f.iter_arg_type(&it) != TYPE_UINT32) return null;
    var code: u32 = 0;
    f.iter_get_basic(&it, @ptrCast(&code));
    if (code != 0) return null; // cancelled / error
    _ = f.iter_next(&it); // → a{sv} results
    if (f.iter_arg_type(&it) != TYPE_ARRAY) return null;
    return extractFirstUri(f, allocator, &it);
}

fn toZ(buf: []u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    std.mem.copyForwards(u8, buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

// ── Tests ───────────────────────────────────────────────────────────────────
test "uriToPath strips file:// and percent-decodes" {
    const a = std.testing.allocator;
    const p1 = uriToPath(a, "file:///home/a%20b.txt").?;
    defer a.free(p1);
    try std.testing.expectEqualStrings("/home/a b.txt", p1);
    const p2 = uriToPath(a, "file:///etc/hosts").?;
    defer a.free(p2);
    try std.testing.expectEqualStrings("/etc/hosts", p2);
}

test "libdbus loads and every dbus_* symbol resolves (Linux only)" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var lib = std.DynLib.open("libdbus-1.so.3") catch return error.SkipZigTest;
    defer lib.close();
    // Confirms the comptime symbol-name mapping matches the real exports — the one
    // part of the portal flow that's checkable without a running portal backend.
    try std.testing.expect(load(&lib) != null);
}
