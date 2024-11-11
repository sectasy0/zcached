const std = @import("std");
const consts = @import("consts.zig");

pub fn main() !void {
    const addr = try std.net.Address.parseIp(consts.HOST, consts.PORT);

    var socket = try std.net.tcpConnectToAddress(addr);
    defer socket.close();

    _ = try socket.write(@constCast("*1\r\n$4\r\nPING\r\n\x03"));
}
