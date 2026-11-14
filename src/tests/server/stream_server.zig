const std = @import("std");
const StreamServer = @import("../../server/network/stream_server.zig");

test "StreamServer listens on an ephemeral port and closes cleanly" {
    var server = try StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    try server.listen(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0));

    try std.testing.expect(server.sockfd != null);
    try std.testing.expect(server.listen_address.getPort() != 0);

    server.close();
    try std.testing.expect(server.sockfd == null);
}
