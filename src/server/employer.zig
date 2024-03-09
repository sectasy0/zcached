const std = @import("std");

const Worker = @import("worker.zig");
const Listener = @import("listener.zig");
const log = @import("logger.zig");
const utils = @import("utils.zig");

const StreamServer = @import("stream_server.zig");
const MemoryStorage = @import("storage.zig");
const Config = @import("config.zig");

const Allocator = std.mem.Allocator;
const Employer = @This();

server: StreamServer,

context: Context,

workers: []Worker,
threads: []std.Thread,

allocator: std.mem.Allocator,

pub const Context = struct {
    storage: *MemoryStorage,
    config: *const Config,
    logger: *const log.Logger,
};

pub fn init(allocator: Allocator, context: Context) !Employer {
    return .{
        .server = StreamServer.init(.{
            .kernel_backlog = 128,
            .reuse_address = true,
            .reuse_port = true,
        }),
        .context = context,
        .workers = try allocator.alloc(Worker, context.config.workers),
        .threads = try allocator.alloc(std.Thread, context.config.workers),
        .allocator = allocator,
    };
}

pub fn supervise(self: *Employer) void {
    self.server.listen(self.context.config.address) catch |err| {
        self.context.logger.log(
            .Error,
            "# failed to run server listener: {?}",
            .{err},
        );
    };

    utils.set_nonblocking(self.server.sockfd.?) catch |err| {
        self.context.logger.log(
            .Error,
            "# failed to set server fd to non-blocking: {?}",
            .{err},
        );
    };

    var listener = Listener.init(
        self.allocator,
        &self.server,
        self.context,
        self.context.config.cbuffer,
    );
    const fds_size = self.context.config.maxclients;

    for (0..self.context.config.workers) |i| {
        // every thread have own allocator.
        var gpa = std.heap.GeneralPurposeAllocator(.{
            .safety = true,
            // .verbose_log = true,
            // .retain_metadata = true,
        }){};
        var allocator = gpa.allocator();

        // + 1 becouse first index is always listener fd
        self.workers[i] = Worker.init(allocator, fds_size + 1) catch |err| {
            self.context.logger.log(
                .Error,
                "# failed to create worker: {?}",
                .{err},
            );
            return;
        };

        errdefer self.workers[i].deinit();

        self.threads[i] = std.Thread.spawn(
            .{},
            delegate,
            .{ &self.workers[i], &listener },
        ) catch |err| {
            self.context.logger.log(
                .Error,
                "# failed to swpan std.Thread: {?}",
                .{err},
            );
            return;
        };
    }

    for (0..self.context.config.workers) |i| self.threads[i].join();
}

fn delegate(worker: *Worker, listener: *Listener) void {
    listener.listen(worker);
}

pub fn deinit(self: *Employer) void {
    self.allocator.free(self.workers);
    self.allocator.free(self.threads);
}
