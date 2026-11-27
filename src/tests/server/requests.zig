const std = @import("std");
const fs = @import("fs");
const runtime_io = @import("runtime_io");

const Connection = @import("../../server/network/connection.zig");
const ZType = @import("../../protocol/types.zig").ZType;
const Auth = @import("../../server/auth.zig");

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

test "ASAVE returns immediately and serializes background saves" {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        allocator,
        "./tmp/asave-{d}",
        .{runtime_io.timestampNanoseconds()},
    );
    defer allocator.free(path);
    defer fs.cwd().deleteTree(path) catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    defer fixture.agent.deinit();
    try fixture.create_memory();
    try fixture.agent.kickoff();
    try fixture.memory.?.put("key", .{ .int = 7 });
    fixture.snapshot.?.path = path;
    var started: @import("sync").Event = .{};
    var gate: @import("sync").Event = .{};
    fixture.snapshot.?.test_started = &started;
    fixture.snapshot.?.test_gate = &gate;

    var handler = Processor.init(allocator, fixture.context()) catch unreachable;
    defer handler.deinit();
    var command = std.array_list.Managed(ZType).init(allocator);
    defer command.deinit();
    try command.append(.{ .str = "ASAVE" });
    var result = handler.cmd_handler.process(&command);
    try std.testing.expectEqualStrings("OK", result.ok.sstr);
    started.wait();
    try std.testing.expect(fixture.memory.?.isSaveInProgress());

    result = handler.cmd_handler.process(&command);
    try std.testing.expectEqual(error.SaveInProgress, result.err);
    const synchronous = fixture.memory.?.save();
    try std.testing.expectError(error.SaveInProgress, synchronous);

    gate.set();
    const limit = runtime_io.timestampNanoseconds() + 5 * std.time.ns_per_s;
    while (fixture.memory.?.isSaveInProgress() and runtime_io.timestampNanoseconds() < limit)
        try runtime_io.get().sleep(.fromMilliseconds(10), .awake);
    try std.testing.expect(!fixture.memory.?.isSaveInProgress());
    try std.testing.expect(fixture.memory.?.last_save.load(.monotonic) > 0);

    const filename = try std.fmt.allocPrint(
        allocator,
        "{s}/dump_{d}.zcpf",
        .{ path, fixture.memory.?.last_save.load(.monotonic) },
    );
    defer allocator.free(filename);
    const file = try fs.cwd().openFile(filename, .{});
    file.close();
}

