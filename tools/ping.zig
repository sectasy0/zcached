const std = @import("std");
const consts = @import("consts.zig");

pub fn main() !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const address = try std.Io.net.IpAddress.parse(consts.HOST, consts.PORT);
    const socket = try address.connect(io, .{ .mode = .stream });
    defer socket.close(io);

    var buffer: [256]u8 = undefined;
    var writer = socket.writer(io, &buffer);
    try writer.interface.writeAll("*1\r\n$4\r\nPING\r\n\x03");
    try writer.interface.flush();
}
