const std = @import("std");
const builtin = @import("builtin");
const Reactor = @import("reactor.zig");
const Io = std.Io;
const posix = std.posix;
const Evented = @This();

// Synchronous platform services are reused; their task scheduler is never used.
blocking: Io.Threaded,
reactor: Reactor,
allocator: std.mem.Allocator,
owner: std.Thread.Id,
mutex: Lock,
condition: Condition,
fibers: ?*Fiber = null,
ready_head: ?*Fiber = null,
ready_tail: ?*Fiber = null,
current: *Fiber,
main_fiber: Fiber,
scheduler_context: Io.fiber.Context,
scheduler_stack: []align(16) u8,
finished: ?*Fiber = null,
wake_pipe: [2]posix.fd_t,
stopping: bool = false,
next_backend: ?*Evented = null,

const stack_size = 4 * 1024 * 1024;
var backends: ?*Evented = null;
var backends_mutex: Io.Mutex = .init;

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

fn freeStack(stack: []align(16) u8) void {
    const guard = std.heap.pageSize();
    const memory = stack.ptr - guard;
    std.heap.page_allocator.rawFree(memory[0 .. stack.len + guard], .@"16", @returnAddress());
}
const Lock = struct {
    backend: *Evented,
    inner: Io.Mutex = .init,

    fn lock(self: *Lock) void {
        self.inner.lockUncancelable(self.backend.blocking.io());
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock(self.backend.blocking.io());
    }
};
const Condition = struct {
    backend: *Evented,
    inner: Io.Condition = .init,

    fn wait(self: *Condition, mutex: *Lock) void {
        self.inner.waitUncancelable(self.backend.blocking.io(), &mutex.inner);
    }

    fn broadcast(self: *Condition) void {
        self.inner.broadcast(self.backend.blocking.io());
    }
};
const Closure = extern struct { backend: *Evented, fiber: ?*Fiber };
const Wait = union(enum) {
    none,
    socket: Reactor.Key,
    futex: struct { ptr: *const u32, expected: u32 },
    future: *Fiber,
    group: *Io.Group,
    timer,
};
const Fiber = struct {
    context: Io.fiber.Context = undefined,
    stack: ?[]align(16) u8 = null,
    arguments: ?[]align(64) u8 = null,
    result: ?[]align(64) u8 = null,
    start: ?*const fn (*const anyopaque, *anyopaque) void = null,
    group_start: ?*const fn (*const anyopaque) void = null,
    group: ?*Io.Group = null,
    next: ?*Fiber = null,
    ready_next: ?*Fiber = null,
    queued: bool = false,
    done: bool = false,
    parked: bool = false,
    cancel_requested: bool = false,
    protection: Io.CancelProtection = .unblocked,
    cancelable: bool = true,
    wait: Wait = .none,
    deadline: ?Io.Clock.Timestamp = null,
};

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

pub fn io(self: *Evented) Io {
    return .{ .userdata = &self.blocking, .vtable = &vtable };
}

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

fn from(userdata: ?*anyopaque) *Evented {
    const blocking: *Io.Threaded = @ptrCast(@alignCast(userdata));
    return @alignCast(@fieldParentPtr("blocking", blocking));
}

fn active(self: *Evented) ?*Fiber {
    return if (std.Thread.getCurrentId() == self.owner) self.current else null;
}

fn contextFor(closure: *Closure) Io.fiber.Context {
    return switch (builtin.cpu.arch) {
        .aarch64 => .{ .sp = @intFromPtr(closure), .fp = 0, .pc = @intFromPtr(&entry) },
        .x86_64 => .{ .rsp = @intFromPtr(closure) - @sizeOf(usize), .rbp = 0, .rip = @intFromPtr(&entry) },
        else => @compileError("evented I/O currently supports aarch64 and x86_64"),
    };
}

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

fn switchToScheduler(self: *Evented) void {
    const message: Io.fiber.Switch = .{ .old = &self.current.context, .new = &self.scheduler_context };
    switchContext(&message);
}

fn switchContext(message: *const Io.fiber.Switch) void {
    const call: *const fn (*const Io.fiber.Switch) callconv(.c) void = @ptrCast(&switchAssembly);
    call(message);
}

// Save the C ABI's callee-saved state explicitly; inline fiber asm loses live registers in optimized Zig 0.17 builds.
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

fn yieldReady(self: *Evented) void {
    self.mutex.lock();
    self.enqueue(self.current);
    self.mutex.unlock();
    self.switchToScheduler();
}

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

fn enqueue(self: *Evented, fiber: *Fiber) void {
    if (fiber.queued or fiber.done) return;
    fiber.parked = false;
    fiber.queued = true;
    fiber.ready_next = null;
    if (self.ready_tail) |tail| tail.ready_next = fiber else self.ready_head = fiber;
    self.ready_tail = fiber;
}

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

fn destroy(self: *Evented, fiber: *Fiber) void {
    freeStack(fiber.stack.?);
    self.allocator.free(fiber.arguments.?);
    self.allocator.free(fiber.result.?);
    self.allocator.destroy(fiber);
}

fn unlink(self: *Evented, fiber: *Fiber) void {
    var link = &self.fibers;
    while (link.* != fiber) link = &link.*.?.next;
    link.* = fiber.next;
}

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

fn asyncStart(userdata: ?*anyopaque, result: []u8, alignment: std.mem.Alignment, arguments: []const u8, arguments_alignment: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) ?*Io.AnyFuture {
    return concurrent(userdata, result.len, alignment, arguments, arguments_alignment, start) catch {
        start(arguments.ptr, result.ptr);
        return null;
    };
}

