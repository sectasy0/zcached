const std = @import("std");
const benchmark = @import("benchmark");
const parseOptions = benchmark.parseOptions;
const isGet = benchmark.isGet;
const percentile = benchmark.percentile;

test "benchmark parses pipelining payload size and custom client count" {
    const options = try parseOptions(&.{ "benchmark", "--mode", "ram", "--pipeline", "64", "--value-size", "16384", "--clients", "32", "--requests", "10002" });
    try std.testing.expectEqual(@as(usize, 64), options.pipeline);
    try std.testing.expectEqual(@as(usize, 16384), options.value_size);
    try std.testing.expectEqual(@as(?usize, 32), options.clients);
    try std.testing.expectEqual(@as(usize, 10002), options.requests);
    for ([_][:0]const u8{ "0", "4097" }) |value| {
        try std.testing.expectError(error.InvalidPipeline, parseOptions(&.{ "benchmark", "--mode", "ram", "--pipeline", value }));
    }
    for ([_][:0]const u8{ "0", "1048577" }) |value| {
        try std.testing.expectError(error.InvalidValueSize, parseOptions(&.{ "benchmark", "--mode", "ram", "--value-size", value }));
    }
    for ([_][:0]const u8{ "0", "129" }) |value| {
        try std.testing.expectError(error.InvalidClientCount, parseOptions(&.{ "benchmark", "--mode", "ram", "--clients", value }));
    }
}

test "mixed workload is exactly balanced" {
    var gets: usize = 0;
    for (0..100) |i| gets += @intFromBool(isGet(.mixed, i));
    try std.testing.expectEqual(50, gets);
    try std.testing.expect(isGet(.get, 1));
    try std.testing.expect(!isGet(.set, 0));
    try std.testing.expect(!isGet(.persistence, 0));
}

test "nearest-rank latency percentiles" {
    const samples = [_]u64{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(3, percentile(&samples, 50));
    try std.testing.expectEqual(5, percentile(&samples, 95));
    try std.testing.expectEqual(5, percentile(&samples, 99));
}

test "benchmark options require mode and an even request count" {
    try std.testing.expectError(error.MissingMode, parseOptions(&.{"benchmark"}));
    try std.testing.expectError(error.InvalidRequestCount, parseOptions(&.{ "benchmark", "--mode", "ram", "--requests", "3" }));
    try std.testing.expectError(error.InvalidMode, parseOptions(&.{ "benchmark", "--mode", "other" }));
    const options = try parseOptions(&.{ "benchmark", "--mode", "persistence", "--port", "1234", "--requests", "2" });
    try std.testing.expectEqual(.persistence, options.mode);
    try std.testing.expectEqual(1234, options.port);
    try std.testing.expectEqual(2, options.requests);
}
