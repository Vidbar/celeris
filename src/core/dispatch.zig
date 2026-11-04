const std = @import("std");

pub const Task = struct {
    callback: *const fn (ctx: ?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
};

pub const TaskQueue = struct {
    mutex: std.atomic.Mutex,
    tasks: std.ArrayList(Task),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TaskQueue {
        return .{
            .mutex = .unlocked,
            .tasks = .empty,
            .allocator = allocator,
        };
    }

    fn acquireLock(self: *TaskQueue) void {
        var spin: u32 = 0;
        while (!self.mutex.tryLock()) {
            if (spin < 10) {
                std.atomic.spinLoopHint();
                spin += 1;
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    pub fn deinit(self: *TaskQueue) void {
        self.acquireLock();
        defer self.mutex.unlock();
        self.tasks.deinit(self.allocator);
    }

    pub fn push(self: *TaskQueue, task: Task) !void {
        self.acquireLock();
        defer self.mutex.unlock();
        try self.tasks.append(self.allocator, task);
    }

    /// Drains all currently queued tasks and executes them.
    /// This should only be called from the main thread.
    pub fn drain(self: *TaskQueue) void {
        self.acquireLock();
        if (self.tasks.items.len == 0) {
            self.mutex.unlock();
            return;
        }

        // Move tasks to a local array so we can unlock the mutex
        // quickly and execute tasks without holding the lock.
        // This prevents deadlocks if a task calls postTask itself.
        const items = self.tasks.toOwnedSlice(self.allocator) catch {
            self.mutex.unlock();
            return; // Ignore OOM here, task dropped
        };
        self.mutex.unlock();

        defer self.allocator.free(items);

        for (items) |task| {
            task.callback(task.ctx);
        }
    }
};

// ── Concurrency tests ───────────────────────────────────────────────────────
// The queue is the ONLY sanctioned way for a background thread to touch engine
// state (`celeris_post_task`), so a lost, duplicated or torn task here would
// surface as state silently not applying — the hardest class of bug to chase
// from an app. These stress it with real threads rather than reasoning about it.

var test_sink: std.atomic.Value(u64) = .init(0);

fn testTaskAdd(_: ?*anyopaque) callconv(.c) void {
    _ = test_sink.fetchAdd(1, .monotonic);
}

test "TaskQueue — concurrent producers lose no tasks" {
    const producers = 8;
    const per_producer = 2000;

    var q = TaskQueue.init(std.testing.allocator);
    defer q.deinit();
    test_sink.store(0, .monotonic);

    const Producer = struct {
        fn run(queue: *TaskQueue) void {
            var i: usize = 0;
            while (i < per_producer) : (i += 1) {
                queue.push(.{ .callback = &testTaskAdd, .ctx = null }) catch {};
            }
        }
    };

    var threads: [producers]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Producer.run, .{&q});

    // Drain concurrently with the producers, the way the render loop does, then
    // once more after they join to pick up whatever landed after the last drain.
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) q.drain();
    for (threads) |t| t.join();
    q.drain();

    try std.testing.expectEqual(@as(u64, producers * per_producer), test_sink.load(.monotonic));
}

fn testTaskReentrant(ctx: ?*anyopaque) callconv(.c) void {
    const queue: *TaskQueue = @ptrCast(@alignCast(ctx.?));
    // A task that queues another task must not deadlock: `drain` releases the
    // lock before running callbacks precisely so this is legal.
    if (test_sink.fetchAdd(1, .monotonic) < 100) {
        queue.push(.{ .callback = &testTaskReentrant, .ctx = ctx }) catch {};
    }
}

test "TaskQueue — a task may post from inside drain without deadlocking" {
    var q = TaskQueue.init(std.testing.allocator);
    defer q.deinit();
    test_sink.store(0, .monotonic);

    try q.push(.{ .callback = &testTaskReentrant, .ctx = &q });
    var rounds: usize = 0;
    while (rounds < 200) : (rounds += 1) q.drain();

    try std.testing.expectEqual(@as(u64, 101), test_sink.load(.monotonic));
}

// A bare arrival counter can't tell "A lost, B ran twice" from "both ran once".
// This checks payload integrity: every (producer, seq) pair must arrive exactly
// once with its `ctx` pointer intact — so a torn Task write (callback/ctx from
// different pushes) or a lost-and-duplicated pair is caught, not just net loss.

const PRODUCERS = 6;
const PER_PRODUCER = 4000;

var g_marks: [PRODUCERS * PER_PRODUCER]std.atomic.Value(u8) = undefined;

fn markArrival(ctx: ?*anyopaque) callconv(.c) void {
    // ctx is `1 + index` reinterpreted as a pointer — never dereferenced.
    const idx = @intFromPtr(ctx) - 1;
    _ = g_marks[idx].fetchAdd(1, .monotonic);
}

test "TaskQueue — concurrent producers: every task arrives exactly once, ctx intact" {
    var q = TaskQueue.init(std.testing.allocator);
    defer q.deinit();
    for (&g_marks) |*m| m.store(0, .monotonic);

    const Producer = struct {
        fn run(queue: *TaskQueue, pid: usize) void {
            var s: usize = 0;
            while (s < PER_PRODUCER) : (s += 1) {
                const idx = pid * PER_PRODUCER + s;
                queue.push(.{
                    .callback = &markArrival,
                    .ctx = @ptrFromInt(idx + 1), // +1 so it's never null
                }) catch unreachable;
            }
        }
    };

    var threads: [PRODUCERS]std.Thread = undefined;
    for (&threads, 0..) |*t, pid| t.* = try std.Thread.spawn(.{}, Producer.run, .{ &q, pid });
    var spins: usize = 0;
    while (spins < 2000) : (spins += 1) q.drain();
    for (threads) |t| t.join();
    q.drain();

    var missing: usize = 0;
    var duped: usize = 0;
    for (&g_marks) |*m| switch (m.load(.monotonic)) {
        0 => missing += 1,
        1 => {},
        else => duped += 1,
    };
    try std.testing.expectEqual(@as(usize, 0), missing);
    try std.testing.expectEqual(@as(usize, 0), duped);
}
