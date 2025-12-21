const std = @import("std");
const ctime = @cImport(@cInclude("time.h"));

const openssl = @cImport({
    @cInclude("openssl/err.h");
});

/// Converts a string representation of an enum or union type to the corresponding enum value (Ignores case).
///
/// Example usage:
///
/// const MyEnum = enum { A, B, C };
/// const value = enumTypeFromStr(MyEnum, "B"); // returns MyEnum.B
///
pub inline fn enumTypeFromStr(comptime T: type, str: []const u8) ?T {
    switch (@typeInfo(T)) {
        .@"enum", .@"union" => {},
        else => @compileError("expected type T to be union or enum"),
    }
    const fields = std.meta.fields(T);

    inline for (fields) |field| {
        if (std.ascii.eqlIgnoreCase(str, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

// Performs a pointer cast from an opaque pointer to a typed pointer of type `T`.
pub fn ptrCast(comptime T: type, ptr: *anyopaque) *T {
    if (@alignOf(T) == 0) @compileError(@typeName(T));
    return @ptrCast(@alignCast(ptr));
}

// Creates the directory path for the given file path if it does not already exist.
pub fn createPath(file_path: []const u8) void {
    const path = std.fs.path.dirname(file_path) orelse return;

    std.fs.cwd().makePath(path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        std.log.err("failed to create path: {s} ({any})", .{ path, err });
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

// Parses a string literal from the AST and returns it as a byte slice.
pub fn parseString(alloc: std.mem.Allocator, ast: std.zig.Ast, idx: u32) ![]const u8 {
    return std.zig.string_literal.parseAlloc(alloc, ast.tokenSlice(
        ast.nodes.items(.main_token)[idx],
    ));
}

// Parses a numeric literal from the AST and returns it as a Result.
pub fn parseNumber(ast: std.zig.Ast, idx: u32) std.zig.number_literal.Result {
    return std.zig.number_literal.parseNumberLiteral(ast.tokenSlice(
        ast.nodes.items(.main_token)[idx],
    ));
}
