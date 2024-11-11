const std = @import("std");

const builtin = @import("builtin");
const native_os = builtin.os.tag;
const build_options = @import("build_options");
const secure = if (build_options.tls_enabled) @import("secure.zig") else @import("unsecure.zig");

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

    SSLProtocolError,

    /// This error occurs when no global event loop is configured,
    /// and reading from the file descriptor would block.
    WouldBlock,

    /// In WASI, this error occurs when the file descriptor does
    /// not hold the required rights to read from it.
    AccessDenied,
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
} || std.posix.UnexpectedError;

pub const Stream = struct {
    /// Underlying platform-defined type which may or may not be
    /// interchangeable with a file system file descriptor.
    handle: std.posix.socket_t,
    ctx: ?secure.StreamContext = null,

    pub fn close(self: Stream) void {
        if (self.ctx != null and build_options.tls_enabled) self.ctx.?.deinit();

        switch (native_os) {
            .windows => std.windows.closesocket(self.handle) catch unreachable,
            else => std.posix.close(self.handle),
        }
    }

    pub const Reader = std.io.Reader(Stream, ReadError, read);
    pub const Writer = std.io.Writer(Stream, WriteError, write);

    pub fn reader(self: Stream) Reader {
        return .{ .context = self };
    }

    pub fn writer(self: Stream) Writer {
        return .{ .context = self };
    }

    pub fn read(self: Stream, buffer: []u8) ReadError!usize {
        if (buffer.len == 0) return 0;

        if (self.ctx != null and build_options.tls_enabled) {
            return secure.ssl_read(@ptrCast(self.ctx.?.ctx), buffer);
        }

        if (native_os == .windows) {
            return std.windows.ReadFile(self.handle, buffer, null);
        }

        return std.posix.read(self.handle, buffer);
    }

    /// Returns the number of bytes read. If the number read is smaller than
    /// `buffer.len`, it means the stream reached the end. Reaching the end of
    /// a stream is not an error condition.
    pub fn readAll(s: Stream, buffer: []u8) ReadError!usize {
        return readAtLeast(s, buffer, buffer.len);
    }

    /// Returns the number of bytes read, calling the underlying read function
    /// the minimal number of times until the buffer has at least `len` bytes
    /// filled. If the number read is less than `len` it means the stream
    /// reached the end. Reaching the end of the stream is not an error
    /// condition.
    pub fn readAtLeast(s: Stream, buffer: []u8, len: usize) ReadError!usize {
        std.assert(len <= buffer.len);

        var index: usize = 0;
        while (index < len) {
            const amt = try s.read(buffer[index..]);
            if (amt == 0) break;
            index += amt;
        }
        return index;
    }

    /// TODO in evented I/O mode, this implementation incorrectly uses the event loop's
    /// file system thread instead of non-blocking. It needs to be reworked to properly
    /// use non-blocking I/O.
    pub fn write(self: Stream, buffer: []const u8) WriteError!usize {
        if (buffer.len == 0) return 0;

        if (self.ctx != null and build_options.tls_enabled) {
            return secure.ssl_write(@ptrCast(self.ctx.?.ctx), buffer);
        }

        if (native_os == .windows) {
            return std.windows.WriteFile(self.handle, buffer, null);
        }

        return std.posix.write(self.handle, buffer);
    }

    pub fn writeAll(self: Stream, bytes: []const u8) WriteError!void {
        var index: usize = 0;
        while (index < bytes.len) {
            index += try self.write(bytes[index..]);
        }
    }
};
