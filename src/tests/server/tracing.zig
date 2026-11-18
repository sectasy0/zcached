const std = @import("std");
const TracingAllocator = @import("../../server/tracing.zig");

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
