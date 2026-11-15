const builtin = @import("builtin");
const std = @import("std");

pub var runtime: std.Io = undefined;

pub fn get() std.Io {
    if (builtin.is_test) return std.testing.io;
    return runtime;
}

pub fn timestamp() i64 {
    return std.Io.Clock.real.now(get()).toSeconds();
}

pub fn timestampNanoseconds() i96 {
    return std.Io.Clock.awake.now(get()).nanoseconds;
}

pub fn sleepNanoseconds(nanoseconds: u64) void {
    get().sleep(.fromNanoseconds(nanoseconds), .awake) catch unreachable;
}
