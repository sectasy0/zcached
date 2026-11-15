const std = @import("std");
const sync = @import("sync");

const ptrCast = @import("utils.zig").ptrCast;

const TracingAllocator = @This();

/// TracingAllocator is a thread-safe structure that wraps an underlying allocator,
/// allowing tracking of various statistics related to memory allocation operations.
///
/// It keeps a record of allocation counts, successful allocations, resizes, and frees.
/// Additionally, it tracks the real size (allocated - freed size) and the total size allocated.
child_allocator: std.mem.Allocator,

real_size: u64 = 0, // live requested bytes
total_size: u64 = 0, // total size allocated

count_allocs: u64 = 0,
count_allocs_success: u64 = 0,
count_resizes: u64 = 0,
count_frees: u64 = 0,

mutex: sync.Mutex = .{},

pub fn init(child_allocator: std.mem.Allocator) TracingAllocator {
    return TracingAllocator{ .child_allocator = child_allocator };
}

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

fn recordResize(self: *TracingAllocator, old_len: usize, new_len: usize) void {
    if (new_len >= old_len) {
        const growth = new_len - old_len;
        self.real_size += growth;
        self.total_size += growth;
    } else {
        self.real_size -= old_len - new_len;
    }
}

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

test "tracing accounts for shrinking and same-address remaps" {
    var bytes: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    var tracking = TracingAllocator.init(fixed.allocator());
    const traced = tracking.allocator();
    var buffer = try traced.alloc(u8, 8);
    defer traced.free(buffer);
    try std.testing.expect(traced.resize(buffer, 4));
    buffer = buffer[0..4];
    try std.testing.expectEqual(@as(u64, 4), tracking.real_size);
    const before = buffer.ptr;
    buffer = traced.remap(buffer, 12) orelse return error.OutOfMemory;
    try std.testing.expectEqual(before, buffer.ptr);
    try std.testing.expectEqual(@as(u64, 12), tracking.real_size);
    try std.testing.expectEqual(@as(u64, 16), tracking.total_size);
}
