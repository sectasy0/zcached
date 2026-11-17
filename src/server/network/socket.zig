//! Small socket read/write adapters using the caller-supplied I/O implementation.
const std = @import("std");

/// Socket-level errors, with explicit detection of a zero-progress write.
pub const Error = std.Io.net.Stream.Reader.Error || std.Io.net.Stream.Writer.Error || error{WriteZero};

/// Reads into one mutable buffer; an empty destination succeeds without I/O.
pub fn read(io: std.Io, socket: std.Io.net.Stream, buffer: []u8) Error!usize {
    if (buffer.len == 0) return 0;
    var vectors = [_][]u8{buffer};
    return socket.read(io, &vectors);
}

/// Writes one buffer once; empty writes succeed and a zero-byte result is an error.
pub fn write(io: std.Io, socket: std.Io.net.Stream, bytes: []const u8) Error!usize {
    if (bytes.len == 0) return 0;
    const vectors = [_][]const u8{bytes};
    const count = try (try io.operate(.{ .net_write = .{
        .socket_handle = socket.socket.handle,
        .data = &vectors,
        .splat = 1,
    } })).net_write;
    if (count == 0) return error.WriteZero;
    return count;
}

/// Repeats partial writes until every byte is sent or a socket error occurs.
pub fn writeAll(io: std.Io, socket: std.Io.net.Stream, bytes: []const u8) Error!void {
    var written: usize = 0;
    while (written < bytes.len) written += try write(io, socket, bytes[written..]);
}
