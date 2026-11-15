const std = @import("std");
const Address = @import("../../server/network/address.zig").Address;
const ContextFixture = @import("../fixtures.zig").ContextFixture;
const Warden = @import("../../server/network/warden.zig");
const Worker = @import("../../server/processing/worker.zig");
const StreamServer = @import("../../server/network/stream_server.zig");
const Stream = @import("../../server/network/stream.zig").Stream;

test "Warden rejects a connection when the worker has no free slot" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var worker = try Worker.init(fixture.allocator, 1);
    defer worker.deinit();
    var warden = Warden.init(fixture.allocator, fixture.context());
    defer warden.deinit();

    const incoming = StreamServer.Connection{
        .stream = Stream{ .handle = -1 },
        .address = Address.initIp4(.{ 127, 0, 0, 1 }, 1234),
    };
    const result = warden.setupConnection(&worker, incoming);

    try std.testing.expectEqual(@as(usize, 1), worker.connections);
    try std.testing.expectEqual(@as(usize, 0), worker.states.count());
    try std.testing.expectEqual(error.MaxConnections, result.err.etype);
}
