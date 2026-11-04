//! Reactive signals — the state layer of the declarative framework.
//!
//! A `Signal(T)` is an observable value. Reading it inside an effect subscribes
//! that effect automatically (SolidJS-style dependency tracking); writing a new
//! value re-runs the subscribed effects. Writing an *equal* value is a no-op,
//! mirroring the `PropValue.eql` dirty-guard already in `PropertyStore`.
//!
//! Bindings turn a signal into a write into the retained tree: `bindStyle`
//! creates an effect that pushes the signal's value into `PropertyStore`, so the
//! existing dirty-tracking does the rest — no `build()` re-runs for value
//! changes, and a color change only sets `render_dirty`, never `layout_dirty`.
//!
//! Ownership: effects live in a `Scope`. Dropping the scope tears down every
//! effect and its subscriptions in one batch — the same arena-style lifetime
//! model `PropertyStore` uses for strings. The UI loop is single-threaded, so a
//! single module-global "current effect" pointer is all the tracker needs.

const std = @import("std");
const props = @import("properties.zig");
const reg = @import("registry.zig");

// ── Global tracking state ─────────────────────────────────────────────────────

const Tracker = struct {
    /// The effect currently executing, if any. Signal reads subscribe to it.
    current: ?*Effect = null,
    /// Propagation nesting depth. `set()`/`batch()` open a propagation; when the
    /// OUTERMOST one closes (depth → 0) the queued effects are drained in dependency
    /// order. A burst of writes inside one propagation collapses into one run each.
    depth: u32 = 0,
    /// True while the drain loop is running, so a `set()` issued by an effect during
    /// the drain just enqueues (the running loop picks it up) instead of recursing.
    draining: bool = false,
    /// Queued effects. Optional entries so a destroyed effect can be nulled out
    /// (`unschedule`) without disturbing the drain — that's what makes tearing down
    /// a scope mid-drain safe instead of a use-after-free.
    pending: std.ArrayListUnmanaged(?*Effect) = .empty,
    pending_allocator: ?std.mem.Allocator = null,
    /// Monotonic counter bumped when a top-level propagation opens. The component
    /// build layer stamps a rebuilt subtree's anchor with the current value
    /// so that, within one propagation, a parent rebuild that already re-ran a child
    /// makes the child's own queued build-effect skip (subsumption).
    propagation_gen: u32 = 0,
    /// Set when `schedule` could not enqueue an effect and had to run it inline,
    /// out of dependency order — the one path where the drain is not glitch-free.
    /// Only reachable under allocator exhaustion. Tests assert it stays false.
    glitched: bool = false,
};

/// True if any propagation in this process ever had to fall back to an
/// out-of-order inline effect run (allocator exhaustion in `schedule`). Sticky.
pub fn everGlitched() bool {
    return tracker.glitched;
}

/// The generation of the in-flight (or most recent) top-level propagation. Used by
/// the build layer's subsumption guard; opaque to everything else.
pub fn currentPropagationGen() u32 {
    return tracker.propagation_gen;
}

/// Drops `eff` from the pending queue (called when it is destroyed) so the drain
/// never dereferences a freed effect. Cheap no-op when nothing is queued.
fn unschedule(eff: *Effect) void {
    for (tracker.pending.items, 0..) |p, i| {
        if (p == eff) tracker.pending.items[i] = null;
    }
}

var tracker: Tracker = .{};

/// Optional global hook invoked once at the end of a top-level propagation that
/// actually ran at least one effect. `signals.zig` is a core module and cannot
/// import `c_api`, so the engine registers a callback here to wake the render
/// loop when a signal is written outside an OS event (background thread, host
/// timer). No-op propagations (equal-value writes, no subscribers) never fire it.
pub var on_propagation_end: ?*const fn () void = null;

fn beginPropagation() void {
    if (tracker.depth == 0) tracker.propagation_gen +%= 1;
    tracker.depth += 1;
}

fn endPropagation() void {
    tracker.depth -= 1;
    if (tracker.depth == 0) drain();
}

/// Runs the queued effects in ascending `height` order — i.e. dependency order, so
/// a computed always recomputes before any effect that reads it. Combined with the
/// dedup in `schedule`, each effect runs at most once per propagation and always
/// sees fresh inputs: the engine is glitch-free for the batched/single-write path.
fn drain() void {
    if (tracker.draining) return; // a nested set() during the drain just enqueued
    tracker.draining = true;
    var effects_run: usize = 0;
    while (true) {
        // Pick the lowest-height pending effect (sources before their dependents).
        var best: ?usize = null;
        var best_h: u32 = 0;
        for (tracker.pending.items, 0..) |p, i| {
            if (p) |eff| {
                if (best == null or eff.height < best_h) {
                    best = i;
                    best_h = eff.height;
                }
            }
        }
        if (best == null) break;
        const eff = tracker.pending.items[best.?].?;
        tracker.pending.items[best.?] = null; // consumed
        if (eff.alive) {
            eff.execute();
            effects_run += 1;
        }
    }
    if (tracker.pending_allocator) |al| tracker.pending.deinit(al);
    tracker.pending = .empty;
    tracker.pending_allocator = null;
    tracker.draining = false;
    // Wake the render loop once, after the batch settled, if anything ran.
    if (effects_run > 0) {
        if (on_propagation_end) |cb| cb();
    }
}

/// Runs `body` as a single propagation: effects scheduled by `set()` calls inside
/// run exactly once, in dependency order, after `body` returns. Nested batches/sets
/// drain only at the outermost exit.
pub fn batch(allocator: std.mem.Allocator, ctx: anytype, comptime body: fn (@TypeOf(ctx)) void) void {
    tracker.pending_allocator = tracker.pending_allocator orelse allocator;
    beginPropagation();
    body(ctx);
    endPropagation();
}

