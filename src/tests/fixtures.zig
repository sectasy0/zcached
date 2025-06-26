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
    port: []const u8 = "7556",
    max_clients: []const u8 = "512",
    max_memory: []const u8 = "0",
    max_request_size: []const u8 = "10485760",
    workers: []const u8 = "4",
    cbuffer: []const u8 = "4096",
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

    pub fn create(self: *ConfigFile, allocator: std.mem.Allocator, override: ?[]const u8) !void {
        if (override) |content| return try self.__write(content);

        const content: []const u8 =
            \\ .{{
            \\     .address = "{s}",
            \\     .port = {s},
            \\     .max_clients = {s},
            \\     .max_memory = {s},
            \\     .max_request_size = {s},
            \\     .workers = {s},
            \\     .cbuffer = {s},
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
            self.max_clients,
            self.max_memory,
            self.max_request_size,
            self.workers,
            self.cbuffer,
            self.whitelist.items[0],
            self.whitelist.items[1],
            self.whitelist.items[2],
            self.whitelist.items[3],
        });
        defer allocator.free(result);

        try self.__write(result);
    }

    fn __write(self: *ConfigFile, content: []const u8) !void {
        utils.create_path(self.path);

        const file = try std.fs.cwd().createFile(self.path, .{});
        defer file.close();

        try file.writeAll(content);
    }
};
