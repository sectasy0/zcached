const std = @import("std");

const serializer = @import("../../src/protocol/serializer.zig");

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
    // any non-zero or positive value is considered true
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