fn schedule(allocator: std.mem.Allocator, eff: *Effect) void {
    // Outside any propagation (shouldn't normally happen — set/batch open one), run
    // immediately so a stray notify still takes effect.
    if (tracker.depth == 0 and !tracker.draining) {
        eff.execute();
        return;
    }
    tracker.pending_allocator = tracker.pending_allocator orelse allocator;
    // Dedup: don't queue the same effect twice in one propagation.
    for (tracker.pending.items) |p| {
        if (p) |pp| if (pp == eff) return;
    }
    tracker.pending.append(allocator, eff) catch {
        tracker.glitched = true; // out-of-order run; see Tracker.glitched
        eff.execute();
    };
}

/// Snapshots a subscriber list and schedules each effect. Shared by `Signal` and
/// `Computed`. The snapshot matters because an effect re-run may resubscribe and
/// mutate the source list mid-iteration; a small stack buffer avoids allocating
/// for the common (≤16 subscribers) case.
fn notifySubscribers(allocator: std.mem.Allocator, subs: []const *Effect) void {
    const n = subs.len;
    if (n == 0) return;
    var stack_buf: [16]*Effect = undefined;
    if (n <= stack_buf.len) {
        std.mem.copyForwards(*Effect, stack_buf[0..n], subs);
        for (stack_buf[0..n]) |eff| schedule(allocator, eff);
    } else {
        const copy = allocator.dupe(*Effect, subs) catch {
            // Snapshot alloc failed: still don't iterate the live list (an
            // effect re-run can resubscribe and reallocate it mid-iteration).
            // Copy through the stack buffer in ≤16-wide chunks instead.
            var off: usize = 0;
            while (off < n) {
                const end = @min(off + stack_buf.len, n);
                const len = end - off;
                std.mem.copyForwards(*Effect, stack_buf[0..len], subs[off..end]);
                for (stack_buf[0..len]) |eff| schedule(allocator, eff);
                off = end;
            }
            return;
        };
        defer allocator.free(copy);
        for (copy) |eff| schedule(allocator, eff);
    }
}

// ── Effect ────────────────────────────────────────────────────────────────────

/// A reactive computation. It re-runs whenever any signal it read last time
/// changes. Type-erased so signals of any T can hold a `*Effect` subscriber.
pub const Effect = struct {
    run_fn: *const fn (*anyopaque) void,
    ctx: *anyopaque,
    deps: std.ArrayListUnmanaged(Dep) = .empty,
    allocator: std.mem.Allocator,
    alive: bool = true,
    /// Dependency depth, rebuilt on every run from the sources it reads: a signal
    /// contributes height 1, a computed contributes its own height + 1. The drain
    /// runs lower-height effects first so dependents always read fresh inputs.
    height: u32 = 0,
    /// Floor for `height`, reset into it at the start of every run before reads
    /// raise it. 0 for ordinary effects/computeds. Component build-effects
    /// use a large base (`HEIGHT_BASE + anchor depth`) so every computed drains
    /// before any build, and ancestor builds before descendant builds.
    height_base: u32 = 0,

    /// Called from a source's `get()` during this effect's run to raise its height
    /// above that source. `source_height` is 0 for a signal, the computed's height
    /// for a computed.
    fn observeHeight(self: *Effect, source_height: u32) void {
        const h = source_height + 1;
        if (h > self.height) self.height = h;
    }

    /// A back-reference to a signal this effect is subscribed to, with a
    /// type-erased unsubscribe so cleanup doesn't need to know T.
    const Dep = struct {
        signal: *anyopaque,
        unsubscribe: *const fn (*anyopaque, *Effect) void,
    };

    fn execute(self: *Effect) void {
        if (!self.alive) return;
        self.clearDeps();
        self.height = self.height_base; // reset to floor; reads raise it via observeHeight
        const prev = tracker.current;
        tracker.current = self;
        self.run_fn(self.ctx);
        tracker.current = prev;
    }

    fn clearDeps(self: *Effect) void {
        for (self.deps.items) |dep| dep.unsubscribe(dep.signal, self);
        self.deps.clearRetainingCapacity();
    }

    /// Records a back-edge to a source. Fallible: the caller (`Signal.get` /
    /// `Computed.get`) rolls back the matching forward-edge on `error.OutOfMemory`
    /// so the two sides never disagree — a half-subscription (`eff` in the
    /// source's `subscribers` but the source absent from `eff.deps`, or vice
    /// versa) silently breaks either re-runs or teardown. Degrading to an
    /// untracked read is lossy but consistent.
    fn addDep(self: *Effect, dep: Dep) error{OutOfMemory}!void {
        for (self.deps.items) |existing| {
            if (existing.signal == dep.signal) return;
        }
        try self.deps.append(self.allocator, dep);
    }

    fn destroy(self: *Effect) void {
        self.clearDeps();
        self.deps.deinit(self.allocator);
        self.alive = false;
        // Remove from any in-progress batch queue so the flush can't touch this
        // effect after the scope frees its memory.
        unschedule(self);
    }
};

/// Makes `eff` the current effect and resets it for a fresh run — clears its old
/// subscriptions and lowers `height` to its floor — then returns the previously
/// current effect. Used by the component build layer to track the signal
/// reads of a build that runs *inline* on the shared builder (first mount and
/// parent-driven re-mount) rather than through `Effect.execute`. Pair with
/// `popEffect(prev)`.
pub fn pushEffect(eff: *Effect) ?*Effect {
    eff.clearDeps();
    eff.height = eff.height_base;
    const prev = tracker.current;
    tracker.current = eff;
    return prev;
}

/// Restores the current effect saved by `pushEffect`.
pub fn popEffect(prev: ?*Effect) void {
    tracker.current = prev;
}

/// Enters an untracked region: signal reads until `untrackedEnd` subscribe nobody.
/// Returns the previously-current effect to restore. Used to re-apply derived
/// values (e.g. a widget re-applying its background after a structural rebuild
/// cleared the node) without accidentally subscribing the running build-effect.
pub fn untrackedBegin() ?*Effect {
    const prev = tracker.current;
    tracker.current = null;
    return prev;
}

/// Restores the current effect saved by `untrackedBegin`.
pub fn untrackedEnd(prev: ?*Effect) void {
    tracker.current = prev;
}

