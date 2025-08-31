const std = @import("std");

const Connection = @import("../../server/network/connection.zig");

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;

const Processor = @import("../../server/processing/requests.zig");

test "should deframe" {
    var fixture: ContextFixture = try .init();
    try fixture.create_memory();
    defer fixture.deinit();

    const conn_fixture: fixtures.ConnectionFixture = try .init(std.testing.allocator);

    const context = fixture.context();

    var processor: Processor = .init(std.testing.allocator, context);
    defer processor.deinit();

    var connection = conn_fixture.connection;
    defer connection.deinit();

    const request1 = @constCast("*3\r\n$3\r\nSET\r\n$5\r\ntest1\r\n:43\r\n\x03");
    const request2 = @constCast("*3\r\n$3\r\nSET\r\n$5\r\ntest2\r\n:44\r\n\x03");
    try connection.accumulator.appendSlice(request1);
    try connection.accumulator.appendSlice(request2);

    processor.deframe(&connection);

    try std.testing.expectEqual(0, connection.accumulator.items.len);
    try std.testing.expectEqual(43, (try fixture.memory.?.get("test1")).int);
    try std.testing.expectEqual(44, (try fixture.memory.?.get("test2")).int);

    connection.accumulator.clearRetainingCapacity();

    _ = fixture.memory.?.delete("test1");

    try std.testing.expectEqual(error.NotFound, fixture.memory.?.get("test1"));

    // partial request
    const partial_request = @constCast("*3\r\n$3\r\nSET\r\n$5\r");
    try connection.accumulator.appendSlice(request1);
    try connection.accumulator.appendSlice(partial_request);
    processor.deframe(&connection);

    try std.testing.expectEqual(43, (try fixture.memory.?.get("test1")).int);
    try std.testing.expectEqual(16, connection.accumulator.items.len);

    // now we append rest of the partial request
    try connection.accumulator.appendSlice("\ntest8\r\n:44\r\n\x03");
    processor.deframe(&connection);

    try std.testing.expectEqual(44, (try fixture.memory.?.get("test8")).int);

    try std.testing.expectEqual(0, connection.accumulator.items.len);
}
