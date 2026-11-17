//! Single-thread-owned evented I/O with stackful fibers and readiness-driven waits.
//! Fibers run on the backend's owner thread; foreign callers are dispatched through
//! futures, while blocking platform services are delegated to a private threaded
//! interface that does not schedule tasks.
const std = @import("std");
const builtin = @import("builtin");
const Reactor = @import("reactor.zig");
const Io = std.Io;
const posix = std.posix;
const Evented = @This();

/// Synchronous platform services are reused; their task scheduler is never used.
blocking: Io.Threaded,
/// One-shot readiness queue used to resume fibers blocked on sockets.
reactor: Reactor,
/// Allocator for fiber records, argument/result buffers, and scheduler state.
allocator: std.mem.Allocator,
/// Thread allowed to execute this backend's fibers and scheduler.
owner: std.Thread.Id,
/// Backend-aware lock protecting scheduler and fiber bookkeeping.
mutex: Lock,
/// Wakes foreign threads waiting for fiber/group completion.
condition: Condition,
/// All live asynchronous fibers, linked for scheduler scans.
fibers: ?*Fiber = null,
/// FIFO head of fibers ready to run.
ready_head: ?*Fiber = null,
/// FIFO tail of fibers ready to run.
ready_tail: ?*Fiber = null,
/// Fiber currently executing on the owner thread.
current: *Fiber,
/// Embedded fiber representing execution outside a scheduled task.
main_fiber: Fiber,
/// Saved context to resume the scheduler after a fiber yields.
scheduler_context: Io.fiber.Context,
/// Guarded scheduler stack and storage for the scheduler's launch closure.
scheduler_stack: []align(16) u8,
/// Completed fiber awaiting scheduler bookkeeping and possible reclamation.
finished: ?*Fiber = null,
/// Nonblocking pipe used to wake a scheduler waiting in the native reactor.
wake_pipe: [2]posix.fd_t,
/// Requests scheduler shutdown during backend deinitialization.
stopping: bool = false,
/// Link to the next registered backend for cross-thread futex wakeups.
next_backend: ?*Evented = null,

/// Fixed stack capacity for each scheduled fiber.
const stack_size = 4 * 1024 * 1024;
/// Head of live backends that can receive futex wakeups.
var backends: ?*Evented = null;
/// Serializes modifications and scans of the backend registry.
var backends_mutex: Io.Mutex = .init;

/// Allocates an aligned fiber stack with an inaccessible guard page.
fn allocateStack() ![]align(16) u8 {
    const guard = std.heap.pageSize();
    const memory = std.heap.page_allocator.rawAlloc(stack_size + guard, .@"16", @returnAddress()) orelse return error.OutOfMemory;
    errdefer std.heap.page_allocator.rawFree(memory[0 .. stack_size + guard], .@"16", @returnAddress());
    const result = posix.system.mprotect(@ptrCast(@alignCast(memory)), guard, .{});
    if (posix.errno(result) != .SUCCESS) {
        std.log.err("fiber stack guard setup failed: {s}", .{@tagName(posix.errno(result))});
        return error.StackGuardFailed;
    }
    return @alignCast(memory[guard .. guard + stack_size]);
}

/// Releases a stack previously returned by `allocateStack`.
fn freeStack(stack: []align(16) u8) void {
    const guard = std.heap.pageSize();
    const memory = stack.ptr - guard;
    std.heap.page_allocator.rawFree(memory[0 .. stack.len + guard], .@"16", @returnAddress());
}
/// Mutex whose blocking operations use this backend's synchronous I/O services.
const Lock = struct {
    /// Backend supplying an uncancelable I/O context for the lock operations.
    backend: *Evented,
    /// Underlying standard-library mutex.
    inner: Io.Mutex = .init,

    /// Acquires the mutex without allowing task cancellation to interrupt it.
    fn lock(self: *Lock) void {
        self.inner.lockUncancelable(self.backend.blocking.io());
    }

    /// Releases the mutex using the same backend context as acquisition.
    fn unlock(self: *Lock) void {
        self.inner.unlock(self.backend.blocking.io());
    }
};
/// Condition variable bound to a backend's platform I/O context.
const Condition = struct {
    /// Backend supplying the I/O interface used while waiting or waking.
    backend: *Evented,
    /// Underlying standard-library condition variable.
    inner: Io.Condition = .init,

    /// Atomically releases `mutex` while waiting, then reacquires it.
    fn wait(self: *Condition, mutex: *Lock) void {
        self.inner.waitUncancelable(self.backend.blocking.io(), &mutex.inner);
    }

    /// Wakes all threads waiting on this condition.
    fn broadcast(self: *Condition) void {
        self.inner.broadcast(self.backend.blocking.io());
    }
};
/// Data placed at the top of a new stack to enter a fiber or scheduler.
/// `fiber == null` identifies the scheduler's launch closure.
const Closure = extern struct { backend: *Evented, fiber: ?*Fiber };
/// Reason a fiber is parked, including its identity-check data where needed.
const Wait = union(enum) {
    /// Fiber is not waiting on an external event.
    none,
    /// Fiber awaits a one-shot descriptor readiness notification.
    socket: Reactor.Key,
    /// Fiber waits while an atomic word retains an expected value.
    futex: struct { ptr: *const u32, expected: u32 },
    /// Fiber awaits completion of another future.
    future: *Fiber,
    /// Fiber awaits all members of a task group.
    group: *Io.Group,
    /// Fiber awaits only its deadline.
    timer,
};
/// Stack, context, callback, and scheduler state for one task.
const Fiber = struct {
    /// Saved machine state used when this fiber is suspended.
    context: Io.fiber.Context = undefined,
    /// Owned execution stack; allocated on task creation and freed on completion.
    stack: ?[]align(16) u8 = null,
    /// Aligned copy of callback arguments retained until task destruction.
    arguments: ?[]align(64) u8 = null,
    /// Aligned callback result buffer copied out by await.
    result: ?[]align(64) u8 = null,
    /// Entry callback for a future, absent for group-only tasks.
    start: ?*const fn (*const anyopaque, *anyopaque) void = null,
    /// Entry callback for a group task, mutually exclusive with `start`.
    group_start: ?*const fn (*const anyopaque) void = null,
    /// Group accounting owner; group fibers are reclaimed when they finish.
    group: ?*Io.Group = null,
    /// Next fiber in the backend's live-fiber list.
    next: ?*Fiber = null,
    /// Next fiber in the scheduler's ready queue.
    ready_next: ?*Fiber = null,
    /// Prevents duplicate insertion into the ready queue.
    queued: bool = false,
    /// Set by scheduler after the callback returns.
    done: bool = false,
    /// True while the fiber is suspended awaiting an event or another fiber.
    parked: bool = false,
    /// Pending cancellation delivered at a cancellation point when unblocked.
    cancel_requested: bool = false,
    /// Cancellation shielding state carried across fiber switches.
    protection: Io.CancelProtection = .unblocked,
    /// Whether a wakeup may resume this fiber by delivering cancellation.
    cancelable: bool = true,
    /// Current wait target used by scheduler wakeup scans.
    wait: Wait = .none,
    /// Optional timeout deadline for timer and timed waits.
    deadline: ?Io.Clock.Timestamp = null,
};