// ── Signal ──────────────────────────────────────────────────────────────────

fn valuesEqual(comptime T: type, a: T, b: T) bool {
    if (T == props.PropValue) return a.eql(b);
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => a == b,
        else => std.meta.eql(a, b),
    };
}

pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        subscribers: std.ArrayListUnmanaged(*Effect) = .empty,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, initial: T) Self {
            return .{ .value = initial, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.subscribers.deinit(self.allocator);
        }

        /// Reactive read: subscribes the currently-running effect (if any).
        pub fn get(self: *Self) T {
            if (tracker.current) |eff| {
                // Subscribe both directions or neither: on OOM, undo whatever
                // stuck so this read is simply untracked (consistent) instead
                // of a half-subscription (inconsistent, silently broken).
                if (self.subscribe(eff)) {
                    eff.addDep(.{ .signal = self, .unsubscribe = unsubscribeErased }) catch {
                        self.unsubscribe(eff);
                        return self.value;
                    };
                    eff.observeHeight(0); // a signal is a leaf source
                }
            }
            return self.value;
        }

        /// Non-reactive read: never creates a subscription.
        pub fn peek(self: *const Self) T {
            return self.value;
        }

        /// Writes a value. Equal values are a no-op (no notify, no work). The write
        /// opens a propagation so dependents run once, in dependency order, after it.
        pub fn set(self: *Self, v: T) void {
            if (valuesEqual(T, self.value, v)) return;
            self.value = v;
            tracker.pending_allocator = tracker.pending_allocator orelse self.allocator;
            beginPropagation();
            self.notify();
            endPropagation();
        }

        fn notify(self: *Self) void {
            notifySubscribers(self.allocator, self.subscribers.items);
        }

        /// Returns true if `eff` is subscribed (already was, or was just added),
        /// false if the list couldn't grow. The caller keeps `eff.deps` in sync
        /// with this result.
        fn subscribe(self: *Self, eff: *Effect) bool {
            for (self.subscribers.items) |existing| {
                if (existing == eff) return true;
            }
            self.subscribers.append(self.allocator, eff) catch return false;
            return true;
        }

        fn unsubscribe(self: *Self, eff: *Effect) void {
            for (self.subscribers.items, 0..) |existing, i| {
                if (existing == eff) {
                    _ = self.subscribers.swapRemove(i);
                    return;
                }
            }
        }

        fn unsubscribeErased(ptr: *anyopaque, eff: *Effect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.unsubscribe(eff);
        }
    };
}

// ── Computed (memoized derived value) ─────────────────────────────────────────

/// A memoized derived value. Recomputes (once) only when a signal/computed it read
/// changes, and re-notifies its own subscribers only when the recomputed value
/// actually differs. N readers share one cached value and one recomputation — this
/// is what makes derived state O(1) per reader instead of recomputing in every
/// consumer. Read it with `get()` (reactive) or `peek()`. Create via
/// `Scope.createComputed`, which owns the recompute effect and the struct.
///
/// Note: like `Signal`, propagation is not yet topologically ordered, so a diamond
/// dependency can still observe a stale read in the same tick (full glitch-free
/// scheduling is a separate, pending step). Memoization itself is exact.
pub fn Computed(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T = undefined,
        ready: bool = false,
        compute_ctx: *anyopaque = undefined,
        /// The recompute effect; its `height` is this computed's depth in the graph.
        effect: ?*Effect = null,
        subscribers: std.ArrayListUnmanaged(*Effect) = .empty,
        allocator: std.mem.Allocator,

        /// Reactive read: subscribes the currently-running effect (if any).
        pub fn get(self: *Self) T {
            if (tracker.current) |eff| {
                // Both edges or neither — see Signal.get.
                if (self.subscribe(eff)) {
                    eff.addDep(.{ .signal = self, .unsubscribe = unsubscribeErased }) catch {
                        self.unsubscribe(eff);
                        return self.value;
                    };
                    // A reader of this computed must sit above it in the drain order.
                    eff.observeHeight(if (self.effect) |e| e.height else 0);
                }
            }
            return self.value;
        }

        /// Non-reactive read.
        pub fn peek(self: *const Self) T {
            return self.value;
        }

        fn subscribe(self: *Self, eff: *Effect) bool {
            for (self.subscribers.items) |existing| {
                if (existing == eff) return true;
            }
            self.subscribers.append(self.allocator, eff) catch return false;
            return true;
        }

        fn unsubscribe(self: *Self, eff: *Effect) void {
            for (self.subscribers.items, 0..) |existing, i| {
                if (existing == eff) {
                    _ = self.subscribers.swapRemove(i);
                    return;
                }
            }
        }

        fn unsubscribeErased(ptr: *anyopaque, eff: *Effect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.unsubscribe(eff);
        }

        fn notify(self: *Self) void {
            notifySubscribers(self.allocator, self.subscribers.items);
        }
    };
}

// ── Scope (ownership) ─────────────────────────────────────────────────────────

