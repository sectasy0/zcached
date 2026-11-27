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

    var processor: Processor = try .init(std.testing.allocator, context);
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
    try std.testing.expectEqual(request1.len, connection.receive_start);
    try std.testing.expectEqualStrings(request1, connection.accumulator.items[0..connection.receive_start]);
    try std.testing.expectEqualStrings(partial_request, connection.accumulator.items[connection.receive_start..]);

    // now we append rest of the partial request
    try connection.accumulator.appendSlice("\ntest8\r\n:44\r\n\x03");
    processor.deframe(&connection);

    try std.testing.expectEqual(44, (try fixture.memory.?.get("test8")).int);

    try std.testing.expectEqual(0, connection.accumulator.items.len);
    try std.testing.expectEqual(@as(usize, 0), connection.receive_start);
}

test "deframe defers pipelined commands until pending replies have drained" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.config.network.max_pending_response_bytes = 1;
    const incoming = try fixtures.ConnectionFixture.init(std.testing.allocator);
    var connection = incoming.connection;
    defer connection.deinit();
    var processor = try Processor.init(std.testing.allocator, fixture.context());
    defer processor.deinit();

    const first = "*1\r\n$4\r\nPING\r\n\x03";
    const second = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n:2\r\n\x03";
    try connection.accumulator.appendSlice(first ++ second);
    processor.deframe(&connection);
    try std.testing.expectEqualStrings("+PONG\r\n\x03", connection.tx_accumulator.items);
    try std.testing.expectEqual(first.len, connection.receive_start);
    try std.testing.expectError(error.NotFound, fixture.memory.?.get("key"));

    connection.tx_accumulator.clearRetainingCapacity();
    processor.deframe(&connection);
    try std.testing.expectEqual(@as(i64, 2), (try fixture.memory.?.get("key")).int);
    try std.testing.expectEqual(@as(usize, 0), connection.accumulator.items.len);
}

test "deframe batches pipelines by command count" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.config.network.max_pipeline_commands = 1;
    const incoming = try fixtures.ConnectionFixture.init(std.testing.allocator);
    var connection = incoming.connection;
    defer connection.deinit();
    var processor = try Processor.init(std.testing.allocator, fixture.context());
    defer processor.deinit();

    const first = "*1\r\n$4\r\nPING\r\n\x03";
    const second = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n:2\r\n\x03";
    try connection.accumulator.appendSlice(first ++ second);

    processor.deframe(&connection);
    try std.testing.expectEqualStrings("+PONG\r\n\x03", connection.tx_accumulator.items);
    try std.testing.expectEqual(first.len, connection.receive_start);
    try std.testing.expectError(error.NotFound, fixture.memory.?.get("key"));

    connection.tx_accumulator.clearRetainingCapacity();
    processor.deframe(&connection);
    try std.testing.expectEqual(@as(i64, 2), (try fixture.memory.?.get("key")).int);
    try std.testing.expectEqual(@as(usize, 0), connection.accumulator.items.len);
}

test "response size limit rejects a large reply before serialization" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.config.network.max_response_bytes = 8;
    try fixture.memory.?.put("key", .{ .str = "too-large" });
    const incoming = try fixtures.ConnectionFixture.init(std.testing.allocator);
    var connection = incoming.connection;
    defer connection.deinit();
    var processor = try Processor.init(std.testing.allocator, fixture.context());
    defer processor.deinit();

    processor.process(&connection, @constCast("*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n"));
    try std.testing.expectEqualStrings("-RESPONSE_TOO_LARGE\r\n\x03", connection.tx_accumulator.items);
}

test "malformed collection count is rejected before a large allocation" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    const incoming = try fixtures.ConnectionFixture.init(std.testing.allocator);
    var connection = incoming.connection;
    defer connection.deinit();
    var processor = try Processor.init(std.testing.allocator, fixture.context());
    defer processor.deinit();

    processor.process(&connection, @constCast("*18446744073709551615\r\n"));
    try std.testing.expectEqualStrings("-INVALID_LENGTH\r\n\x03", connection.tx_accumulator.items);
}

