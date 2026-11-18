const std = @import("std");

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;
const Fabric = @import("../../server/storage/fabric.zig");

const types = @import("../../protocol/types.zig");
const helper = @import("../helper.zig");
const sync = @import("sync");

fn keyForShard(fabric: *Fabric, index: usize, buffer: []u8) ![]const u8 {
    var candidate: usize = 0;
    while (true) : (candidate += 1) {
        const key = try std.fmt.bufPrint(buffer, "shard-key-{d}", .{candidate});
        if (fabric.shardIndex(key) == index) return key;
    }
}

test "fabric routes to independently owned heaps and aggregates all shards" {
    var fabric = try Fabric.init(std.testing.allocator, .{ .shard_count = 3, .default_capacity = 8 });
    defer fabric.deinit();
    for (fabric.shards, 0..) |*shard, index| {
        var buffer: [64]u8 = undefined;
        const key = try keyForShard(&fabric, index, &buffer);
        try fabric.put(key, .{ .str = "value" });
        try std.testing.expectEqual(@as(u32, 1), shard.map.count());
        try std.testing.expectEqual(@as(usize, 5), try fabric.valueSize(key));
        try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&shard.heap)), shard.map.allocator.ptr);
        if (index > 0) try std.testing.expect(shard.map.allocator.ptr != fabric.shards[0].map.allocator.ptr);
    }
    try std.testing.expectEqual(@as(usize, 3), fabric.size());
    var keys = try fabric.keysCopy(std.testing.allocator);
    defer {
        for (keys.items) |*key| types.ztype_free(key, std.testing.allocator);
        keys.deinit();
    }
    {
        var iter = fabric.iterator();
        defer iter.deinit();
        try std.testing.expectEqual(@as(usize, 3), iter.count());
        _ = iter.next();
    }
    const used = fabric.memoryUsed();
    fabric.flush();
    try std.testing.expectEqual(@as(usize, 0), fabric.size());
    try std.testing.expect(fabric.memoryUsed() < used);
    for (keys.items) |key| try std.testing.expectError(error.NotFound, fabric.get(key.str));
}

test "fabric copy and rename preserve ownership within and across shards" {
    for ([_]usize{ 1, 3 }) |shard_count| {
        var fabric = try Fabric.init(std.testing.allocator, .{ .shard_count = shard_count, .default_capacity = 0 });
        defer fabric.deinit();
        var source_buffer: [64]u8 = undefined;
        var destination_buffer: [64]u8 = undefined;
        const source = try keyForShard(&fabric, 0, &source_buffer);
        const destination = if (shard_count == 1) "destination" else try keyForShard(&fabric, 1, &destination_buffer);
        var array = try helper.setup_array(std.testing.allocator);
        defer array.deinit();
        try fabric.put(source, .{ .array = array });
        try fabric.put(destination, .{ .str = "previous destination" });
        try std.testing.expectError(error.BusyKey, fabric.copy(source, destination, false));
        try fabric.copy(source, destination, true);
        try std.testing.expect((try fabric.get(source)).array.items.ptr != (try fabric.get(destination)).array.items.ptr);
        try fabric.rename(source, source);
        try fabric.copy(source, source, true);
        try std.testing.expectError(error.BusyKey, fabric.copy(source, source, false));
        try fabric.rename(source, destination);
        try std.testing.expectError(error.NotFound, fabric.get(source));
        try std.testing.expectEqual(@as(usize, 1), fabric.size());
        var copied = try fabric.getCopy(destination, std.testing.allocator);
        defer types.ztype_free(&copied, std.testing.allocator);
        fabric.flush();
        try helper.expectEqualZTypes(.{ .array = array }, copied);
    }
}

test "memory accepts legacy and section limits and rejects invalid shard settings" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.max_memory = 1;
    try fixture.create_memory();
    try std.testing.expectError(error.MemoryLimitExceeded, fixture.memory.?.put("blocked", .{ .int = 1 }));
    fixture.config.memory.limit = std.math.maxInt(usize);
    try fixture.create_memory();
    try fixture.memory.?.put("allowed", .{ .int = 1 });
    try std.testing.expectError(error.InvalidShardCount, Fabric.init(std.testing.allocator, .{ .shard_count = 0 }));
    try std.testing.expectError(error.InvalidCapacity, Fabric.init(std.testing.allocator, .{ .default_capacity = std.math.maxInt(u32) }));
}

fn initializeReservedShards(allocator: std.mem.Allocator) !void {
    var fabric = try Fabric.init(allocator, .{ .shard_count = 3, .default_capacity = 64 });
    defer fabric.deinit();
}

test "fabric frees previously initialized shards when reserving another shard fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initializeReservedShards, .{});
}

