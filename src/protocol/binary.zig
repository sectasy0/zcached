const std = @import("std");
const ZType = @import("types/ztype.zig");
const sets = @import("types/sets.zig");

/// Enum representing the type of data in a binary header.
pub const Tag = enum(u4) {
    bool,
    int,
    float,
    str,
    array,
    set,
    uset,
    map,
    null,
};

const TagSize = @bitSizeOf(Tag);

// Enum representing the size type for `array`, `map`, `set`, and `uset` in a binary header.
pub const LengthSize = enum(u2) {
    u8,
    u16,
    u32,
    u64,

    /// Determines the appropriate `LengthSize` variant based on the provided value.
    /// Returns an error if the value type is not an integer.
    pub fn from_value(value: anytype) !LengthSize {
        if (@typeInfo(@TypeOf(value)) != .Int) return error.InvalidType;

        if (value <= std.math.maxInt(u8)) return .u8;
        if (value <= std.math.maxInt(u16)) return .u16;
        if (value <= std.math.maxInt(u32)) return .u32;

        return .u64;
    }

    /// Returns the size in bytes corresponding to the `LengthSize` variant.
    fn size(ls: LengthSize) usize {
        return @as(usize, 1) << @intFromEnum(ls);
    }
};

/// Encodes `ZType` into binary representation
pub const ZWriter = struct {
    writer: std.io.AnyWriter,

    pub fn init(writer: std.io.AnyWriter) ZWriter {
        return .{ .writer = writer };
    }

    pub fn write(zw: ZWriter, value: ZType) anyerror!usize {
        return switch (value) {
            .str => |val| try zw.write_str(val),
            .bool => |val| try zw.write_bool(val),
            .int => |val| try zw.write_int(val),
            .float => |val| try zw.write_float(val),
            .array => |val| try zw.write_array(val.items),
            .map => |val| try zw.write_map(val),
            .set => |val| try zw.write_set(val),
            .uset => |val| try zw.write_uset(val),
            .null => try zw.write_null(),
            else => unreachable,
        };
    }

    fn write_null(zw: ZWriter) !usize {
        try zw.writer.writeByte(@intFromEnum(Tag.null));
        return 1;
    }

    fn write_uset(zw: ZWriter, uset: sets.SetUnordered(ZType)) !usize {
        const length = uset.count();

        const length_size_enum = try LengthSize.from_value(length);
        const length_size = length_size_enum.size();

        var total_size = 1 + length_size;

        const size_bytes = std.mem.asBytes(&length);

        _ = try zw.writer.writeByte(
            @intFromEnum(Tag.array) | @as(u8, @intFromEnum(length_size_enum)) << TagSize,
        );
        _ = try zw.writer.write(size_bytes[0..length_size]);

        var iter = uset.iterator();
        while (iter.next()) |item| total_size += try zw.write(item.*);

        return total_size;
    }

    fn write_set(zw: ZWriter, set: sets.Set(ZType)) !usize {
        const length = set.count();

        const length_size_enum = try LengthSize.from_value(length);
        const length_size = length_size_enum.size();

        var total_size = 1 + length_size;

        const size_bytes = std.mem.asBytes(&length);

        _ = try zw.writer.writeByte(
            @intFromEnum(Tag.array) | @as(u8, @intFromEnum(length_size_enum)) << TagSize,
        );
        _ = try zw.writer.write(size_bytes[0..length_size]);

        var iter = set.iterator();
        while (iter.next()) |item| total_size += try zw.write(item.key_ptr.*);

        return total_size;
    }

    fn write_array(zw: ZWriter, array: []ZType) !usize {
        const length = array.len;

        const length_size_enum = try LengthSize.from_value(length);
        const length_size = length_size_enum.size();

        var total_size = 1 + length_size;

        const size_bytes = std.mem.asBytes(&length);

        _ = try zw.writer.writeByte(
            @intFromEnum(Tag.array) | @as(u8, @intFromEnum(length_size_enum)) << TagSize,
        );
        _ = try zw.writer.write(size_bytes[0..length_size]);

        for (array) |item| total_size += try zw.write(item);

        return total_size;
    }

    fn write_map(zw: ZWriter, map: std.StringHashMap(ZType)) !usize {
        const length: u64 = @intCast(map.count());

        const length_size_enum = try LengthSize.from_value(length);
        const length_size = length_size_enum.size();

        var total_size = 1 + length_size;
        const size_bytes = std.mem.asBytes(&length);

        _ = try zw.writer.writeByte(
            @intFromEnum(Tag.map) | @as(u8, @intFromEnum(length_size_enum)) << TagSize,
        );
        _ = try zw.writer.write(size_bytes[0..length_size]);

        var iter = map.iterator();
        while (iter.next()) |entry| {
            total_size += try zw.write_str(entry.key_ptr.*);
            total_size += try zw.write(entry.value_ptr.*);
        }

        return total_size;
    }

    fn write_int(zw: ZWriter, value: i64) !usize {
        const needed = bytes_needed(i64, value);
        const as_bytes = std.mem.asBytes(&value);

        _ = try zw.writer.writeByte(
            @intFromEnum(Tag.int) | @as(u8, needed) << 4,
        );
        _ = try zw.writer.write(as_bytes[0..needed]);

        return needed + 1;
    }

    fn write_float(zw: ZWriter, value: f64) !usize {
        const needed = bytes_needed(f64, value);
        const as_bytes = std.mem.asBytes(&value);

        _ = try zw.writer.writeByte(
            @intFromEnum(Tag.float) | @as(u8, needed) << 4,
        );
        _ = try zw.writer.write(as_bytes[0..needed]);

        return needed + 1;
    }

    fn write_str(zw: ZWriter, str: []const u8) !usize {
        const length_size_enum = try LengthSize.from_value(str.len);
        try zw.writer.writeByte(
            @as(u8, @intFromEnum(Tag.str)) | @as(u8, @intFromEnum(length_size_enum)) << TagSize,
        );
        const length_bytes = std.mem.asBytes(&str.len);
        const length_size = length_size_enum.size();

        _ = try zw.writer.write(length_bytes[0..length_size]);

        const size = try zw.writer.write(str);
        return length_size + size + 1;
    }

    fn write_bool(
        zw: ZWriter,
        value: bool,
    ) !usize {
        try zw.writer.writeByte(
            @intFromEnum(Tag.bool) | @as(u8, @intFromBool(value)) << TagSize,
        );
        return 1;
    }
};

