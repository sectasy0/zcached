const stdlib = @import("std");
const std = struct {
    pub const testing = stdlib.testing;
    pub const array_list = stdlib.array_list;
    pub const StringHashMap = stdlib.StringHashMap;
    pub const io = struct {
        pub const fixedBufferStream = @import("../../protocol/fixed_buffer_stream.zig").fixedBufferStream;
    };
};

const serializer = @import("../../protocol/serializer.zig");
const types = @import("../../protocol/types.zig");
const helpers = @import("../helper.zig");
const fixed_buffer_stream = @import("../../protocol/fixed_buffer_stream.zig");

// Checks that a command array and its nested scalar arguments are parsed in order.
test "ProtocolHandler handle simple command" {
    var stream = fixed_buffer_stream.fixedBufferStream("*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.process(reader);
    const result_array = result.array.items;
    try std.testing.expectEqualStrings("SET", result_array[0].str);
    try std.testing.expectEqualStrings("mycounter", result_array[1].str);
    try std.testing.expectEqual(42, result_array[2].int);
}

// Ensures an empty input reports end-of-stream rather than producing a value.
test "ProtocolHandler handle empty bufferr" {
    var stream = std.io.fixedBufferStream("");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = handler.process(reader);
    try std.testing.expectEqual(result, error.EndOfStream);
}

// Checks that a simple-string marker yields the expected string payload.
test "ProtocolHandler handle simple string" {
    var stream = std.io.fixedBufferStream("+OK\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.process(reader);
    try std.testing.expectEqualStrings("OK", result.sstr);
}

// Checks parsing a valid signed integer scalar.
test "ProtocolHandler handle integer" {
    var stream = std.io.fixedBufferStream(":42\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.process(reader);
    try std.testing.expectEqual(types.ZType{ .int = 42 }, result);
}

// Ensures an empty integer payload is rejected as malformed input.
test "ProtocolHandler handle integer without value" {
    var stream = std.io.fixedBufferStream(":\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = handler.process(reader);
    try std.testing.expectEqual(result, error.Unprocessable);
}

// Ensures non-decimal integer payloads return a type error.
test "ProtocolHandler handle integer with non-integer value" {
    var stream = std.io.fixedBufferStream(":kk\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = handler.process(reader);
    try std.testing.expectEqual(result, error.InvalidType);
}

// Checks parsing a bulk string with a declared payload length.
test "ProtocolHandler handle string" {
    var stream = std.io.fixedBufferStream("$9\r\nmycounter\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.process(reader);
    try std.testing.expectEqualStrings("mycounter", result.str);
}

// Ensures a bulk string missing its payload terminator is rejected.
test "ProtocolHandler handle string invalid length" {
    var stream = std.io.fixedBufferStream("$2\r\nmycounter");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = handler.process(reader);
    try std.testing.expectEqual(result, error.Unprocessable);
}

// Ensures a declared bulk string with no payload is rejected.
test "ProtocolHandler handle string lenght passed but value not" {
    var stream = std.io.fixedBufferStream("$9\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = handler.process(reader);
    try std.testing.expectEqual(result, error.Unprocessable);
}

// Checks parsing the false boolean marker.
test "ProtocolHandler handle boolean f value" {
    var stream = std.io.fixedBufferStream("#f\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = handler.process(reader);
    try std.testing.expectEqual(result, types.ZType{ .bool = false });
}

// Checks parsing the true boolean marker.
test "ProtocolHandler handle boolean t value" {
    var stream = std.io.fixedBufferStream("#t\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = handler.process(reader);
    try std.testing.expectEqual(result, types.ZType{ .bool = true });
}

// Ensures an unrecognized boolean payload returns a type error.
test "ProtocolHandler handle boolean invalid value" {
    var stream = std.io.fixedBufferStream("#a\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = handler.process(reader);
    try std.testing.expectEqual(result, error.InvalidType);
}

// Checks that the null marker produces the null variant.
test "ProtocolHandler handle null" {
    var stream = std.io.fixedBufferStream("_\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = handler.process(reader);
    try std.testing.expectEqual(result, types.ZType{ .null = {} });
}

// Checks that a client error line is retained as an error message.
test "ProtocolHandler handle error" {
    var stream = std.io.fixedBufferStream("-unknown command 'foobar'\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.process(reader);
    try std.testing.expectEqualStrings("unknown command 'foobar'", result.err.message);
}

// Checks parsing a floating-point scalar from its protocol line.
test "serialize float" {
    var stream = std.io.fixedBufferStream(",3.14\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.process(reader);
    try std.testing.expectEqual(types.ZType{ .float = 3.14 }, result);
}

// Ensures a payload exceeding the configured bulk limit is rejected.
test "not serialize too large bulk" {
    serializer.MAX_BULK_LEN = 10;
    var stream = std.io.fixedBufferStream("$80\r\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    try std.testing.expectEqual(handler.process(reader), error.PayloadExceeded);
}

// Exercises nested map parsing across null, array, boolean, integer, and float values.
test "serialize map with various types" {
    serializer.MAX_BULK_LEN = 0;
    var stream = std.io.fixedBufferStream("*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n%6\r\n$6\r\npimpek\r\n_\r\n$2\r\nxd\r\n*3\r\n#t\r\n#f\r\n_\r\n$7\r\nsomeint\r\n:50\r\n$9\r\nsomefloat\r\n,55.55\r\n$15\r\nsomenegativeint\r\n:-120\r\n$17\r\nsomenegativefloat\r\n,-50.123\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var hash = std.StringHashMap(types.ZType).init(std.testing.allocator);
    defer hash.deinit();

    try hash.put("pimpek", .{ .null = {} });

    var array = try std.array_list.Managed(types.ZType).initCapacity(std.testing.allocator, 3);
    defer array.deinit();

    try array.append(.{ .bool = true });
    try array.append(.{ .bool = false });
    try array.append(.{ .null = {} });
    try hash.put("xd", .{ .array = array });
    try hash.put("someint", .{ .int = 50 });
    try hash.put("somefloat", .{ .float = 55.55 });
    try hash.put("somenegaativeint", .{ .int = -120 });
    try hash.put("somenegativefloat", .{ .float = -50.123 });

    const result = try handler.process(reader);
    const result_array = result.array.items;
    try std.testing.expectEqualStrings("SET", result_array[0].str);
    try std.testing.expectEqualStrings("foo", result_array[1].str);
    try helpers.expectEqualZTypes(.{ .map = hash }, result_array[2]);
}

// Exercises recursive array parsing with scalar, nested array, and map values.
test "serialize array with various types" {
    serializer.MAX_BULK_LEN = 0;
    var stream = std.io.fixedBufferStream("*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n*9\r\n:124\r\n:-500\r\n,55.123\r\n,-23.2\r\n#t\r\n#f\r\n_\r\n*7\r\n:124\r\n:-500\r\n,55.123\r\n,-23.2\r\n#t\r\n#f\r\n_\r\n%8\r\n$15\r\nsomenegativeint\r\n:-500\r\n$9\r\nsomefalse\r\n#f\r\n$9\r\nsomefloat\r\n,55.123\r\n$9\r\nsomearray\r\n*7\r\n:124\r\n:-500\r\n,55.123\r\n,-23.2\r\n#t\r\n#f\r\n_\r\n$7\r\nsomeint\r\n:124\r\n$17\r\nsomenegativefloat\r\n,-23.2\r\n$8\r\nsomenull\r\n_\r\n$8\r\nsometrue\r\n#t\r\n");

    const reader = stream.reader();

    const HandlerType = serializer.SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var array = try std.array_list.Managed(types.ZType).initCapacity(std.testing.allocator, 7);
    defer array.deinit();

    const int: types.ZType = .{ .int = 124 };
    const nint: types.ZType = .{ .int = -500 };
    const float: types.ZType = .{ .float = 55.123 };
    const nfloat: types.ZType = .{ .float = -23.2 };
    const fbool: types.ZType = .{ .bool = false };
    const tbool: types.ZType = .{ .bool = true };
    const vnull: types.ZType = .{ .null = {} };

    try array.append(int);
    try array.append(nint);
    try array.append(float);
    try array.append(nfloat);
    try array.append(tbool);
    try array.append(fbool);
    try array.append(vnull);

    var second_array = try std.array_list.Managed(types.ZType).initCapacity(std.testing.allocator, 7);
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

    const result = try handler.process(reader);
    const result_array = result.array.items;

    try std.testing.expectEqualStrings("SET", result_array[0].str);
    try std.testing.expectEqualStrings("foo", result_array[1].str);
    try helpers.expectEqualZTypes(.{ .array = array }, result_array[2]);
}
