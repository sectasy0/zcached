const std = @import("std");
const runtime_io = @import("runtime_io");

const Io = std.Io;

pub const path = Io.Dir.path;

pub const File = struct {
    inner: Io.File,

    pub const Kind = Io.File.Kind;
    pub const Lock = Io.File.Lock;

    pub fn stdout() File {
        return .{ .inner = Io.File.stdout() };
    }

    pub fn stderr() File {
        return .{ .inner = Io.File.stderr() };
    }

    pub fn close(self: File) void {
        self.inner.close(runtime_io.get());
    }

    pub fn stat(self: File) !Io.File.Stat {
        return self.inner.stat(runtime_io.get());
    }

    pub fn read(self: File, buffer: []u8) !usize {
        var data: [1][]u8 = .{buffer};
        return self.inner.readStreaming(runtime_io.get(), &data);
    }

    pub fn readAll(self: File, buffer: []u8) !usize {
        var total: usize = 0;
        while (total < buffer.len) {
            const count = try self.read(buffer[total..]);
            if (count == 0) break;
            total += count;
        }
        return total;
    }

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

    pub fn writeAll(self: File, bytes: []const u8) !void {
        try self.inner.writeStreamingAll(runtime_io.get(), bytes);
    }

    pub fn write(self: File, bytes: []const u8) !usize {
        return self.inner.writeStreaming(runtime_io.get(), &.{}, &.{bytes}, 1);
    }

    pub fn writer(self: File, buffer: []u8) Io.File.Writer {
        return self.inner.writerStreaming(runtime_io.get(), buffer);
    }

    pub fn seekFromEnd(self: File, offset: i64) !void {
        const io = runtime_io.get();
        const size = (try self.inner.stat(io)).size;
        const target = @as(i128, size) + offset;
        if (target < 0) return error.InvalidArgument;
        try io.vtable.fileSeekTo(io.userdata, self.inner, @intCast(target));
    }

    pub fn lock(self: File, lock_type: Lock) !void {
        try self.inner.lock(runtime_io.get(), lock_type);
    }

    pub fn unlock(self: File) void {
        self.inner.unlock(runtime_io.get());
    }
};

pub const Dir = struct {
    inner: Io.Dir,

    pub const Entry = Io.Dir.Entry;
    pub const OpenOptions = Io.Dir.OpenOptions;
    pub const OpenFileOptions = Io.Dir.OpenFileOptions;
    pub const CreateFileOptions = Io.Dir.CreateFileOptions;

    pub fn close(self: Dir) void {
        self.inner.close(runtime_io.get());
    }

    pub fn openFile(self: Dir, path_arg: []const u8, options: OpenFileOptions) !File {
        return .{ .inner = try self.inner.openFile(runtime_io.get(), path_arg, options) };
    }

    pub fn createFile(self: Dir, path_arg: []const u8, options: CreateFileOptions) !File {
        return .{ .inner = try self.inner.createFile(runtime_io.get(), path_arg, options) };
    }

    pub fn openDir(self: Dir, path_arg: []const u8, options: OpenOptions) !Dir {
        return .{ .inner = try self.inner.openDir(runtime_io.get(), path_arg, options) };
    }

    pub fn iterate(self: Dir) Iterator {
        return .{ .inner = self.inner.iterate() };
    }

    pub fn makeDir(self: Dir, path_arg: []const u8) !void {
        try self.inner.createDir(runtime_io.get(), path_arg, .default_dir);
    }

    pub fn makePath(self: Dir, path_arg: []const u8) !void {
        try self.inner.createDirPath(runtime_io.get(), path_arg);
    }

    pub fn deleteFile(self: Dir, path_arg: []const u8) !void {
        try self.inner.deleteFile(runtime_io.get(), path_arg);
    }

    pub fn deleteDir(self: Dir, path_arg: []const u8) !void {
        try self.inner.deleteDir(runtime_io.get(), path_arg);
    }

    pub fn deleteTree(self: Dir, path_arg: []const u8) !void {
        try self.inner.deleteTree(runtime_io.get(), path_arg);
    }

    pub fn realpathAlloc(self: Dir, allocator: std.mem.Allocator, path_arg: []const u8) ![:0]u8 {
        return self.inner.realPathFileAlloc(runtime_io.get(), path_arg, allocator);
    }

    pub fn statFile(self: Dir, path_arg: []const u8) !Io.File.Stat {
        return self.inner.statFile(runtime_io.get(), path_arg, .{});
    }

    pub fn rename(self: Dir, old_path: []const u8, new_path: []const u8) !void {
        try self.inner.rename(old_path, self.inner, new_path, runtime_io.get());
    }

    pub const Iterator = struct {
        inner: Io.Dir.Iterator,

        pub fn next(self: *Iterator) !?Entry {
            return self.inner.next(runtime_io.get());
        }
    };
};

pub fn cwd() Dir {
    return .{ .inner = .cwd() };
}