fn allocationFailureScenario(allocator: std.mem.Allocator, move: bool, same_shard: bool) !void {
    var fabric = try Fabric.init(allocator, .{ .shard_count = if (same_shard) 1 else 3, .default_capacity = 0 });
    defer fabric.deinit();
    var source_buffer: [64]u8 = undefined;
    var destination_buffer: [64]u8 = undefined;
    const source = try keyForShard(&fabric, 0, &source_buffer);
    const destination = if (same_shard) "other" else try keyForShard(&fabric, 1, &destination_buffer);
    // A large string forces a backing allocation even after the shard heap has warmed up.
    const payload: [8192]u8 = @splat('x');
    try fabric.put(source, .{ .str = &payload });
    try fabric.put(destination, .{ .int = 42 });
    const result = if (move) fabric.rename(source, destination) else fabric.copy(source, destination, true);
    result catch |err| {
        try std.testing.expectEqualStrings(&payload, (try fabric.get(source)).str);
        try std.testing.expectEqual(@as(i64, 42), (try fabric.get(destination)).int);
        return err;
    };
    try std.testing.expectEqualStrings(&payload, (try fabric.get(destination)).str);
}

test "fabric cleans up allocation failures without losing transfer data" {
    for ([_]bool{ false, true }) |move| {
        for ([_]bool{ false, true }) |same_shard|
            try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureScenario, .{ move, same_shard });
    }
}

const TransferWorker = struct {
    fabric: *Fabric,
    start: *sync.Event,
    source: []const u8,
    destination: []const u8,
    failure: ?anyerror = null,

    fn run(self: *TransferWorker) void {
        self.start.wait();
        for (0..100) |_| {
            self.fabric.copy(self.source, self.destination, true) catch |err| {
                self.failure = err;
                return;
            };
        }
    }
};

test "opposite cross-shard copies coordinate concurrent shard allocators" {
    var fabric = try Fabric.init(std.testing.allocator, .{ .shard_count = 3 });
    defer fabric.deinit();
    var left_buffer: [64]u8 = undefined;
    var right_buffer: [64]u8 = undefined;
    const left = try keyForShard(&fabric, 0, &left_buffer);
    const right = try keyForShard(&fabric, 2, &right_buffer);
    var array = try helper.setup_array(std.testing.allocator);
    defer array.deinit();
    try fabric.put(left, .{ .array = array });
    try fabric.put(right, .{ .array = array });
    var start: sync.Event = .{};
    var workers: [4]TransferWorker = undefined;
    var threads: [4]?std.Thread = @splat(null);
    defer {
        start.set();
        for (threads) |thread| if (thread) |t| t.join();
    }
    for (&workers, 0..) |*worker, index| {
        worker.* = .{
            .fabric = &fabric,
            .start = &start,
            .source = if (index % 2 == 0) left else right,
            .destination = if (index % 2 == 0) right else left,
        };
        threads[index] = try std.Thread.spawn(.{}, TransferWorker.run, .{worker});
    }
    start.set();
    for (&threads) |*thread| {
        thread.*.?.join();
        thread.* = null;
    }
    for (workers) |worker| if (worker.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), fabric.size());
    try helper.expectEqualZTypes(.{ .array = array }, try fabric.get(left));
    try helper.expectEqualZTypes(.{ .array = array }, try fabric.get(right));
}

test "should get existing and not get non-existing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try helper.setup_storage(&fixture.memory.?);

    try std.testing.expectEqual(fixture.memory.?.get("foo"), types.ZType{ .int = 42 });
    try std.testing.expectEqual(fixture.memory.?.get("foo2"), types.ZType{ .float = 123.45 });
    try std.testing.expectEqual(fixture.memory.?.get("foo3"), types.ZType{ .bool = true });
    try std.testing.expectEqual(fixture.memory.?.get("foo4"), types.ZType{ .null = {} });
    // we have to compare values cause it's not same place in memory
    try std.testing.expectEqualStrings((try fixture.memory.?.get("foo5")).sstr, helper.SIMPLE_STRING);
    try std.testing.expectEqualStrings((try fixture.memory.?.get("bar")).str, helper.STRING);

    // array
    var array = try helper.setup_array(fixture.allocator);
    defer array.deinit();

    try fixture.memory.?.put("foo6", .{ .array = array });

    const getted = try fixture.memory.?.get("foo6");
    try helper.expectEqualZTypes(getted, .{ .array = array });

    // map
    var map = try helper.setup_map(fixture.allocator);
    defer map.deinit();

    try fixture.memory.?.put("foo7", .{ .map = map });

    const getted_map = try fixture.memory.?.get("foo7");
    try helper.expectEqualZTypes(getted_map, .{ .map = map });

    try std.testing.expectEqual(fixture.memory.?.get("baz"), error.NotFound);
}

test "should delete existing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const string = "Die meisten Menschen sind nichts als Bauern auf einem Schachbrett, das von einer unbekannten Hand geführt wird.";
    const value: types.ZType = .{ .str = string };

    try fixture.memory.?.put("foo", .{ .int = 42 });
    try fixture.memory.?.put("bar", value);

    try std.testing.expectEqual(fixture.memory.?.delete("foo"), true);
    try std.testing.expectEqual(fixture.memory.?.get("foo"), error.NotFound);
    try std.testing.expectEqualStrings((try fixture.memory.?.get("bar")).str, value.str);
}

