//! Owner-thread-only, one-shot readiness reactor.
//! Architectural reference: Bun/TigerBeetle's completion queues and kqueue
//! EV_ONESHOT at oven-sh/bun e14a3af491ece8d1b0309e76ae3022b4fad91f16/src/io.
//! That Bun revision is MIT-licensed (README.md, "License"). This is an
//! independent implementation using std APIs; no Bun source is copied.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Reactor = @This();

pub const Interest = enum { read, write };
pub const Key = struct { fd: std.posix.fd_t, interest: Interest };

const Watch = struct { id: u64, ready: bool = false };
const Native = switch (builtin.os.tag) {
    .macos => std.posix.fd_t,
    .linux => linux.IoUring,
    else => @compileError("The native reactor supports macOS and Linux only"),
};

allocator: std.mem.Allocator,
native: Native,
watches: std.AutoHashMapUnmanaged(Key, Watch) = .empty,
generations: std.AutoHashMapUnmanaged(u64, Key) = .empty,
next_id: u64 = 1,

pub fn init(allocator: std.mem.Allocator) !Reactor {
    const native = if (builtin.os.tag == .macos) blk: {
        while (true) {
            const fd = std.c.kqueue();
            if (fd >= 0) break :blk fd;
            const err = std.posix.errno(fd);
            if (err == .INTR) continue;
            return nativeError(err);
        }
    } else blk: {
        var ring = try linux.IoUring.init(256, 0);
        errdefer ring.deinit();
        // EXT_ARG has syscall-scoped timeout storage, unlike an async SQE.
        // NODROP ensures CQ pressure never silently loses a one-shot watch.
        if (ring.features & linux.IORING_FEAT_EXT_ARG == 0)
            return error.IoUringTimedWaitUnsupported;
        if (ring.features & linux.IORING_FEAT_NODROP == 0)
            return error.IoUringNoDropUnsupported;
        break :blk ring;
    };
    return .{ .allocator = allocator, .native = native };
}

pub fn deinit(self: *Reactor) void {
    if (builtin.os.tag == .macos) {
        const rc = std.c.close(self.native);
        if (rc != 0) std.log.err("reactor close: {t}", .{std.posix.errno(rc)});
    } else {
        // poll_add/remove carry only integer IDs, never userspace pointers.
        self.native.deinit();
    }
    self.watches.deinit(self.allocator);
    self.generations.deinit(self.allocator);
    self.* = undefined;
}

pub fn arm(self: *Reactor, key: Key) !void {
    if (self.watches.contains(key)) return;
    if (key.fd < 0) return error.FileDescriptorInvalid;
    if (self.next_id == std.math.maxInt(u64)) return error.GenerationExhausted;
    const id = self.next_id;
    self.next_id += 1;
    try self.watches.ensureUnusedCapacity(self.allocator, 1);
    try self.generations.ensureUnusedCapacity(self.allocator, 1);
    if (builtin.os.tag == .macos) {
        try self.change(key, id, std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT);
    } else {
        const mask: u32 = (if (key.interest == .read) @as(u32, linux.POLL.IN) else @as(u32, linux.POLL.OUT)) |
            linux.POLL.ERR | linux.POLL.HUP;
        while (true) {
            _ = self.native.poll_add(id, key.fd, mask) catch |err| switch (err) {
                error.SubmissionQueueFull => {
                    try self.flush();
                    continue;
                },
            };
            break;
        }
    }
    self.watches.putAssumeCapacity(key, .{ .id = id });
    self.generations.putAssumeCapacity(id, key);
}

pub fn disarm(self: *Reactor, key: Key) !void {
    const watch = self.watches.get(key) orelse return;
    if (builtin.os.tag == .macos) {
        self.change(key, watch.id, std.c.EV.DELETE) catch |err| switch (err) {
            // A closed fd or an already-emitted EV_ONESHOT is already deleted.
            error.FileNotFound, error.FileDescriptorInvalid => {},
            else => return err,
        };
    } else if (!watch.ready) {
        while (true) {
            _ = self.native.poll_remove(0, watch.id) catch |err| switch (err) {
                error.SubmissionQueueFull => {
                    try self.flush();
                    continue;
                },
            };
            break;
        }
    }
    _ = self.watches.remove(key);
    _ = self.generations.remove(watch.id);
}