test "AUTH authenticates pipelines and enforces command and key scopes" {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, "./tmp/auth-{d}.zon", .{runtime_io.timestampNanoseconds()});
    defer allocator.free(path);
    defer fs.cwd().deleteFile(path) catch {};
    try fs.cwd().makePath("./tmp");
    const file = try fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(
        \\.{
        \\    .principals = .{
        \\        .{
        \\            .id = "app",
        \\            .name = "app",
        \\            .token_sha256 = "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b",
        \\            .permissions = .{
        \\                .groups = .{ .basic, .diagnostic },
        \\                .read = .{ "app:" },
        \\                .write = .{ "app:" },
        \\                .delete = .{ "app:" },
        \\            },
        \\        },
        \\    },
        \\}
    );

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.auth.enabled = true;
    fixture.config.auth.max_attempts = 2;
    fixture.auth.deinit();
    if (fixture.config.auth.path) |auth_path| allocator.free(auth_path);
    fixture.config.auth.path = try allocator.dupe(u8, path);
    fixture.auth = try Auth.init(allocator, fixture.config.auth);
    try fixture.create_memory();
    const incoming = try fixtures.ConnectionFixture.init(allocator);
    var connection = incoming.connection;
    defer connection.deinit();
    var processor = try Processor.init(allocator, fixture.context());
    defer processor.deinit();

    processor.process(&connection, @constCast("*1\r\n$4\r\nPING\r\n"));
    try std.testing.expectEqualStrings("-NOAUTH\r\n\x03", connection.tx_accumulator.items);
    connection.tx_accumulator.clearRetainingCapacity();

    processor.process(&connection, @constCast("*2\r\n$4\r\nAUTH\r\n$5\r\nwrong\r\n"));
    try std.testing.expectEqualStrings("-INVALID_CREDENTIALS\r\n\x03", connection.tx_accumulator.items);
    connection.tx_accumulator.clearRetainingCapacity();
    processor.process(&connection, @constCast("*2\r\n$4\r\nAUTH\r\n$5\r\nwrong\r\n"));
    try std.testing.expectEqualStrings("-INVALID_CREDENTIALS\r\n\x03", connection.tx_accumulator.items);
    connection.tx_accumulator.clearRetainingCapacity();
    processor.process(&connection, @constCast("*2\r\n$4\r\nAUTH\r\n$6\r\nsecret\r\n"));
    try std.testing.expectEqualStrings("-AUTH_RATE_LIMITED\r\n\x03", connection.tx_accumulator.items);
    connection.tx_accumulator.clearRetainingCapacity();

    connection.auth = .{};
    try connection.accumulator.appendSlice(
        "*2\r\n$4\r\nAUTH\r\n$6\r\nsecret\r\n\x03" ++
            "*3\r\n$3\r\nSET\r\n$7\r\napp:key\r\n:7\r\n\x03" ++
            "*2\r\n$3\r\nGET\r\n$7\r\napp:key\r\n\x03" ++
            "*2\r\n$3\r\nGET\r\n$9\r\nother:key\r\n\x03",
    );
    processor.deframe(&connection);
    try std.testing.expectEqualStrings("+OK\r\n\x03+OK\r\n\x03:7\r\n\x03-NO_PERMISSION\r\n\x03", connection.tx_accumulator.items);
    try std.testing.expectEqual(@as(i64, 7), (try fixture.memory.?.get("app:key")).int);
}

test "AUTH preflights every key in a multi-key command" {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, "./tmp/auth-multi-{d}.zon", .{runtime_io.timestampNanoseconds()});
    defer allocator.free(path);
    defer fs.cwd().deleteFile(path) catch {};
    const file = try fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(
        \\.{
        \\    .principals = .{
        \\        .{
        \\            .id = "writer",
        \\            .name = "writer",
        \\            .token_sha256 = "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b",
        \\            .permissions = .{
        \\                .groups = .{ .basic },
        \\                .write = .{ "app:" },
        \\            },
        \\        },
        \\    },
        \\}
    );
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.auth.enabled = true;
    fixture.auth.deinit();
    if (fixture.config.auth.path) |auth_path| allocator.free(auth_path);
    fixture.config.auth.path = try allocator.dupe(u8, path);
    fixture.auth = try Auth.init(allocator, fixture.config.auth);
    try fixture.create_memory();
    const incoming = try fixtures.ConnectionFixture.init(allocator);
    var connection = incoming.connection;
    defer connection.deinit();
    try fixture.auth.authenticate(
        &connection.auth,
        "secret",
        fixture.config.auth,
    );
    var processor = try Processor.init(allocator, fixture.context());
    defer processor.deinit();

    processor.process(&connection, @constCast("*5\r\n$4\r\nMSET\r\n$5\r\napp:a\r\n:1\r\n$7\r\nother:b\r\n:2\r\n"));
    try std.testing.expectEqualStrings("-NO_PERMISSION\r\n\x03", connection.tx_accumulator.items);
    try std.testing.expectError(error.NotFound, fixture.memory.?.get("app:a"));
    try std.testing.expectError(error.NotFound, fixture.memory.?.get("other:b"));
}

