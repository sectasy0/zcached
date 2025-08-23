const std = @import("std");

const ptrCast = @import("utils.zig").ptrCast;

const TracingAllocator = @This();

/// TracingAllocator is a thread-safe structure that wraps an underlying allocator,
/// allowing tracking of various statistics related to memory allocation operations.
///
/// It keeps a record of allocation counts, successful allocations, resizes, and frees.
/// Additionally, it tracks the real size (allocated - freed size) and the total size allocated.
child_allocator: std.mem.Allocator,

real_size: u64 = 0, // total_size - freed size
total_size: u64 = 0, // total size allocated

count_allocs: u64 = 0,
count_allocs_success: u64 = 0,
count_resizes: u64 = 0,
count_frees: u64 = 0,

mutex: std.Thread.Mutex = .{},

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
        const size_diff = new_len - old_len;

        self.*.real_size += size_diff;
        self.*.total_size += size_diff;

        if (new_len <= old_len) {
            self.*.real_size -= 2 * size_diff;
            self.*.total_size -= 2 * size_diff;
        }
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

    if (memory_new != memory.ptr) self.real_size -= memory.len;
    if (memory_new != memory.ptr) self.real_size += new_len;
    if (memory_new != memory.ptr) self.total_size -= memory.len;
    if (memory_new != memory.ptr) self.total_size += new_len;

    return memory_new;
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
