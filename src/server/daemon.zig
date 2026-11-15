const std = @import("std");
const fs = @import("fs");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

const EXIT = enum { SUCCESS, FAILURE, SETIDERR, SIGHERR, CHDERR, PIDERR };

pub fn daemonize(pid_path: []const u8) void {
    const parent_pid = c.fork();

    if (parent_pid < 0) std.process.exit(@intFromEnum(EXIT.FAILURE));

    if (parent_pid > 0) std.process.exit(@intFromEnum(EXIT.SUCCESS));

    if (c.setsid() < 0) std.process.exit(@intFromEnum(EXIT.SETIDERR));

    const pid = c.fork();

    if (pid < 0) std.process.exit(@intFromEnum(EXIT.FAILURE));

    if (pid > 0) std.process.exit(@intFromEnum(EXIT.SUCCESS));

    _ = c.umask(0x007);

    if (c.chdir("/") < 0) std.process.exit(@intFromEnum(EXIT.CHDERR));

    _ = c.close(std.posix.STDOUT_FILENO);
    _ = c.close(std.posix.STDERR_FILENO);

    createPidFile(pid_path, c.getpid()) catch {
        std.process.exit(@intFromEnum(EXIT.PIDERR));
    };
}

const MAX_PID_STRING: u8 = 100;

fn createPidFile(pid_path: []const u8, pid: c.pid_t) !void {
    var pid_file = try fs.cwd().createFile(
        pid_path,
        .{
            .truncate = true,
            .exclusive = false,
        },
    );
    defer pid_file.close();

    const Lock = fs.File.Lock;
    try pid_file.lock(Lock.exclusive);

    var buf: [MAX_PID_STRING]u8 = undefined;
    const pid_string = try std.fmt.bufPrint(&buf, "{d}", .{pid});

    _ = try pid_file.write(pid_string);
}
