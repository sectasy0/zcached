const std = @import("std");
const runtime_io = @import("runtime_io");
const Address = @import("../../server/network/address.zig").Address;
const Server = @import("../../server/network/server.zig");
const ContextFixture = @import("../fixtures.zig").ContextFixture;

const ping = "*1\r\n$4\r\nPING\r\n\x03";
const pong = "+PONG\r\n\x03";

test "Runtime worker passes native IO and joins after its futures finish" {
    const State = struct {
        failure: ?anyerror = null,
        completed: bool = false,

        fn run(io: std.Io, self: *@This()) void {
            var future = io.concurrent(std.Io.sleep, .{ io, .fromMilliseconds(1), .awake }) catch |err| {
                self.failure = err;
                return;
            };
            future.await(io) catch |err| {
                self.failure = err;
                return;
            };
            self.completed = true;
        }
    };
    var state: State = .{};
    var worker: runtime_io.Worker = .{};
    try worker.start(std.testing.io, std.testing.allocator, State.run, .{&state});
    worker.join();
    try std.testing.expect(state.failure == null);
    try std.testing.expect(state.completed);
}

fn expectResponse(client: std.Io.net.Stream, expected: []const u8) !void {
    var reader = client.reader(runtime_io.get(), &.{});
    var buffer: [64]u8 = undefined;
    try reader.interface.readSliceAll(buffer[0..expected.len]);
    try std.testing.expectEqualStrings(expected, buffer[0..expected.len]);
}

fn expectResponseTimeout(client: std.Io.net.Stream, expected: []const u8, milliseconds: i64) !void {
    const io = runtime_io.get();
    const Result = union(enum) {
        response: anyerror!void,
        timeout: std.Io.Cancelable!void,
    };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.response, expectResponse, .{ client, expected });
    try select.concurrent(.timeout, std.Io.sleep, .{ io, .fromMilliseconds(milliseconds), .awake });
    switch (try select.await()) {
        .response => |result| try result,
        .timeout => |result| {
            try result;
            return error.ResponseTimedOut;
        },
    }
}

test "Server handles fragmented and pipelined requests alongside an idle client" {
    const io = runtime_io.get();
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    defer fixture.agent.deinit();
    try fixture.create_memory();
    fixture.logger.agent = &fixture.agent;
    fixture.config.max_clients = 2;
    fixture.config.network.max_pending_response_bytes = pong.len;
    var running: std.atomic.Value(bool) = .init(true);
    var context = fixture.context();
    context.running = &running;
    var server = try Server.init(fixture.allocator, io, context);
    defer server.deinit();
    try server.transport.listen(Address.initIp4(.{ 127, 0, 0, 1 }, 0));
    var task = try io.concurrent(Server.acceptConnections, .{ &server, io });
    defer task.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
    };

    const idle = try server.transport.listen_address.ip.connect(io, .{ .mode = .stream });
    defer idle.close(io);
    const client = try server.transport.listen_address.ip.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var writer = client.writer(io, &.{});
    try writer.interface.writeAll(ping[0..8]);
    try writer.interface.writeAll(ping[8..] ++ ping);
    try expectResponseTimeout(client, pong ++ pong, 3000);
    try std.testing.expectEqual(@as(usize, 2), fixture.metrics.connections_accepted.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), fixture.metrics.commands_total.load(.monotonic));
    try std.testing.expectEqual(@as(usize, ping.len * 2), fixture.metrics.request_bytes_total.load(.monotonic));
    try std.testing.expectEqual(@as(usize, pong.len * 2), fixture.metrics.response_bytes_total.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), fixture.metrics.response_batches_total.load(.monotonic));

    // Leave both reads blocked while canceling to verify shutdown releases sockets and buffers.
    task.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
    };
}

