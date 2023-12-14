const std = @import("std");

const ptrCast = @import("utils.zig").ptrCast;

pub const TracingAllocator = struct {
    child_allocator: std.mem.Allocator,

    real_size: u64 = 0, // total_size - freed size
    total_size: u64 = 0, // total size allocated

    count_allocs: u64 = 0,
    count_allocs_success: u64 = 0,
    count_resizes: u64 = 0,
    count_frees: u64 = 0,

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
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        var self = ptrCast(TracingAllocator, ctx);
        self.*.count_allocs += 1;
        const ptr = self.*.child_allocator.rawAlloc(len, ptr_align, ret_addr) orelse return null;
        self.*.count_allocs_success += 1;
        self.*.real_size += len;
        self.*.total_size += len;
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        var self = ptrCast(TracingAllocator, ctx);
        self.*.count_resizes += 1;
        const old_len = buf.len;
        const stable = self.*.child_allocator.rawResize(
            buf,
            buf_align,
            new_len,
            ret_addr,
        );
        if (stable) {
            if (new_len > old_len) {
                self.*.real_size += new_len;
                self.*.real_size -= old_len;
                self.*.total_size += new_len;
                self.*.total_size -= old_len;
            } else {
                self.*.real_size -= old_len;
                self.*.real_size += new_len;
                self.*.total_size -= old_len;
                self.*.total_size += new_len;
            }
        }
        return stable;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        var self = ptrCast(TracingAllocator, ctx);
        self.*.count_frees += 1;
        self.*.real_size -= buf.len;
        return self.*.child_allocator.rawFree(buf, buf_align, ret_addr);
    }
};

// TODO: write tests for this, for now just manually tested
