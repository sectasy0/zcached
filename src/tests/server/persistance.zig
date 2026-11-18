const std = @import("std");
const fs = @import("fs");
const runtime_io = @import("runtime_io");

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;
const Handler = @import("../../server/storage/persistance.zig");

test "snapshots restore live deadlines and skip expired records" {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, "./tmp/persist-ttl-{d}", .{runtime_io.timestampNanoseconds()});
    defer allocator.free(path);
    try fs.cwd().makePath(path);
    defer fs.cwd().deleteTree(path) catch {};
    const dir = try fs.cwd().openDir(path, .{});
    defer dir.close();
    {
        const file = try dir.createFile("dump_1.zcpf", .{});
        defer file.close();
        try file.writeAll("zcpf2%1\r\n$4\r\npast\r\n:1\r\n:1\r\n");
    }

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = path;
    const memory = &fixture.memory.?;
    try fixture.persistance.?.load(memory);
    try std.testing.expectEqual(@as(i64, 0), memory.size());

    const deadline = @import("../../server/storage/memory.zig").unixMillis() + 60_000;
    try memory.putExpiring("live", .{ .int = 42 }, deadline);
    try memory.putExpiring("past", .{ .int = 1 }, 1);
    try memory.put("permanent", .{ .int = 2 });
    _ = try memory.save();
    memory.flush();
    try fixture.persistance.?.load(memory);
    try std.testing.expectEqual(@as(i64, 2), memory.size());
    try std.testing.expectEqual(@as(i64, -1), memory.ttl("permanent"));
    var iter = memory.iterator();
    defer iter.deinit();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "live")) continue;
        try std.testing.expectEqual(deadline, entry.expired_at);
        try std.testing.expectEqual(@as(i64, 42), entry.value_ptr.int);
        return;
    }
    return error.MissingKey;
}

test "scheduled snapshots use configured directory and prune only older snapshots" {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, "./tmp/persist-scheduled-{d}", .{runtime_io.timestampNanoseconds()});
    defer allocator.free(path);
    try fs.cwd().makePath(path);
    defer fs.cwd().deleteTree(path) catch {};
    const dir = try fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    for ([_][]const u8{ "dump_1.zcpf", "dump_2.zcpf", "unrelated.zcpf" }) |name| {
        const file = try dir.createFile(name, .{});
        defer file.close();
        try file.writeAll("zcpf%0\r\n");
    }

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    defer fixture.agent.deinit();
    try fixture.create_memory();
    var config = fixture.config;
    config.snapshot = .{ .path = path, .interval_secs = 1, .keep_last = 2 };
    var persister = try Handler.init(allocator, config, &fixture.logger, null);
    defer persister.deinit();
    const memory = &fixture.memory.?;
    memory.last_save.store(0, .monotonic);
    try memory.put("scheduled", .{ .int = 12 });
    try fixture.agent.kickoff();
    try persister.start(&fixture.agent, memory);
    const io = runtime_io.get();
    const limit = runtime_io.timestampNanoseconds() + 5 * std.time.ns_per_s;
    while (memory.last_save.load(.monotonic) == 0 and runtime_io.timestampNanoseconds() < limit)
        try io.sleep(.fromMilliseconds(10), .awake);
    persister.stop();
    try std.testing.expect(memory.last_save.load(.monotonic) > 2);
    const removed = dir.openFile("dump_1.zcpf", .{});
    if (removed) |file| file.close() else |_| {}
    try std.testing.expectError(error.FileNotFound, removed);
    for ([_][]const u8{ "dump_2.zcpf", "unrelated.zcpf" }) |name| {
        const file = try dir.openFile(name, .{});
        file.close();
    }
    memory.flush();
    try persister.load(memory);
    try std.testing.expectEqual(@as(i64, 12), (try memory.get("scheduled")).int);
}

test "snapshot round trip restores every shard with a different shard count" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.memory.shard_count = 3;
    try fixture.create_memory();
    const path = try std.fmt.allocPrint(fixture.allocator, "./tmp/persist-sharded-{d}/", .{runtime_io.timestampNanoseconds()});
    defer fixture.allocator.free(path);
    try fs.cwd().makePath(path);
    defer fs.cwd().deleteDir(path) catch {};
    fixture.persistance.?.path = path;

    for (0..128) |index| {
        var buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "snapshot-key-{d}", .{index});
        try fixture.memory.?.put(key, .{ .int = @intCast(index) });
    }
    for (fixture.memory.?.fabric.shards) |*shard| try std.testing.expect(shard.map.count() > 0);
    try std.testing.expect(try fixture.memory.?.save() > 0);
    const filename = try std.fmt.allocPrint(fixture.allocator, "{s}dump_{d}.zcpf", .{ path, fixture.memory.?.last_save.load(.monotonic) });
    defer fixture.allocator.free(filename);
    defer fs.cwd().deleteFile(filename) catch {};

    fixture.config.memory.shard_count = 5;
    try fixture.create_memory();
    try fixture.persistance.?.load(&fixture.memory.?);
    try std.testing.expectEqual(@as(i64, 128), fixture.memory.?.size());
    for (0..128) |index| {
        var buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "snapshot-key-{d}", .{index});
        try std.testing.expectEqual(@as(i64, @intCast(index)), (try fixture.memory.?.get(key)).int);
    }
}

