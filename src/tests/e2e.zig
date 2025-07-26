const std = @import("std");
const fixtures = @import("fixtures.zig");

const Employer = @import("../server/processing/employer.zig");

test "should work" {
    // var context_fixture = try fixtures.ContextFixture.init();
    // try context_fixture.create_memory();
    // defer context_fixture.deinit();

    // const context = Employer.Context{
    //     .config = &context_fixture.config,
    //     .logger = &context_fixture.logger,
    //     .memory = &context_fixture.memory.?,
    // };

    // context.logger.sout = true;

    // var employer = try Employer.init(std.testing.allocator, context);
    // const server_fn: fn (self: *Employer) void = Employer.supervise;
    // var server_thread = try std.Thread.spawn(.{}, server_fn, .{&employer});

    // var socket = try std.net.tcpConnectToAddress(context.config.address);

    // _ = try socket.writeAll(@constCast("*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n\x03"));
    // try printResponse(&socket, "SET Response");

    // socket.close();

    // std.time.sleep(100000);

    // std.debug.print("Stopping employer...\n", .{});

    // employer.running.store(false, .release);
    // server_thread.join();
    // employer.deinit();
}

fn printResponse(socket: *std.net.Stream, label: []const u8) !void {
    const response = try socket.reader().readUntilDelimiterAlloc(std.heap.page_allocator, '\n', 1024);
    defer std.heap.page_allocator.free(response);
    std.debug.print("{s}: {s}\n", .{ label, response });
}