/// Initializes native readiness, wakeup, guarded-stack, and scheduler state.
/// This backend must be deinitialized on its owner thread after all fibers finish.
pub fn init(self: *Evented, allocator: std.mem.Allocator) !void {
    if (!Io.fiber.supported) @compileError("evented I/O requires a supported fiber architecture");
    var reactor = try Reactor.init(allocator);
    errdefer reactor.deinit();
    const pipe = try Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    errdefer {
        Io.Threaded.closeFd(pipe[0]);
        Io.Threaded.closeFd(pipe[1]);
    }
    const stack = try allocateStack();
    errdefer freeStack(stack);
    try reactor.arm(.{ .fd = pipe[0], .interest = .read });
    self.* = .{
        .blocking = Io.Threaded.init(allocator, .{ .concurrent_limit = .nothing }),
        .reactor = reactor,
        .allocator = allocator,
        .owner = std.Thread.getCurrentId(),
        .mutex = .{ .backend = self },
        .condition = .{ .backend = self },
        .current = &self.main_fiber,
        .main_fiber = .{},
        .scheduler_context = undefined,
        .scheduler_stack = stack,
        .wake_pipe = pipe,
    };
    const closure: *Closure = @ptrCast(@alignCast(stack[stack.len - @sizeOf(Closure) ..].ptr));
    closure.* = .{ .backend = self, .fiber = null };
    self.scheduler_context = contextFor(closure);
    backends_mutex.lockUncancelable(self.blocking.io());
    defer backends_mutex.unlock(self.blocking.io());
    self.next_backend = backends;
    backends = self;
}

/// Stops scheduling, releases native resources, and invalidates this backend.
/// The caller must ensure no asynchronous fibers remain.
pub fn deinit(self: *Evented) void {
    std.debug.assert(self.fibers == null);
    backends_mutex.lockUncancelable(self.blocking.io());
    var link = &backends;
    while (link.*) |backend| {
        if (backend == self) {
            link.* = self.next_backend;
            break;
        }
        link = &backend.next_backend;
    }
    backends_mutex.unlock(self.blocking.io());
    self.stopping = true;
    self.switchToScheduler();
    self.reactor.deinit();
    Io.Threaded.closeFd(self.wake_pipe[0]);
    Io.Threaded.closeFd(self.wake_pipe[1]);
    freeStack(self.scheduler_stack);
    self.blocking.deinit();
    self.* = undefined;
}

/// Builds the I/O interface whose task operations use this fiber scheduler.
pub fn io(self: *Evented) Io {
    return .{ .userdata = &self.blocking, .vtable = &vtable };
}

/// Starts from the threaded vtable and replaces supported operations with evented versions.
const vtable: Io.VTable = blk: {
    var services: Io.Threaded = undefined;
    var result = services.io().vtable.*;
    result.async = asyncStart;
    result.concurrent = concurrent;
    result.await = awaitFuture;
    result.cancel = cancelFuture;
    result.groupAsync = groupAsync;
    result.groupConcurrent = groupConcurrent;
    result.groupAwait = groupAwait;
    result.groupCancel = groupCancel;
    result.recancel = recancel;
    result.swapCancelProtection = swapCancelProtection;
    result.checkCancel = checkCancel;
    result.futexWait = futexWait;
    result.futexWaitUncancelable = futexWaitUncancelable;
    result.futexWake = futexWake;
    result.sleep = sleep;
    result.netListenIp = netListenIp;
    result.netAccept = netAccept;
    result.netConnectIp = netConnectIp;
    result.netBindIp = unsupportedBind;
    result.netListenUnix = unsupportedListenUnix;
    result.netConnectUnix = unsupportedConnectUnix;
    result.netSocketCreatePair = unsupportedPair;
    result.netWriteFile = unsupportedWriteFile;
    result.netLookup = unsupportedLookup;
    result.operate = operate;
    result.batchAwaitAsync = batchAwaitAsync;
    result.batchAwaitConcurrent = batchAwaitConcurrent;
    result.batchCancel = batchCancel;
    break :blk result;
};

/// Recovers the containing backend from the userdata pointer passed by `Io`.
fn from(userdata: ?*anyopaque) *Evented {
    const blocking: *Io.Threaded = @ptrCast(@alignCast(userdata));
    return @alignCast(@fieldParentPtr("blocking", blocking));
}

/// Returns the currently executing fiber only on the backend's owner thread.
fn active(self: *Evented) ?*Fiber {
    return if (std.Thread.getCurrentId() == self.owner) self.current else null;
}

/// Constructs the initial ABI-specific context pointing at a launch closure.
fn contextFor(closure: *Closure) Io.fiber.Context {
    return switch (builtin.cpu.arch) {
        .aarch64 => .{ .sp = @intFromPtr(closure), .fp = 0, .pc = @intFromPtr(&entry) },
        .x86_64 => .{ .rsp = @intFromPtr(closure) - @sizeOf(usize), .rbp = 0, .rip = @intFromPtr(&entry) },
        else => @compileError("evented I/O currently supports aarch64 and x86_64"),
    };
}

/// Architecture entry stub that terminates unwinding before entering Zig code.
fn entry() callconv(.naked) noreturn {
    // Terminate stack unwinding at the fiber root instead of retaining the previous fiber's return address.
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ mov x30, xzr
            \\ b %[run]
            :
            : [run] "i" (&run),
        ),
        .x86_64 => asm volatile (
            \\ leaq 8(%%rsp), %%rdi
            \\ movq $0, (%%rsp)
            \\ jmp %[run:P]
            :
            : [run] "X" (&run),
        ),
        else => unreachable,
    }
}

/// Dispatches a newly entered stack to its callback or to the scheduler loop.
fn run(closure: *Closure) callconv(.c) noreturn {
    const self = closure.backend;
    if (closure.fiber) |fiber| {
        if (fiber.group_start) |start| start(fiber.arguments.?.ptr) else fiber.start.?(fiber.arguments.?.ptr, fiber.result.?.ptr);
        self.finished = fiber;
        self.switchToScheduler();
        unreachable;
    }
    self.scheduler();
}

/// Saves the current fiber and transfers execution to the scheduler context.
fn switchToScheduler(self: *Evented) void {
    const message: Io.fiber.Switch = .{ .old = &self.current.context, .new = &self.scheduler_context };
    switchContext(&message);
}

/// Invokes the ABI-specific context switch with the supplied old/new contexts.
fn switchContext(message: *const Io.fiber.Switch) void {
    const call: *const fn (*const Io.fiber.Switch) callconv(.c) void = @ptrCast(&switchAssembly);
    call(message);
}

