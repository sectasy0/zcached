const std = @import("std");
const ctime = @cImport(@cInclude("time.h"));

// Converts each character in the given byte array to its uppercase equivalent.
pub fn to_uppercase(str: []u8) []u8 {
    var result: [1024]u8 = undefined;
    for (str, 0..) |c, index| result[index] = std.ascii.toUpper(c);
    return result[0..str.len];
}

// Performs a pointer cast from an opaque pointer to a typed pointer of type `T`.
pub fn ptr_cast(comptime T: type, ptr: *anyopaque) *T {
    if (@alignOf(T) == 0) @compileError(@typeName(T));
    return @ptrCast(@alignCast(ptr));
}

// Creates the directory path for the given file path if it does not already exist.
pub fn create_path(file_path: []const u8) void {
    const path = std.fs.path.dirname(file_path) orelse return;

    std.fs.cwd().makePath(path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        std.log.err("failed to create path: {?}", .{err});
        return;
    };
}

// Formats the current time in a specific timestamp format and copies it to the `buff` byte array.
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

// Converts the provided byte array representing protocol raw data to its string
// representation by replacing occurrences of "\r\n" with "\\r\\n".
pub fn repr(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const size = std.mem.replacementSize(u8, value, "\r\n", "\\r\\n");
    const output = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, value, "\r\n", "\\r\\n", output);
    return output;
}

pub fn parse_field_name(
    alloc: std.mem.Allocator,
    ast: std.zig.Ast,
    idx: std.zig.Ast.Node.Index,
) ![]const u8 {
    const name = ast.tokenSlice(ast.firstToken(idx) - 2);
    if (name[0] == '@') {
        return std.zig.string_literal.parseAlloc(
            alloc,
            name[1..],
        );
    }
    return name;
}

pub fn parse_string(
    alloc: std.mem.Allocator,
    ast: std.zig.Ast,
    idx: std.zig.Ast.Node.Index,
) ![]const u8 {
    return std.zig.string_literal.parseAlloc(alloc, ast.tokenSlice(
        ast.nodes.items(.main_token)[idx],
    ));
}

pub fn parse_number(
    ast: std.zig.Ast,
    idx: std.zig.Ast.Node.Index,
) std.zig.number_literal.Result {
    return std.zig.number_literal.parseNumberLiteral(ast.tokenSlice(
        ast.nodes.items(.main_token)[idx],
    ));
}

pub fn parse_address(value: []const u8, port: u16) ?std.net.Address {
    return std.net.Address.parseIp(value, port) catch |err| {
        std.debug.print(
            "DEBUG [{d}] * parsing {s} as std.net.Address, {?}\n",
            .{ std.time.timestamp(), value, err },
        );
        return null;
    };
}
