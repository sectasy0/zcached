const std = @import("std");

pub const Error = std.Io.net.Stream.Reader.Error || std.Io.net.Stream.Writer.Error || error{WriteZero};

pub fn read(io: std.Io, socket: std.Io.net.Stream, buffer: []u8) Error!usize {
    if (buffer.len == 0) return 0;
    var vectors = [_][]u8{buffer};
    return io.vtable.netRead(io.userdata, socket.socket.handle, &vectors);
}

pub fn write(io: std.Io, socket: std.Io.net.Stream, bytes: []const u8) Error!usize {
    if (bytes.len == 0) return 0;
    const vectors = [_][]const u8{bytes};
    const count = try io.vtable.netWrite(io.userdata, socket.socket.handle, &.{}, &vectors, 1);
    if (count == 0) return error.WriteZero;
    return count;
}

pub fn writeAll(io: std.Io, socket: std.Io.net.Stream, bytes: []const u8) Error!void {
    var written: usize = 0;
    while (written < bytes.len) written += try write(io, socket, bytes[written..]);
}
