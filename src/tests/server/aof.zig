const std = @import("std");
const AOF = @import("../../server/storage/aof.zig");
const Context = @import("../../server/processing/employer.zig").Context;
const Commands = @import("../../server/processing/commands.zig");
const ContextFixture = @import("../fixtures.zig").ContextFixture;
const ZType = @import("../../protocol/types.zig").ZType;

fn appendAOFCommand(ptr: *anyopaque, command: []const ZType) anyerror!void {
    const aof: *AOF = @ptrCast(@alignCast(ptr));
    try aof.appendCommand(command);
}

fn uniquePath(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "tmp/aof-test-{d}.aof",
        .{std.time.nanoTimestamp()},
    );
}

fn configureAOF(
    fixture: *ContextFixture,
    path: []const u8,
    strategy: AOF.Strategy,
) !void {
    if (fixture.config.aof.path) |configured_path| {
        fixture.allocator.free(configured_path);
    }
    fixture.config.aof.path = try fixture.allocator.dupe(u8, path);
    fixture.config.aof.flush_strategy = strategy;
}

fn fileSize(path: []const u8) !u64 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return (try file.stat()).size;
}

fn processCommand(
    handler: *Commands.Handler,
    allocator: std.mem.Allocator,
    items: []const ZType,
) !void {
    var command = std.array_list.Managed(ZType).init(allocator);
    defer command.deinit();
    try command.appendSlice(items);
    const result = handler.process(&command);
    try std.testing.expect(result == .ok);
}

test "AOF stores successful mutations and replays them from configured path" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};
    try configureAOF(&fixture, path, .everysec);

    var context: Context = fixture.context();
    var aof = try AOF.init(fixture.allocator, context);
    defer aof.deinit();

    context.resources.aof = .{
        .ptr = &aof,
        .append_command = appendAOFCommand,
    };

    var handler = Commands.Handler.init(fixture.allocator, context);
    try processCommand(&handler, fixture.allocator, &.{
        .{ .str = "SET" },
        .{ .str = "original" },
        .{ .str = "original-value" },
    });
    try processCommand(&handler, fixture.allocator, &.{
        .{ .str = "MSET" },
        .{ .str = "alpha" },
        .{ .str = "first" },
        .{ .str = "beta" },
        .{ .str = "second" },
    });
    try processCommand(&handler, fixture.allocator, &.{
        .{ .str = "RENAME" },
        .{ .str = "original" },
        .{ .str = "renamed" },
    });
    try processCommand(&handler, fixture.allocator, &.{
        .{ .str = "COPY" },
        .{ .str = "alpha" },
        .{ .str = "copied" },
    });
    try processCommand(&handler, fixture.allocator, &.{
        .{ .str = "DELETE" },
        .{ .str = "beta" },
    });

    fixture.memory.?.flush();
    try aof.flush();
    try aof.replay();

    try std.testing.expectEqualStrings("original-value", (try fixture.memory.?.get("renamed")).str);
    try std.testing.expectEqualStrings("first", (try fixture.memory.?.get("alpha")).str);
    try std.testing.expectEqualStrings("first", (try fixture.memory.?.get("copied")).str);
    try std.testing.expectError(error.NotFound, fixture.memory.?.get("original"));
    try std.testing.expectError(error.NotFound, fixture.memory.?.get("beta"));

    try processCommand(&handler, fixture.allocator, &.{.{ .str = "FLUSH" }});
    fixture.memory.?.flush();
    try aof.flush();
    try aof.replay();
    try std.testing.expectEqual(@as(usize, 0), fixture.memory.?.internal.count());
}

test "always strategy flushes each append immediately" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};
    try configureAOF(&fixture, path, .always);

    var aof = try AOF.init(fixture.allocator, fixture.context());
    defer aof.deinit();

    try aof.append("x");
    try std.testing.expectEqual(@as(u64, 2), try fileSize(path));
    try std.testing.expectEqual(@as(usize, 0), aof.buffer.items.len);
}

test "auto strategy flushes when the buffer threshold is reached" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};
    try configureAOF(&fixture, path, .auto);

    var aof = try AOF.init(fixture.allocator, fixture.context());
    defer aof.deinit();

    const below_threshold = try fixture.allocator.alloc(u8, 4094);
    defer fixture.allocator.free(below_threshold);
    @memset(below_threshold, 'x');
    try aof.append(below_threshold);
    try std.testing.expectEqual(@as(u64, 0), try fileSize(path));
    try std.testing.expectEqual(@as(usize, 4095), aof.buffer.items.len);

    try aof.append("x");
    try std.testing.expectEqual(@as(u64, 4097), try fileSize(path));
    try std.testing.expectEqual(@as(usize, 0), aof.buffer.items.len);
}

test "everysec strategy flushes from the background loop" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};
    try configureAOF(&fixture, path, .everysec);

    var aof = try AOF.init(fixture.allocator, fixture.context());
    defer aof.deinit();

    try aof.append("x");
    try std.testing.expectEqual(@as(u64, 0), try fileSize(path));
    try aof.start();

    var attempts: usize = 0;
    while (attempts < 150 and try fileSize(path) == 0) : (attempts += 1) {
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(u64, 2), try fileSize(path));
    try std.testing.expectEqual(@as(usize, 0), aof.buffer.items.len);
}

test "no strategy neither appends nor replays commands" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};
    try configureAOF(&fixture, path, .no);

    const existing_command = "*3\r\n$3\r\nSET\r\n$7\r\nignored\r\n$5\r\nvalue\r\n\x03";
    {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(existing_command);
    }

    var aof = try AOF.init(fixture.allocator, fixture.context());
    defer aof.deinit();

    try aof.append("ignored");
    try aof.replay();
    try std.testing.expectEqual(@as(u64, existing_command.len), try fileSize(path));
    try std.testing.expectEqual(@as(usize, 0), aof.buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.memory.?.internal.count());
}
