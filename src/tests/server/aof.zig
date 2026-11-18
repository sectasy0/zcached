const std = @import("std");
const fs = @import("fs");
const runtime_io = @import("runtime_io");
const AOF = @import("../../server/storage/aof.zig");
const Context = @import("../../server/context.zig");
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
        .{runtime_io.timestampNanoseconds()},
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
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();
    return (try file.stat()).size;
}

fn bufferedBytes(aof: *AOF) usize {
    aof.mutex.lock();
    defer aof.mutex.unlock();
    return aof.buffer.items.len;
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

test "AOF rewrite snapshots every shard and replays into a different shard count" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.memory.shard_count = 3;
    try fixture.create_memory();
    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer fs.cwd().deleteFile(path) catch {};
    const rewrite_path = try std.fmt.allocPrint(fixture.allocator, "{s}.rewrite", .{path});
    defer fixture.allocator.free(rewrite_path);
    defer fs.cwd().deleteFile(rewrite_path) catch {};
    try configureAOF(&fixture, path, .everysec);
    var aof = try AOF.init(fixture.allocator, fixture.context());
    defer aof.deinit();
    for (0..128) |index| {
        var buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "rewrite-key-{d}", .{index});
        try fixture.memory.?.put(key, .{ .int = @intCast(index) });
    }
    for (fixture.memory.?.fabric.shards) |*shard| try std.testing.expect(shard.map.count() > 0);
    aof.rewrite();
    try std.testing.expect(aof.last_rewrite_size.load(.seq_cst) > 0);
    try std.testing.expectEqual(aof.last_rewrite_size.load(.seq_cst), try fileSize(path));
    fixture.config.memory.shard_count = 5;
    try fixture.create_memory();
    try aof.replay();
    try std.testing.expectEqual(@as(i64, 128), fixture.memory.?.size());
    for (0..128) |index| {
        var buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "rewrite-key-{d}", .{index});
        try std.testing.expectEqual(@as(i64, @intCast(index)), (try fixture.memory.?.get(key)).int);
    }
}

// Verifies successful mutations are journaled and replay restores the final key state.
test "AOF stores successful mutations and replays them from configured path" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer fs.cwd().deleteFile(path) catch {};
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
    try std.testing.expectEqual(@as(i64, 0), fixture.memory.?.size());
}

// Checks the always policy writes each append to disk immediately.
test "always strategy flushes each append immediately" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer fs.cwd().deleteFile(path) catch {};
    try configureAOF(&fixture, path, .always);

    var aof = try AOF.init(fixture.allocator, fixture.context());
    defer aof.deinit();

    try aof.append("x");
    try std.testing.expectEqual(@as(u64, 2), try fileSize(path));
    try std.testing.expectEqual(@as(usize, 0), aof.buffer.items.len);
}

// Ensures large pending records are preserved until flush and buffer capacity is then bounded.
test "everysec preserves pending bytes beyond the retained buffer threshold" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer fs.cwd().deleteFile(path) catch |err| std.log.err("Failed to remove AOF test file: {any}", .{err});
    try configureAOF(&fixture, path, .everysec);
    var aof = try AOF.init(fixture.allocator, fixture.context());
    defer aof.deinit();

    const payload = try fixture.allocator.alloc(u8, AOF.BUFFER_MAX_SIZE * 2);
    defer fixture.allocator.free(payload);
    @memset(payload, 'x');
    try aof.append("first");
    try aof.append(payload);
    try aof.append("last");
    const expected_size = "first\x03".len + payload.len + 1 + "last\x03".len;
    try std.testing.expectEqual(expected_size, aof.buffer.items.len);
    try std.testing.expectEqual(@as(u64, 0), try fileSize(path));
    try aof.flush();
    try std.testing.expectEqual(expected_size, try fileSize(path));
    try std.testing.expectEqual(@as(usize, 0), aof.buffer.items.len);
    try std.testing.expect(aof.buffer.capacity <= AOF.BUFFER_MAX_SIZE);
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try fixture.allocator.alloc(u8, expected_size);
    defer fixture.allocator.free(bytes);
    try std.testing.expectEqual(expected_size, try file.readAll(bytes));
    try std.testing.expectEqualStrings("first\x03", bytes[0..6]);
    try std.testing.expectEqualSlices(u8, payload, bytes[6 .. 6 + payload.len]);
    try std.testing.expectEqualStrings("\x03last\x03", bytes[6 + payload.len ..]);
}

