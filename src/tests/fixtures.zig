const std = @import("std");

const Logger = @import("../server/logger.zig");
const Config = @import("../server/config.zig");
const utils = @import("../server/utils.zig");

const TracingAllocator = @import("../server/tracing.zig");

const persistance = @import("../server/storage/persistance.zig");
const Memory = @import("../server/storage/memory.zig");

pub const ContextFixture = struct {
    allocator: std.mem.Allocator,
    tracing_allocator: TracingAllocator,
    logger: Logger,
    config: Config,
    persistance: ?persistance.Handler,
    memory: ?Memory,

    pub fn init() !ContextFixture {
        const allocator: std.mem.Allocator = std.testing.allocator;
        const tracing_allocator: TracingAllocator = TracingAllocator.init(allocator);

        return ContextFixture{
            .allocator = allocator,
            .tracing_allocator = tracing_allocator,
            .logger = try Logger.init(allocator, null, false),
            .config = try Config.load(allocator, null, null),
            .persistance = null,
            .memory = null,
        };
    }

    pub fn create_memory(self: *ContextFixture) !void {
        if (self.memory != null) self.memory.?.deinit();
        if (self.persistance == null) try self.create_persistance();

        self.memory = Memory.init(
            self.tracing_allocator.allocator(),
            self.config,
            &self.persistance.?,
        );
    }

    pub fn create_persistance(self: *ContextFixture) !void {
        if (self.persistance != null) self.persistance.?.deinit();

        self.persistance = try persistance.Handler.init(
            self.allocator,
            self.config,
            self.logger,
            null,
        );
    }

    pub fn deinit(self: *ContextFixture) void {
        self.config.deinit();
        if (self.persistance != null) self.persistance.?.deinit();
        if (self.memory != null) self.memory.?.deinit();
    }
};

pub const ConfigFile = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 7556,
    maxclients: usize = 123,
    maxmemory: usize = 0,
    proto_max_bulk_len: usize = 0,
    workers: usize = 4,
    cbuffer: usize = 4096,
    whitelist: std.ArrayList([]const u8),

    path: []const u8 = undefined,

    pub fn init(path: []const u8) !ConfigFile {
        var config_file = ConfigFile{
            .whitelist = std.ArrayList([]const u8).init(std.testing.allocator),
            .path = path,
        };

        try config_file.whitelist.append("127.0.0.1");
        try config_file.whitelist.append("127.0.0.2");
        try config_file.whitelist.append("127.0.0.3");
        try config_file.whitelist.append("127.0.0.4");

        return config_file;
    }

    pub fn deinit(self: *ConfigFile) void {
        std.fs.cwd().deleteFile(self.path) catch {};
        self.whitelist.deinit();
    }

    pub fn create(self: *ConfigFile, allocator: std.mem.Allocator) ![]const u8 {
        const content: []const u8 =
            \\ .{{
            \\     .address = "{s}",
            \\     .port = {d},
            \\     .maxclients = {d},
            \\     .maxmemory = {d},
            \\     .proto_max_bulk_len = {d},
            \\     .workers = {d},
            \\     .cbuffer = {d},
            \\     .whitelist = .{{
            \\         "{s}",
            \\         "{s}",
            \\         "{s}",
            \\         "{s}",
            \\      }},
            \\ }}
        ;

        const result = try std.fmt.allocPrint(allocator, content, .{
            self.address,
            self.port,
            self.maxclients,
            self.maxmemory,
            self.proto_max_bulk_len,
            self.workers,
            self.cbuffer,
            self.whitelist.items[0],
            self.whitelist.items[1],
            self.whitelist.items[2],
            self.whitelist.items[3],
        });
        defer allocator.free(result);

        utils.create_path(self.path);

        const file = try std.fs.cwd().openFile(self.path, .{ .mode = .write_only });
        defer file.close();

        std.debug.print("{s}", .{result});

        return result;
    }
};
