const std = @import("std");

const Fixtures = @import("../fixtures.zig");

test "should load" {
    std.fs.cwd().makePath("./tmp/persist") catch {};
    std.fs.cwd().deleteFile("./tmp/persist/dump_123.zcpf") catch {};

    var fixtures = try Fixtures.init();
    defer fixtures.deinit();
    fixtures.persistance.path = "./tmp/persist/";

    var storage = fixtures.create_memory_storage();
    defer storage.deinit();

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "zcpf%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest\r\n";
    const file = try std.fs.cwd().createFile("./tmp/persist/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try fixtures.persistance.load(&storage);

    try std.testing.expectEqual(storage.internal.count(), 4);

    std.fs.cwd().deleteFile("./tmp/persist/dump_123.zcpf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load without header" {
    std.fs.cwd().makePath("./tmp/persist") catch {};
    var fixtures = try Fixtures.init();
    defer fixtures.deinit();
    fixtures.persistance.path = "./tmp/persist/without_header/";

    var storage = fixtures.create_memory_storage();
    defer storage.deinit();

    std.fs.cwd().makeDir("./tmp/persist/without_header") catch {};

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/without_header/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixtures.persistance.load(&storage), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist/without_header/dump_123.zcpf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load invalid ext" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var fixtures = try Fixtures.init();
    defer fixtures.deinit();
    fixtures.persistance.path = "./tmp/persist/invalid_ext/";

    var storage = fixtures.create_memory_storage();
    defer storage.deinit();

    std.fs.cwd().makeDir("./tmp/persist/invalid_ext") catch {};

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/invalid_ext/dump_latest_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixtures.persistance.load(&storage), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist/invalid_ext/dump_123.asdf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load corrupted file" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var fixtures = try Fixtures.init();
    defer fixtures.deinit();
    fixtures.persistance.path = "./tmp/persist/corrupted/";

    var storage = fixtures.create_memory_storage();
    defer storage.deinit();

    std.fs.cwd().makeDir("./tmp/persist/corrupted") catch {};

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "%4\r\n$5test2\r\n$4\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/corrupted/dump_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixtures.persistance.load(&storage), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist/corrupted/dump_123.asdf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should save" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var fixtures = try Fixtures.init();
    defer fixtures.deinit();

    var storage = fixtures.create_memory_storage();
    defer storage.deinit();

    try storage.put("test1", .{ .str = @constCast("testtest") });
    try storage.put("test2", .{ .str = @constCast("testtest") });
    try storage.put("test3", .{ .str = @constCast("testtest") });
    try storage.put("test4", .{ .str = @constCast("testtest") });

    const result = try fixtures.persistance.save(&storage);

    try std.testing.expectEqual(result, 108);

    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}
