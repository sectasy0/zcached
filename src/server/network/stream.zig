const std = @import("std");
const runtime_io = @import("runtime_io");

const builtin = @import("builtin");
const native_os = builtin.os.tag;

// Build configuration and conditional imports
const build_options = @import("build_options");
const transport = if (build_options.tls_enabled)
    @import("secure.zig")
else
    @import("unsecure.zig");

pub const Stream = StreamT(transport);

pub const ReadError = error{
    InputOutput,
    SystemResources,
    IsDir,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,
    SocketUnconnected,
    SSLProtocolError,

    /// This error occurs when no global event loop is configured,
    /// and reading from the file descriptor would block.
    WouldBlock,

    /// In WASI, this error occurs when the file descriptor does
    /// not hold the required rights to read from it.
    AccessDenied,
    LockViolation,
    ProcessNotFound,
    Canceled,
} || std.posix.UnexpectedError;

pub const WriteError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    InvalidArgument,

    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to write to it.
    AccessDenied,
    BrokenPipe,
    SystemResources,
    OperationAborted,
    NotOpenForWriting,
    SSLProtocolError,

    /// The process cannot access the file because another process has locked
    /// a portion of the file. Windows-only.
    LockViolation,

    /// This error occurs when no global event loop is configured,
    /// and reading from the file descriptor would block.
    WouldBlock,

    /// Connection reset by peer.
    ConnectionResetByPeer,
    SocketUnconnected,

    NoDevice,
    ProcessNotFound,
    PermissionDenied,
    MessageTooBig,
    FileBusy,
    Canceled,
} || std.posix.UnexpectedError;

pub fn StreamT(comptime T: type) type {
    return struct {
        handle: std.posix.socket_t,
        ctx: ?T.StreamContext = null,

        pub const transport = T;

        pub fn close(self: *Self) void {
            if (@hasDecl(T, "deinit")) {
                self.ctx.deinit();
            }

            switch (native_os) {
                .windows => std.windows.closesocket(self.handle) catch unreachable,
                else => (std.Io.File{ .handle = self.handle, .flags = .{ .nonblocking = false } }).close(runtime_io.get()),
            }
        }

        const Self = @This();
        pub const Reader = struct {
            stream: Self,

            pub fn read(self: Reader, buffer: []u8) ReadError!usize {
                return self.stream.read(buffer);
            }

            pub fn readUntilDelimiterAlloc(
                self: Reader,
                allocator: std.mem.Allocator,
                delimiter: u8,
                max_size: usize,
            ) ![]u8 {
                var result = std.array_list.Managed(u8).init(allocator);
                errdefer result.deinit();

                while (result.items.len <= max_size) {
                    var byte: [1]u8 = undefined;
                    const count = try self.read(&byte);
                    if (count == 0) return error.EndOfStream;
                    if (byte[0] == delimiter) return result.toOwnedSlice();
                    try result.append(byte[0]);
                }
                return error.StreamTooLong;
            }
        };

        pub const Writer = struct {
            stream: Self,

            pub fn write(self: Writer, buffer: []const u8) WriteError!usize {
                return self.stream.write(buffer);
            }

            pub fn writeAll(self: Writer, buffer: []const u8) WriteError!void {
                return self.stream.writeAll(buffer);
            }
        };

        pub fn reader(self: Self) Reader {
            return .{ .stream = self };
        }

        pub fn writer(self: Self) Writer {
            return .{ .stream = self };
        }

        pub fn read(self: Self, buffer: []u8) ReadError!usize {
            if (buffer.len == 0) return 0;

            const ctx_ptr: ?*anyopaque = if (self.ctx) |ctx| blk: {
                break :blk ctx.ctx;
            } else blk: {
                break :blk @ptrCast(@constCast(&self.handle));
            };

            return Self.transport.read(ctx_ptr, buffer);
        }

        pub fn readAll(s: Self, buffer: []u8) ReadError!usize {
            return readAtLeast(s, buffer, buffer.len);
        }

        pub fn readAtLeast(s: Self, buffer: []u8, len: usize) ReadError!usize {
            std.assert(len <= buffer.len);

            var index: usize = 0;
            while (index < len) {
                const amt = try s.read(buffer[index..]);
                if (amt == 0) break;
                index += amt;
            }
            return index;
        }

        pub fn write(self: Self, buffer: []const u8) WriteError!usize {
            if (buffer.len == 0) return 0;

            const ctx_ptr: ?*anyopaque = if (self.ctx) |ctx| blk: {
                break :blk ctx.ctx;
            } else blk: {
                break :blk @ptrCast(@constCast(&self.handle));
            };

            return Self.transport.write(ctx_ptr, buffer);
        }

        pub fn writeAll(self: Self, bytes: []const u8) WriteError!void {
            var index: usize = 0;
            while (index < bytes.len) {
                index += try self.write(bytes[index..]);
            }
        }
    };
}
