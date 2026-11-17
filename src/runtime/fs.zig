//! File and directory conveniences bound to the runtime's current I/O interface.
//! Handles own their underlying resources and must be closed; operations return
//! platform errors unless their signatures are infallible.
const std = @import("std");
const runtime_io = @import("runtime_io");

const Io = std.Io;

/// Standard-library path utilities used with directory handles.
pub const path = Io.Dir.path;

/// An open file handle whose operations use the current runtime I/O interface.
pub const File = struct {
    /// The standard-library file handle; closing this wrapper closes the handle.
    inner: Io.File,

    /// File kind values reported by the standard library.
    pub const Kind = Io.File.Kind;
    /// Advisory lock modes supported by the standard-library file API.
    pub const Lock = Io.File.Lock;

    /// Returns a wrapper for the process standard-output handle.
    pub fn stdout() File {
        return .{ .inner = Io.File.stdout() };
    }

    /// Returns a wrapper for the process standard-error handle.
    pub fn stderr() File {
        return .{ .inner = Io.File.stderr() };
    }

    /// Closes the underlying handle; this wrapper must not be used afterward.
    pub fn close(self: File) void {
        self.inner.close(runtime_io.get());
    }

    /// Reads file metadata, propagating operating-system errors.
    pub fn stat(self: File) !Io.File.Stat {
        return self.inner.stat(runtime_io.get());
    }

    /// Reads at most `buffer.len` bytes from the current file position.
    pub fn read(self: File, buffer: []u8) !usize {
        var data: [1][]u8 = .{buffer};
        return self.inner.readStreaming(runtime_io.get(), &data);
    }

    /// Reads until the buffer fills or end-of-file; returns the bytes read.
    pub fn readAll(self: File, buffer: []u8) !usize {
        var total: usize = 0;
        while (total < buffer.len) {
            const count = try self.read(buffer[total..]);
            if (count == 0) break;
            total += count;
        }
        return total;
    }

    /// Allocates and positionally reads up to `max_bytes` starting at `offset`.
    /// The returned slice is owned by `allocator`; an optional sentinel is
    /// written after the data, and allocation/read failures are returned.
    pub fn readToEndAllocOptions(
        self: File,
        allocator: std.mem.Allocator,
        max_bytes: usize,
        comptime sentinel: ?u8,
        comptime alignment: std.mem.Alignment,
        offset: usize,
    ) !if (sentinel) |value| [:value]align(alignment.toByteUnits()) u8 else []align(alignment.toByteUnits()) u8 {
        const io = runtime_io.get();
        const size = @min((try self.inner.stat(io)).size, max_bytes);
        const len: usize = @intCast(size);
        const extra: usize = if (sentinel == null) 0 else 1;
        const buffer = try allocator.alignedAlloc(u8, alignment, len + extra);
        const read_count = try self.inner.readPositionalAll(io, buffer[0..len], offset);
        if (sentinel) |value| {
            buffer[read_count] = value;
            return buffer[0..read_count :value];
        }
        return buffer[0..read_count];
    }

    /// Writes all bytes, retrying or suspending as required by the active I/O.
    pub fn writeAll(self: File, bytes: []const u8) !void {
        try self.inner.writeStreamingAll(runtime_io.get(), bytes);
    }

    /// Writes one streaming chunk and returns the number of bytes accepted.
    pub fn write(self: File, bytes: []const u8) !usize {
        return self.inner.writeStreaming(runtime_io.get(), &.{}, &.{bytes}, 1);
    }

    /// Creates a streaming writer using caller-owned scratch storage.
    pub fn writer(self: File, buffer: []u8) Io.File.Writer {
        return self.inner.writerStreaming(runtime_io.get(), buffer);
    }

    /// Seeks to `offset` bytes relative to end-of-file; negative targets fail.
    pub fn seekFromEnd(self: File, offset: i64) !void {
        const io = runtime_io.get();
        const size = (try self.inner.stat(io)).size;
        const target = @as(i128, size) + offset;
        if (target < 0) return error.InvalidArgument;
        try io.vtable.fileSeekTo(io.userdata, self.inner, @intCast(target));
    }

    /// Acquires the requested file lock, potentially waiting through runtime I/O.
    pub fn lock(self: File, lock_type: Lock) !void {
        try self.inner.lock(runtime_io.get(), lock_type);
    }

    /// Releases the file lock held through this handle.
    pub fn unlock(self: File) void {
        self.inner.unlock(runtime_io.get());
    }
};

