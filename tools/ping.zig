const std = @import("std");
const consts = @import("consts.zig");

/// Reads a single line response from the socket and prints it with the given label.
fn printResponse(socket: *std.net.Stream, label: []const u8) !void {
    const response = try socket.reader().readUntilDelimiterAlloc(std.heap.page_allocator, '\n', 1024);
    defer std.heap.page_allocator.free(response);
    std.debug.print("{s}: {s}\n", .{label, response});
}

pub fn main() !void {
    const addr = try std.net.Address.parseIp(consts.HOST, consts.PORT);

    var socket = try std.net.tcpConnectToAddress(addr);
    defer socket.close();

    // send set command
    _ = try socket.writeAll(@constCast("*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n\x03"));
    try printResponse(&socket, "SET Response");

    // send get command
    _ = try socket.writeAll(@constCast("*2\r\n$3\r\nGET\r\n$9\r\nmycounter\r\n\x03"));
    try printResponse(&socket, "GET Response");
}