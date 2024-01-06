const std = @import("std");
const ctime = @cImport(@cInclude("time.h"));

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

pub fn timestampf(buff: []u8) usize {
    var buffer: [40]u8 = undefined;

    const time = ctime.time(null);
    const local_time = ctime.localtime(&time);

    const time_len = ctime.strftime(
        &buffer,
        buffer.len,
        "%Y-%m-%dT%H:%M:%S.000 %Z",
        local_time,
    );
    @memcpy(buff.ptr, buffer[0..time_len]);
    return time_len;
}

pub fn is_whitelisted(whitelist: std.ArrayList(std.net.Address), addr: std.net.Address) bool {
    for (whitelist.items) |whitelisted| {
        if (std.meta.eql(whitelisted.any.data[2..].*, addr.any.data[2..].*)) return true;
    }
    return false;
}

pub fn repr(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const size = std.mem.replacementSize(u8, value, "\r\n", "\\r\\n");
    var output = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, value, "\r\n", "\\r\\n", output);
    return output;
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

    const actual_len = timestampf(buff[0..]);
    const actual = std.mem.bytesAsSlice(u8, buff[0..actual_len]);

    try std.testing.expectEqualStrings(ex_buffer[0..time_len], actual);
}

test "is_whitelisted should return true for whitelisted address ipv4" {
    var whitelist = std.ArrayList(std.net.Address).init(std.testing.allocator);
    const whitelisted = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    defer whitelist.deinit();

    try whitelist.append(whitelisted);

    const addrToCheck = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);

    try std.testing.expectEqual(true, is_whitelisted(whitelist, addrToCheck));
}

test "is_whitelisted should return true for whitelisted address ipv4 if different port" {
    var whitelist = std.ArrayList(std.net.Address).init(std.testing.allocator);
    const whitelisted = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    defer whitelist.deinit();

    try whitelist.append(whitelisted);

    const addrToCheck = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7558);

    try std.testing.expectEqual(true, is_whitelisted(whitelist, addrToCheck));
}

test "is_whitelisted should return false for non whitelisted address ipv4" {
    var whitelist = std.ArrayList(std.net.Address).init(std.testing.allocator);
    const whitelisted = std.net.Address.initIp4(.{ 127, 0, 0, 5 }, 7556);
    defer whitelist.deinit();

    try whitelist.append(whitelisted);

    const addrToCheck = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);

    try std.testing.expectEqual(false, is_whitelisted(whitelist, addrToCheck));
}

test "is_whitelisted should return true for whitelisted address ipv6" {
    const addr = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    var whitelist = std.ArrayList(std.net.Address).init(std.testing.allocator);
    const whitelisted = std.net.Address.initIp6(addr, 1234, 0, 0);
    defer whitelist.deinit();

    try whitelist.append(whitelisted);

    const addrToCheck = std.net.Address.initIp6(addr, 1234, 0, 0);

    try std.testing.expectEqual(true, is_whitelisted(whitelist, addrToCheck));
}

test "is_whitelisted should return true for whitelisted address ipv6 if different port" {
    const addr = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    var whitelist = std.ArrayList(std.net.Address).init(std.testing.allocator);
    const whitelisted = std.net.Address.initIp6(addr, 1234, 0, 0);
    defer whitelist.deinit();

    try whitelist.append(whitelisted);

    const addrToCheck = std.net.Address.initIp6(addr, 7556, 0, 0);

    try std.testing.expectEqual(true, is_whitelisted(whitelist, addrToCheck));
}

test "is_whitelisted should return fallse for non whitelisted address ipv6" {
    const addr = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    var whitelist = std.ArrayList(std.net.Address).init(std.testing.allocator);
    const whitelisted = std.net.Address.initIp6(
        .{ 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 },
        1234,
        0,
        0,
    );
    defer whitelist.deinit();

    try whitelist.append(whitelisted);

    const addrToCheck = std.net.Address.initIp6(addr, 1234, 0, 0);

    try std.testing.expectEqual(false, is_whitelisted(whitelist, addrToCheck));
}

test "repr" {
    var expected: []const u8 = "Hello\\r\\nWorld";
    var input: []const u8 = "Hello\r\nWorld";
    var actual = try repr(std.testing.allocator, input);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}
