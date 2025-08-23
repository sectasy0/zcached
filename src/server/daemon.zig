const std = @import("std");
const os = std.os.linux;

const EXIT = enum { SUCCESS, FAILURE, SETIDERR, SIGHERR, CHDERR, PIDERR };

pub fn daemonize(pid_path: []const u8) void {
    const parent_pid: std.posix.pid_t = std.posix.fork() catch return;

    if (parent_pid < 0) std.posix.exit(@intFromEnum(EXIT.FAILURE));

    if (parent_pid > 0) std.posix.exit(@intFromEnum(EXIT.SUCCESS));

    if (std.os.linux.setsid() < 0) std.posix.exit(@intFromEnum(EXIT.SETIDERR));

    const pid: std.posix.pid_t = std.posix.fork() catch return;

    if (pid < 0) std.posix.exit(@intFromEnum(EXIT.FAILURE));

    if (pid > 0) std.posix.exit(@intFromEnum(EXIT.SUCCESS));

    _ = std.c.umask(0x007);

    std.posix.chdir("/") catch std.posix.exit(@intFromEnum(EXIT.CHDERR));

    std.posix.close(std.posix.STDOUT_FILENO);
    std.posix.close(std.posix.STDERR_FILENO);

    createPidFile(pid_path, os.getpid()) catch {
        std.posix.exit(@intFromEnum(EXIT.PIDERR));
    };
}

const MAX_PID_STRING: u8 = 100;

fn createPidFile(pid_path: []const u8, pid: std.posix.pid_t) !void {
    var pid_file = try std.fs.cwd().createFile(
        pid_path,
        .{
            .truncate = true,
            .exclusive = false,
        },
    );
    defer pid_file.close();

    const Lock = std.fs.File.Lock;
    try pid_file.lock(Lock.exclusive);

    var buf: [MAX_PID_STRING]u8 = undefined;
    const pid_string = try std.fmt.bufPrint(&buf, "{d}", .{pid});

    _ = try pid_file.write(pid_string);
}
