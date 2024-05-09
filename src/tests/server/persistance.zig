const std = @import("std");

const ContextFixture = @import("../fixtures.zig").ContextFixture;

test "should load" {
    std.fs.cwd().makePath("./tmp/persist") catch {};
    std.fs.cwd().deleteFile("./tmp/persist/dump_123.zcpf") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.create_memory_storage();
    fixture.persistance.path = "./tmp/persist/";

    try std.testing.expectEqual(fixture.memory_storage.?.internal.count(), 0);

    const file_content = "zcpf%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest\r\n";
    const file = try std.fs.cwd().createFile("./tmp/persist/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try fixture.persistance.load(&fixture.memory_storage.?);

    try std.testing.expectEqual(fixture.memory_storage.?.internal.count(), 4);

    std.fs.cwd().deleteFile("./tmp/persist/dump_123.zcpf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load without header" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.create_memory_storage();
    fixture.persistance.path = "./tmp/persist/without_header/";

    std.fs.cwd().makeDir("./tmp/persist/without_header") catch {};

    try std.testing.expectEqual(fixture.memory_storage.?.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/without_header/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixture.persistance.load(&fixture.memory_storage.?), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist/without_header/dump_123.zcpf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load invalid ext" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.create_memory_storage();
    fixture.persistance.path = "./tmp/persist/invalid_ext/";

    std.fs.cwd().makeDir("./tmp/persist/invalid_ext") catch {};

    try std.testing.expectEqual(fixture.memory_storage.?.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/invalid_ext/dump_latest_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixture.persistance.load(&fixture.memory_storage.?), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist/invalid_ext/dump_123.asdf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load corrupted file" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.create_memory_storage();
    fixture.persistance.path = "./tmp/persist/corrupted/";

    std.fs.cwd().makeDir("./tmp/persist/corrupted") catch {};

    try std.testing.expectEqual(fixture.memory_storage.?.internal.count(), 0);

    const file_content = "%4\r\n$5test2\r\n$4\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/corrupted/dump_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixture.persistance.load(&fixture.memory_storage.?), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist/corrupted/dump_123.asdf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should save" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.create_memory_storage();

    try fixture.memory_storage.?.put("test1", .{ .str = @constCast("testtest") });
    try fixture.memory_storage.?.put("test2", .{ .str = @constCast("testtest") });
    try fixture.memory_storage.?.put("test3", .{ .str = @constCast("testtest") });
    try fixture.memory_storage.?.put("test4", .{ .str = @constCast("testtest") });

    const result = try fixture.persistance.save(&fixture.memory_storage.?);

    try std.testing.expectEqual(result, 108);

    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}