/// Owns the effects created during a component's lifetime. Tearing down the
/// scope destroys every effect (and unsubscribes it from all signals) in one
/// pass — callers never track individual subscriptions.
pub const Scope = struct {
    allocator: std.mem.Allocator,
    effects: std.ArrayListUnmanaged(*Effect) = .empty,
    /// Heap allocations whose lifetime is tied to the scope (e.g. binding
    /// structs captured by effect closures), freed in `deinit`.
    owned: std.ArrayListUnmanaged(Owned) = .empty,

    const Owned = struct {
        ptr: *anyopaque,
        free: *const fn (std.mem.Allocator, *anyopaque) void,
    };

    pub fn init(allocator: std.mem.Allocator) Scope {
        return .{ .allocator = allocator };
    }

    /// Destroys a single effect owned by this scope: unsubscribes it, unschedules
    /// it from any in-flight drain (safe mid-drain), removes it from the scope's
    /// list, and frees it. No-op if the effect isn't owned here. Used by the
    /// component layer to tear down one component's build-effect on unmount
    /// without dropping the whole scope.
    pub fn destroyEffect(self: *Scope, eff: *Effect) void {
        for (self.effects.items, 0..) |e, i| {
            if (e == eff) {
                _ = self.effects.swapRemove(i);
                eff.destroy();
                self.allocator.destroy(eff);
                return;
            }
        }
    }

    pub fn deinit(self: *Scope) void {
        for (self.effects.items) |eff| {
            eff.destroy();
            self.allocator.destroy(eff);
        }
        self.effects.deinit(self.allocator);
        for (self.owned.items) |o| o.free(self.allocator, o.ptr);
        self.owned.deinit(self.allocator);
    }

    /// Transfers ownership of a heap pointer to the scope; freed at teardown.
    pub fn own(self: *Scope, comptime T: type, ptr: *T) !void {
        const F = struct {
            fn f(a: std.mem.Allocator, p: *anyopaque) void {
                a.destroy(@as(*T, @ptrCast(@alignCast(p))));
            }
        };
        try self.owned.append(self.allocator, .{ .ptr = @ptrCast(ptr), .free = F.f });
    }

    /// Creates an effect and runs it once immediately (registering its initial
    /// dependencies). `run` receives `ctx` verbatim on every re-run.
    ///
    /// Effects re-run **synchronously inside `Signal.set()`**, on the thread that
    /// wrote the signal (normally the UI thread). Don't do blocking work in an
    /// effect — file/pipe I/O, network, dialogs — or every `set()` that triggers
    /// it stalls the render loop for that long. Same rule as `pickDirectory`: do
    /// the blocking work on a worker thread and marshal the result back with
    /// `application.postTask`, writing signals from the posted task.
    pub fn createEffect(
        self: *Scope,
        ctx: anytype,
        comptime run: fn (@TypeOf(ctx)) void,
    ) !*Effect {
        const Ctx = @TypeOf(ctx);
        const Wrap = struct {
            fn call(erased: *anyopaque) void {
                const typed: Ctx = @ptrCast(@alignCast(erased));
                run(typed);
            }
        };

        const eff = try self.allocator.create(Effect);
        errdefer self.allocator.destroy(eff);
        eff.* = .{
            .run_fn = Wrap.call,
            .ctx = ctx,
            .allocator = self.allocator,
        };
        try self.effects.append(self.allocator, eff);
        eff.execute();
        return eff;
    }

    /// Like `createEffect` but does NOT run the effect (so it registers no deps
    /// yet) and sets its `height_base`. The component build layer uses this
    /// for build-effects: the first build runs inline on the shared builder (which
    /// can't be re-entered via `rootAt` while the anchor is open), and the effect
    /// only fires later, in isolation, on a signal change.
    pub fn createEffectDeferred(
        self: *Scope,
        ctx: anytype,
        comptime run: fn (@TypeOf(ctx)) void,
        height_base: u32,
    ) !*Effect {
        const Ctx = @TypeOf(ctx);
        const Wrap = struct {
            fn call(erased: *anyopaque) void {
                const typed: Ctx = @ptrCast(@alignCast(erased));
                run(typed);
            }
        };
        const eff = try self.allocator.create(Effect);
        errdefer self.allocator.destroy(eff);
        eff.* = .{
            .run_fn = Wrap.call,
            .ctx = ctx,
            .allocator = self.allocator,
            .height_base = height_base,
        };
        try self.effects.append(self.allocator, eff);
        return eff;
    }

    /// Creates a memoized `Computed(T)` whose value is `compute(ctx)`. The compute
    /// closure runs once now and again only when a signal/computed it reads changes;
    /// the result is cached and re-published to the computed's own subscribers only
    /// when it differs. The scope owns the recompute effect and the struct, so both
    /// are torn down with the scope. `ctx` must be a pointer (same rule as
    /// `createEffect`); it is captured verbatim for every recompute.
    pub fn createComputed(
        self: *Scope,
        comptime T: type,
        ctx: anytype,
        comptime compute: fn (@TypeOf(ctx)) T,
    ) !*Computed(T) {
        const Ctx = @TypeOf(ctx);
        const C = Computed(T);

        const c = try self.allocator.create(C);
        errdefer self.allocator.destroy(c);
        c.* = .{ .allocator = self.allocator, .compute_ctx = ctx };

        const Wrap = struct {
            fn recompute(erased: *anyopaque) void {
                const cc: *C = @ptrCast(@alignCast(erased));
                // compute() reads upstream signals/computeds; because this runs as
                // an Effect, those reads subscribe THIS recompute (dynamic deps).
                const nv = compute(@as(Ctx, @ptrCast(@alignCast(cc.compute_ctx))));
                if (cc.ready and valuesEqual(T, cc.value, nv)) return; // memoized: unchanged
                cc.value = nv;
                cc.ready = true;
                cc.notify();
            }
        };

        // Free the computed AFTER all effects are torn down (effects are destroyed
        // first in `deinit`, unsubscribing from `c` while it is still valid), then
        // its subscriber list + struct are released.
        const F = struct {
            fn f(a: std.mem.Allocator, p: *anyopaque) void {
                const cc: *C = @ptrCast(@alignCast(p));
                cc.subscribers.deinit(a);
                a.destroy(cc);
            }
        };

        // Reserve both slots up front so the two ownership transfers below cannot
        // fail. Otherwise a failed second append would leave `eff` already in
        // `self.effects` while `errdefer` also frees it — a double free on scope
        // teardown.
        try self.effects.ensureUnusedCapacity(self.allocator, 1);
        try self.owned.ensureUnusedCapacity(self.allocator, 1);

        const eff = try self.allocator.create(Effect);
        errdefer self.allocator.destroy(eff); // safe: nothing fallible before return
        eff.* = .{ .run_fn = Wrap.recompute, .ctx = c, .allocator = self.allocator };
        c.effect = eff;

        self.effects.appendAssumeCapacity(eff);
        self.owned.appendAssumeCapacity(.{ .ptr = @ptrCast(c), .free = F.f });

        eff.execute(); // initial computation
        return c;
    }
};

