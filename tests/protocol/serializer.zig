const std = @import("std");

const serializer = @import("../../src/protocol/serializer.zig");
const types = @import("../../src/protocol/types.zig");
const helpers = @import("../test_helper.zig");

test "ProtocolHandler handle simple command" {
    var stream = std.io.fixedBufferStream("*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    var result_array = result.array.items;
    try std.testing.expectEqualStrings("SET", result_array[0].str);
    try std.testing.expectEqualStrings("mycounter", result_array[1].str);
    try std.testing.expectEqual(.{ .int = 42 }, result_array[2].int);
}

test "ProtocolHandler handle empty bufferr" {
    var stream = std.io.fixedBufferStream("");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, error.BadRequest);
}

test "ProtocolHandler handle simple string" {
    var stream = std.io.fixedBufferStream("+OK\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    try std.testing.expectEqualStrings("OK", result.str);
}

test "ProtocolHandler handle integer" {
    var stream = std.io.fixedBufferStream(":42\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    try std.testing.expectEqual(.{ .int = 42 }, result.int);
}

test "ProtocolHandler handle integer without value" {
    var stream = std.io.fixedBufferStream(":\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, error.NotInteger);
}

test "ProtocolHandler handle string" {
    var stream = std.io.fixedBufferStream("$9\r\nmycounter\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    try std.testing.expectEqualStrings("mycounter", result.str);
}

test "ProtocolHandler handle string invalid length" {
    var stream = std.io.fixedBufferStream("$2\r\nmycounter");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, error.BadRequest);
}

test "ProtocolHandler handle string lenght passed but value not" {
    var stream = std.io.fixedBufferStream("$9\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, error.BadRequest);
}

test "ProtocolHandler handle boolean f value" {
    var stream = std.io.fixedBufferStream("#f\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, .{ .bool = false });
}

test "ProtocolHandler handle boolean t value" {
    var stream = std.io.fixedBufferStream("#t\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, .{ .bool = true });
}

test "ProtocolHandler handle boolean invalid value" {
    var stream = std.io.fixedBufferStream("#a\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, error.NotBoolean);
}

test "ProtocolHandler handle null" {
    var stream = std.io.fixedBufferStream("_\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, .{ .null = void{} });
}

test "ProtocolHandler handle error" {
    var stream = std.io.fixedBufferStream("-unknown command 'foobar'\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    try std.testing.expectEqualStrings("unknown command 'foobar'", result.err.message);
}

test "serialize float" {
    var stream = std.io.fixedBufferStream(",3.14\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    try std.testing.expectEqual(.{ .float = 3.14 }, result.float);
}

test "not serialize too large bulk" {
    serializer.MAX_BULK_LEN = 10;
    var stream = std.io.fixedBufferStream("$80\r\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    try std.testing.expectEqual(handler.process(reader), error.BulkTooLarge);
}

test "serialize map with various types" {
    serializer.MAX_BULK_LEN = 0;
    var stream = std.io.fixedBufferStream("*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n%6\r\n$6\r\npimpek\r\n_\r\n$2\r\nxd\r\n*3\r\n#t\r\n#f\r\n_\r\n$7\r\nsomeint\r\n:50\r\n$9\r\nsomefloat\r\n,55.55\r\n$15\r\nsomenegativeint\r\n:-120\r\n$17\r\nsomenegativefloat\r\n,-50.123\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var hash = std.StringHashMap(types.ZType).init(std.testing.allocator);
    defer hash.deinit();

    try hash.put("pimpek", .{ .null = void{} });

    var array = std.ArrayList(types.ZType).init(std.testing.allocator);
    defer array.deinit();

    try array.append(.{ .bool = true });
    try array.append(.{ .bool = false });
    try array.append(.{ .null = void{} });
    try hash.put("xd", .{ .array = array });
    try hash.put("someint", .{ .int = 50 });
    try hash.put("somefloat", .{ .float = 55.55 });
    try hash.put("somenegaativeint", .{ .int = -120 });
    try hash.put("somenegativefloat", .{ .float = -50.123 });

    var result = try handler.process(reader);
    var result_array = result.array.items;
    try std.testing.expectEqualStrings("SET", result_array[0].str);
    try std.testing.expectEqualStrings("foo", result_array[1].str);
    try helpers.expectEqualZTypes(.{ .map = hash }, result_array[2]);
}

test "serialize array with various types" {
    serializer.MAX_BULK_LEN = 0;
    var stream = std.io.fixedBufferStream("*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n*9\r\n:124\r\n:-500\r\n,55.123\r\n,-23.2\r\n#t\r\n#f\r\n_\r\n*7\r\n:124\r\n:-500\r\n,55.123\r\n,-23.2\r\n#t\r\n#f\r\n_\r\n%8\r\n$15\r\nsomenegativeint\r\n:-500\r\n$9\r\nsomefalse\r\n#f\r\n$9\r\nsomefloat\r\n,55.123\r\n$9\r\nsomearray\r\n*7\r\n:124\r\n:-500\r\n,55.123\r\n,-23.2\r\n#t\r\n#f\r\n_\r\n$7\r\nsomeint\r\n:124\r\n$17\r\nsomenegativefloat\r\n,-23.2\r\n$8\r\nsomenull\r\n_\r\n$8\r\nsometrue\r\n#t\r\n");

    var reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var array = std.ArrayList(types.ZType).init(std.testing.allocator);
    defer array.deinit();

    var int = .{ .int = 124 };
    var nint = .{ .int = -500 };
    var float = .{ .float = 55.123 };
    var nfloat = .{ .float = -23.2 };
    var fbool = .{ .bool = false };
    var tbool = .{ .bool = true };
    var vnull = .{ .null = void{} };

    try array.append(int);
    try array.append(nint);
    try array.append(float);
    try array.append(nfloat);
    try array.append(tbool);
    try array.append(fbool);
    try array.append(vnull);

    var second_array = std.ArrayList(types.ZType).init(std.testing.allocator);
    defer second_array.deinit();

    try second_array.append(int);
    try second_array.append(nint);
    try second_array.append(float);
    try second_array.append(nfloat);
    try second_array.append(tbool);
    try second_array.append(fbool);
    try second_array.append(vnull);

    try array.append(.{ .array = second_array });

    var map = std.StringHashMap(types.ZType).init(std.testing.allocator);
    defer map.deinit();

    try map.put("someint", int);
    try map.put("somenegativeint", nint);
    try map.put("somefloat", float);
    try map.put("somenegativefloat", nfloat);
    try map.put("sometrue", tbool);
    try map.put("somefalse", fbool);
    try map.put("somenull", vnull);
    try map.put("somearray", .{ .array = second_array });

    try array.append(.{ .map = map });

    var result = try handler.process(reader);
    var result_array = result.array.items;

    try std.testing.expectEqualStrings("SET", result_array[0].str);
    try std.testing.expectEqualStrings("foo", result_array[1].str);
    try helpers.expectEqualZTypes(.{ .array = array }, result_array[2]);
}
