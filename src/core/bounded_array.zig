//! Minimal fixed-capacity array — replaces `std.BoundedArray`, removed in Zig
//! 0.16. Stack-stored (no allocation); the API mirrors the std one we used:
//! `.slice()`, `.constSlice()`, `.append()`, `.pop()`, `.get()`, and `.len`.

const std = @import("std");

pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        len: usize = 0,

        pub fn slice(self: *Self) []T {
            return self.buffer[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn get(self: *const Self, i: usize) T {
            std.debug.assert(i < self.len); // matches std.BoundedArray.get; catches OOB in safe builds
            return self.buffer[i];
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buffer[self.len];
        }
    };
}
