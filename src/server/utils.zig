const std = @import("std");

pub fn to_uppercase(str: []u8) []u8 {
    var result: [1024]u8 = undefined;
    for (str, 0..) |c, index| result[index] = std.ascii.toUpper(c);
    return result[0..str.len];
}

pub fn ptrCast(comptime T: type, ptr: *anyopaque) *T {
    if (@alignOf(T) == 0) @compileError(@typeName(T));
    return @ptrCast(@alignCast(ptr));
}

pub fn create_path(file_path: []const u8) void {
    const path = std.fs.path.dirname(file_path) orelse return;

    std.fs.cwd().makePath(path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        std.log.err("failed to create path: {?}", .{err});
        return;
    };
}

test "to_uppercase" {
    const str = @constCast("hello world");
    const expected = @constCast("HELLO WORLD");
    const actual = to_uppercase(str);
    try std.testing.expectEqualStrings(expected, actual);
}

test "create_path" {
    const file_path = "./test/file.txt";
    const path = std.fs.path.dirname(file_path).?;

    defer std.fs.cwd().deleteDir(path) catch {};

    create_path(file_path);

    std.fs.cwd().makeDir(path) catch |err| {
        std.debug.print("err: {any}\n", .{err});
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

    create_path(absolute_path);

    std.fs.cwd().makeDir(absolute_path) catch |err| {
        std.debug.print("err: {any}\n", .{err});
        try std.testing.expectEqual(err, error.PathAlreadyExists);
    };
}