fn requestCancel(self: *Evented, fiber: *Fiber) void {
    fiber.cancel_requested = true;
    if (fiber.parked and fiber.cancelable and fiber.protection == .unblocked) self.enqueue(fiber);
}

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

fn cancelFuture(userdata: ?*anyopaque, future: *Io.AnyFuture, result: []u8, alignment: std.mem.Alignment) void {
    const self = from(userdata);
    self.mutex.lock();
    self.requestCancel(@ptrCast(@alignCast(future)));
    self.mutex.unlock();
    self.notify();
    awaitFuture(userdata, future, result, alignment);
}

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

fn groupAsync(userdata: ?*anyopaque, group: *Io.Group, arguments: []const u8, alignment: std.mem.Alignment, start: *const fn (*const anyopaque) void) void {
    groupConcurrent(userdata, group, arguments, alignment, start) catch start(arguments.ptr);
}

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

fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, _: *anyopaque) Io.Cancelable!void {
    if (from(userdata).waitGroup(group, false)) return error.Canceled;
}

fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, _: *anyopaque) void {
    _ = from(userdata).waitGroup(group, true);
}

const BatchState = struct {
    group: Io.Group = .init,
    event: Io.Event = .unset,
};

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

fn batchCancel(userdata: ?*anyopaque, batch: *Io.Batch) void {
    const self = from(userdata);
    if (batch.userdata) |ptr| {
        const state: *BatchState = @ptrCast(@alignCast(ptr));
        state.group.cancel(self.io());
        self.allocator.destroy(state);
        batch.userdata = null;
    }
}

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

fn recancel(userdata: ?*anyopaque) void {
    const self = from(userdata);
    if (self.active()) |fiber| {
        self.mutex.lock();
        fiber.cancel_requested = true;
        self.mutex.unlock();
    } else self.blocking.io().recancel();
}

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

fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const self = from(userdata);
    if (self.active() == null) return self.blocking.io().vtable.futexWait(userdata, ptr, expected, timeout);
    if (@atomicLoad(u32, ptr, .acquire) != expected) return;
    try self.park(.{ .futex = .{ .ptr = ptr, .expected = expected } }, timeout, true);
}

fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    const self = from(userdata);
    if (self.active() == null) return self.blocking.io().vtable.futexWaitUncancelable(userdata, ptr, expected);
    if (@atomicLoad(u32, ptr, .acquire) != expected) return;
    self.park(.{ .futex = .{ .ptr = ptr, .expected = expected } }, .none, false) catch unreachable;
}

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

fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const self = from(userdata);
    if (self.active() == null) return self.blocking.io().vtable.sleep(userdata, timeout);
    try self.park(.timer, timeout, true);
}

fn nonblocking(fd: posix.fd_t) !void {
    const flags = try fcntl(fd, posix.F.GETFL, 0);
    const mask: u32 = @bitCast(@as(posix.O, .{ .NONBLOCK = true }));
    _ = try fcntl(fd, posix.F.SETFL, flags | mask);
}

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

fn unsupportedBind(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
    std.log.err("datagram binding is not supported by the TCP reactor backend", .{});
    return Io.failingNetBindIp(userdata, address, options);
}

fn unsupportedListenUnix(userdata: ?*anyopaque, address: *const Io.net.UnixAddress, options: Io.net.UnixAddress.ListenOptions) Io.net.UnixAddress.ListenError!Io.net.Socket.Handle {
    std.log.err("Unix sockets are not supported by the TCP reactor backend", .{});
    return Io.failingNetListenUnix(userdata, address, options);
}

fn unsupportedConnectUnix(userdata: ?*anyopaque, address: *const Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
    std.log.err("Unix sockets are not supported by the TCP reactor backend", .{});
    return Io.failingNetConnectUnix(userdata, address);
}

fn unsupportedPair(userdata: ?*anyopaque, options: Io.net.Socket.CreatePairOptions) Io.net.Socket.CreatePairError![2]Io.net.Socket {
    std.log.err("socket pairs are not supported by the TCP reactor backend", .{});
    return Io.failingNetSocketCreatePair(userdata, options);
}

fn unsupportedWriteFile(userdata: ?*anyopaque, fd: Io.net.Socket.Handle, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
    std.log.err("sendfile is not supported by the TCP reactor backend; use streaming writes", .{});
    return Io.failingNetWriteFile(userdata, fd, header, reader, limit);
}

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
        fn thread(io_arg: Io) Io.Cancelable!std.Thread.Id {
            try io_arg.sleep(.fromMilliseconds(1), .awake);
            return std.Thread.getCurrentId();
        }
        fn block(io_arg: Io) Io.Cancelable!void {
            try io_arg.sleep(.fromSeconds(60), .awake);
        }
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
        fn run(io_arg: Io, fd: posix.fd_t) !void {
            const payload: [65536]u8 = @splat(0);
            while (true) _ = try (try io_arg.operate(.{ .net_write = .{ .socket_handle = fd, .data = &.{&payload} } })).net_write;
        }
    };
    var writing = try interface.concurrent(Writer.run, .{ interface, client.socket.handle });
    try interface.sleep(.fromMilliseconds(2), .awake);
    try std.testing.expectError(error.Canceled, writing.cancel(interface));
    const ReadyWriter = struct {
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
        ready: Io.Event = .unset,
        request: Io.Semaphore = .{},
        response: Io.Semaphore = .{},
        mutex: Io.Mutex = .init,
        count: usize = 0,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.work() catch |err| {
                self.failure = err;
            };
        }

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
        fn block(io_arg: Io) Io.Cancelable!void {
            try io_arg.sleep(.fromSeconds(60), .awake);
        }
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