// ── PropertyStore bindings ────────────────────────────────────────────────────

const StyleBinding = struct {
    store: *props.PropertyStore,
    node_id: reg.NodeId,
    key: props.StyleKey,
    signal: *Signal(props.PropValue),
};

const LayoutBinding = struct {
    store: *props.PropertyStore,
    node_id: reg.NodeId,
    key: props.LayoutKey,
    signal: *Signal(props.PropValue),
};

/// Binds a style property of `node_id` to `signal`: whenever the signal changes,
/// the new value is written into the store, which marks the node `render_dirty`
/// (never `layout_dirty`). No `build()` re-runs.
pub fn bindStyle(
    scope: *Scope,
    store: *props.PropertyStore,
    node_id: reg.NodeId,
    key: props.StyleKey,
    signal: *Signal(props.PropValue),
) !void {
    const b = try scope.allocator.create(StyleBinding);
    b.* = .{ .store = store, .node_id = node_id, .key = key, .signal = signal };
    // The binding struct outlives the effect closure; the scope owns it.
    try scope.own(StyleBinding, b);
    _ = try scope.createEffect(b, struct {
        fn run(bb: *StyleBinding) void {
            bb.store.setStyle(bb.node_id, bb.key, bb.signal.get()) catch {};
        }
    }.run);
}

/// Binds a layout property of `node_id` to `signal`. Layout changes propagate
/// dirtiness up the ancestor chain, as the existing setter already handles.
pub fn bindLayout(
    scope: *Scope,
    store: *props.PropertyStore,
    node_id: reg.NodeId,
    key: props.LayoutKey,
    signal: *Signal(props.PropValue),
) !void {
    const b = try scope.allocator.create(LayoutBinding);
    b.* = .{ .store = store, .node_id = node_id, .key = key, .signal = signal };
    try scope.own(LayoutBinding, b);
    _ = try scope.createEffect(b, struct {
        fn run(bb: *LayoutBinding) void {
            bb.store.setLayout(bb.node_id, bb.key, bb.signal.get()) catch {};
        }
    }.run);
}

/// Binds the text content of `node_id` to `signal`, formatted with `fmt` (a
/// comptime `std.fmt` string, e.g. "{d}" or "{s}"). Whenever the signal changes,
/// the effect formats the value and writes it via `setTextContent`, which marks the
/// node `layout_dirty` (text changes metrics) and re-shapes it — no `build()` re-run.
/// Accepts a `*Signal(T)` or `*Computed(T)`.
///
/// The formatted string is allocated with the store's allocator and handed to
/// `setTextContent`, which owns it from then on: it frees the previous content on
/// the next write and the final content in `PropertyStore.deinit`. An equal-value
/// `set()` is already a no-op upstream, so the effect never re-runs for it.
pub fn bindText(
    comptime T: type,
    scope: *Scope,
    store: *props.PropertyStore,
    node_id: reg.NodeId,
    signal: anytype,
    comptime fmt: []const u8,
) !void {
    const Sig = @TypeOf(signal);
    const Binding = struct {
        store: *props.PropertyStore,
        node_id: reg.NodeId,
        signal: Sig,
    };
    const b = try scope.allocator.create(Binding);
    b.* = .{ .store = store, .node_id = node_id, .signal = signal };
    try scope.own(Binding, b);
    _ = try scope.createEffect(b, struct {
        fn run(bb: *Binding) void {
            const val: T = bb.signal.get();
            const str = std.fmt.allocPrint(bb.store.stringAllocator(), fmt, .{val}) catch return;
            // setTextContent takes ownership of `str`; do not free it here.
            bb.store.setTextContent(bb.node_id, str);
        }
    }.run);
}

// ── Structural bindings (bindList) ───────────────────────────────────────────

/// Binds a reactive list to a parent node, dynamically appending/removing children
/// without needing a full `c_api.rebuildUI` from the host.
pub fn bindList(
    comptime T: type,
    scope: *Scope,
    b: *const @import("../framework/builder.zig").UIBuilder,
    parent_id: reg.NodeId,
    signal: *Signal([]const T),
    comptime build_item: fn (b: *@import("../framework/builder.zig").UIBuilder, item: T) anyerror!void,
) !void {
    const builder_mod = @import("../framework/builder.zig");
    const Ctx = struct {
        registry: *reg.UIRegistry,
        store: *props.PropertyStore,
        theme: @import("../framework/theme.zig").Theme,
        measure: ?builder_mod.TextMeasure,
        clipboard: ?builder_mod.Clipboard,
        parent_id: reg.NodeId,
        signal: *Signal([]const T),
    };

    const ctx = try scope.allocator.create(Ctx);
    ctx.* = .{
        .registry = b.registry,
        .store = b.store,
        .theme = b.theme,
        .measure = b.measure,
        .clipboard = b.clipboard,
        .parent_id = parent_id,
        .signal = signal,
    };
    try scope.own(Ctx, ctx);

    _ = try scope.createEffect(ctx, struct {
        fn run(c: *Ctx) void {
            const items = c.signal.get();
            var b_local = builder_mod.UIBuilder.init(c.registry, c.store);
            b_local.theme = c.theme;
            b_local.measure = c.measure;
            b_local.clipboard = c.clipboard;

            b_local.rootAt(c.parent_id) catch return;
            for (items) |item| {
                build_item(&b_local, item) catch continue;
            }
            b_local.close();

            // Re-layout just this container and its ancestors
            c.registry.markLayoutDirty(c.parent_id);
        }
    }.run);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Signal — set notifies, equal set is a no-op" {
    const a = std.testing.allocator;
    var sig = Signal(i32).init(a, 0);
    defer sig.deinit();

    var scope = Scope.init(a);
    defer scope.deinit();

    const Counter = struct {
        var runs: u32 = 0;
        sig: *Signal(i32),
        fn run(self: *@This()) void {
            _ = self.sig.get();
            runs += 1;
        }
    };
    Counter.runs = 0;
    var c = Counter{ .sig = &sig };
    _ = try scope.createEffect(&c, Counter.run);

    try std.testing.expectEqual(@as(u32, 1), Counter.runs); // initial run

    sig.set(5);
    try std.testing.expectEqual(@as(u32, 2), Counter.runs); // re-ran on change

    sig.set(5); // same value
    try std.testing.expectEqual(@as(u32, 2), Counter.runs); // no extra run
}

