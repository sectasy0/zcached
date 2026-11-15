const std = @import("std");
const build_options = @import("build_options");
const secure = @import("secure.zig");
const socket_io = @import("socket.zig");

pub const Stream = StreamT(build_options.tls_enabled);

pub const ReadError = secure.Error || error{StreamClosed};
pub const WriteError = ReadError;

pub fn StreamT(comptime tls_enabled: bool) type {
    return struct {
        const Self = @This();

        socket: std.Io.net.Stream,
        io: std.Io,
        ctx: ?if (tls_enabled) secure.StreamContext else void = null,
        closed: bool = false,

        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            if (tls_enabled) {
                if (self.ctx) |*ctx| ctx.deinit();
                self.ctx = null;
            }
            self.socket.close(self.io);
        }

        pub fn read(self: *Self, buffer: []u8) ReadError!usize {
            if (self.closed) return error.StreamClosed;
            if (buffer.len == 0) return 0;
            if (tls_enabled) {
                if (self.ctx) |*ctx| return ctx.read(self.socket, buffer);
            }
            return socket_io.read(self.io, self.socket, buffer);
        }

        pub fn write(self: *Self, bytes: []const u8) WriteError!usize {
            if (self.closed) return error.StreamClosed;
            if (bytes.len == 0) return 0;
            if (tls_enabled) {
                if (self.ctx) |*ctx| return ctx.write(self.socket, bytes);
            }
            return socket_io.write(self.io, self.socket, bytes);
        }

        pub fn writeAll(self: *Self, bytes: []const u8) WriteError!void {
            var written: usize = 0;
            while (written < bytes.len) written += try self.write(bytes[written..]);
        }

        pub const Reader = struct {
            stream: *Self,
            interface: std.Io.Reader,
            err: ?ReadError = null,

            fn readImpl(interface: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                const self: *Reader = @alignCast(@fieldParentPtr("interface", interface));
                const destination = limit.slice(try writer.writableSliceGreedy(1));
                if (destination.len == 0) return 0;
                const count = self.stream.read(destination) catch |err| {
                    self.err = err;
                    return error.ReadFailed;
                };
                if (count == 0) return error.EndOfStream;
                writer.advance(count);
                return count;
            }
        };

        pub fn reader(self: *Self, buffer: []u8) Reader {
            return .{
                .stream = self,
                .interface = .{
                    .vtable = &.{ .stream = Reader.readImpl },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }
    };
}
