//! Console logging for the engine, split so that routine chatter stays out of test
//! binaries.
//!
//! Why this exists rather than calling `std.debug.print` directly: Zig's build runner
//! reprints a step's ENTIRE stderr, prefixed by the step tree and followed by a
//! `failed command: <argv>` line, whenever the step writes any stderr at all —
//! success or not (see `build_runner.zig`: "No matter the result, we want to display
//! error/warning messages", and `Step.captureChildProcess`, which fills
//! `result_failed_command` up-front as context and never clears it). So a passing
//! `zig build test` that happened to log a few font paths printed a wall of output
//! ending in "failed command", which reads exactly like a failing build. It cost real
//! debugging time more than once.
//!
//! Rule of thumb: `info` for anything you'd want when running the app and would
//! shrug at in CI; `warn` for something actually wrong, which stays loud everywhere.

const std = @import("std");
const builtin = @import("builtin");

/// Routine diagnostics — font discovery, engine init, node counts. Silent unless
/// the host opts in, because a library shouldn't write to its app's stderr
/// uninvited: set the `CELERIS_LOG` environment variable (any value), or call
/// `setVerbose(true)` / `celeris_set_verbose_logging(true)`. Compiled out of test
/// binaries entirely (the `if` folds at comptime), so a green run looks green.
pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    if (!verbose()) return;
    std.debug.print("[Celeris] " ++ fmt, args);
}

var verbose_state: enum(u8) { unset, off, on } = .unset;

/// Whether `info` prints. Resolved from `CELERIS_LOG` on first use unless
/// `setVerbose` already decided.
pub fn verbose() bool {
    if (verbose_state == .unset) {
        verbose_state = if (builtin.link_libc and std.c.getenv("CELERIS_LOG") != null) .on else .off;
    }
    return verbose_state == .on;
}

/// Turns routine diagnostics on or off, overriding `CELERIS_LOG`.
pub fn setVerbose(on: bool) void {
    verbose_state = if (on) .on else .off;
}

/// Something went wrong. Printed everywhere, tests included — if a test trips one of
/// these, the noise is the point.
pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[Celeris] " ++ fmt, args);
}
