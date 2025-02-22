const std = @import("std");
const build_options = @import("build_options");

const Listener = @import("../network/listener.zig");
const StreamServer = @import("../network/stream_server.zig");

const Logger = @import("../logger.zig");
const Config = @import("../config.zig");
const utils = @import("../utils.zig");

const Memory = @import("../storage/memory.zig");
const Worker = @import("../processing/worker.zig");

const Allocator = std.mem.Allocator;
const Employer = @This();

server: StreamServer,

context: Context,

workers: []Worker,
threads: []std.Thread,

allocator: std.mem.Allocator,

pub const Context = struct {
    memory: *Memory,
    config: *const Config,
    logger: *Logger,
};

pub fn init(allocator: Allocator, context: Context) !Employer {
    if (context.config.secure_transport and build_options.tls_enabled) {
        context.logger.log(.Info, "# zcached is running with TLS enabled", .{});
    }

    return .{
        .server = try StreamServer.init(.{
            .reuse_address = true,
            .reuse_port = true,
            .tls = context.config.secure_transport,
            .cert_path = context.config.cert_path,
            .key_path = context.config.key_path,
            .force_nonblocking = true,
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

    if (self.server.sockfd == null) {
        const err = error.AddressNotAvailable;

        // temporary set `sout` to true to force stdout print.
        const prev_sout = self.context.logger.sout;
        self.context.logger.sout = true;

        self.context.logger.log(
            .Error,
            "# failed to run server listener: {?}",
            .{err},
        );
        self.context.logger.sout = prev_sout;
        return;
    }

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
        const allocator = gpa.allocator();

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
