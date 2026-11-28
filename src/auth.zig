const Auth = @import("server/auth.zig");

pub const CommandGroup = Auth.CommandGroup;
pub const Permissions = Auth.Permissions;
pub const PrincipalConfig = Auth.PrincipalConfig;
pub const File = Auth.File;
pub const Session = Auth.Session;

pub fn initPath(allocator: @import("std").mem.Allocator, path: []const u8) !Auth {
    return Auth.initPath(allocator, path);
}