/// A zero timeout is nonblocking; null waits indefinitely. Empty output is an
/// immediate no-op. Readiness, including EOF/ERR, is removed only when emitted.
pub fn wait(self: *Reactor, events: []Key, timeout_ns: ?u64) !usize {
    if (events.len == 0) return 0;
    const deadline: ?u64 = if (timeout_ns) |ns| (try monotonic()) +| ns else null;
    if (builtin.os.tag == .macos) return self.waitKqueue(events, deadline);
    try self.flush();
    var entered = false;
    while (true) {
        _ = try self.drain();
        const count = self.emit(events);
        if (count != 0) return count;
        const remaining: ?u64 = if (deadline) |end| end -| try monotonic() else null;
        if (remaining == 0 and entered) return 0;
        try self.enterWait(remaining);
        entered = true;
    }
}

fn emit(self: *Reactor, events: []Key) usize {
    var count: usize = 0;
    var it = self.watches.iterator();
    while (it.next()) |entry| {
        if (!entry.value_ptr.ready) continue;
        events[count] = entry.key_ptr.*;
        count += 1;
        if (count == events.len) break;
    }
    // Removing after iteration avoids invalidating the iterator.
    for (events[0..count]) |key| {
        const watch = self.watches.fetchRemove(key).?.value;
        _ = self.generations.remove(watch.id);
    }
    return count;
}

fn change(self: *Reactor, key: Key, id: u64, flags: u16) !void {
    const changes = [1]std.c.Kevent{.{
        .ident = @intCast(key.fd),
        .filter = if (key.interest == .read) std.c.EVFILT.READ else std.c.EVFILT.WRITE,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = @intCast(id),
    }};
    var unused: [0]std.c.Kevent = .{};
    while (true) {
        const rc = std.c.kevent(self.native, &changes, 1, &unused, 0, null);
        if (rc >= 0) return;
        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        return nativeError(err);
    }
}

fn waitKqueue(self: *Reactor, events: []Key, deadline: ?u64) !usize {
    var native_events: [128]std.c.Kevent = undefined;
    const changes: [0]std.c.Kevent = .{};
    while (true) {
        var ts: std.c.timespec = undefined;
        if (deadline) |end| {
            const ns = end -| try monotonic();
            ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
        }
        const rc = std.c.kevent(self.native, &changes, 0, &native_events, @intCast(@min(events.len, native_events.len)), if (deadline != null) &ts else null);
        if (rc < 0) {
            const err = std.posix.errno(rc);
            if (err == .INTR) continue;
            return nativeError(err);
        }
        var count: usize = 0;
        for (native_events[0..@intCast(rc)]) |event| {
            const key = self.generations.get(event.udata) orelse continue;
            // EV_EOF and EV_ERROR are deliberately not filtered out.
            events[count] = key;
            count += 1;
            _ = self.watches.remove(key);
            _ = self.generations.remove(event.udata);
        }
        if (count != 0 or rc == 0) return count;
        if (deadline) |end| {
            if (try monotonic() >= end) return 0;
        }
    }
}

fn flush(self: *Reactor) !void {
    _ = self.native.flush_sq();
    while (self.native.sq_ready() != 0) {
        _ = self.native.submit() catch |err| switch (err) {
            error.SignalInterrupt => continue,
            error.CompletionQueueOvercommitted, error.SystemResources => {
                // Preserve readiness under CQ pressure rather than discarding it.
                if (try self.drain() == 0) return err;
                continue;
            },
            else => return err,
        };
    }
}

fn drain(self: *Reactor) !usize {
    var cqes: [128]linux.io_uring_cqe = undefined;
    var total: usize = 0;
    while (true) {
        const count = self.native.copy_cqes(&cqes, 0) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        total += count;
        for (cqes[0..count]) |cqe| try self.complete(cqe);
        if (count < cqes.len) return total;
    }
}

fn complete(self: *Reactor, cqe: linux.io_uring_cqe) !void {
    if (cqe.user_data == 0) {
        // A poll may win its race with cancellation (ENOENT/EALREADY).
        if (cqe.res == 0 or cqe.res == -@as(i32, @backingInt(linux.E.NOENT)) or
            cqe.res == -@as(i32, @backingInt(linux.E.ALREADY))) return;
        std.log.err("reactor poll_remove completion: {d}", .{cqe.res});
        return error.PollRemoveFailed;
    }
    const key = self.generations.get(cqe.user_data) orelse {
        // Only a canceled or previously completed generation may be stale.
        if (cqe.res >= 0 or cqe.res == -@as(i32, @backingInt(linux.E.CANCELED))) return;
        std.log.err("reactor stale poll completion {d}: {d}", .{ cqe.user_data, cqe.res });
        return error.PollFailed;
    };
    if (cqe.res < 0 and cqe.res != -@as(i32, @backingInt(linux.E.BADF))) {
        std.log.err("reactor poll completion {d}: {d}", .{ cqe.user_data, cqe.res });
        return error.PollFailed;
    }
    self.watches.getPtr(key).?.ready = true;
    _ = self.generations.remove(cqe.user_data);
}

