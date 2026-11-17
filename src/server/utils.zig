//! Provides small helpers for enum conversion, paths, timestamps, formatting, and AST literals.

const std = @import("std");
const fs = @import("fs");
const ctime = @import("c");

/// Resolves an enum name or tagged-union tag name without regard to ASCII case.
/// Returns `null` when the spelling is not a member; unsupported types fail compilation.
pub inline fn enumTypeFromStr(comptime T: type, str: []const u8) ?T {
    const tag = switch (@typeInfo(T)) {
        .@"enum" => T,
        .@"union" => |info| info.tag_type orelse @compileError("expected tagged union"),
        else => @compileError("expected type T to be union or enum"),
    };
    const info = @typeInfo(tag).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        if (std.ascii.eqlIgnoreCase(str, name)) return @fromBackingInt(@intCast(value));
    }
    return null;
}

/// Casts an aligned opaque pointer to a pointer of the requested type.
pub fn ptrCast(comptime T: type, ptr: *anyopaque) *T {
    if (@alignOf(T) == 0) @compileError(@typeName(T));
    return @ptrCast(@alignCast(ptr));
}

/// Creates the parent directory of a file path; logs and suppresses other creation errors.
pub fn createPath(file_path: []const u8) void {
    const path = std.fs.path.dirname(file_path) orelse return;

    fs.cwd().makePath(path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        std.log.err("failed to create path: {s} ({any})", .{ path, err });
        return;
    };
}

/// Writes a local-time timestamp into the caller-provided buffer and returns its byte length.
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

/// Escapes each CRLF pair as the visible characters `\\r\\n` in an allocated result.
/// The caller owns the returned slice and must free it with `allocator`.
pub fn repr(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const size = std.mem.replacementSize(u8, value, "\r\n", "\\r\\n");
    const output = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, value, "\r\n", "\\r\\n", output);
    return output;
}

/// Decodes the string literal at an AST node into allocator-owned bytes.
/// Parsing and allocation errors are propagated; the caller owns the result.
pub fn parseString(alloc: std.mem.Allocator, ast: std.zig.Ast, idx: u32) ![]const u8 {
    return std.zig.string_literal.parseAlloc(alloc, ast.tokenSlice(
        ast.nodes.items(.main_token)[idx],
    ));
}

/// Parses the numeric token at an AST node, returning the Zig literal parser's result.
pub fn parseNumber(ast: std.zig.Ast, idx: u32) std.zig.number_literal.Result {
    return std.zig.number_literal.parseNumberLiteral(ast.tokenSlice(
        ast.nodes.items(.main_token)[idx],
    ));
}