test "Server expires idle clients and enforces a deadline across request fragments" {
    const Check = struct {
        result: anyerror!void = undefined,

        fn run(io: std.Io, state: *@This()) void {
            state.result = check(io);
        }

        fn check(io: std.Io) !void {
            var fixture = try ContextFixture.init();
            defer fixture.deinit();
            defer fixture.agent.deinit();
            try fixture.create_memory();
            fixture.config.log_network_payloads = false;
            fixture.config.network.idle_timeout_ms = 250;
            fixture.config.network.request_timeout_ms = 90;
            var server = try Server.init(fixture.allocator, io, fixture.context());
            defer server.deinit();
            try server.transport.listen(Address.initIp4(.{ 127, 0, 0, 1 }, 0));
            var task = try io.concurrent(Server.acceptConnections, .{ &server, io });
            defer task.cancel(io) catch {};

            const addr = server.transport.listen_address.ip;
            const idle = try addr.connect(io, .{ .mode = .stream });
            defer idle.close(io);
            const slow = try addr.connect(io, .{ .mode = .stream });
            defer slow.close(io);
            var writer = slow.writer(io, &.{});
            try writer.interface.writeAll(ping);
            try expectResponseTimeout(slow, pong, 2000);
            try writer.interface.writeAll(ping[0..1]);
            try io.sleep(.fromMilliseconds(55), .awake);
            try writer.interface.writeAll(ping[1..2]);
            // This read expires after the original request deadline, but before
            // a new 90 ms timer started on the second fragment would expire.
            try expectClosed(io, slow, 70);
            try expectClosed(io, idle, 2000);
        }
    };
    var check: Check = .{};
    var worker: runtime_io.Worker = .{};
    try worker.start(std.testing.io, std.testing.allocator, Check.run, .{&check});
    worker.join();
    try check.result;
}

test "Server closes a connection that does not authenticate before its deadline" {
    const io = runtime_io.get();
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    defer fixture.agent.deinit();
    try fixture.create_memory();
    fixture.config.auth.enabled = true;
    fixture.config.auth.timeout_ms = 80;
    fixture.config.network.idle_timeout_ms = 0;
    var server = try Server.init(fixture.allocator, io, fixture.context());
    defer server.deinit();
    try server.transport.listen(Address.initIp4(.{ 127, 0, 0, 1 }, 0));
    var task = try io.concurrent(Server.acceptConnections, .{ &server, io });
    defer task.cancel(io) catch {};

    const client = try server.transport.listen_address.ip.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try expectResponseTimeout(client, "-AUTH_TIMEOUT\r\n\x03", 1000);
    try expectClosed(io, client, 1000);
}

fn expectClosed(io: std.Io, stream: std.Io.net.Stream, ms: i64) !void {
    var byte: [1]u8 = undefined;
    var buffers = [_][]u8{&byte};
    const result = try io.operateTimeout(.{ .net_read = .{
        .socket_handle = stream.socket.handle,
        .data = &buffers,
    } }, .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } });
    try std.testing.expectEqual(@as(usize, 0), (try result.net_read).data_len);
}

test "Server resumes accepting after its client limit is released" {
    const io = runtime_io.get();
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    defer fixture.agent.deinit();
    try fixture.create_memory();
    fixture.logger.agent = &fixture.agent;
    fixture.config.max_clients = 1;
    var running: std.atomic.Value(bool) = .init(true);
    var context = fixture.context();
    context.running = &running;
    var server = try Server.init(fixture.allocator, io, context);
    defer server.deinit();
    try server.transport.listen(Address.initIp4(.{ 127, 0, 0, 1 }, 0));
    var task = try io.concurrent(Server.acceptConnections, .{ &server, io });
    defer task.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
    };

    const first = try server.transport.listen_address.ip.connect(io, .{ .mode = .stream });
    var first_open = true;
    defer if (first_open) first.close(io);
    var first_writer = first.writer(io, &.{});
    try first_writer.interface.writeAll(ping);
    try expectResponseTimeout(first, pong, 3000);

    const second = try server.transport.listen_address.ip.connect(io, .{ .mode = .stream });
    defer second.close(io);
    var second_writer = second.writer(io, &.{});
    try second_writer.interface.writeAll(ping);
    try std.testing.expectError(error.ResponseTimedOut, expectResponseTimeout(second, pong, 100));
    first.close(io);
    first_open = false;
    try expectResponseTimeout(second, pong, 3000);
}