fn enterWait(self: *Reactor, remaining: ?u64) !void {
    var ts: linux.kernel_timespec = undefined;
    var arg: linux.io_uring_getevents_arg = .{ .sigmask = 0, .sigmask_sz = 0, .pad = 0, .ts = 0 };
    var flags: u32 = linux.IORING_ENTER_GETEVENTS;
    if (remaining) |ns| {
        ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
        arg.ts = @intFromPtr(&ts);
        flags |= linux.IORING_ENTER_EXT_ARG;
    }
    const rc = linux.syscall6(.io_uring_enter, @as(u32, @bitCast(self.native.fd)), 0, if (remaining == 0) 0 else 1, flags, if (remaining != null) @intFromPtr(&arg) else 0, if (remaining != null) @sizeOf(linux.io_uring_getevents_arg) else 0);
    switch (linux.errno(rc)) {
        .SUCCESS, .TIME, .INTR => return, // outer loop recomputes the deadline
        else => |err| return nativeError(err),
    }
}

fn monotonic() !u64 {
    var ts: std.c.timespec = undefined;
    if (builtin.os.tag == .linux) {
        const rc = linux.clock_gettime(.MONOTONIC, &ts);
        if (linux.errno(rc) != .SUCCESS) return nativeError(linux.errno(rc));
    } else {
        while (true) {
            const rc = std.c.clock_gettime(.MONOTONIC, &ts);
            if (rc == 0) break;
            const err = std.posix.errno(rc);
            if (err == .INTR) continue;
            return nativeError(err);
        }
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn nativeError(err: std.posix.E) anyerror {
    return switch (err) {
        .BADF => error.FileDescriptorInvalid,
        .NOENT => error.FileNotFound,
        .NOMEM, .NOBUFS, .AGAIN => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .PERM, .ACCES => error.PermissionDenied,
        .INVAL => error.InvalidArgument,
        .NOSYS => error.SystemOutdated,
        else => blk: {
            std.log.err("reactor native syscall: {t}", .{err});
            break :blk error.Unexpected;
        },
    };
}

fn testPipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return nativeError(std.posix.errno(-1));
    return fds;
}

test "one-shot duplicate arm, rearm, disarm, and EOF" {
    var reactor = try init(std.testing.allocator);
    defer reactor.deinit();
    const fds = try testPipe();
    defer _ = std.c.close(fds[0]);
    var writer_open = true;
    defer if (writer_open) {
        _ = std.c.close(fds[1]);
    };
    const key: Key = .{ .fd = fds[0], .interest = .read };
    var events: [4]Key = undefined;
    try reactor.arm(key);
    try reactor.arm(key);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 0));
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    try std.testing.expectEqual(key, events[0]);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 0));
    try reactor.arm(key);
    try reactor.disarm(key);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 0));
    try reactor.arm(key);
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(fds[0], &byte, 1));
    _ = std.c.close(fds[1]);
    writer_open = false;
    try reactor.arm(key);
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    try std.testing.expectEqual(@as(isize, 0), std.c.read(fds[0], &byte, 1));
}

test "bounded wait and output capacity preserve watches" {
    var reactor = try init(std.testing.allocator);
    defer reactor.deinit();
    const fds = try testPipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const read: Key = .{ .fd = fds[0], .interest = .read };
    const write: Key = .{ .fd = fds[1], .interest = .write };
    var events: [1]Key = undefined;
    try reactor.arm(read);
    const start = try monotonic();
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 5 * std.time.ns_per_ms));
    const elapsed = (try monotonic()) - start;
    try std.testing.expect(elapsed >= 5 * std.time.ns_per_ms);
    try std.testing.expect(elapsed < std.time.ns_per_s);
    try reactor.arm(write);
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    const first = events[0];
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    try std.testing.expect(first.interest != events[0].interest);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 0));
}

test "rapid cancellation generations never deliver an old watch" {
    var reactor = try init(std.testing.allocator);
    defer reactor.deinit();
    const fds = try testPipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const key: Key = .{ .fd = fds[0], .interest = .read };
    for (0..600) |_| {
        try reactor.arm(key);
        try reactor.disarm(key);
    }
    try reactor.arm(key);
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    var events: [1]Key = undefined;
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    try std.testing.expectEqual(key, events[0]);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 0));
}
