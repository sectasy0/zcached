const std = @import("std");

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;

test "should load" {
    std.fs.cwd().makePath("./tmp/persist-load") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = "./tmp/persist-load/";

    try std.testing.expectEqual(fixture.memory.?.internal.count(), 0);

    const file_content = "zcpf%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest\r\n\x03";
    const file = try std.fs.cwd().createFile("./tmp/persist-load/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try fixture.persistance.?.load(&fixture.memory.?);

    try std.testing.expectEqual(fixture.memory.?.internal.count(), 4);

    std.fs.cwd().deleteFile("./tmp/persist-load/dump_123.zcpf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist-load") catch {};
}

test "should not load without header" {
    std.fs.cwd().makePath("./tmp/persist-no-header") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = "./tmp/persist-no-header/";

    std.fs.cwd().makeDir("./tmp/persist-no-header") catch {};

    try std.testing.expectEqual(fixture.memory.?.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist-no-header/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixture.persistance.?.load(&fixture.memory.?), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist-no-header/dump_123.zcpf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist-no-header") catch {};
}

test "should not load invalid ext" {
    std.fs.cwd().makePath("./tmp/persist-invalid-ext") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = "./tmp/persist-invalid-ext/";

    std.fs.cwd().makeDir("./tmp/persist-invalid-ext") catch {};

    try std.testing.expectEqual(fixture.memory.?.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist-invalid-ext/dump_latest_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixture.persistance.?.load(&fixture.memory.?), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist-invalid-ext/dump_latest_123.asdf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist-invalid-ext") catch {};
}

test "should not load corrupted file" {
    std.fs.cwd().makePath("./tmp/persist-corrupted") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = "./tmp/persist-corrupted/";

    std.fs.cwd().makeDir("./tmp/persist-corrupted") catch {};

    try std.testing.expectEqual(fixture.memory.?.internal.count(), 0);

    const file_content = "%4\r\n$5test2\r\n$4\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist-corrupted/dump_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixture.persistance.?.load(&fixture.memory.?), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist-corrupted/dump_123.asdf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist-corrupted") catch {};
}

test "should save" {
    std.fs.cwd().makePath("./tmp/persist-save") catch {};

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
        .{fixture.memory.?.last_save},
    );
    defer std.testing.allocator.free(filename);
    std.fs.cwd().deleteFile(filename) catch {};
    std.fs.cwd().deleteDir("./tmp/persist-save") catch {};
}
