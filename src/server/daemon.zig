//! Implements daemon process detachment, standard-stream redirection, and PID-file creation.

const std = @import("std");
const fs = @import("fs");
const c = @import("c");

/// Exit status codes used by the daemon setup stages.
const EXIT = enum { SUCCESS, FAILURE, SETIDERR, SIGHERR, CHDERR, PIDERR, STDIOERR };

/// Forks into the background, redirects output, and writes the child PID.
/// Setup failures terminate the process with a stage-specific status code.
pub fn daemonize(pid_path: []const u8) void {
    const parent_pid = c.fork();

    if (parent_pid < 0) std.process.exit(@backingInt(EXIT.FAILURE));

    if (parent_pid > 0) std.process.exit(@backingInt(EXIT.SUCCESS));

    if (c.setsid() < 0) std.process.exit(@backingInt(EXIT.SETIDERR));

    const pid = c.fork();

    if (pid < 0) std.process.exit(@backingInt(EXIT.FAILURE));

    if (pid > 0) std.process.exit(@backingInt(EXIT.SUCCESS));

    _ = c.umask(0x007);

    if (c.chdir("/") < 0) std.process.exit(@backingInt(EXIT.CHDERR));

    redirectOutput() catch |err| {
        std.log.err("# failed to redirect daemon output: {s}", .{@errorName(err)});
        std.process.exit(@backingInt(EXIT.STDIOERR));
    };

    createPidFile(pid_path, c.getpid()) catch {
        std.process.exit(@backingInt(EXIT.PIDERR));
    };
}

/// Replaces standard output and error with `/dev/null`, retrying interrupted descriptor copies.
fn redirectOutput() !void {
    const null_file = try fs.cwd().openFile("/dev/null", .{ .mode = .read_write });
    defer if (null_file.inner.handle != std.posix.STDOUT_FILENO and null_file.inner.handle != std.posix.STDERR_FILENO) null_file.close();
    // Keep these descriptors occupied so reactor handles cannot be mistaken for stdout/stderr.
    for ([_]c_int{ std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO }) |target| {
        while (true) {
            const result = c.dup2(null_file.inner.handle, target);
            switch (std.posix.errno(result)) {
                .SUCCESS => break,
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }
}

/// Maximum capacity reserved for the decimal representation of a process ID.
const MAX_PID_STRING: u8 = 100;

/// Creates or truncates and exclusively locks a file before writing the process ID.
/// File-system, lock, formatting, and write errors are returned to the caller.
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
