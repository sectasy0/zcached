comptime {
    // protocol
    _ = @import("protocol/handler.zig");
    _ = @import("protocol/serializer.zig");
    _ = @import("protocol/deserializer.zig");

    // server
    _ = @import("server/cmd_handler.zig");
    _ = @import("server/err_handler.zig");
    // _ = @import("src/server/listener.zig");
    _ = @import("server/config.zig");
    _ = @import("server/storage.zig");
    // _ = @import("server/tracing.zig");
    // _ = @import("src/server/cli.zig");
    _ = @import("server/logger.zig");
    _ = @import("server/utils.zig");
    _ = @import("server/persistance.zig");
    _ = @import("server/access_control.zig");
}
