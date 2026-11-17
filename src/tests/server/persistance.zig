const std = @import("std");
const fs = @import("fs");

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;

// Verifies a valid snapshot restores all encoded entries.
test "should load" {
    fs.cwd().makePath("./tmp/persist-load") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = "./tmp/persist-load/";

    try std.testing.expectEqual(fixture.memory.?.internal.count(), 0);

    const file_content = "zcpf%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest\r\n\x03";
    const file = try fs.cwd().createFile("./tmp/persist-load/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try fixture.persistance.?.load(&fixture.memory.?);

    try std.testing.expectEqual(fixture.memory.?.internal.count(), 4);

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

    try std.testing.expectEqual(fixture.memory.?.internal.count(), 0);

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

    try std.testing.expectEqual(fixture.memory.?.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try fs.cwd().createFile("./tmp/persist-invalid-ext/dump_latest_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixture.persistance.?.load(&fixture.memory.?), error.InvalidFile);

    fs.cwd().deleteFile("./tmp/persist-invalid-ext/dump_latest_123.asdf") catch {};
    fs.cwd().deleteDir("./tmp/persist-invalid-ext") catch {};
}

// Checks malformed snapshot contents return InvalidFile.
test "should not load corrupted file" {
    fs.cwd().makePath("./tmp/persist-corrupted") catch {};

    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    fixture.persistance.?.path = "./tmp/persist-corrupted/";

    fs.cwd().makeDir("./tmp/persist-corrupted") catch {};

    try std.testing.expectEqual(fixture.memory.?.internal.count(), 0);

    const file_content = "%4\r\n$5test2\r\n$4\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try fs.cwd().createFile("./tmp/persist-corrupted/dump_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(fixture.persistance.?.load(&fixture.memory.?), error.InvalidFile);

    fs.cwd().deleteFile("./tmp/persist-corrupted/dump_123.asdf") catch {};
    fs.cwd().deleteDir("./tmp/persist-corrupted") catch {};
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
        .{fixture.memory.?.last_save},
    );
    defer std.testing.allocator.free(filename);
    fs.cwd().deleteFile(filename) catch {};
    fs.cwd().deleteDir("./tmp/persist-save") catch {};
}