/// Decodes binary representation into `ZType`
pub const ZReader = struct {
    reader: std.io.AnyReader,

    pub fn init(reader: std.io.AnyReader) ZReader {
        return .{ .reader = reader };
    }

    pub fn read(zr: ZReader, out: *ZType, allocator: std.mem.Allocator) !usize {
        var size: usize = 1;
        const byte = try zr.reader.readByte();

        const tag = get_tag(byte);

        switch (tag) {
            .bool => out.* = .{ .bool = (byte & 0b11111000) != 0 },
            .null => out.* = .{ .null = {} },
            .int => {
                const bytes_len = @as(usize, byte >> 4);
                const value = try zr.reader.readVarInt(i64, .little, bytes_len);

                size += bytes_len;

                out.* = .{ .int = value };
            },
            .float => {
                const bytes_len = @as(usize, byte >> 4);
                var value: [@sizeOf(f64)]u8 = undefined;

                size += try zr.reader.read(value[0..bytes_len]);

                out.* = .{ .float = @bitCast(value) };
            },
            .str => {
                const length_size_enum: LengthSize = @enumFromInt(@as(u8, byte >> TagSize));
                const length_size = length_size_enum.size();

                const length = try zr.reader.readVarInt(usize, .little, length_size);
                size += length_size;
                const str = try allocator.alloc(u8, length);

                size += try zr.reader.read(str);

                out.* = .{ .str = str };
            },
            .array => {
                const length_size_enum: LengthSize = @enumFromInt(@as(u8, byte >> TagSize));
                const length_size = length_size_enum.size();

                const length = try zr.reader.readVarInt(usize, .little, length_size);
                size += length_size;

                var array = try std.ArrayList(ZType).initCapacity(allocator, length);
                for (0..length) |_| {
                    var elem: ZType = undefined;
                    size += try zr.read(&elem, allocator);
                    try array.append(elem);
                }

                out.* = .{ .array = array };
            },
            .uset => {
                const length_size_enum: LengthSize = @enumFromInt(@as(u8, byte >> TagSize));
                const length_size = length_size_enum.size();

                const length = try zr.reader.readVarInt(usize, .little, length_size);
                size += length_size;

                var uset = sets.SetUnordered(ZType).init(allocator);
                for (0..length) |_| {
                    var elem: ZType = undefined;
                    size += try zr.read(&elem, allocator);
                    try uset.insert(elem);
                }

                out.* = .{ .uset = uset };
            },
            .set => {
                const length_size_enum: LengthSize = @enumFromInt(@as(u8, byte >> TagSize));
                const length_size = length_size_enum.size();

                const length = try zr.reader.readVarInt(usize, .little, length_size);
                size += length_size;

                var set = sets.Set(ZType).init(allocator);
                for (0..length) |_| {
                    var elem: ZType = undefined;
                    size += try zr.read(&elem, allocator);
                    try set.insert(elem);
                }

                out.* = .{ .set = set };
            },
            .map => {
                const length_size_enum: LengthSize = @enumFromInt(@as(u8, byte >> TagSize));
                const length_size = length_size_enum.size();

                const length = try zr.reader.readVarInt(usize, .little, length_size);
                size += length_size;

                var map = std.StringHashMap(ZType).init(allocator);
                for (0..length) |_| {
                    var key: ZType = undefined;
                    var value: ZType = undefined;
                    size += try zr.read(&key, allocator);
                    size += try zr.read(&value, allocator);
                    try map.put(key.str, value);
                }

                out.* = .{ .map = map };
            },
        }

        return size;
    }

    fn get_tag(tag_byte: u8) Tag {
        return @enumFromInt(tag_byte & 0b1111);
    }
};

/// Determines the number of bytes needed to represent the given value of type `T`.
fn bytes_needed(comptime T: type, value: T) u8 {
    return switch (@typeInfo(T)) {
        .Int => |info| {
            if (info.signedness == .signed and value < 0) {
                return @intCast(@sizeOf(i64));
            }

            const U = std.meta.Int(.unsigned, info.bits);
            const x = @as(U, @intCast(value));
            const bits = std.math.log2_int_ceil(U, x);
            return @intCast((bits + 7) / 8);
        },
        .Float => return @sizeOf(f64),
        else => @compileError("unsupported type"),
    };
}
