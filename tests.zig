comptime {
    // protocol
    _ = @import("src/protocol/handler.zig");
    _ = @import("src/protocol/serializer.zig");
    _ = @import("src/protocol/deserializer.zig");

    // server
    _ = @import("src/server/cmd_handler.zig");
    _ = @import("src/server/err_handler.zig");
    _ = @import("src/server/listener.zig");
    _ = @import("src/server/config.zig");
    _ = @import("src/server/storage.zig");
    _ = @import("src/server/tracing.zig");
    _ = @import("src/server/cli.zig");
    _ = @import("src/server/logger.zig");
    _ = @import("src/server/utils.zig");
    _ = @import("src/server/persistance.zig");
}