test "should not delete non-existing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try std.testing.expectEqual(fixture.memory.?.delete("foo"), false);
}

test "should flush storage" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const string = "Es gibt Momente im Leben, da muss man verstehen, dass die Entscheidungen, die man trifft, nicht nur das eigene Schicksal angehen.";
    const value: types.ZType = .{ .str = string };

    try fixture.memory.?.put("foo", .{ .int = 42 });
    try fixture.memory.?.put("bar", value);

    fixture.memory.?.flush();

    try std.testing.expectEqual(fixture.memory.?.get("foo"), error.NotFound);
    try std.testing.expectEqual(fixture.memory.?.get("bar"), error.NotFound);
}

test "should not store error" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const err_value: types.ZType = .{ .err = .{ .message = "random error" } };
    try std.testing.expectEqual(fixture.memory.?.put("test", err_value), error.InvalidValue);
}

test "should return error.MemoryLimitExceeded" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var arena = std.heap.ArenaAllocator.init(fixture.allocator);
    defer arena.deinit();

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = string };
    for (0..64) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        try fixture.memory.?.put(key, value);
    }

    fixture.memory.?.fabric.limit = fixture.memory.?.fabric.memoryUsed();
    try std.testing.expectEqual(fixture.memory.?.put("test key", value), error.MemoryLimitExceeded);
}

test "should not return error.MemoryLimitExceed when max but deleted some" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var arena = std.heap.ArenaAllocator.init(fixture.allocator);
    defer arena.deinit();

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = string };
    for (0..8) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        try fixture.memory.?.put(key, value);
    }

    fixture.memory.?.fabric.limit = fixture.memory.?.fabric.memoryUsed();
    try std.testing.expectError(error.MemoryLimitExceeded, fixture.memory.?.put("blocked", value));
    for (0..3) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});

        _ = fixture.memory.?.delete(key);
    }

    const result = fixture.memory.?.put("test key", value);

    try std.testing.expectEqual({}, result);
}

test "memory should not grow if key overriden with put" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.max_memory = std.math.maxInt(usize);
    try fixture.create_memory();

    try helper.setup_storage(&fixture.memory.?);

    var arena = std.heap.ArenaAllocator.init(fixture.allocator);
    defer arena.deinit();

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = string };
    for (0..8) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        fixture.memory.?.put(key, value) catch {};
    }

    const before_put = fixture.memory.?.fabric.memoryUsed();
    try fixture.memory.?.put("key-1", value);
    try fixture.memory.?.put("key-2", value);

    try std.testing.expectEqual(before_put, fixture.memory.?.fabric.memoryUsed());
}

test "same-length string overwrite reuses stored allocation" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.max_memory = std.math.maxInt(usize);
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = "old" });
    const stored = (try fixture.memory.?.get("key")).str.ptr;
    const bytes_before = fixture.memory.?.fabric.memoryUsed();

    try fixture.memory.?.put("key", .{ .str = "new" });

    try std.testing.expectEqual(stored, (try fixture.memory.?.get("key")).str.ptr);
    try std.testing.expectEqual(bytes_before, fixture.memory.?.fabric.memoryUsed());
    try std.testing.expectEqualStrings("new", (try fixture.memory.?.get("key")).str);
}

test "same-length simple string overwrite reuses stored allocation" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.max_memory = std.math.maxInt(usize);
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .sstr = "old" });
    const stored = (try fixture.memory.?.get("key")).sstr.ptr;
    const bytes_before = fixture.memory.?.fabric.memoryUsed();

    try fixture.memory.?.put("key", .{ .sstr = "new" });

    try std.testing.expectEqual(stored, (try fixture.memory.?.get("key")).sstr.ptr);
    try std.testing.expectEqual(bytes_before, fixture.memory.?.fabric.memoryUsed());
    try std.testing.expectEqualStrings("new", (try fixture.memory.?.get("key")).sstr);
}

test "unlimited storage supports mutations through shard allocators" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.max_memory = 0;
    try fixture.create_memory();

    try std.testing.expectEqual(fixture.allocator.ptr, fixture.memory.?.allocator.ptr);
    try std.testing.expectEqual(fixture.allocator.vtable, fixture.memory.?.allocator.vtable);
    try fixture.memory.?.put("key", .{ .str = "value" });
    try fixture.memory.?.copy("key", "copy", false);
    try fixture.memory.?.rename("copy", "longer-key");
    try std.testing.expectEqualStrings("value", (try fixture.memory.?.get("longer-key")).str);
    try std.testing.expect(fixture.memory.?.delete("key"));
    fixture.memory.?.flush();

    try std.testing.expectEqual(@as(i64, 0), fixture.memory.?.size());
}
