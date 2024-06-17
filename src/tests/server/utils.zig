const std = @import("std");
const ctime = @cImport(@cInclude("time.h"));
const utils = @import("../../server/utils.zig");

test "enum_type_from_str" {
    const Tag = enum {
        a,
        b,
    };
    const str = "A";
    const expected = Tag.a;
    const actual = utils.enum_type_from_str(Tag, str).?;
    try std.testing.expectEqual(expected, actual);
}

test "create_path" {
    const file_path = "./test/file.txt";
    const path = std.fs.path.dirname(file_path).?;

    defer std.fs.cwd().deleteDir(path) catch {};

    utils.create_path(file_path);

    std.fs.cwd().makeDir(path) catch |err| {
        try std.testing.expectEqual(err, error.PathAlreadyExists);
    };
}

test "create_path absolute" {
    const file_path = "/home/sectasy/zcached/test/file.txt";
    const path = std.fs.path.dirname(file_path).?;

    defer std.fs.cwd().deleteDir(path) catch {};

    const cwd_path = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd_path);

    const absolute_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd_path,
    });

    defer std.testing.allocator.free(absolute_path);

    utils.create_path(absolute_path);

    std.fs.cwd().makeDir(absolute_path) catch |err| {
        try std.testing.expectEqual(err, error.PathAlreadyExists);
    };
}

test "timestampf should format current time correctly" {
    var buff: [40]u8 = undefined;
    const expected = "2024-01-06T12:00:00.000 UTC";
    _ = expected;

    var ex_buffer: [40]u8 = undefined;

    const time = ctime.time(null);
    const local_time = ctime.localtime(&time);

    const time_len = ctime.strftime(
        &ex_buffer,
        ex_buffer.len,
        "%Y-%m-%dT%H:%M:%S.000 %Z",
        local_time,
    );

    const actual_len = utils.timestampf(buff[0..]);
    const actual = std.mem.bytesAsSlice(u8, buff[0..actual_len]);

    try std.testing.expectEqualStrings(ex_buffer[0..time_len], actual);
}

test "repr" {
    const expected: []const u8 = "Hello\\r\\nWorld";
    const input: []const u8 = "Hello\r\nWorld";
    const actual = try utils.repr(std.testing.allocator, input);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}
