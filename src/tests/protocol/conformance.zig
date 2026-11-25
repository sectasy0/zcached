const std = @import("std");
const Deserializer = @import("../../protocol/deserializer.zig").Deserializer;
const fixed_buffer_stream = @import("../../protocol/fixed_buffer_stream.zig");
const Serializer = @import("../../protocol/serializer.zig").SerializerT(fixed_buffer_stream.FixedBufferStream.Reader);
const types = @import("../../protocol/types.zig");

test "wire protocol conformance request command vector" {
    const wire = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$7\r\na\r\nb\x00xy\r\n";
    var stream = fixed_buffer_stream.fixedBufferStream(wire);
    var parser = try Serializer.init(std.testing.allocator);
    defer parser.deinit();

    const result = try parser.process(stream.reader());
    try std.testing.expectEqual(@as(usize, 3), result.array.items.len);
    try std.testing.expectEqualStrings("SET", result.array.items[0].str);
    try std.testing.expectEqualStrings("key", result.array.items[1].str);
    try std.testing.expectEqualStrings("a\r\nb\x00xy", result.array.items[2].str);
}

test "wire protocol conformance permits empty bulk strings" {
    var stream = fixed_buffer_stream.fixedBufferStream("$0\r\n\r\n");
    var parser = try Serializer.init(std.testing.allocator);
    defer parser.deinit();

    const result = try parser.process(stream.reader());
    try std.testing.expectEqualStrings("", result.str);
}

test "wire protocol conformance rejects incorrect bulk lengths and LF-only lines" {
    for ([_][]const u8{
        "$3\r\nab\r\n",
        "$1\r\nab\r\n",
        "+OK\n",
        "$1\na\r\n",
        "_\n",
    }) |wire| {
        var stream = fixed_buffer_stream.fixedBufferStream(wire);
        var parser = try Serializer.init(std.testing.allocator);
        defer parser.deinit();
        try std.testing.expectEqual(error.Unprocessable, parser.process(stream.reader()));
    }
}

test "wire protocol conformance response vectors" {
    const vectors = [_]struct { value: types.ZType, wire: []const u8 }{
        .{ .value = .{ .sstr = "OK" }, .wire = "+OK\r\n" },
        .{ .value = .{ .str = "a\r\nb\x00" }, .wire = "$5\r\na\r\nb\x00\r\n" },
        .{ .value = .{ .int = -42 }, .wire = ":-42\r\n" },
        .{ .value = .{ .float = 1.5 }, .wire = ",1.5\r\n" },
        .{ .value = .{ .bool = true }, .wire = "#t\r\n" },
        .{ .value = .{ .null = {} }, .wire = "_\r\n" },
    };

    var encoder = Deserializer.init(std.testing.allocator);
    defer encoder.deinit();
    for (vectors) |vector| {
        encoder.reset();
        try std.testing.expectEqualStrings(vector.wire, try encoder.process(vector.value));
    }
}
