//! Small socket read/write adapters using the caller-supplied I/O implementation.
const std = @import("std");

/// Socket-level errors, with explicit detection of a zero-progress write.
pub const Error = std.Io.net.Stream.Reader.Error || std.Io.net.Stream.Writer.Error || std.Io.OperateTimeoutError || error{WriteZero};

pub fn deadline(io: std.Io, milliseconds: u32) std.Io.Timeout {
    if (milliseconds == 0) return .none;
    return .{ .deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{
        .raw = .fromMilliseconds(milliseconds),
        .clock = .awake,
    }) };
}

/// Reads into one mutable buffer; an empty destination succeeds without I/O.
pub fn read(io: std.Io, socket: std.Io.net.Stream, buffer: []u8, timeout: std.Io.Timeout) Error!usize {
    if (buffer.len == 0) return 0;
    var vectors = [_][]u8{buffer};
    if (timeout == .none) return socket.read(io, &vectors);
    if (timeout.deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.Timeout;
    return (try (try io.operateTimeout(.{ .net_read = .{
        .socket_handle = socket.socket.handle,
        .data = &vectors,
    } }, timeout)).net_read).data_len;
}

/// Writes one buffer once; empty writes succeed and a zero-byte result is an error.
pub fn write(io: std.Io, socket: std.Io.net.Stream, bytes: []const u8) Error!usize {
    return writeTimed(io, socket, bytes, .none);
}

fn writeTimed(io: std.Io, socket: std.Io.net.Stream, bytes: []const u8, timeout: std.Io.Timeout) Error!usize {
    if (bytes.len == 0) return 0;
    if (timeout != .none and timeout.deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.Timeout;
    const vectors = [_][]const u8{bytes};
    const count = try (try io.operateTimeout(.{ .net_write = .{
        .socket_handle = socket.socket.handle,
        .data = &vectors,
        .splat = 1,
    } }, timeout)).net_write;
    if (count == 0) return error.WriteZero;
    return count;
}

/// Repeats partial writes until every byte is sent or a socket error occurs.
pub fn writeAll(io: std.Io, socket: std.Io.net.Stream, bytes: []const u8, timeout: std.Io.Timeout) Error!void {
    var written: usize = 0;
    while (written < bytes.len) written += try writeTimed(io, socket, bytes[written..], timeout);
}