// Verifies a valid snapshot restores all encoded entries.
test "should load" {
    fs.cwd().makePath("./tmp/persist-load") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = "./tmp/persist-load/";

    try std.testing.expectEqual(fixture.memory.?.size(), 0);

    const file_content = "zcpf%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest\r\n\x03";
    const file = try fs.cwd().createFile("./tmp/persist-load/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try fixture.persistance.?.load(&fixture.memory.?);

    try std.testing.expectEqual(fixture.memory.?.size(), 4);

    fs.cwd().deleteFile("./tmp/persist-load/dump_123.zcpf") catch {};
    fs.cwd().deleteDir("./tmp/persist-load") catch {};
}

// Checks snapshot loading rejects a missing file signature.
test "should not load without header" {
    fs.cwd().makePath("./tmp/persist-no-header") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = "./tmp/persist-no-header/";

    fs.cwd().makeDir("./tmp/persist-no-header") catch {};

    try std.testing.expectEqual(fixture.memory.?.size(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try fs.cwd().createFile("./tmp/persist-no-header/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixture.persistance.?.load(&fixture.memory.?), error.InvalidFile);

    fs.cwd().deleteFile("./tmp/persist-no-header/dump_123.zcpf") catch {};
    fs.cwd().deleteDir("./tmp/persist-no-header") catch {};
}

// Checks files without the snapshot extension are not accepted.
test "should not load invalid ext" {
    fs.cwd().makePath("./tmp/persist-invalid-ext") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = "./tmp/persist-invalid-ext/";

    fs.cwd().makeDir("./tmp/persist-invalid-ext") catch {};

    try std.testing.expectEqual(fixture.memory.?.size(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try fs.cwd().createFile("./tmp/persist-invalid-ext/dump_latest_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixture.persistance.?.load(&fixture.memory.?), error.InvalidFile);

    fs.cwd().deleteFile("./tmp/persist-invalid-ext/dump_latest_123.asdf") catch {};
    fs.cwd().deleteDir("./tmp/persist-invalid-ext") catch {};
}

test "rejects malformed contents in a recognized snapshot file" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    const path = "./tmp/persist-corrupted/";
    const filename = path ++ "dump_123.zcpf";
    try fs.cwd().makePath(path);
    defer fs.cwd().deleteDir(path) catch {};
    defer fs.cwd().deleteFile(filename) catch {};
    fixture.persistance.?.path = path;
    const memory = &fixture.memory.?;
    const last_save = memory.last_save.load(.monotonic);

    for ([_][]const u8{
        "zc",
        "zcpf%1\r\n:5\r\n:7\r\n",
        "zcpf%1\r\n$3\r\nkey\r\n$8\r\n",
    }) |payload| {
        {
            const file = try fs.cwd().createFile(filename, .{});
            defer file.close();
            try file.writeAll(payload);
        }
        try std.testing.expectError(error.InvalidFile, fixture.persistance.?.load(memory));
        try std.testing.expectEqual(@as(i64, 0), memory.size());
        try std.testing.expectEqual(last_save, memory.last_save.load(.monotonic));
    }
}

// Verifies saving writes a snapshot and reports its serialized length.
test "should save" {
    fs.cwd().makePath("./tmp/persist-save") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = "./tmp/persist-save/";

    try fixture.memory.?.put("test1", .{ .str = "testtest" });
    try fixture.memory.?.put("test2", .{ .str = "testtest" });
    try fixture.memory.?.put("test3", .{ .str = "testtest" });
    try fixture.memory.?.put("test4", .{ .str = "testtest" });

    const result = try fixture.persistance.?.save(&fixture.memory.?);

    try std.testing.expectEqual(result, 108);

    const filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "./tmp/persist-save/dump_{d}.zcpf",
        .{fixture.memory.?.last_save.load(.monotonic)},
    );
    defer std.testing.allocator.free(filename);
    fs.cwd().deleteFile(filename) catch {};
    fs.cwd().deleteDir("./tmp/persist-save") catch {};
}