// Save the C ABI's callee-saved state explicitly; inline fiber asm loses live registers in optimized Zig 0.17 builds.
/// Saves and restores the ABI-preserved machine state during a fiber switch.
fn switchAssembly() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ sub sp, sp, #176
            \\ stp x19, x20, [sp, #0]
            \\ stp x21, x22, [sp, #16]
            \\ stp x23, x24, [sp, #32]
            \\ stp x25, x26, [sp, #48]
            \\ stp x27, x28, [sp, #64]
            \\ stp x29, x30, [sp, #80]
            \\ mrs x9, fpcr
            \\ mrs x10, fpsr
            \\ stp x9, x10, [sp, #96]
            \\ stp d8, d9, [sp, #112]
            \\ stp d10, d11, [sp, #128]
            \\ stp d12, d13, [sp, #144]
            \\ stp d14, d15, [sp, #160]
            \\ ldp x1, x2, [x0]
            \\ mov x4, sp
            \\ stp x4, x29, [x1]
            \\ adr x5, 0f
            \\ str x5, [x1, #16]
            \\ ldr x3, [x2, #16]
            \\ ldp x4, x29, [x2]
            \\ mov sp, x4
            \\ br x3
            \\0:
            \\ ldp x9, x10, [sp, #96]
            \\ msr fpcr, x9
            \\ msr fpsr, x10
            \\ ldp d8, d9, [sp, #112]
            \\ ldp d10, d11, [sp, #128]
            \\ ldp d12, d13, [sp, #144]
            \\ ldp d14, d15, [sp, #160]
            \\ ldp x19, x20, [sp, #0]
            \\ ldp x21, x22, [sp, #16]
            \\ ldp x23, x24, [sp, #32]
            \\ ldp x25, x26, [sp, #48]
            \\ ldp x27, x28, [sp, #64]
            \\ ldp x29, x30, [sp, #80]
            \\ add sp, sp, #176
            \\ ret
        ),
        .x86_64 => asm volatile (
            \\ pushq %%rbx
            \\ pushq %%rbp
            \\ pushq %%r12
            \\ pushq %%r13
            \\ pushq %%r14
            \\ pushq %%r15
            \\ subq $16, %%rsp
            \\ stmxcsr (%%rsp)
            \\ fnstcw 4(%%rsp)
            \\ movq (%%rdi), %%rax
            \\ movq 8(%%rdi), %%rdx
            \\ movq %%rsp, (%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ leaq 0f(%%rip), %%rcx
            \\ movq %%rcx, 16(%%rax)
            \\ movq (%%rdx), %%rsp
            \\ movq 8(%%rdx), %%rbp
            \\ jmpq *16(%%rdx)
            \\0:
            \\ ldmxcsr (%%rsp)
            \\ fldcw 4(%%rsp)
            \\ addq $16, %%rsp
            \\ popq %%r15
            \\ popq %%r14
            \\ popq %%r13
            \\ popq %%r12
            \\ popq %%rbp
            \\ popq %%rbx
            \\ retq
        ),
        else => unreachable,
    }
}

/// Places the current fiber on the ready queue before yielding to the scheduler.
fn yieldReady(self: *Evented) void {
    self.mutex.lock();
    self.enqueue(self.current);
    self.mutex.unlock();
    self.switchToScheduler();
}

/// Notifies a scheduler blocked in the reactor through the nonblocking wake pipe.
fn notify(self: *Evented) void {
    const byte = [_]u8{1};
    while (true) {
        const result = posix.system.write(self.wake_pipe[1], &byte, byte.len);
        switch (posix.errno(result)) {
            .SUCCESS, .AGAIN => return,
            .INTR => continue,
            else => |err| {
                std.log.err("reactor wake failed: {s}", .{@tagName(err)});
                @panic("reactor wake failed");
            },
        }
    }
}

/// Appends a live fiber once to the ready queue and clears its parked state.
fn enqueue(self: *Evented, fiber: *Fiber) void {
    if (fiber.queued or fiber.done) return;
    fiber.parked = false;
    fiber.queued = true;
    fiber.ready_next = null;
    if (self.ready_tail) |tail| tail.ready_next = fiber else self.ready_head = fiber;
    self.ready_tail = fiber;
}

/// Runs the owner-thread scheduler until shutdown, dispatching ready fibers and
/// polling descriptor events or deadlines between runs.
fn scheduler(self: *Evented) noreturn {
    var ready_runs: usize = 0;
    while (true) {
        self.mutex.lock();
        if (self.finished) |fiber| {
            self.finished = null;
            fiber.done = true;
            if (fiber.group) |group| {
                group.state -= 2;
                if (group.state < 2) {
                    group.state = 0;
                    group.token.store(null, .release);
                }
            }
            var candidate = self.fibers;
            while (candidate) |waiting| : (candidate = waiting.next) {
                if (!waiting.parked) continue;
                const completed = switch (waiting.wait) {
                    .future => |target| target == fiber,
                    .group => |group| group.token.load(.acquire) == null,
                    else => false,
                };
                if (completed) self.enqueue(waiting);
            }
            if (self.main_fiber.parked) {
                const completed = switch (self.main_fiber.wait) {
                    .future => |target| target == fiber,
                    .group => |group| group.token.load(.acquire) == null,
                    else => false,
                };
                if (completed) self.enqueue(&self.main_fiber);
            }
            self.condition.broadcast();
            if (fiber.group != null) {
                self.unlink(fiber);
                self.destroy(fiber);
            }
        }
        if (self.stopping) {
            self.mutex.unlock();
            const message: Io.fiber.Switch = .{ .old = &self.scheduler_context, .new = &self.main_fiber.context };
            switchContext(&message);
            unreachable;
        }
        var timeout: ?u64 = null;
        var candidate: ?*Fiber = &self.main_fiber;
        while (candidate) |fiber| : (candidate = if (fiber == &self.main_fiber) self.fibers else fiber.next) {
            if (!fiber.parked) continue;
            if (fiber.deadline) |deadline| {
                const remaining = deadline.durationFromNow(self.blocking.io()).raw.nanoseconds;
                if (remaining <= 0) {
                    self.enqueue(fiber);
                } else {
                    const ns: u64 = @intCast(@min(remaining, std.math.maxInt(u64)));
                    timeout = @min(timeout orelse ns, ns);
                }
            }
        }
        if (self.ready_head != null) timeout = 0;
        const poll = self.ready_head == null or ready_runs >= 32;
        self.mutex.unlock();

        var events: [64]Reactor.Key = undefined;
        const count = if (poll) self.reactor.wait(&events, timeout) catch |err| {
            std.log.err("reactor wait failed: {s}", .{@errorName(err)});
            @panic("reactor wait failed");
        } else 0;
        if (poll) ready_runs = 0;
        self.mutex.lock();
        for (events[0..count]) |key| {
            if (key.fd == self.wake_pipe[0]) {
                var bytes: [256]u8 = undefined;
                while (posix.system.read(key.fd, &bytes, bytes.len) > 0) {}
                self.reactor.arm(key) catch |err| {
                    std.log.err("reactor wake registration failed: {s}", .{@errorName(err)});
                    @panic("reactor wake registration failed");
                };
                continue;
            }
            candidate = &self.main_fiber;
            while (candidate) |fiber| : (candidate = if (fiber == &self.main_fiber) self.fibers else fiber.next) {
                if (fiber.parked and fiber.wait == .socket and std.meta.eql(fiber.wait.socket, key)) self.enqueue(fiber);
            }
        }
        if (self.ready_head) |fiber| {
            self.ready_head = fiber.ready_next;
            if (self.ready_head == null) self.ready_tail = null;
            fiber.ready_next = null;
            fiber.queued = false;
            self.current = fiber;
            ready_runs += 1;
            self.mutex.unlock();
            const message: Io.fiber.Switch = .{ .old = &self.scheduler_context, .new = &fiber.context };
            switchContext(&message);
        } else self.mutex.unlock();
    }
}

/// Allocates a fiber stack and aligned argument/result storage.
/// Callback alignments above 64 bytes are rejected as unavailable.
fn create(self: *Evented, result_len: usize, alignment: std.mem.Alignment, arguments: []const u8, arguments_alignment: std.mem.Alignment) !*Fiber {
    if (alignment.compare(.gt, .@"64") or arguments_alignment.compare(.gt, .@"64")) return error.ConcurrencyUnavailable;
    const fiber = try self.allocator.create(Fiber);
    errdefer self.allocator.destroy(fiber);
    const stack = try allocateStack();
    errdefer freeStack(stack);
    const args = try self.allocator.alignedAlloc(u8, .@"64", @max(arguments.len, 1));
    errdefer self.allocator.free(args);
    const result = try self.allocator.alignedAlloc(u8, .@"64", @max(result_len, 1));
    fiber.* = .{ .stack = stack, .arguments = args, .result = result };
    @memcpy(args[0..arguments.len], arguments);
    const closure: *Closure = @ptrCast(@alignCast(stack[stack.len - @sizeOf(Closure) ..].ptr));
    closure.* = .{ .backend = self, .fiber = fiber };
    fiber.context = contextFor(closure);
    return fiber;
}

/// Releases all owned buffers and the stack of a completed fiber.
fn destroy(self: *Evented, fiber: *Fiber) void {
    freeStack(fiber.stack.?);
    self.allocator.free(fiber.arguments.?);
    self.allocator.free(fiber.result.?);
    self.allocator.destroy(fiber);
}

/// Removes a fiber from the live list; the caller must hold the backend mutex.
fn unlink(self: *Evented, fiber: *Fiber) void {
    var link = &self.fibers;
    while (link.* != fiber) link = &link.*.?.next;
    link.* = fiber.next;
}

/// Creates and schedules a future-backed fiber, returning its opaque future handle.
/// Allocation or unsupported alignment is reported as concurrency unavailable.
fn concurrent(userdata: ?*anyopaque, result_len: usize, alignment: std.mem.Alignment, arguments: []const u8, arguments_alignment: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
    const self = from(userdata);
    const fiber = self.create(result_len, alignment, arguments, arguments_alignment) catch return error.ConcurrencyUnavailable;
    fiber.start = start;
    self.mutex.lock();
    fiber.next = self.fibers;
    self.fibers = fiber;
    self.enqueue(fiber);
    self.mutex.unlock();
    self.notify();
    return @ptrCast(fiber);
}

/// Starts asynchronous work, falling back to inline execution if scheduling fails.
fn asyncStart(userdata: ?*anyopaque, result: []u8, alignment: std.mem.Alignment, arguments: []const u8, arguments_alignment: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) ?*Io.AnyFuture {
    return concurrent(userdata, result.len, alignment, arguments, arguments_alignment, start) catch {
        start(arguments.ptr, result.ptr);
        return null;
    };
}

/// Marks cancellation pending and makes an eligible parked fiber runnable.
fn requestCancel(self: *Evented, fiber: *Fiber) void {
    fiber.cancel_requested = true;
    if (fiber.parked and fiber.cancelable and fiber.protection == .unblocked) self.enqueue(fiber);
}

/// Waits for a future, copies its result to caller storage, and reclaims it.
/// Owner-thread callers suspend as fibers; foreign callers block on a condition.
fn awaitFuture(userdata: ?*anyopaque, future: *Io.AnyFuture, result: []u8, _: std.mem.Alignment) void {
    const self = from(userdata);
    const fiber: *Fiber = @ptrCast(@alignCast(future));
    self.mutex.lock();
    while (!fiber.done) {
        if (self.active()) |caller| {
            caller.wait = .{ .future = fiber };
            caller.cancelable = false;
            caller.parked = true;
            self.mutex.unlock();
            self.switchToScheduler();
            self.mutex.lock();
            caller.wait = .none;
        } else self.condition.wait(&self.mutex);
    }
    @memcpy(result, fiber.result.?[0..result.len]);
    self.unlink(fiber);
    self.destroy(fiber);
    self.mutex.unlock();
}

/// Requests cancellation, wakes the target if needed, then awaits its final result.
fn cancelFuture(userdata: ?*anyopaque, future: *Io.AnyFuture, result: []u8, alignment: std.mem.Alignment) void {
    const self = from(userdata);
    self.mutex.lock();
    self.requestCancel(@ptrCast(@alignCast(future)));
    self.mutex.unlock();
    self.notify();
    awaitFuture(userdata, future, result, alignment);
}

/// Adds a group task and increments group accounting before scheduling it.
fn groupConcurrent(userdata: ?*anyopaque, group: *Io.Group, arguments: []const u8, alignment: std.mem.Alignment, start: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
    const self = from(userdata);
    const fiber = self.create(0, .@"1", arguments, alignment) catch return error.ConcurrencyUnavailable;
    fiber.group_start = start;
    fiber.group = group;
    self.mutex.lock();
    group.state += 2;
    group.token.store(group, .release);
    fiber.cancel_requested = group.state & 1 != 0;
    fiber.next = self.fibers;
    self.fibers = fiber;
    self.enqueue(fiber);
    self.mutex.unlock();
    self.notify();
}

/// Adds group work or runs the callback inline if fiber creation is unavailable.
fn groupAsync(userdata: ?*anyopaque, group: *Io.Group, arguments: []const u8, alignment: std.mem.Alignment, start: *const fn (*const anyopaque) void) void {
    groupConcurrent(userdata, group, arguments, alignment, start) catch start(arguments.ptr);
}

/// Waits for group completion and propagates cancellation to group members when requested.
fn waitGroup(self: *Evented, group: *Io.Group, cancel_requested: bool) bool {
    self.mutex.lock();
    var canceled = cancel_requested;
    while (group.token.load(.acquire) != null) {
        if (canceled) {
            group.state |= 1;
            var fiber = self.fibers;
            while (fiber) |member| : (fiber = member.next) {
                if (member.group == group) self.requestCancel(member);
            }
        }
        if (self.active()) |caller| {
            if (!cancel_requested and caller.cancel_requested and caller.protection == .unblocked) {
                caller.cancel_requested = false;
                canceled = true;
                continue;
            }
            caller.wait = .{ .group = group };
            caller.cancelable = !cancel_requested;
            caller.parked = true;
            self.mutex.unlock();
            self.notify();
            self.switchToScheduler();
            self.mutex.lock();
            caller.wait = .none;
        } else {
            self.notify();
            self.condition.wait(&self.mutex);
        }
    }
    self.mutex.unlock();
    return canceled;
}

/// Awaits every group member and reports cancellation to the caller.
fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, _: *anyopaque) Io.Cancelable!void {
    if (from(userdata).waitGroup(group, false)) return error.Canceled;
}

/// Cancels outstanding group members and waits for their cleanup to finish.
fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, _: *anyopaque) void {
    _ = from(userdata).waitGroup(group, true);
}

/// Persistent state shared by asynchronous batch operation callbacks.
const BatchState = struct {
    /// Tracks tasks launched for the batch so cancellation joins them.
    group: Io.Group = .init,
    /// Signals that a worker has updated completion or pending state.
    event: Io.Event = .unset,
};

/// Executes one submitted batch item and moves it to completed or reusable storage.
fn batchRun(self: *Evented, batch: *Io.Batch, state: *BatchState, index: Io.Operation.OptionalIndex, operation: Io.Operation) void {
    const result = self.io().operate(operation) catch error.Canceled;
    self.mutex.lock();
    const slot = &batch.storage[index.toIndex()];
    const node = slot.pending.node;
    if (node.prev == .none) batch.pending.head = node.next else batch.storage[node.prev.toIndex()].pending.node.next = node.next;
    if (node.next == .none) batch.pending.tail = node.prev else batch.storage[node.next.toIndex()].pending.node.prev = node.prev;
    if (result) |completed| {
        if (batch.completed.tail == .none) batch.completed.head = index else batch.storage[batch.completed.tail.toIndex()].completion.node.next = index;
        batch.completed.tail = index;
        slot.* = .{ .completion = .{ .node = .{ .next = .none }, .result = completed } };
    } else |_| {
        slot.* = .{ .unused = .{ .prev = batch.unused.tail, .next = .none } };
        if (batch.unused.tail == .none) batch.unused.head = index else batch.storage[batch.unused.tail.toIndex()].unused.next = index;
        batch.unused.tail = index;
    }
    self.mutex.unlock();
    state.event.set(self.io());
}

/// Dispatches submitted batch operations concurrently until a result, timeout,
/// or idle state is reached; timed-out work remains cancelable through the batch.
fn batchAwaitConcurrent(userdata: ?*anyopaque, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    const self = from(userdata);
    if (self.active() == null) {
        var future = try self.io().concurrent(batchAwaitConcurrent, .{ userdata, batch, timeout });
        return future.await(self.io());
    }
    errdefer batch.cancel(self.io());
    const deadline = timeout.toDeadline(self.io());
    const state: *BatchState = if (batch.userdata) |ptr| @ptrCast(@alignCast(ptr)) else blk: {
        const allocated = self.allocator.create(BatchState) catch return error.ConcurrencyUnavailable;
        allocated.* = .{};
        batch.userdata = allocated;
        break :blk allocated;
    };
    while (batch.submitted.head != .none) {
        const index = batch.submitted.head;
        const slot = &batch.storage[index.toIndex()];
        const submission = slot.submission;
        try state.group.concurrent(self.io(), batchRun, .{ self, batch, state, index, submission.operation });
        self.mutex.lock();
        batch.submitted.head = submission.node.next;
        if (batch.submitted.head == .none) batch.submitted.tail = .none;
        slot.* = .{ .pending = .{ .node = .{ .prev = batch.pending.tail, .next = .none }, .tag = std.meta.activeTag(submission.operation), .userdata = undefined } };
        if (batch.pending.tail == .none) batch.pending.head = index else batch.storage[batch.pending.tail.toIndex()].pending.node.next = index;
        batch.pending.tail = index;
        self.mutex.unlock();
    }
    while (true) {
        self.mutex.lock();
        if (batch.completed.head != .none or batch.pending.head == .none) {
            const idle = batch.pending.head == .none;
            self.mutex.unlock();
            if (idle) batchCancel(userdata, batch);
            return;
        }
        state.event.reset();
        self.mutex.unlock();
        try state.event.waitTimeout(self.io(), deadline);
    }
}

/// Completes one submitted operation inline or waits for concurrent work.
fn batchAwaitAsync(userdata: ?*anyopaque, batch: *Io.Batch) Io.Cancelable!void {
    const self = from(userdata);
    errdefer batch.cancel(self.io());
    if (batch.submitted.head != .none) {
        const index = batch.submitted.head;
        const submission = batch.storage[index.toIndex()].submission;
        const result = try self.io().operate(submission.operation);
        batch.submitted.head = submission.node.next;
        if (batch.submitted.head == .none) batch.submitted.tail = .none;
        batch.storage[index.toIndex()] = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
        if (batch.completed.tail == .none) batch.completed.head = index else batch.storage[batch.completed.tail.toIndex()].completion.node.next = index;
        batch.completed.tail = index;
    } else if (batch.pending.head != .none) {
        batchAwaitConcurrent(userdata, batch, .none) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout, error.ConcurrencyUnavailable => unreachable,
        };
    } else batchCancel(userdata, batch);
}

/// Cancels and joins batch work, then frees its persistent state.
fn batchCancel(userdata: ?*anyopaque, batch: *Io.Batch) void {
    const self = from(userdata);
    if (batch.userdata) |ptr| {
        const state: *BatchState = @ptrCast(@alignCast(ptr));
        state.group.cancel(self.io());
        self.allocator.destroy(state);
        batch.userdata = null;
    }
}

/// Delivers pending cancellation at an unblocked cancellation point.
fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    const self = from(userdata);
    if (self.active()) |fiber| {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (fiber.cancel_requested and fiber.protection == .unblocked) {
            fiber.cancel_requested = false;
            return error.Canceled;
        }
    } else try self.blocking.io().checkCancel();
}

/// Marks cancellation pending for the active fiber or threaded caller.
fn recancel(userdata: ?*anyopaque) void {
    const self = from(userdata);
    if (self.active()) |fiber| {
        self.mutex.lock();
        fiber.cancel_requested = true;
        self.mutex.unlock();
    } else self.blocking.io().recancel();
}

/// Replaces cancellation shielding and returns the prior protection state.
fn swapCancelProtection(userdata: ?*anyopaque, protection: Io.CancelProtection) Io.CancelProtection {
    const self = from(userdata);
    if (self.active()) |fiber| {
        self.mutex.lock();
        defer self.mutex.unlock();
        const previous = fiber.protection;
        fiber.protection = protection;
        return previous;
    }
    return self.blocking.io().swapCancelProtection(protection);
}

/// Parks the active fiber on a wait condition and optional deadline.
/// Socket watches are shared among matching fibers and disarmed only when the
/// final waiter leaves; cancellation is checked before and after the wait.
fn park(self: *Evented, wait: Wait, timeout: Io.Timeout, cancelable: bool) Io.Cancelable!void {
    const fiber = self.active().?;
    if (cancelable) try checkCancel(&self.blocking);
    self.mutex.lock();
    if (wait == .futex and @atomicLoad(u32, wait.futex.ptr, .acquire) != wait.futex.expected) {
        self.mutex.unlock();
        return;
    }
    if (cancelable and fiber.cancel_requested and fiber.protection == .unblocked) {
        fiber.cancel_requested = false;
        self.mutex.unlock();
        return error.Canceled;
    }
    if (wait == .socket) self.reactor.arm(wait.socket) catch |err| {
        self.mutex.unlock();
        std.log.err("socket readiness registration failed: {s}", .{@errorName(err)});
        @panic("socket readiness registration failed");
    };
    fiber.wait = wait;
    fiber.deadline = timeout.toTimestamp(self.blocking.io());
    fiber.cancelable = cancelable;
    fiber.parked = true;
    self.mutex.unlock();
    self.switchToScheduler();
    self.mutex.lock();
    fiber.wait = .none;
    fiber.deadline = null;
    if (wait == .socket) {
        var other = self.fibers;
        var watched = false;
        while (other) |candidate| : (other = candidate.next) {
            if (candidate.parked and candidate.wait == .socket and std.meta.eql(candidate.wait.socket, wait.socket)) watched = true;
        }
        if (self.main_fiber.parked and self.main_fiber.wait == .socket and std.meta.eql(self.main_fiber.wait.socket, wait.socket)) watched = true;
        if (!watched) self.reactor.disarm(wait.socket) catch |err| {
            std.log.err("socket readiness cancellation failed: {s}", .{@errorName(err)});
            @panic("socket readiness cancellation failed");
        };
    }
    self.mutex.unlock();
    if (cancelable) try checkCancel(&self.blocking);
}

/// Waits until a futex word changes, times out, or the fiber is canceled.
fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const self = from(userdata);
    if (self.active() == null) return self.blocking.io().vtable.futexWait(userdata, ptr, expected, timeout);
    if (@atomicLoad(u32, ptr, .acquire) != expected) return;
    try self.park(.{ .futex = .{ .ptr = ptr, .expected = expected } }, timeout, true);
}

/// Waits on a futex without cancellation or a deadline.
fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    const self = from(userdata);
    if (self.active() == null) return self.blocking.io().vtable.futexWaitUncancelable(userdata, ptr, expected);
    if (@atomicLoad(u32, ptr, .acquire) != expected) return;
    self.park(.{ .futex = .{ .ptr = ptr, .expected = expected } }, .none, false) catch unreachable;
}

/// Wakes matching fibers across registered backends, delegating any remaining
/// wake quota to the threaded implementation.
fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    const self = from(userdata);
    var remaining = max_waiters;
    backends_mutex.lockUncancelable(self.blocking.io());
    var backend = backends;
    while (backend) |peer| : (backend = peer.next_backend) {
        if (remaining == 0) break;
        const before = remaining;
        peer.mutex.lock();
        var candidate: ?*Fiber = &peer.main_fiber;
        while (candidate) |fiber| : (candidate = if (fiber == &peer.main_fiber) peer.fibers else fiber.next) {
            if (remaining == 0) break;
            if (fiber.parked and fiber.wait == .futex and fiber.wait.futex.ptr == ptr) {
                peer.enqueue(fiber);
                remaining -= 1;
            }
        }
        peer.mutex.unlock();
        if (remaining != before) peer.notify();
    }
    backends_mutex.unlock(self.blocking.io());
    if (remaining != 0) self.blocking.io().vtable.futexWake(userdata, ptr, remaining);
}

/// Suspends the current fiber until the timeout expires or cancellation arrives.
fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const self = from(userdata);
    if (self.active() == null) return self.blocking.io().vtable.sleep(userdata, timeout);
    try self.park(.timer, timeout, true);
}

/// Enables nonblocking mode on an existing descriptor.
fn nonblocking(fd: posix.fd_t) !void {
    const flags = try fcntl(fd, posix.F.GETFL, 0);
    const mask: u32 = @bitCast(@as(posix.O, .{ .NONBLOCK = true }));
    _ = try fcntl(fd, posix.F.SETFL, flags | mask);
}

/// Calls `fcntl`, retrying interruptions and translating other syscall failures.
fn fcntl(fd: posix.fd_t, command: i32, argument: usize) !usize {
    while (true) {
        const result = posix.system.fcntl(fd, command, argument);
        switch (posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Establishes a stream TCP connection, suspending the owner-thread fiber while
/// connect is pending and honoring the optional timeout/cancellation.
fn netConnectIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
    const self = from(userdata);
    if (self.active() == null) {
        var future = self.io().concurrent(netConnectIp, .{ userdata, address, options }) catch return error.SystemResources;
        return future.await(self.io());
    }
    self.yieldReady();
    try checkCancel(userdata);
    if (options.mode != .stream) return error.SocketModeUnsupported;
    var storage: Io.Threaded.PosixAddress = undefined;
    const length = Io.Threaded.addressToPosix(address, &storage);
    const mode_protocol = try Io.Threaded.posixSocketModeProtocol(storage.any.family, options.mode, options.protocol);
    const created = posix.system.socket(storage.any.family, @intCast(mode_protocol[0]), @intCast(mode_protocol[1]));
    switch (posix.errno(created)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM, .NOBUFS => return error.SystemResources,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .PROTONOSUPPORT => return error.ProtocolUnsupportedBySystem,
        .ACCES => return error.AccessDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
    const fd: posix.fd_t = @intCast(created);
    errdefer Io.Threaded.closeFd(fd);
    nonblocking(fd) catch return error.Unexpected;
    _ = fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC) catch return error.Unexpected;
    const deadline = options.timeout.toTimestamp(self.io());
    var err = posix.errno(posix.system.connect(fd, &storage.any, length));
    while (true) {
        switch (err) {
            .SUCCESS, .ISCONN => return .{ .handle = fd, .address = address.* },
            .INTR, .INPROGRESS, .ALREADY, .AGAIN => {},
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.Timeout,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NETDOWN => return error.NetworkDown,
            .ADDRNOTAVAIL, .ADDRINUSE => return error.AddressUnavailable,
            .ACCES, .PERM => return error.AccessDenied,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            else => return posix.unexpectedErrno(err),
        }
        try self.park(.{ .socket = .{ .fd = fd, .interest = .write } }, if (deadline) |timestamp| .{ .deadline = timestamp } else .none, true);
        if (deadline) |timestamp| {
            if (timestamp.durationFromNow(self.io()).raw.nanoseconds <= 0) return error.Timeout;
        }
        var socket_error: i32 = 0;
        var error_length: posix.socklen_t = @sizeOf(i32);
        const result = posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&socket_error), &error_length);
        if (posix.errno(result) != .SUCCESS) return posix.unexpectedErrno(posix.errno(result));
        err = @fromBackingInt(@intCast(socket_error));
    }
}

/// Creates a listening IP socket through threaded services, then enables
/// nonblocking mode so the reactor can drive accepts.
fn netListenIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ListenOptions) Io.net.IpAddress.ListenError!Io.net.Socket {
    const self = from(userdata);
    const socket = try self.blocking.io().vtable.netListenIp(userdata, address, options);
    errdefer socket.close(self.blocking.io());
    nonblocking(socket.handle) catch |err| {
        std.log.err("nonblocking listener setup failed: {s}", .{@errorName(err)});
        return error.Unexpected;
    };
    return socket;
}

/// Accepts one connection, parking on read readiness when the listener is empty.
/// The returned socket is nonblocking and close-on-exec.
fn netAccept(userdata: ?*anyopaque, fd: Io.net.Socket.Handle, options: Io.net.Server.AcceptOptions) Io.net.Server.AcceptError!Io.net.Socket {
    const self = from(userdata);
    if (self.active() == null) {
        var future = self.io().concurrent(netAccept, .{ userdata, fd, options }) catch return error.SystemResources;
        return future.await(self.io());
    }
    var address: Io.Threaded.PosixAddress = undefined;
    var length: posix.socklen_t = @sizeOf(Io.Threaded.PosixAddress);
    while (true) {
        self.yieldReady();
        try checkCancel(userdata);
        const result = posix.system.accept(fd, &address.any, &length);
        switch (posix.errno(result)) {
            .SUCCESS => {
                const incoming: posix.fd_t = @intCast(result);
                errdefer Io.Threaded.closeFd(incoming);
                nonblocking(incoming) catch return error.Unexpected;
                _ = fcntl(incoming, posix.F.SETFD, posix.FD_CLOEXEC) catch return error.Unexpected;
                return .{ .handle = incoming, .address = Io.Threaded.addressFromPosix(&address) };
            },
            .INTR => continue,
            .AGAIN => try self.park(.{ .socket = .{ .fd = fd, .interest = .read } }, .none, true),
            .CONNABORTED => return error.ConnectionAborted,
            .INVAL => return error.SocketNotListening,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Routes supported stream operations to evented handlers and delegates other
/// operations to threaded I/O; unsupported datagram requests return their API errors.
fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    const self = from(userdata);
    switch (operation) {
        .net_receive, .net_send => {
            std.log.err("datagram operations are not supported by the TCP reactor backend", .{});
            return Io.failingOperate(userdata, operation);
        },
        else => {},
    }
    if (self.active() == null) {
        switch (operation) {
            .net_read, .net_write => {
                var future = self.io().concurrent(operate, .{ userdata, operation }) catch {
                    std.log.err("cannot dispatch socket operation to reactor: concurrency unavailable", .{});
                    return switch (operation) {
                        .net_read => .{ .net_read = error.SystemResources },
                        .net_write => .{ .net_write = error.SystemResources },
                        else => unreachable,
                    };
                };
                return future.await(self.io());
            },
            else => return self.blocking.io().operate(operation),
        }
    }
    if (operation == .net_read or operation == .net_write) self.yieldReady();
    try checkCancel(userdata);
    return switch (operation) {
        .net_read => |read| .{ .net_read = readSocket(self, read) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => @as(Io.Operation.NetRead.Error, @errorCast(err)),
        } },
        .net_write => |write| .{ .net_write = writeSocket(self, write) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => @as(Io.Operation.NetWrite.Error, @errorCast(err)),
        } },
        else => self.blocking.io().operate(operation),
    };
}

/// Receives stream data and ancillary control bytes, retrying after read readiness.
fn readSocket(self: *Evented, operation: Io.Operation.NetRead) (Io.Cancelable || Io.Operation.NetRead.Error)!Io.net.Stream.ReadResult {
    var buffers: [8]posix.iovec = undefined;
    var count: usize = 0;
    for (operation.data) |bytes| {
        if (count == buffers.len) break;
        if (bytes.len == 0) continue;
        buffers[count] = .{ .base = bytes.ptr, .len = bytes.len };
        count += 1;
    }
    if (count == 0) return .{ .data_len = 0 };
    var message: posix.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &buffers,
        .iovlen = @intCast(count),
        .control = operation.control.ptr,
        .controllen = @intCast(operation.control.len),
        .flags = 0,
    };
    while (true) {
        try checkCancel(&self.blocking);
        const result = posix.system.recvmsg(operation.socket_handle, &message, 0);
        switch (posix.errno(result)) {
            .SUCCESS => return .{ .data_len = @intCast(result), .control_len = @intCast(message.controllen), .control_truncated = message.flags & posix.MSG.CTRUNC != 0 },
            .INTR => continue,
            .AGAIN => try self.park(.{ .socket = .{ .fd = operation.socket_handle, .interest = .read } }, .none, true),
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN, .PIPE => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NETDOWN => return error.NetworkDown,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Sends stream headers, payload slices, and control data, parking on write readiness.
fn writeSocket(self: *Evented, operation: Io.Operation.NetWrite) (Io.Cancelable || Io.Operation.NetWrite.Error)!usize {
    var buffers: [8]posix.iovec_const = undefined;
    var count: usize = 0;
    if (operation.header.len > 0) {
        buffers[count] = .{ .base = operation.header.ptr, .len = operation.header.len };
        count += 1;
    }

    for (operation.data, 0..) |bytes, index| {
        const repeats = if (index + 1 == operation.data.len) operation.splat else 1;
        for (0..@min(repeats, buffers.len - count)) |_| {
            if (bytes.len == 0) continue;
            buffers[count] = .{ .base = bytes.ptr, .len = bytes.len };
            count += 1;
        }
        if (count == buffers.len) break;
    }
    if (count == 0) return 0;
    const message: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &buffers,
        .iovlen = @intCast(count),
        .control = if (operation.control.len == 0) null else @constCast(operation.control.ptr),
        .controllen = @intCast(operation.control.len),
        .flags = 0,
    };
    while (true) {
        try checkCancel(&self.blocking);
        const result = posix.system.sendmsg(operation.socket_handle, &message, posix.MSG.NOSIGNAL);
        switch (posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .AGAIN => try self.park(.{ .socket = .{ .fd = operation.socket_handle, .interest = .write } }, .none, true),
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN, .PIPE => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NETDOWN => return error.NetworkDown,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Reports IP datagram binding as unsupported by this TCP-only reactor.
fn unsupportedBind(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
    std.log.err("datagram binding is not supported by the TCP reactor backend", .{});
    return Io.failingNetBindIp(userdata, address, options);
}

/// Reports Unix-domain listeners as unsupported by this TCP-only reactor.
fn unsupportedListenUnix(userdata: ?*anyopaque, address: *const Io.net.UnixAddress, options: Io.net.UnixAddress.ListenOptions) Io.net.UnixAddress.ListenError!Io.net.Socket.Handle {
    std.log.err("Unix sockets are not supported by the TCP reactor backend", .{});
    return Io.failingNetListenUnix(userdata, address, options);
}

/// Reports Unix-domain connections as unsupported by this TCP-only reactor.
fn unsupportedConnectUnix(userdata: ?*anyopaque, address: *const Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
    std.log.err("Unix sockets are not supported by the TCP reactor backend", .{});
    return Io.failingNetConnectUnix(userdata, address);
}

/// Reports socket-pair creation as unsupported by this TCP-only reactor.
fn unsupportedPair(userdata: ?*anyopaque, options: Io.net.Socket.CreatePairOptions) Io.net.Socket.CreatePairError![2]Io.net.Socket {
    std.log.err("socket pairs are not supported by the TCP reactor backend", .{});
    return Io.failingNetSocketCreatePair(userdata, options);
}

/// Reports sendfile-style transfer as unsupported; callers can stream writes instead.
fn unsupportedWriteFile(userdata: ?*anyopaque, fd: Io.net.Socket.Handle, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
    std.log.err("sendfile is not supported by the TCP reactor backend; use streaming writes", .{});
    return Io.failingNetWriteFile(userdata, fd, header, reader, limit);
}

/// Reports hostname lookup as unsupported; callers must use numeric IP addresses.
fn unsupportedLookup(userdata: ?*anyopaque, host: Io.net.HostName, results: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
    std.log.err("DNS lookup is not supported by the TCP reactor backend; use numeric IP addresses", .{});
    return Io.failingNetLookup(userdata, host, results, options);
}

test "evented futures and groups run on the reactor thread and cancel sleeps" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    const Work = struct {
        /// Sleeps briefly and returns the thread ID on which its fiber ran.
        fn thread(io_arg: Io) Io.Cancelable!std.Thread.Id {
            try io_arg.sleep(.fromMilliseconds(1), .awake);
            return std.Thread.getCurrentId();
        }
        /// Remains parked until canceled, exercising future cancellation.
        fn block(io_arg: Io) Io.Cancelable!void {
            try io_arg.sleep(.fromSeconds(60), .awake);
        }
        /// Delays and then signals the supplied event.
        fn mark(io_arg: Io, event: *Io.Event) Io.Cancelable!void {
            try io_arg.sleep(.fromMilliseconds(1), .awake);
            event.set(io_arg);
        }
    };
    var thread = try interface.concurrent(Work.thread, .{interface});
    defer _ = thread.cancel(interface) catch {};
    var blocked = try interface.concurrent(Work.block, .{interface});
    defer blocked.cancel(interface) catch {};
    var event: Io.Event = .unset;
    var group: Io.Group = .init;
    defer group.cancel(interface);
    try group.concurrent(interface, Work.mark, .{ interface, &event });
    try event.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try group.await(interface);
    try std.testing.expectEqual(backend.owner, try thread.await(interface));
    try std.testing.expectError(error.Canceled, blocked.cancel(interface));
}

test "evented TCP accept, connect, streaming and batch timeout" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(interface, .{ .reuse_address = true });
    defer listener.deinit(interface);
    var accepted = try interface.concurrent(Io.net.Server.accept, .{ &listener, interface });
    defer if (accepted.cancel(interface)) |stream| stream.close(interface) else |err| {
        if (err != error.Canceled) @panic(@errorName(err));
    };
    const client = try listener.socket.address.connect(interface, .{ .mode = .stream });
    defer client.close(interface);
    const peer = try accepted.await(interface);
    const sent = try interface.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &.{"hello"} } });
    try std.testing.expectEqual(@as(usize, 5), try sent.net_write);
    var bytes: [8]u8 = undefined;
    var buffers = [_][]u8{&bytes};
    try std.testing.expectEqual(@as(usize, 5), try peer.read(interface, &buffers));
    try std.testing.expectEqualStrings("hello", bytes[0..5]);
    const ForeignWriter = struct {
        /// Writes from a foreign thread through the evented interface.
        fn run(io_arg: Io, stream: Io.net.Stream) void {
            var writer = stream.writer(io_arg, &.{});
            writer.interface.writeAll("thread") catch |err| @panic(@errorName(err));
        }
    };
    const foreign_thread = try std.Thread.spawn(.{}, ForeignWriter.run, .{ interface, client });
    defer foreign_thread.join();
    try std.testing.expectEqual(@as(usize, 6), try peer.read(interface, &buffers));
    try std.testing.expectEqualStrings("thread", bytes[0..6]);
    try std.testing.expectError(error.Timeout, interface.operateTimeout(.{ .net_read = .{ .socket_handle = peer.socket.handle, .data = &buffers } }, .{ .duration = .{ .raw = .fromMilliseconds(2), .clock = .awake } }));
    const Writer = struct {
        /// Repeatedly fills the socket until cancellation interrupts the write.
        fn run(io_arg: Io, fd: posix.fd_t) !void {
            const payload: [65536]u8 = @splat(0);
            while (true) _ = try (try io_arg.operate(.{ .net_write = .{ .socket_handle = fd, .data = &.{&payload} } })).net_write;
        }
    };
    var writing = try interface.concurrent(Writer.run, .{ interface, client.socket.handle });
    try interface.sleep(.fromMilliseconds(2), .awake);
    try std.testing.expectError(error.Canceled, writing.cancel(interface));
    const ReadyWriter = struct {
        /// Repeats zero-byte writes to exercise cancellation while always ready.
        fn run(io_arg: Io, fd: posix.fd_t) !void {
            while (true) _ = try (try io_arg.operate(.{ .net_write = .{ .socket_handle = fd, .data = &.{""} } })).net_write;
        }
    };
    var ready_writer = try interface.concurrent(ReadyWriter.run, .{ interface, client.socket.handle });
    try interface.sleep(.fromMilliseconds(2), .awake);
    try std.testing.expectError(error.Canceled, ready_writer.cancel(interface));
    var pending = try interface.concurrent(Io.net.Server.accept, .{ &listener, interface });
    try interface.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expectError(error.Canceled, pending.cancel(interface));
}

test "evented futex wakeups interoperate with an external queue thread" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    var semaphore: Io.Semaphore = .{};
    const Producer = struct {
        /// Posts all semaphore tokens from a non-owner thread.
        fn run(io_arg: Io, sem: *Io.Semaphore) void {
            for (0..2000) |_| sem.post(io_arg);
        }
    };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{ interface, &semaphore });
    defer thread.join();
    for (0..2000) |_| try semaphore.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
}

test "evented synchronization wakes fibers on another reactor thread" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    const Shared = struct {
        /// Signals that the peer backend is ready to exchange semaphore tokens.
        ready: Io.Event = .unset,
        /// Requests work from the peer thread.
        request: Io.Semaphore = .{},
        /// Acknowledges one completed peer update.
        response: Io.Semaphore = .{},
        /// Protects the shared update count.
        mutex: Io.Mutex = .init,
        /// Number of updates performed by both threads.
        count: usize = 0,
        /// Captures a failure from the worker thread for the test thread.
        failure: ?anyerror = null,

        /// Runs peer work and records any error for the owning test.
        fn run(self: *@This()) void {
            self.work() catch |err| {
                self.failure = err;
            };
        }

        /// Creates a peer backend and participates in the synchronized exchange.
        fn work(self: *@This()) !void {
            var peer: Evented = undefined;
            try peer.init(std.testing.allocator);
            defer peer.deinit();
            const io_arg = peer.io();
            self.ready.set(io_arg);
            for (0..2000) |_| {
                try self.request.waitTimeout(io_arg, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
                self.mutex.lockUncancelable(io_arg);
                self.count += 1;
                self.mutex.unlock(io_arg);
                self.response.post(io_arg);
            }
        }
    };
    var shared: Shared = .{};
    {
        const thread = try std.Thread.spawn(.{}, Shared.run, .{&shared});
        defer thread.join();
        try shared.ready.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        for (0..2000) |_| {
            shared.mutex.lockUncancelable(interface);
            shared.count += 1;
            shared.mutex.unlock(interface);
            shared.request.post(interface);
            try shared.response.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        }
    }
    if (shared.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 4000), shared.count);
}

test "evented completed group members release stacks before the group is canceled" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    var group: Io.Group = .init;
    defer group.cancel(interface);
    var count: usize = 0;
    var completed: Io.Event = .unset;
    const Work = struct {
        /// Parks until group cancellation reaches this task.
        fn block(io_arg: Io) Io.Cancelable!void {
            try io_arg.sleep(.fromSeconds(60), .awake);
        }
        /// Increments completion count and signals when all short tasks finish.
        fn finish(io_arg: Io, n: *usize, event: *Io.Event) void {
            n.* += 1;
            if (n.* == 32) event.set(io_arg);
        }
    };
    try group.concurrent(interface, Work.block, .{interface});
    for (0..32) |_| try group.concurrent(interface, Work.finish, .{ interface, &count, &completed });
    try completed.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try std.testing.expect(backend.fibers != null);
    try std.testing.expect(backend.fibers.?.next == null);
    group.cancel(interface);
    try std.testing.expect(backend.fibers == null);
}

test "evented cancellation protection, cleanup and recancel" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    var entered: Io.Event = .unset;
    var cleaned = false;
    const Work = struct {
        /// Tests shielding, cleanup, and redelivery of cancellation.
        fn run(io_arg: Io, event: *Io.Event, cleanup: *bool) !void {
            defer cleanup.* = true;
            const previous = io_arg.swapCancelProtection(.blocked);
            defer _ = io_arg.swapCancelProtection(previous);
            event.set(io_arg);
            try io_arg.sleep(.fromMilliseconds(2), .awake);
            _ = io_arg.swapCancelProtection(previous);
            try std.testing.expectError(error.Canceled, io_arg.checkCancel());
            try io_arg.checkCancel();
            io_arg.recancel();
            try std.testing.expectError(error.Canceled, io_arg.checkCancel());
        }
    };
    var future = try interface.concurrent(Work.run, .{ interface, &entered, &cleaned });
    defer future.cancel(interface) catch |err| @panic(@errorName(err));
    try entered.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try future.cancel(interface);
    try std.testing.expect(cleaned);
}
