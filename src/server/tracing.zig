//! Wraps an allocator to maintain synchronized allocation counters and byte totals.

const std = @import("std");
const sync = @import("sync");

const ptrCast = @import("utils.zig").ptrCast;

const TracingAllocator = @This();

/// Thread-safe allocator wrapper that records allocation counts and requested-byte totals.
child_allocator: std.mem.Allocator,

/// Requested bytes currently live according to successful allocations and size changes.
real_size: u64 = 0, // live requested bytes
/// Cumulative requested bytes allocated, including successful growth and excluding shrinkage.
total_size: u64 = 0, // total size allocated

/// Number of allocation callbacks, including failed allocation attempts.
count_allocs: u64 = 0,
/// Number of successful allocation callbacks.
count_allocs_success: u64 = 0,
/// Number of resize callbacks, whether or not the backing allocator accepts them.
count_resizes: u64 = 0,
/// Number of free callbacks.
count_frees: u64 = 0,

/// Protects both allocator operations and the statistics they update.
mutex: sync.Mutex = .{},

/// Initializes statistics to zero and stores the allocator that performs the work.
pub fn init(child_allocator: std.mem.Allocator) TracingAllocator {
    return TracingAllocator{ .child_allocator = child_allocator };
}

/// Returns an allocator interface whose callbacks forward to this wrapper.
/// The wrapper must remain alive while the returned allocator is in use.
pub fn allocator(self: *TracingAllocator) std.mem.Allocator {
    return std.mem.Allocator{
        .ptr = self,
        .vtable = &std.mem.Allocator.VTable{
            .alloc = alloc,
            .resize = resize,
            .free = free,
            .remap = remap,
        },
    };
}

/// Allocates through the child allocator and updates allocation and byte counters.
fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    var self = ptrCast(TracingAllocator, ctx);
    self.mutex.lock();
    defer self.mutex.unlock();

    self.*.count_allocs += 1;
    const ptr = self.*.child_allocator.rawAlloc(
        len,
        ptr_align,
        ret_addr,
    ) orelse return null;

    self.*.count_allocs_success += 1;
    self.*.real_size += len;
    self.*.total_size += len;
    return ptr;
}

/// Attempts an in-place resize and adjusts live and cumulative byte totals on success.
fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    var self = ptrCast(TracingAllocator, ctx);
    self.mutex.lock();
    defer self.mutex.unlock();

    self.*.count_resizes += 1;
    const old_len = buf.len;
    const stable = self.*.child_allocator.rawResize(
        buf,
        buf_align,
        new_len,
        ret_addr,
    );

    if (stable) {
        self.recordResize(old_len, new_len);
    }
    return stable;
}

/// Attempts a remap and accounts for the requested-size change when it succeeds.
fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    var self = ptrCast(TracingAllocator, ctx);
    self.mutex.lock();
    defer self.mutex.unlock();

    const memory_new = self.child_allocator.rawRemap(
        memory,
        alignment,
        new_len,
        ret_addr,
    ) orelse return null;

    self.recordResize(memory.len, new_len);

    return memory_new;
}

/// Applies a successful size change to live bytes and cumulative growth.
fn recordResize(self: *TracingAllocator, old_len: usize, new_len: usize) void {
    if (new_len >= old_len) {
        const growth = new_len - old_len;
        self.real_size += growth;
        self.total_size += growth;
    } else {
        self.real_size -= old_len - new_len;
    }
}

/// Frees through the child allocator and subtracts the released requested bytes.
fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    var self = ptrCast(TracingAllocator, ctx);
    self.mutex.lock();
    defer self.mutex.unlock();

    self.*.count_frees += 1;
    self.*.real_size -= buf.len;

    return self.*.child_allocator.rawFree(
        buf,
        buf_align,
        ret_addr,
    );
}