/// An open directory handle used for relative filesystem operations.
pub const Dir = struct {
    /// The standard-library directory handle; closing this wrapper closes it.
    inner: Io.Dir,

    /// One directory entry returned by iteration.
    pub const Entry = Io.Dir.Entry;
    /// Options for opening child directories.
    pub const OpenOptions = Io.Dir.OpenOptions;
    /// Options for opening existing files.
    pub const OpenFileOptions = Io.Dir.OpenFileOptions;
    /// Options for creating files.
    pub const CreateFileOptions = Io.Dir.CreateFileOptions;

    /// Closes the directory handle; do not use this wrapper afterward.
    pub fn close(self: Dir) void {
        self.inner.close(runtime_io.get());
    }

    /// Opens a file relative to this directory and transfers handle ownership.
    pub fn openFile(self: Dir, path_arg: []const u8, options: OpenFileOptions) !File {
        return .{ .inner = try self.inner.openFile(runtime_io.get(), path_arg, options) };
    }

    /// Creates or opens a file relative to this directory.
    pub fn createFile(self: Dir, path_arg: []const u8, options: CreateFileOptions) !File {
        return .{ .inner = try self.inner.createFile(runtime_io.get(), path_arg, options) };
    }

    /// Opens a child directory relative to this directory.
    pub fn openDir(self: Dir, path_arg: []const u8, options: OpenOptions) !Dir {
        return .{ .inner = try self.inner.openDir(runtime_io.get(), path_arg, options) };
    }

    /// Starts iteration over this directory; the iterator borrows its handle.
    pub fn iterate(self: Dir) Iterator {
        return .{ .inner = self.inner.iterate() };
    }

    /// Creates a single directory with the runtime's default permissions.
    pub fn makeDir(self: Dir, path_arg: []const u8) !void {
        try self.inner.createDir(runtime_io.get(), path_arg, .default_dir);
    }

    /// Creates the path and any missing parent directories.
    pub fn makePath(self: Dir, path_arg: []const u8) !void {
        try self.inner.createDirPath(runtime_io.get(), path_arg);
    }

    /// Removes a file relative to this directory.
    pub fn deleteFile(self: Dir, path_arg: []const u8) !void {
        try self.inner.deleteFile(runtime_io.get(), path_arg);
    }

    /// Removes an empty child directory.
    pub fn deleteDir(self: Dir, path_arg: []const u8) !void {
        try self.inner.deleteDir(runtime_io.get(), path_arg);
    }

    /// Recursively removes a tree beneath this directory.
    pub fn deleteTree(self: Dir, path_arg: []const u8) !void {
        try self.inner.deleteTree(runtime_io.get(), path_arg);
    }

    /// Resolves a path and allocates its NUL-terminated absolute form.
    pub fn realpathAlloc(self: Dir, allocator: std.mem.Allocator, path_arg: []const u8) ![:0]u8 {
        return self.inner.realPathFileAlloc(runtime_io.get(), path_arg, allocator);
    }

    /// Returns metadata for a path relative to this directory.
    pub fn statFile(self: Dir, path_arg: []const u8) !Io.File.Stat {
        return self.inner.statFile(runtime_io.get(), path_arg, .{});
    }

    /// Renames a child path within this directory.
    pub fn rename(self: Dir, old_path: []const u8, new_path: []const u8) !void {
        try self.inner.rename(old_path, self.inner, new_path, runtime_io.get());
    }

    /// A stateful iterator borrowing the open directory handle.
    pub const Iterator = struct {
        /// The standard-library iterator state.
        inner: Io.Dir.Iterator,

        /// Returns the next entry, or `null` at end-of-directory.
        pub fn next(self: *Iterator) !?Entry {
            return self.inner.next(runtime_io.get());
        }
    };
};

/// Returns a wrapper for the process current working directory.
pub fn cwd() Dir {
    return .{ .inner = .cwd() };
}