test "auth files reject duplicate identities and permissive empty prefixes" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\.{
        \\    .principals = .{
        \\        .{ .id = "one", .name = "one", .token_sha256 = "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b", .permissions = .{} },
        \\        .{ .id = "one", .name = "one", .token_sha256 = "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b", .permissions = .{} },
        \\    },
        \\}
        ,
        \\.{
        \\    .principals = .{
        \\        .{
        \\            .id = "one",
        \\            .name = "one",
        \\            .token_sha256 = "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b",
        \\            .permissions = .{ .read = .{ "" } },
        \\        },
        \\    },
        \\}
        ,
    };
    for (cases, 0..) |contents, index| {
        const path = try std.fmt.allocPrint(allocator, "./tmp/auth-invalid-{d}-{d}.zon", .{ runtime_io.timestampNanoseconds(), index });
        defer allocator.free(path);
        defer fs.cwd().deleteFile(path) catch {};
        const file = try fs.cwd().createFile(path, .{});
        try file.writeAll(contents);
        file.close();
        const config: @import("../../server/config.zig").AuthConfig = .{ .enabled = true, .path = path };
        try std.testing.expectError(error.InvalidPrincipal, Auth.init(allocator, config));
    }
}

test "AUTH RELOAD atomically revokes sessions and survives reinitialization" {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, "./tmp/auth-reload-{d}.zon", .{runtime_io.timestampNanoseconds()});
    defer allocator.free(path);
    defer fs.cwd().deleteFile(path) catch {};
    const original =
        \\.{
        \\    .principals = .{
        \\        .{
        \\            .id = "admin",
        \\            .name = "admin",
        \\            .token_sha256 = "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b",
        \\            .permissions = .{ .groups = .{ .all }, .admin = true, .read = .{ "*" }, .write = .{ "*" }, .delete = .{ "*" } },
        \\        },
        \\    },
        \\}
    ;
    var file = try fs.cwd().createFile(path, .{});
    try file.writeAll(original);
    file.close();

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.auth.enabled = true;
    fixture.auth.deinit();
    if (fixture.config.auth.path) |auth_path| allocator.free(auth_path);
    fixture.config.auth.path = try allocator.dupe(u8, path);
    fixture.auth = try Auth.init(allocator, fixture.config.auth);
    try fixture.create_memory();
    const incoming = try fixtures.ConnectionFixture.init(allocator);
    var connection = incoming.connection;
    defer connection.deinit();
    var processor = try Processor.init(allocator, fixture.context());
    defer processor.deinit();

    processor.process(&connection, @constCast("*2\r\n$4\r\nAUTH\r\n$6\r\nsecret\r\n"));
    try std.testing.expectEqualStrings("+OK\r\n\x03", connection.tx_accumulator.items);
    connection.tx_accumulator.clearRetainingCapacity();

    file = try fs.cwd().createFile(path, .{});
    try file.writeAll("not valid zon");
    file.close();
    processor.process(&connection, @constCast("*2\r\n$4\r\nAUTH\r\n$6\r\nRELOAD\r\n"));
    try std.testing.expectEqualStrings("-AUTH_RELOAD_FAILED\r\n\x03", connection.tx_accumulator.items);
    connection.tx_accumulator.clearRetainingCapacity();
    try fixture.auth.authorize(&connection.auth, &.{.{ .str = "PING" }});

    const rotated = try allocator.alloc(u8, original.len);
    defer allocator.free(rotated);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.replace(
            u8,
            original,
            "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b",
            "8810ad581e59f2bc3928b261707a71308f7e139eb04820366dc4d5c18d980225",
            rotated,
        ),
    );
    file = try fs.cwd().createFile(path, .{});
    try file.writeAll(rotated);
    file.close();
    processor.process(&connection, @constCast("*2\r\n$4\r\nAUTH\r\n$6\r\nRELOAD\r\n"));
    try std.testing.expectEqualStrings("+OK\r\n\x03", connection.tx_accumulator.items);
    connection.tx_accumulator.clearRetainingCapacity();
    try std.testing.expectError(error.NoAuth, fixture.auth.authorize(&connection.auth, &.{.{ .str = "PING" }}));

    var restarted = try Auth.init(allocator, fixture.config.auth);
    defer restarted.deinit();
    var restarted_session: Auth.Session = .{};
    try std.testing.expectError(
        error.InvalidCredentials,
        restarted.authenticate(&restarted_session, "secret", fixture.config.auth),
    );
    try restarted.authenticate(&restarted_session, "wrong", fixture.config.auth);
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
