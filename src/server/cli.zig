//! Defines command-line options and parses process arguments for the server.

const std = @import("std");
const fs = @import("fs");

/// Command-line options accepted by the server executable.
pub const Args = struct {
    /// Optional path to the configuration file.
    @"config-path": ?[]const u8 = null,
    /// Optional path to the log file.
    @"log-path": ?[]const u8 = null,

    /// Whether to mirror log output to standard output.
    sout: bool = false,
    /// Whether to detach the server into the background.
    daemon: bool = false,
    /// Optional path for the daemon process ID file.
    pid: ?[]const u8 = null,
    /// Whether to print the version and exit.
    version: bool = false,
    /// Whether to print command-line help and exit.
    help: bool = false,

    /// Maps each supported shorthand option to its corresponding field name.
    pub const shorthands = .{
        .c = "config-path",
        .l = "log-path",
        .s = "sout",
        .d = "daemon",
        .pid = "pid",
        .v = "version",
        .h = "help",
    };
};

/// Holds both the parsed options and their parser's owned argument storage.
pub const ParserResult = struct {
    /// Parser whose argument slice must be released with `deinit`.
    parser: Parser,
    /// Parsed command-line options.
    args: Args,
};

/// Parses process arguments and provides help and version output.
pub const Parser = struct {
    /// Sentinel-terminated arguments owned by the parser allocator.
    _process_args: []const [:0]const u8 = undefined,
    /// Allocator used for the retained process-argument slice.
    _allocator: std.mem.Allocator,

    /// Parsed options associated with this parser.
    args: Args,

    /// Writes usage information to standard output.
    pub fn showHelp() !void {
        const stdout = fs.File.stdout();
        const help_text: []const u8 =
            \\Usage: zcached [OPTIONS]
            \\
            \\Description:
            \\  zcached is a lightweight, high-performance, in-memory key-value database.
            \\
            \\Options:
            \\  -c, --config <str>      Path to the configuration file (default: ./zcached).
            \\  -l, --log-path <str>    Path to the log file (default: ./logs/zcached.log).
            \\  -d, --daemon            Run zcached as a background process.
            \\  -pid                    Create pid file at specific location.
            \\  -v, --version           Display zcached's version and exit.
            \\  -h, --help              Display this help message and exit.
            \\
            \\Examples:
            \\  zcached --config-path /etc/zcached.conf
            \\
        ;
        try stdout.writeAll(help_text);
        try stdout.writeAll("\n");
    }

    /// Writes the executable version to standard output.
    pub fn showVersion() !void {
        const stdout = fs.File.stdout();
        const version_text: []const u8 =
            \\zcached 0.0.1
            \\
        ;
        try stdout.writeAll(version_text);
    }

    /// Copies process arguments into allocator-owned storage and parses them.
    /// The returned parser must be deinitialized; allocation and parse errors propagate.
    pub fn parse(allocator: std.mem.Allocator, process_args: std.process.Args) !ParserResult {
        var parser = Parser{ ._allocator = allocator, .args = .{} };
        parser._process_args = try process_args.toSlice(allocator);
        errdefer parser.deinit();
        parser.args = try parseArgs(parser._process_args);

        return .{ .parser = parser, .args = parser.args };
    }

    /// Converts an argument vector into options; argument zero is treated as the executable.
    pub fn parseArgs(process_args: []const [:0]const u8) !Args {
        var args = Args{};
        if (process_args.len == 1) return args;

        const fields = @typeInfo(Args).@"struct";
        inline for (fields.field_names, fields.field_types) |name, Field| {
            const short = try fieldShorthand(name);

            const field_args = try argsForField(
                name,
                Field,
                short,
                process_args,
            );
            if (field_args != null) {
                switch (Field) {
                    bool => @field(args, name) = true,
                    ?[]const u8 => {
                        if (std.mem.eql(u8, field_args.?[1], "")) {
                            try showHelp();
                            return error.MissingValue;
                        }

                        @field(args, name) = field_args.?[1];
                    },
                    else => return error.InvalidType,
                }
            }
        }
        return args;
    }

    /// Releases the copied process-argument slice using the allocator passed to `parse`.
    pub fn deinit(self: *const Parser) void {
        self._allocator.free(self._process_args);
    }

    /// Finds the shorthand associated with a field, or returns `error.InvalidShorthand`.
    fn fieldShorthand(field_name: []const u8) ![]const u8 {
        inline for (@typeInfo(@TypeOf(Args.shorthands)).@"struct".field_names) |name| {
            const value = @field(Args.shorthands, name);
            if (std.mem.eql(u8, value, field_name)) return name;
        }

        return error.InvalidShorthand;
    }

    /// Finds a matching long or short option and returns its name and following value.
    /// Boolean options have an empty value; missing non-boolean values are also empty.
    fn argsForField(comptime name: []const u8, comptime Field: type, short: []const u8, args: []const [:0]const u8) !?[2][]const u8 {
        for (args, 0..) |arg, index| {
            if (index == 0 or arg.len < 2 or arg[0] != '-') continue;

            const is_long = std.mem.startsWith(u8, arg, "--") and
                std.mem.eql(u8, arg[2..], name);
            const is_short = !std.mem.startsWith(u8, arg, "--") and
                std.mem.eql(u8, arg[1..], short);
            if (!is_long and !is_short) continue;

            if (Field == bool) return .{ name, "" };
            if (args.len > index + 1) return .{ name, args[index + 1] };
            return .{ name, "" };
        }
        return null;
    }
};