test "Signal — effect re-runs reflect the latest value" {
    const a = std.testing.allocator;
    var sig = Signal(i32).init(a, 10);
    defer sig.deinit();

    var scope = Scope.init(a);
    defer scope.deinit();

    const Mirror = struct {
        var seen: i32 = 0;
        sig: *Signal(i32),
        fn run(self: *@This()) void {
            seen = self.sig.get();
        }
    };
    var m = Mirror{ .sig = &sig };
    _ = try scope.createEffect(&m, Mirror.run);

    try std.testing.expectEqual(@as(i32, 10), Mirror.seen);
    sig.set(42);
    try std.testing.expectEqual(@as(i32, 42), Mirror.seen);
}

test "Scope teardown unsubscribes effects" {
    const a = std.testing.allocator;
    var sig = Signal(i32).init(a, 0);
    defer sig.deinit();

    {
        var scope = Scope.init(a);
        const Probe = struct {
            sig: *Signal(i32),
            fn run(self: *@This()) void {
                _ = self.sig.get();
            }
        };
        var p = Probe{ .sig = &sig };
        _ = try scope.createEffect(&p, Probe.run);
        try std.testing.expectEqual(@as(usize, 1), sig.subscribers.items.len);
        scope.deinit();
    }

    // After teardown the signal has no subscribers, and set() must not touch
    // freed effect memory.
    try std.testing.expectEqual(@as(usize, 0), sig.subscribers.items.len);
    sig.set(1);
}

test "bindStyle — color change sets render_dirty only, not layout_dirty" {
    const a = std.testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);

    const id = try registry.createNode(.box);
    try store.registerNode(id);

    var color = Signal(props.PropValue).init(a, .{ .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } });
    defer color.deinit();

    var scope = Scope.init(a);
    defer scope.deinit();

    try bindStyle(&scope, &store, id, .background, &color);

    // Binding ran once: background is set.
    try std.testing.expect(store.getStyle(id, .background) != null);

    // Clear dirty, then change the color through the signal.
    registry.getNode(id).?.layout_dirty = false;
    registry.getNode(id).?.render_dirty = false;
    color.set(.{ .color = .{ .r = 0, .g = 1, .b = 0, .a = 1 } });

    try std.testing.expect(registry.getNode(id).?.render_dirty);
    try std.testing.expect(!registry.getNode(id).?.layout_dirty);

    // The store actually holds the new value.
    try std.testing.expectEqual(@as(f32, 1.0), store.getStyle(id, .background).?.color.g);
}

test "bindText — signal drives text content, reuses the node, layout-dirty on change" {
    const a = std.testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);

    const id = try registry.createNode(.text);
    try store.registerNode(id);

    var count = Signal(i32).init(a, 1);
    defer count.deinit();

    var scope = Scope.init(a);
    defer scope.deinit();

    try bindText(i32, &scope, &store, id, &count, "{d}");

    // Initial run wrote "1".
    try std.testing.expectEqualStrings("1", store.getTextContent(id).?);

    // Change: content follows, node is reused (same id), and it went layout-dirty.
    registry.getNode(id).?.layout_dirty = false;
    const nodes_before = registry.nodes.items.len;
    count.set(2);
    try std.testing.expectEqualStrings("2", store.getTextContent(id).?);
    try std.testing.expect(registry.getNode(id).?.layout_dirty);
    try std.testing.expectEqual(nodes_before, registry.nodes.items.len); // nothing recreated
}

test "bindText — works with Computed and skips the no-op set" {
    const a = std.testing.allocator;
    var registry = reg.UIRegistry.init(a);
    defer registry.deinit();
    var store = props.PropertyStore.init(a);
    defer store.deinit();
    store.setRegistry(&registry);

    const id = try registry.createNode(.text);
    try store.registerNode(id);

    var n = Signal(i32).init(a, 3);
    defer n.deinit();

    var scope = Scope.init(a);
    defer scope.deinit();

    const Ctx = struct { n: *Signal(i32) };
    var cx = Ctx{ .n = &n };
    const doubled = try scope.createComputed(i32, &cx, struct {
        fn f(c: *Ctx) i32 {
            return c.n.get() * 2;
        }
    }.f);

    try bindText(i32, &scope, &store, id, doubled, "={d}=");
    try std.testing.expectEqualStrings("=6=", store.getTextContent(id).?);

    n.set(5);
    try std.testing.expectEqualStrings("=10=", store.getTextContent(id).?);

    // No-op set: the value doesn't change, so the effect must not re-run (the text
    // pointer stays identical — a re-run would allocate a fresh buffer).
    const before_ptr = store.getTextContent(id).?.ptr;
    n.set(5);
    try std.testing.expectEqual(before_ptr, store.getTextContent(id).?.ptr);
}

test "batch — multiple sets collapse into one effect run" {
    const a = std.testing.allocator;
    var x = Signal(i32).init(a, 0);
    defer x.deinit();
    var y = Signal(i32).init(a, 0);
    defer y.deinit();

    var scope = Scope.init(a);
    defer scope.deinit();

    const Sum = struct {
        var runs: u32 = 0;
        x: *Signal(i32),
        y: *Signal(i32),
        fn run(self: *@This()) void {
            _ = self.x.get() + self.y.get();
            runs += 1;
        }
    };
    Sum.runs = 0;
    var s = Sum{ .x = &x, .y = &y };
    _ = try scope.createEffect(&s, Sum.run);
    try std.testing.expectEqual(@as(u32, 1), Sum.runs);

    const Ctx = struct { x: *Signal(i32), y: *Signal(i32) };
    batch(a, Ctx{ .x = &x, .y = &y }, struct {
        fn body(c: Ctx) void {
            c.x.set(1);
            c.y.set(2);
        }
    }.body);

    // Both writes happened, but the effect re-ran only once for the batch.
    try std.testing.expectEqual(@as(u32, 2), Sum.runs);
}

