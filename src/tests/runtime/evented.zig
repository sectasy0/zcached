const std = @import("std");
const Evented = @import("runtime_io").Evented;
const Io = std.Io;
const posix = std.posix;

comptime {
    _ = @import("reactor.zig");
}

test "evented futures and groups run on the reactor thread and cancel sleeps" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    const Work = struct {
        /// Sleeps briefly and returns the thread ID on which its fiber ran.
        fn thread(io_arg: Io) Io.Cancelable!std.Thread.Id {
            try io_arg.sleep(.fromMilliseconds(1), .awake);
            return std.Thread.getCurrentId();
        }
        /// Remains parked until canceled, exercising future cancellation.
        fn block(io_arg: Io) Io.Cancelable!void {
            try io_arg.sleep(.fromSeconds(60), .awake);
        }
        /// Delays and then signals the supplied event.
        fn mark(io_arg: Io, event: *Io.Event) Io.Cancelable!void {
            try io_arg.sleep(.fromMilliseconds(1), .awake);
            event.set(io_arg);
        }
    };
    var thread = try interface.concurrent(Work.thread, .{interface});
    defer _ = thread.cancel(interface) catch {};
    var blocked = try interface.concurrent(Work.block, .{interface});
    defer blocked.cancel(interface) catch {};
    var event: Io.Event = .unset;
    var group: Io.Group = .init;
    defer group.cancel(interface);
    try group.concurrent(interface, Work.mark, .{ interface, &event });
    try event.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try group.await(interface);
    try std.testing.expectEqual(backend.owner, try thread.await(interface));
    try std.testing.expectError(error.Canceled, blocked.cancel(interface));
}

test "evented TCP accept, connect, streaming and batch timeout" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(interface, .{ .reuse_address = true });
    defer listener.deinit(interface);
    var accepted = try interface.concurrent(Io.net.Server.accept, .{ &listener, interface });
    defer if (accepted.cancel(interface)) |stream| stream.close(interface) else |err| {
        if (err != error.Canceled) @panic(@errorName(err));
    };
    const client = try listener.socket.address.connect(interface, .{ .mode = .stream });
    defer client.close(interface);
    const peer = try accepted.await(interface);
    const sent = try interface.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &.{"hello"} } });
    try std.testing.expectEqual(@as(usize, 5), try sent.net_write);
    var bytes: [8]u8 = undefined;
    var buffers = [_][]u8{&bytes};
    try std.testing.expectEqual(@as(usize, 5), try peer.read(interface, &buffers));
    try std.testing.expectEqualStrings("hello", bytes[0..5]);
    const ForeignWriter = struct {
        /// Writes from a foreign thread through the evented interface.
        fn run(io_arg: Io, stream: Io.net.Stream) void {
            var writer = stream.writer(io_arg, &.{});
            writer.interface.writeAll("thread") catch |err| @panic(@errorName(err));
        }
    };
    const foreign_thread = try std.Thread.spawn(.{}, ForeignWriter.run, .{ interface, client });
    defer foreign_thread.join();
    try std.testing.expectEqual(@as(usize, 6), try peer.read(interface, &buffers));
    try std.testing.expectEqualStrings("thread", bytes[0..6]);
    try std.testing.expectError(error.Timeout, interface.operateTimeout(.{ .net_read = .{ .socket_handle = peer.socket.handle, .data = &buffers } }, .{ .duration = .{ .raw = .fromMilliseconds(2), .clock = .awake } }));
    var writer = client.writer(interface, &.{});
    try writer.interface.writeAll("r");
    const retry = try interface.operateTimeout(.{ .net_read = .{
        .socket_handle = peer.socket.handle,
        .data = &buffers,
    } }, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try std.testing.expectEqualStrings("r", bytes[0..(try retry.net_read).data_len]);
    const Writer = struct {
        /// Repeatedly fills the socket until cancellation interrupts the write.
        fn run(io_arg: Io, fd: posix.fd_t) !void {
            const payload: [65536]u8 = @splat(0);
            while (true) _ = try (try io_arg.operate(.{ .net_write = .{ .socket_handle = fd, .data = &.{&payload} } })).net_write;
        }
    };
    var writing = try interface.concurrent(Writer.run, .{ interface, client.socket.handle });
    try interface.sleep(.fromMilliseconds(2), .awake);
    try std.testing.expectError(error.Canceled, writing.cancel(interface));
    const ReadyWriter = struct {
        /// Repeats zero-byte writes to exercise cancellation while always ready.
        fn run(io_arg: Io, fd: posix.fd_t) !void {
            while (true) _ = try (try io_arg.operate(.{ .net_write = .{ .socket_handle = fd, .data = &.{""} } })).net_write;
        }
    };
    var ready_writer = try interface.concurrent(ReadyWriter.run, .{ interface, client.socket.handle });
    try interface.sleep(.fromMilliseconds(2), .awake);
    try std.testing.expectError(error.Canceled, ready_writer.cancel(interface));
    var pending = try interface.concurrent(Io.net.Server.accept, .{ &listener, interface });
    try interface.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expectError(error.Canceled, pending.cancel(interface));
}

