const std = @import("std");
const fixedBufferStream = @import("../../protocol/fixed_buffer_stream.zig").fixedBufferStream;
const fifo_module = @import("../../server/background/fifo.zig");

const LinearFifo = fifo_module.LinearFifo;
const LinearFifoBufferType = fifo_module.LinearFifoBufferType;
const testing = std.testing;

test "LinearFifo(u8, .Dynamic) discard(0) from empty buffer should not error on overflow" {
    var fifo = LinearFifo(u8, .Dynamic).init(testing.allocator);
    defer fifo.deinit();

    fifo.discard(0);
}

test "LinearFifo(u8, .Dynamic)" {
    var fifo = LinearFifo(u8, .Dynamic).init(testing.allocator);
    defer fifo.deinit();

    try fifo.write("HELLO");
    try testing.expectEqual(@as(usize, 5), fifo.readableLength());
    try testing.expectEqualSlices(u8, "HELLO", fifo.readableSlice(0));

    {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            try fifo.write(&[_]u8{fifo.peekItem(i)});
        }
        try testing.expectEqual(@as(usize, 10), fifo.readableLength());
        try testing.expectEqualSlices(u8, "HELLOHELLO", fifo.readableSlice(0));
    }

    {
        try testing.expectEqual(@as(u8, 'H'), fifo.readItem().?);
        try testing.expectEqual(@as(u8, 'E'), fifo.readItem().?);
        try testing.expectEqual(@as(u8, 'L'), fifo.readItem().?);
        try testing.expectEqual(@as(u8, 'L'), fifo.readItem().?);
        try testing.expectEqual(@as(u8, 'O'), fifo.readItem().?);
    }
    try testing.expectEqual(@as(usize, 5), fifo.readableLength());

    {
        try testing.expectEqual(@as(usize, 11), fifo.writableLength());
        try testing.expectEqual(@as(usize, 6), fifo.writableSlice(0).len);
        fifo.writeAssumeCapacity("6<chars<11");
        try testing.expectEqualSlices(u8, "HELLO6<char", fifo.readableSlice(0));
        try testing.expectEqualSlices(u8, "s<11", fifo.readableSlice(11));
        try testing.expectEqualSlices(u8, "11", fifo.readableSlice(13));
        try testing.expectEqualSlices(u8, "", fifo.readableSlice(15));
        fifo.discard(11);
        try testing.expectEqualSlices(u8, "s<11", fifo.readableSlice(0));
        fifo.discard(4);
        try testing.expectEqual(@as(usize, 0), fifo.readableLength());
    }

    {
        const buf = try fifo.writableWithSize(12);
        try testing.expectEqual(@as(usize, 12), buf.len);
        var i: u8 = 0;
        while (i < 10) : (i += 1) {
            buf[i] = i + 'a';
        }
        fifo.update(10);
        try testing.expectEqualSlices(u8, "abcdefghij", fifo.readableSlice(0));
    }

    {
        try fifo.unget("prependedstring");
        var result: [30]u8 = undefined;
        try testing.expectEqualSlices(u8, "prependedstringabcdefghij", result[0..fifo.read(&result)]);
        try fifo.unget("b");
        try fifo.unget("a");
        try testing.expectEqualSlices(u8, "ab", result[0..fifo.read(&result)]);
    }

    fifo.shrink(0);

    {
        try fifo.writer().print("{s}, {s}!", .{ "Hello", "World" });
        var result: [30]u8 = undefined;
        try testing.expectEqualSlices(u8, "Hello, World!", result[0..fifo.read(&result)]);
        try testing.expectEqual(@as(usize, 0), fifo.readableLength());
    }

    {
        try fifo.writer().writeAll("This is a test");
        var result: [30]u8 = undefined;
        try testing.expectEqualSlices(u8, "This", (try fifo.reader().readUntilDelimiterOrEof(&result, ' ')).?);
        try testing.expectEqualSlices(u8, "is", (try fifo.reader().readUntilDelimiterOrEof(&result, ' ')).?);
        try testing.expectEqualSlices(u8, "a", (try fifo.reader().readUntilDelimiterOrEof(&result, ' ')).?);
        try testing.expectEqualSlices(u8, "test", (try fifo.reader().readUntilDelimiterOrEof(&result, ' ')).?);
    }

    {
        try fifo.ensureTotalCapacity(1);
        var in_fbs = fixedBufferStream("pump test");
        var out_buf: [50]u8 = undefined;
        var out_fbs = fixedBufferStream(&out_buf);
        try fifo.pump(in_fbs.reader(), out_fbs.writer());
        try testing.expectEqualSlices(u8, in_fbs.buffer, out_fbs.getWritten());
    }
}

test "LinearFifo supports static, slice, and dynamic buffers" {
    inline for ([_]type{ u1, u8, u16, u64 }) |T| {
        inline for ([_]LinearFifoBufferType{ LinearFifoBufferType{ .Static = 32 }, .Slice, .Dynamic }) |bt| {
            const FifoType = LinearFifo(T, bt);
            var buf: if (bt == .Slice) [32]T else void = undefined;
            var fifo = switch (bt) {
                .Static => FifoType.init(),
                .Slice => FifoType.init(buf[0..]),
                .Dynamic => FifoType.init(testing.allocator),
            };
            defer fifo.deinit();

            try fifo.write(&[_]T{ 0, 1, 1, 0, 1 });
            try testing.expectEqual(@as(usize, 5), fifo.readableLength());

            {
                try testing.expectEqual(@as(T, 0), fifo.readItem().?);
                try testing.expectEqual(@as(T, 1), fifo.readItem().?);
                try testing.expectEqual(@as(T, 1), fifo.readItem().?);
                try testing.expectEqual(@as(T, 0), fifo.readItem().?);
                try testing.expectEqual(@as(T, 1), fifo.readItem().?);
                try testing.expectEqual(@as(usize, 0), fifo.readableLength());
            }

            {
                try fifo.writeItem(1);
                try fifo.writeItem(1);
                try fifo.writeItem(1);
                try testing.expectEqual(@as(usize, 3), fifo.readableLength());
            }

            {
                var read_buf: [3]T = undefined;
                const n = fifo.read(&read_buf);
                try testing.expectEqual(@as(usize, 3), n);
            }
        }
    }
}