// Checks automatic flushing occurs only when the configured buffer threshold is reached.
test "auto strategy flushes when the buffer threshold is reached" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer fs.cwd().deleteFile(path) catch {};
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

// Blocks the database worker so the test can prove every-second flushing uses that queue.
test "everysec flush waits for the database queue instead of a dedicated thread" {
    const io = runtime_io.get();
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    defer fixture.agent.deinit();

    var entered: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    defer release.set(io);
    // Synchronizes the worker start with the test and holds it until explicitly released.
    const Blocker = struct {
        // Signals entry, then waits without cancellation for the release event.
        fn run(started: *std.Io.Event, finish: *std.Io.Event) void {
            started.set(runtime_io.get());
            finish.waitUncancelable(runtime_io.get());
        }
    };
    try fixture.agent.schedule(Blocker.run, .{ &entered, &release }, .{});
    try fixture.agent.kickoff();
    try entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } });

    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer fs.cwd().deleteFile(path) catch {};
    try configureAOF(&fixture, path, .everysec);

    var aof = try AOF.init(fixture.allocator, fixture.context());
    defer aof.deinit();

    try aof.append("x");
    try std.testing.expectEqual(@as(u64, 0), try fileSize(path));
    try aof.start();
    try aof.start();

    runtime_io.sleepNanoseconds(1200 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 0), try fileSize(path));
    release.set(io);

    var attempts: usize = 0;
    while (attempts < 150 and (try fileSize(path) == 0 or bufferedBytes(&aof) != 0)) : (attempts += 1) {
        runtime_io.sleepNanoseconds(20 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(u64, 2), try fileSize(path));
    try std.testing.expectEqual(@as(usize, 0), bufferedBytes(&aof));
}

// Ensures deinitialization cancels scheduled flushes before the handler's memory is freed.
test "AOF deinit cancels pending flush before the AOF object is freed" {
    const io = runtime_io.get();
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    defer fixture.agent.deinit();
    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer fs.cwd().deleteFile(path) catch {};
    try configureAOF(&fixture, path, .everysec);

    const aof = try fixture.allocator.create(AOF);
    aof.* = AOF.init(fixture.allocator, fixture.context()) catch |err| {
        fixture.allocator.destroy(aof);
        return err;
    };
    {
        defer {
            aof.deinit();
            fixture.allocator.destroy(aof);
        }
        try aof.append("x");
        try aof.start();
    }
    try std.testing.expectEqual(@as(u64, 2), try fileSize(path));

    try fixture.agent.kickoff();
    runtime_io.sleepNanoseconds(1200 * std.time.ns_per_ms);
    var completed: std.Io.Event = .unset;
    // Marks that work scheduled after the cancelled flush has completed.
    const Marker = struct {
        // Signals completion to the waiting test thread.
        fn run(event: *std.Io.Event) void {
            event.set(runtime_io.get());
        }
    };
    try fixture.agent.schedule(Marker.run, .{&completed}, .{});
    try completed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try std.testing.expectEqual(@as(u64, 2), try fileSize(path));
}

// Checks the disabled policy leaves the journal and memory unchanged.
test "no strategy neither appends nor replays commands" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const path = try uniquePath(fixture.allocator);
    defer fixture.allocator.free(path);
    defer fs.cwd().deleteFile(path) catch {};
    try configureAOF(&fixture, path, .no);

    const existing_command = "*3\r\n$3\r\nSET\r\n$7\r\nignored\r\n$5\r\nvalue\r\n\x03";
    {
        const file = try fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(existing_command);
    }

    var aof = try AOF.init(fixture.allocator, fixture.context());
    defer aof.deinit();

    try aof.append("ignored");
    try aof.replay();
    try std.testing.expectEqual(@as(u64, existing_command.len), try fileSize(path));
    try std.testing.expectEqual(@as(usize, 0), aof.buffer.items.len);
    try std.testing.expectEqual(@as(i64, 0), fixture.memory.?.size());
}