test "evented futex wakeups interoperate with an external queue thread" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    var semaphore: Io.Semaphore = .{};
    const Producer = struct {
        /// Posts all semaphore tokens from a non-owner thread.
        fn run(io_arg: Io, sem: *Io.Semaphore) void {
            for (0..2000) |_| sem.post(io_arg);
        }
    };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{ interface, &semaphore });
    defer thread.join();
    for (0..2000) |_| try semaphore.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
}

test "evented synchronization wakes fibers on another reactor thread" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    const Shared = struct {
        /// Signals that the peer backend is ready to exchange semaphore tokens.
        ready: Io.Event = .unset,
        /// Requests work from the peer thread.
        request: Io.Semaphore = .{},
        /// Acknowledges one completed peer update.
        response: Io.Semaphore = .{},
        /// Protects the shared update count.
        mutex: Io.Mutex = .init,
        /// Number of updates performed by both threads.
        count: usize = 0,
        /// Captures a failure from the worker thread for the test thread.
        failure: ?anyerror = null,

        /// Runs peer work and records any error for the owning test.
        fn run(self: *@This()) void {
            self.work() catch |err| {
                self.failure = err;
            };
        }

        /// Creates a peer backend and participates in the synchronized exchange.
        fn work(self: *@This()) !void {
            var peer: Evented = undefined;
            try peer.init(std.testing.allocator);
            defer peer.deinit();
            const io_arg = peer.io();
            self.ready.set(io_arg);
            for (0..2000) |_| {
                try self.request.waitTimeout(io_arg, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
                self.mutex.lockUncancelable(io_arg);
                self.count += 1;
                self.mutex.unlock(io_arg);
                self.response.post(io_arg);
            }
        }
    };
    var shared: Shared = .{};
    {
        const thread = try std.Thread.spawn(.{}, Shared.run, .{&shared});
        defer thread.join();
        try shared.ready.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        for (0..2000) |_| {
            shared.mutex.lockUncancelable(interface);
            shared.count += 1;
            shared.mutex.unlock(interface);
            shared.request.post(interface);
            try shared.response.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        }
    }
    if (shared.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 4000), shared.count);
}

test "evented completed group members release stacks before the group is canceled" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    var group: Io.Group = .init;
    defer group.cancel(interface);
    var count: usize = 0;
    var completed: Io.Event = .unset;
    const Work = struct {
        /// Parks until group cancellation reaches this task.
        fn block(io_arg: Io) Io.Cancelable!void {
            try io_arg.sleep(.fromSeconds(60), .awake);
        }
        /// Increments completion count and signals when all short tasks finish.
        fn finish(io_arg: Io, n: *usize, event: *Io.Event) void {
            n.* += 1;
            if (n.* == 32) event.set(io_arg);
        }
    };
    try group.concurrent(interface, Work.block, .{interface});
    for (0..32) |_| try group.concurrent(interface, Work.finish, .{ interface, &count, &completed });
    try completed.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try std.testing.expect(backend.fibers != null);
    try std.testing.expect(backend.fibers.?.next == null);
    group.cancel(interface);
    try std.testing.expect(backend.fibers == null);
}

test "evented cancellation protection, cleanup and recancel" {
    var backend: Evented = undefined;
    try backend.init(std.testing.allocator);
    defer backend.deinit();
    const interface = backend.io();
    var entered: Io.Event = .unset;
    var cleaned = false;
    const Work = struct {
        /// Tests shielding, cleanup, and redelivery of cancellation.
        fn run(io_arg: Io, event: *Io.Event, cleanup: *bool) !void {
            defer cleanup.* = true;
            const previous = io_arg.swapCancelProtection(.blocked);
            defer _ = io_arg.swapCancelProtection(previous);
            event.set(io_arg);
            try io_arg.sleep(.fromMilliseconds(2), .awake);
            _ = io_arg.swapCancelProtection(previous);
            try std.testing.expectError(error.Canceled, io_arg.checkCancel());
            try io_arg.checkCancel();
            io_arg.recancel();
            try std.testing.expectError(error.Canceled, io_arg.checkCancel());
        }
    };
    var future = try interface.concurrent(Work.run, .{ interface, &entered, &cleaned });
    defer future.cancel(interface) catch |err| @panic(@errorName(err));
    try entered.waitTimeout(interface, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try future.cancel(interface);
    try std.testing.expect(cleaned);
}
