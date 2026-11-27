//! Atomically updated runtime counters exposed through the INFO command.

const std = @import("std");

const Metrics = @This();

connections_accepted: std.atomic.Value(usize) = .init(0),
connections_active: std.atomic.Value(usize) = .init(0),
connections_closed: std.atomic.Value(usize) = .init(0),
commands_total: std.atomic.Value(usize) = .init(0),
command_errors_total: std.atomic.Value(usize) = .init(0),
malformed_requests_total: std.atomic.Value(usize) = .init(0),
memory_limit_rejections_total: std.atomic.Value(usize) = .init(0),
request_limit_rejections_total: std.atomic.Value(usize) = .init(0),
response_limit_rejections_total: std.atomic.Value(usize) = .init(0),
read_timeouts_total: std.atomic.Value(usize) = .init(0),
request_bytes_total: std.atomic.Value(usize) = .init(0),
response_bytes_total: std.atomic.Value(usize) = .init(0),
response_batches_total: std.atomic.Value(usize) = .init(0),
write_errors_total: std.atomic.Value(usize) = .init(0),

pub fn connectionOpened(self: *Metrics) void {
    _ = self.connections_accepted.fetchAdd(1, .monotonic);
    _ = self.connections_active.fetchAdd(1, .monotonic);
}

pub fn connectionClosed(self: *Metrics) void {
    _ = self.connections_active.fetchSub(1, .monotonic);
    _ = self.connections_closed.fetchAdd(1, .monotonic);
}

pub fn commandCompleted(self: *Metrics) void {
    _ = self.commands_total.fetchAdd(1, .monotonic);
}

pub fn commandFailed(self: *Metrics, err: anyerror) void {
    _ = self.command_errors_total.fetchAdd(1, .monotonic);
    switch (err) {
        error.Unprocessable, error.InvalidLength, error.InvalidType, error.InvalidKey, error.PayloadExceeded => _ = self.malformed_requests_total.fetchAdd(1, .monotonic),
        error.MemoryLimitExceeded => _ = self.memory_limit_rejections_total.fetchAdd(1, .monotonic),
        error.ResponseTooLarge => _ = self.response_limit_rejections_total.fetchAdd(1, .monotonic),
        else => {},
    }
}

pub fn requestBytes(self: *Metrics, count: usize) void {
    _ = self.request_bytes_total.fetchAdd(count, .monotonic);
}

pub fn requestLimitRejected(self: *Metrics) void {
    _ = self.request_limit_rejections_total.fetchAdd(1, .monotonic);
}

pub fn responseBatch(self: *Metrics, count: usize) void {
    _ = self.response_bytes_total.fetchAdd(count, .monotonic);
    _ = self.response_batches_total.fetchAdd(1, .monotonic);
}

pub fn readTimeout(self: *Metrics) void {
    _ = self.read_timeouts_total.fetchAdd(1, .monotonic);
}

pub fn writeFailed(self: *Metrics) void {
    _ = self.write_errors_total.fetchAdd(1, .monotonic);
}