test "on_propagation_end — fires once per effect-running propagation, never on no-ops" {
    const a = std.testing.allocator;

    const Hook = struct {
        var calls: u32 = 0;
        fn cb() void {
            calls += 1;
        }
    };
    Hook.calls = 0;
    on_propagation_end = &Hook.cb;
    defer on_propagation_end = null;

    var sig = Signal(i32).init(a, 0);
    defer sig.deinit();
    var other = Signal(i32).init(a, 0);
    defer other.deinit();

    // No subscribers yet: a write runs no effects, so the loop must NOT be woken.
    sig.set(1);
    try std.testing.expectEqual(@as(u32, 0), Hook.calls);

    // Scope declared after the signals so its teardown runs first (effects release
    // their subscriptions before the signals they point at are freed).
    var scope = Scope.init(a);
    defer scope.deinit();
    const Probe = struct {
        sig: *Signal(i32),
        fn run(self: *@This()) void {
            _ = self.sig.get();
        }
    };
    var p = Probe{ .sig = &sig };
    _ = try scope.createEffect(&p, Probe.run);

    // A write that re-runs the subscribed effect wakes the loop exactly once.
    sig.set(2);
    try std.testing.expectEqual(@as(u32, 1), Hook.calls);

    // Equal-value write is a no-op: no effect runs, no wake.
    sig.set(2);
    try std.testing.expectEqual(@as(u32, 1), Hook.calls);

    // A batch of N writes to the same effect wakes the loop once, on close.
    const Both = struct {
        sig: *Signal(i32),
        other: *Signal(i32),
        fn run(self: *@This()) void {
            _ = self.sig.get() + self.other.get();
        }
    };
    var b = Both{ .sig = &sig, .other = &other };
    _ = try scope.createEffect(&b, Both.run);
    Hook.calls = 0;

    const Ctx = struct { sig: *Signal(i32), other: *Signal(i32) };
    batch(a, Ctx{ .sig = &sig, .other = &other }, struct {
        fn body(c: Ctx) void {
            c.sig.set(3);
            c.other.set(4);
        }
    }.body);
    try std.testing.expectEqual(@as(u32, 1), Hook.calls);
}

test "Computed — derives from a signal and updates on change" {
    const a = std.testing.allocator;
    var n = Signal(i32).init(a, 2);
    defer n.deinit();

    var scope = Scope.init(a);
    defer scope.deinit();

    const Ctx = struct { n: *Signal(i32) };
    var cx = Ctx{ .n = &n };
    const doubled = try scope.createComputed(i32, &cx, struct {
        fn f(c: *Ctx) i32 {
            return c.n.get() * 2;
        }
    }.f);

    try std.testing.expectEqual(@as(i32, 4), doubled.peek());
    n.set(5);
    try std.testing.expectEqual(@as(i32, 10), doubled.peek());
}

test "Computed — memoizes: one recompute for N readers, no re-run when result is unchanged" {
    const a = std.testing.allocator;
    var n = Signal(i32).init(a, 1);
    defer n.deinit();

    var scope = Scope.init(a);
    defer scope.deinit();

    const Comp = struct {
        var computes: u32 = 0;
        n: *Signal(i32),
        fn f(self: *@This()) i32 {
            computes += 1;
            return @rem(self.n.get(), 2); // parity: 0 or 1
        }
    };
    Comp.computes = 0;
    var comp = Comp{ .n = &n };
    const parity = try scope.createComputed(i32, &comp, Comp.f);

    const Reader = struct {
        var runs: u32 = 0;
        p: *Computed(i32),
        fn run(self: *@This()) void {
            _ = self.p.get();
            runs += 1;
        }
    };
    Reader.runs = 0;
    var r1 = Reader{ .p = parity };
    var r2 = Reader{ .p = parity };
    _ = try scope.createEffect(&r1, Reader.run);
    _ = try scope.createEffect(&r2, Reader.run);

    try std.testing.expectEqual(@as(u32, 1), Comp.computes); // computed once, shared
    try std.testing.expectEqual(@as(u32, 2), Reader.runs); // each reader ran once

    // 1 -> 3: parity stays 1. Computed recomputes, but the value is unchanged, so
    // downstream readers must NOT re-run.
    n.set(3);
    try std.testing.expectEqual(@as(u32, 2), Comp.computes);
    try std.testing.expectEqual(@as(u32, 2), Reader.runs);

    // 3 -> 4: parity flips to 0 → both readers re-run exactly once.
    n.set(4);
    try std.testing.expectEqual(@as(u32, 3), Comp.computes);
    try std.testing.expectEqual(@as(u32, 4), Reader.runs);
}

test "Computed — diamond is glitch-free: dependent runs once, never sees a stale pair" {
    const a = std.testing.allocator;
    var A = Signal(i32).init(a, 1);
    defer A.deinit();

    var scope = Scope.init(a);
    defer scope.deinit();

    // B = A + 1 (a computed that sits between A and the effect).
    const Bctx = struct { a: *Signal(i32) };
    var bctx = Bctx{ .a = &A };
    const B = try scope.createComputed(i32, &bctx, struct {
        fn f(c: *Bctx) i32 {
            return c.a.get() + 1;
        }
    }.f);

    // C reads BOTH A and B — the classic diamond. Without dependency-ordered
    // propagation, a single A write makes C run twice and/or observe B != A+1.
    const C = struct {
        var runs: u32 = 0;
        var glitches: u32 = 0;
        a: *Signal(i32),
        b: *Computed(i32),
        fn run(self: *@This()) void {
            const av = self.a.get();
            const bv = self.b.get();
            runs += 1;
            if (bv != av + 1) glitches += 1;
        }
    };
    C.runs = 0;
    C.glitches = 0;
    var c = C{ .a = &A, .b = B };
    _ = try scope.createEffect(&c, C.run);

    try std.testing.expectEqual(@as(u32, 1), C.runs);
    try std.testing.expectEqual(@as(u32, 0), C.glitches);

    // The dependent (height 2) runs after the computed (height 1) recomputes, so it
    // re-runs exactly once and always sees a consistent (A, B=A+1) pair.
    A.set(10);
    try std.testing.expectEqual(@as(u32, 2), C.runs);
    try std.testing.expectEqual(@as(u32, 0), C.glitches);

    // And again, to be sure heights/ordering hold across writes.
    A.set(20);
    try std.testing.expectEqual(@as(u32, 3), C.runs);
    try std.testing.expectEqual(@as(u32, 0), C.glitches);
}

