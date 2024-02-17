const std = @import("std");
const ctime = @cImport(@cInclude("time.h"));

// Converts each character in the given byte array to its uppercase equivalent.
//
// # Arguments
// * `str` - A byte array containing characters to be converted to uppercase.
pub fn to_uppercase(str: []u8) []u8 {
    var result: [1024]u8 = undefined;
    for (str, 0..) |c, index| result[index] = std.ascii.toUpper(c);
    return result[0..str.len];
}

// Performs a pointer cast from an opaque pointer to a typed pointer of type `T`.
//
// # Arguments
// * `T` - The target type to cast the pointer to.
// * `ptr` - An opaque pointer (`*anyopaque`) to be cast to the target type.
pub fn ptrCast(comptime T: type, ptr: *anyopaque) *T {
    if (@alignOf(T) == 0) @compileError(@typeName(T));
    return @ptrCast(@alignCast(ptr));
}

// Creates the directory path for the given file path if it does not already exist.
//
// # Arguments
// * `file_path` - A null-terminated byte array representing the file path.
pub fn create_path(file_path: []const u8) void {
    const path = std.fs.path.dirname(file_path) orelse return;

    std.fs.cwd().makePath(path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        std.log.err("failed to create path: {?}", .{err});
        return;
    };
}

// Formats the current time in a specific timestamp format and copies it to the `buff` byte array.
//
// # Arguments
// * `buff` - A byte array to store the formatted timestamp.
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

// Checks if the provided network address is present in the given whitelist.
//
// # Arguments
// * `whitelist` - A dynamic array (`std.ArrayList`) containing whitelisted network addresses.
// * `addr` - The network address to be checked for whitelisting.
pub fn is_whitelisted(whitelist: std.ArrayList(std.net.Address), addr: std.net.Address) bool {
    for (whitelist.items) |whitelisted| {
        if (std.meta.eql(whitelisted.any.data[2..].*, addr.any.data[2..].*)) return true;
    }
    return false;
}

// Converts the provided byte array representing protocol raw data to its string
// representation by replacing occurrences of "\r\n" with "\\r\\n".
//
// # Arguments
// * `allocator` - An allocator from `std.mem.Allocator` to allocate memory for the new byte array.
// * `value` - A null-terminated byte array containing the original protocol raw data.
pub fn repr(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const size = std.mem.replacementSize(u8, value, "\r\n", "\\r\\n");
    var output = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, value, "\r\n", "\\r\\n", output);
    return output;
}