test "a malformed frame does not prevent the next pipelined command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.config.network.max_pipeline_commands = 0;
    fixture.config.network.max_pending_response_bytes = 0;
    const incoming = try fixtures.ConnectionFixture.init(std.testing.allocator);
    var connection = incoming.connection;
    defer connection.deinit();
    var processor = try Processor.init(std.testing.allocator, fixture.context());
    defer processor.deinit();

    const malformed = "*18446744073709551615\r\n\x03";
    const valid = "*1\r\n$4\r\nPING\r\n\x03";
    try connection.accumulator.appendSlice(malformed ++ valid);
    processor.deframe(&connection);

    try std.testing.expectEqualStrings("-INVALID_LENGTH\r\n\x03+PONG\r\n\x03", connection.tx_accumulator.items);
    try std.testing.expectEqual(@as(usize, 0), connection.accumulator.items.len);
}

test "memory limit returns a stable protocol error without changing data" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    const incoming = try fixtures.ConnectionFixture.init(std.testing.allocator);
    var connection = incoming.connection;
    defer connection.deinit();
    var processor = try Processor.init(std.testing.allocator, fixture.context());
    defer processor.deinit();

    try fixture.memory.?.put("existing", .{ .int = 1 });
    fixture.memory.?.fabric.limit = fixture.memory.?.fabric.memoryUsed();
    processor.process(&connection, @constCast("*3\r\n$3\r\nSET\r\n$7\r\nblocked\r\n:2\r\n"));

    try std.testing.expectEqualStrings("-MEMORY_LIMIT_EXCEEDED\r\n\x03", connection.tx_accumulator.items);
    try std.testing.expectEqual(@as(usize, 1), fixture.metrics.commands_total.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), fixture.metrics.command_errors_total.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), fixture.metrics.memory_limit_rejections_total.load(.monotonic));
    try std.testing.expectEqual(@as(i64, 1), (try fixture.memory.?.get("existing")).int);
    try std.testing.expectError(error.NotFound, fixture.memory.?.get("blocked"));
}

test "processing repeated commands bounds protocol arena memory" {
    var fixture = try ContextFixture.init();
    try fixture.create_memory();
    defer fixture.deinit();
    const incoming = try fixtures.ConnectionFixture.init(std.testing.allocator);
    var connection = incoming.connection;
    defer connection.deinit();
    var processor = try Processor.init(std.testing.allocator, fixture.context());
    defer processor.deinit();
    for (0..2000) |_| {
        processor.process(&connection, @constCast("*1\r\n$4\r\nPING\r\n"));
        try std.testing.expectEqualStrings("+PONG\r\n\x03", connection.tx_accumulator.items);
        connection.tx_accumulator.clearRetainingCapacity();
    }
    try std.testing.expect(processor.protocol.serializer.arena.queryCapacity() <= 4096);
    try std.testing.expect(processor.protocol.deserializer.arena.queryCapacity() <= 4096);
}

test "GET serializes stored values directly into the connection output" {
    var fixture: ContextFixture = try .init();
    try fixture.create_memory();
    defer fixture.deinit();
    try fixture.memory.?.put("key", .{ .str = "value" });

    const conn_fixture: fixtures.ConnectionFixture = try .init(std.testing.allocator);
    var connection = conn_fixture.connection;
    defer connection.deinit();
    var processor: Processor = try .init(std.testing.allocator, fixture.context());
    defer processor.deinit();

    processor.process(&connection, @constCast("*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n"));

    try std.testing.expectEqualStrings("$5\r\nvalue\r\n\x03", connection.tx_accumulator.items);

    connection.tx_accumulator.clearRetainingCapacity();
    try fixture.memory.?.putExpiring("key", .{ .str = "value" }, 1);
    processor.process(&connection, @constCast("*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n"));
    try std.testing.expectEqualStrings("-NOT_FOUND\r\n\x03", connection.tx_accumulator.items);
}
