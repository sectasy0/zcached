const std = @import("std");
const os = std.os;

const types = @import("types.zig");
const Config = @import("../server/config.zig");

pub var MAX_BULK_LEN: usize = 0;

pub fn SerializerT(comptime GenericReader: type) type {
    return struct {
        const Self = @This();

        const HandlerFunc = fn (self: *Self, reader: GenericReader) anyerror!types.ZType;
        const types_map = std.StaticStringMap(*const HandlerFunc).initComptime(.{
            .{ "+", serialize_sstr },
            .{ "$", serialize_str },
            .{ ",", serialize_float },
            .{ "*", serialize_array },
            .{ "-", serialize_error },
            .{ "#", serialize_bool },
            .{ "_", serialize_null },
            .{ "%", serialize_map },
            .{ ":", serialize_int },
            .{ "~", serialize_uset },
            .{ "/", serialize_set },
        });

        arena: std.heap.ArenaAllocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        pub fn process(self: *Self, reader: GenericReader) !types.ZType {
            var request_type: [1]u8 = undefined;
            const size = try reader.readAtLeast(&request_type, 1);

            if (size == 0) return error.BadRequest;

            const handler_ref = types_map.get(&request_type) orelse return error.BadRequest;
            return try handler_ref(self, reader);
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        fn serialize_sstr(self: *Self, reader: GenericReader) !types.ZType {
            const string = try self.read_line_alloc(reader);
            if (string.len == 0) return error.BadRequest;

            return .{ .str = @constCast(string[0 .. string.len - 1]) };
        }

        fn serialize_str(self: *Self, reader: GenericReader) !types.ZType {
            const bytes = try self.read_line_alloc(reader);

            const string_len = std.fmt.parseInt(usize, bytes[0 .. bytes.len - 1], 10) catch {
                return error.BadRequest;
            };

            if (string_len > MAX_BULK_LEN and MAX_BULK_LEN != 0) return error.BulkTooLarge;

            const string = try self.read_line_alloc(reader);
            if (string.len == 0) return error.BadRequest;
            // .len - 1 because we don't want to include the \n
            if (string_len != string.len - 1) return error.BadRequest;

            return .{ .str = @constCast(string[0 .. string.len - 1]) };
        }

        fn serialize_int(self: *Self, reader: GenericReader) !types.ZType {
            const bytes = try self.read_line_alloc(reader);
            if (bytes.len == 0) return error.BadRequest;

            const int = std.fmt.parseInt(i64, bytes[0 .. bytes.len - 1], 10) catch {
                return error.NotInteger;
            };

            return .{ .int = int };
        }

        fn serialize_bool(self: *Self, reader: GenericReader) !types.ZType {
            const bytes = try self.read_line_alloc(reader);

            // <bool> is either "t" or "f", with \n at the end is 2 bytes
            if (bytes.len != 2) return error.BadRequest;

            const value = bytes[0 .. bytes.len - 1];
            if (std.mem.eql(u8, value, "t") or std.mem.eql(u8, value, "T")) {
                return .{ .bool = true };
            }
            if (std.mem.eql(u8, value, "f") or std.mem.eql(u8, value, "F")) {
                return .{ .bool = false };
            }

            return error.NotBoolean;
        }

        fn serialize_float(self: *Self, reader: GenericReader) !types.ZType {
            const bytes = try self.read_line_alloc(reader);

            if (bytes.len == 0) return error.BadRequest;

            const float = std.fmt.parseFloat(f64, bytes[0 .. bytes.len - 1]) catch {
                return error.NotFloat;
            };

            return .{ .float = float };
        }

        fn serialize_array(self: *Self, reader: GenericReader) !types.ZType {
            const bytes = try self.read_line_alloc(reader);

            if (bytes.len == 0) return error.BadRequest;

            const array_len = std.fmt.parseInt(usize, bytes[0 .. bytes.len - 1], 10) catch {
                return error.InvalidLength;
            };

            var result = std.ArrayList(types.ZType).initCapacity(
                self.arena.allocator(),
                array_len,
            ) catch {
                return error.AllocatorError;
            };

            for (0..array_len) |_| {
                const item = try self.process(reader);
                try result.append(item);
            }
            return .{ .array = result };
        }

        fn serialize_null(self: *Self, reader: GenericReader) !types.ZType {
            _ = self;
            var buff: [2]u8 = undefined;
            _ = try reader.readAtLeast(&buff, 2); // to remove \r\n from buffer
            return .{ .null = void{} };
        }

        // Only for client side, server should never receive an error
        fn serialize_error(self: *Self, reader: GenericReader) !types.ZType {
            const error_message = try self.read_line_alloc(reader);

            if (error_message.len < 1) return error.BadRequest;

            return .{
                .err = .{
                    .message = error_message[0 .. error_message.len - 1],
                },
            };
        }

        fn serialize_map(self: *Self, reader: GenericReader) !types.ZType {
            const bytes = try self.read_line_alloc(reader);

            if (bytes.len == 0) return error.BadRequest;

            const entries = std.fmt.parseInt(usize, bytes[0 .. bytes.len - 1], 10) catch {
                return error.InvalidHashLength;
            };

            var result = std.StringHashMap(types.ZType).init(self.arena.allocator());

            for (0..entries) |_| {
                const key = try self.process(reader);

                const active_tag = std.meta.activeTag(key);
                if (active_tag != .str and active_tag != .sstr) return error.InvalidHashKey;

                const value = try self.process(reader);
                try result.put(key.str, value);
            }
            return .{ .map = result };
        }

        fn serialize_set(self: *Self, reader: GenericReader) !types.ZType {
            const bytes = try self.read_line_alloc(reader);

            if (bytes.len == 0) return error.BadRequest;

            const set_len = std.fmt.parseInt(usize, bytes[0 .. bytes.len - 1], 10) catch {
                return error.InvalidLength;
            };

            var set = types.sets.Set(types.ZType).init(
                self.arena.allocator(),
            );

            for (0..set_len) |_| {
                const item = try self.process(reader);
                try set.insert(item);
            }
            return .{ .set = set };
        }

        fn serialize_uset(self: *Self, reader: GenericReader) !types.ZType {
            const bytes = try self.read_line_alloc(reader);

            if (bytes.len == 0) return error.BadRequest;

            const set_len = std.fmt.parseInt(usize, bytes[0 .. bytes.len - 1], 10) catch {
                return error.InvalidLength;
            };

            var uset = types.sets.SetUnordered(types.ZType).init(
                self.arena.allocator(),
            );

            for (0..set_len) |_| {
                const item = try self.process(reader);
                try uset.insert(item);
            }
            return .{ .uset = uset };
        }

        fn read_line_alloc(self: *Self, reader: GenericReader) ![]const u8 {
            const bytes: []const u8 = reader.readUntilDelimiterAlloc(
                self.arena.allocator(),
                '\n',
                std.math.maxInt(usize),
            ) catch {
                return error.BadRequest;
            };

            return bytes;
        }
    };
}
