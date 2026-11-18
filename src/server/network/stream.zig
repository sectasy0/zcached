//! Stream wrapper providing uniform plain-socket and optional TLS I/O.
const std = @import("std");
const build_options = @import("build_options");
const secure = @import("secure.zig");
const socket_io = @import("socket.zig");

/// Build-selected stream type used by accepted connections.
pub const Stream = StreamT(build_options.tls_enabled);

/// Errors possible while reading through a plain or TLS stream.
pub const ReadError = secure.Error || error{StreamClosed};
/// Errors possible while writing through a plain or TLS stream.
pub const WriteError = ReadError;

/// Returns a stream implementation specialized for the build's TLS mode.
pub fn StreamT(comptime tls_enabled: bool) type {
    return struct {
        /// Concrete stream type returned by this compile-time specialization.
        const Self = @This();

        /// Underlying connected socket; closed by `close`.
        socket: std.Io.net.Stream,
        /// I/O backend used for socket operations.
        io: std.Io,
        /// Optional TLS session, present only in TLS-enabled specializations.
        ctx: ?if (tls_enabled) secure.StreamContext else void = null,
        /// Prevents repeated close operations and rejects subsequent reads/writes.
        closed: bool = false,

        /// Closes TLS state and the socket once; no TLS close-notify is sent.
        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            if (tls_enabled) {
                if (self.ctx) |*ctx| ctx.deinit();
                self.ctx = null;
            }
            self.socket.close(self.io);
        }

        /// Reads bytes from the stream, returning zero for an empty buffer or EOF.
        pub fn read(self: *Self, buffer: []u8) ReadError!usize {
            return self.readTimed(buffer, .none);
        }

        pub fn readTimed(self: *Self, buffer: []u8, timeout: std.Io.Timeout) ReadError!usize {
            if (self.closed) return error.StreamClosed;
            if (buffer.len == 0) return 0;
            if (tls_enabled) {
                if (self.ctx) |*ctx| return ctx.read(self.socket, buffer, timeout);
            }
            return socket_io.read(self.io, self.socket, buffer, timeout);
        }

        /// Writes some bytes to the stream; an empty input succeeds without I/O.
        pub fn write(self: *Self, bytes: []const u8) WriteError!usize {
            if (self.closed) return error.StreamClosed;
            if (bytes.len == 0) return 0;
            if (tls_enabled) {
                if (self.ctx) |*ctx| return ctx.write(self.socket, bytes);
            }
            return socket_io.write(self.io, self.socket, bytes);
        }

        /// Repeats writes until all bytes are sent or an error interrupts progress.
        pub fn writeAll(self: *Self, bytes: []const u8) WriteError!void {
            var written: usize = 0;
            while (written < bytes.len) written += try self.write(bytes[written..]);
        }

        /// Reader adapter that retains the most recent stream error for inspection.
        pub const Reader = struct {
            /// Stream borrowed for the adapter's lifetime.
            stream: *Self,
            /// Standard-library reader interface and its caller-provided buffering.
            interface: std.Io.Reader,
            /// Original stream error when the interface reports `ReadFailed`.
            err: ?ReadError = null,

            /// Fills the writer from the stream, translating EOF and errors to Reader errors.
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

        /// Creates a standard-library buffered reader over this stream.
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