test "batch — destroying a queued effect mid-flush is safe (no use-after-free)" {
    const a = std.testing.allocator;
    var s = Signal(i32).init(a, 0);
    defer s.deinit();

    var scope1 = Scope.init(a);
    defer scope1.deinit();
    var scope2 = Scope.init(a); // torn down by E1 during the flush — intentionally no defer

    // E1 is created first, so it's the earlier subscriber / earlier in the queue.
    // When "armed", its run tears down scope2, freeing E2 which is queued after it.
    const E1 = struct {
        sig: *Signal(i32),
        target: *Scope,
        armed: *bool,
        torn: *bool,
        fn run(self: *@This()) void {
            _ = self.sig.get();
            if (self.armed.* and !self.torn.*) {
                self.torn.* = true;
                self.target.deinit();
            }
        }
    };
    const E2 = struct {
        sig: *Signal(i32),
        fn run(self: *@This()) void {
            _ = self.sig.get();
        }
    };

    var armed = false;
    var torn = false;
    var e1 = E1{ .sig = &s, .target = &scope2, .armed = &armed, .torn = &torn };
    _ = try scope1.createEffect(&e1, E1.run); // initial run: not armed → no teardown
    var e2 = E2{ .sig = &s };
    _ = try scope2.createEffect(&e2, E2.run);

    armed = true;
    // Both effects queue; the flush runs E1 (which frees E2 and unschedules it),
    // then must skip the nulled E2 slot rather than touch freed memory.
    const Ctx = struct { sig: *Signal(i32) };
    batch(a, Ctx{ .sig = &s }, struct {
        fn body(c: Ctx) void {
            c.sig.set(1);
        }
    }.body);

    try std.testing.expect(torn); // E1 ran during the flush and tore down scope2
    // testing.allocator confirms E2 was freed exactly once — no UAF, no leak.
}

/// Test-only: clears the sticky out-of-order flag between failing-allocator runs.
fn resetGlitchFlagForTest() void {
    tracker.glitched = false;
}

test "OOM: Signal.get never leaves a half-subscription (subs and deps agree)" {
    const base = std.testing.allocator;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        resetGlitchFlagForTest();
        var fa = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        const a = fa.allocator();

        var sig = Signal(i32).init(a, 1);
        defer sig.deinit();
        var scope = Scope.init(a);
        defer scope.deinit();

        const Ctx = struct {
            s: *Signal(i32),
            seen: i32 = 0,
            fn run(self: *@This()) void {
                self.seen = self.s.get();
            }
        };
        var ctx = Ctx{ .s = &sig };
        // The effect's own allocation may be the one that fails — that's fine,
        // nothing subscribed yet, move on.
        _ = scope.createEffect(&ctx, Ctx.run) catch continue;

        const eff = scope.effects.items[0];
        const in_subs = blk: {
            for (sig.subscribers.items) |e| if (e == eff) break :blk true;
            break :blk false;
        };
        const in_deps = blk: {
            for (eff.deps.items) |d| if (d.signal == @as(*anyopaque, @ptrCast(&sig))) break :blk true;
            break :blk false;
        };
        // The core invariant: the forward edge and the back edge exist together
        // or not at all. A half-subscription silently breaks re-runs or teardown.
        try std.testing.expectEqual(in_subs, in_deps);

        // A write must not crash whichever allocation was starved.
        sig.set(2);
        // If the read did subscribe, the effect must have observed the new value
        // (either via the ordered drain or the inline out-of-order fallback).
        if (in_subs) try std.testing.expectEqual(@as(i32, 2), ctx.seen);
    }
    resetGlitchFlagForTest();
}

test "OOM: Computed.get never leaves a half-subscription" {
    const base = std.testing.allocator;
    var fail_index: usize = 0;
    while (fail_index < 96) : (fail_index += 1) {
        resetGlitchFlagForTest();
        var fa = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        const a = fa.allocator();

        var src = Signal(i32).init(a, 1);
        defer src.deinit();
        var scope = Scope.init(a);
        defer scope.deinit();

        const DCtx = struct {
            s: *Signal(i32),
            fn double(self: *@This()) i32 {
                return self.s.get() * 2;
            }
        };
        var dctx = DCtx{ .s = &src };
        const comp = scope.createComputed(i32, &dctx, DCtx.double) catch continue;

        const RCtx = struct {
            c: *Computed(i32),
            seen: i32 = 0,
            fn run(self: *@This()) void {
                self.seen = self.c.get();
            }
        };
        var rctx = RCtx{ .c = comp };
        _ = scope.createEffect(&rctx, RCtx.run) catch continue;

        const reader = scope.effects.items[scope.effects.items.len - 1];
        const in_subs = blk: {
            for (comp.subscribers.items) |e| if (e == reader) break :blk true;
            break :blk false;
        };
        const in_deps = blk: {
            for (reader.deps.items) |d| if (d.signal == @as(*anyopaque, @ptrCast(comp))) break :blk true;
            break :blk false;
        };
        try std.testing.expectEqual(in_subs, in_deps);

        src.set(5); // must not crash regardless of the starved allocation
    }
    resetGlitchFlagForTest();
}
