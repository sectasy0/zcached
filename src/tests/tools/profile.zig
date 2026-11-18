const std = @import("std");
const profile = @import("profile");
const parseOptions = profile.parseOptions;

test "profile options validate workload and recording bounds" {
    const options = try parseOptions(&.{ "profile", "--duration", "5", "--clients", "2", "--requests", "10", "--pipeline", "3", "--value-size", "16384", "--output", "/tmp/profile-test" });
    try std.testing.expectEqual(@as(u32, 5), options.duration);
    try std.testing.expectEqual(@as(usize, 3), options.pipeline);
    try std.testing.expectEqual(@as(usize, 16384), options.value_size);
    try std.testing.expectError(error.InvalidOptionValue, parseOptions(&.{ "profile", "--pipeline", "0" }));
    try std.testing.expectError(error.InvalidOptionValue, parseOptions(&.{ "profile", "--clients", "129" }));
    try std.testing.expectError(error.InvalidOptionValue, parseOptions(&.{ "profile", "--value-size", "1048577" }));
    try std.testing.expectError(error.InvalidRequestCount, parseOptions(&.{ "profile", "--requests", "3" }));
    try std.testing.expectError(error.TimeoutTooShort, parseOptions(&.{ "profile", "--duration", "30", "--timeout", "30" }));
    try std.testing.expectError(error.MissingOptionValue, parseOptions(&.{ "profile", "--output" }));
    try std.testing.expectError(error.UnknownOption, parseOptions(&.{ "profile", "--unknown", "1" }));
}

test "canceling process monitoring preserves ownership for cleanup" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "60" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    const pid = child.id.?;
    var started: std.Io.Event = .unset;
    // Isolates child monitoring in a task and signals when cancellation is safe.
    const Monitor = struct {
        /// Announces entry before waiting so the test can reliably cancel the monitor.
        fn run(process: *std.process.Child, interface: std.Io, ready: *std.Io.Event) !std.process.Child.Term {
            ready.set(interface);
            return profile.waitChild(process, interface);
        }
    };
    var future = try io.concurrent(Monitor.run, .{ &child, io, &started });
    started.waitUncancelable(io);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expectEqual(@as(?std.process.Child.Id, pid), child.id);
}
