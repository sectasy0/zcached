const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tls_enabled = b.option(bool, "tls-enabled", "Enable TLS") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "tls_enabled", false);
    const tls_options = b.addOptions();
    tls_options.addOption(bool, "tls_enabled", true);

    const runtime_io = b.createModule(.{
        .root_source_file = b.path("src/runtime/io.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fs = b.createModule(.{
        .root_source_file = b.path("src/runtime/fs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "runtime_io", .module = runtime_io }},
    });
    const sync = b.addModule("sync", .{
        .root_source_file = b.path("src/runtime/sync.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "runtime_io", .module = runtime_io }},
    });
    const runtime_imports = [_]std.Build.Module.Import{
        .{ .name = "runtime_io", .module = runtime_io },
        .{ .name = "fs", .module = fs },
        .{ .name = "sync", .module = sync },
    };

    const exe = b.addExecutable(.{
        .name = "zcached",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &runtime_imports,
        }),
    });
    const exe_tls = b.addExecutable(.{
        .name = "zcached_tls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &runtime_imports,
        }),
    });
    const e2e = b.addExecutable(.{
        .name = "zcached_e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/e2e/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &runtime_imports,
        }),
    });
    const server = b.addModule("server", .{
        .root_source_file = b.path("src/server/server.zig"),
        .imports = &runtime_imports,
    });
    const unit_tests = b.addTest(.{
        .name = "zcached-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &runtime_imports,
        }),
    });

    for ([_]*std.Build.Module{ exe.root_module, e2e.root_module, unit_tests.root_module, server }) |module| {
        module.addOptions("build_options", options);
    }
    exe_tls.root_module.addOptions("build_options", tls_options);
    e2e.root_module.addImport("server", server);

    for ([_]*std.Build.Module{ exe.root_module, exe_tls.root_module, e2e.root_module, unit_tests.root_module }) |module| {
        module.link_libc = true;
    }
    for ([_]*std.Build.Module{ exe_tls.root_module, e2e.root_module }) |module| {
        module.linkSystemLibrary("ssl", .{});
        module.linkSystemLibrary("crypto", .{});
    }
    if (tls_enabled) {
        unit_tests.root_module.linkSystemLibrary("crypto", .{});
        unit_tests.root_module.linkSystemLibrary("ssl", .{});
        b.installArtifact(exe_tls);
    }

    b.installArtifact(exe);
    b.installArtifact(e2e);
    b.installArtifact(unit_tests);

    const run_cmd = b.addRunArtifact(exe);
    const run_e2e = b.addRunArtifact(e2e);
    for ([_]*std.Build.Step.Run{ run_cmd, run_e2e }) |run| {
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
    }
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const install_exe = b.addInstallArtifact(exe, .{});
    const install_exe_tls = b.addInstallArtifact(exe_tls, .{});
    const e2e_step = b.step("e2e", "Run e2e tests");
    e2e_step.dependOn(&install_exe.step);
    e2e_step.dependOn(&install_exe_tls.step);
    e2e_step.dependOn(&run_e2e.step);

    // Preserve terminal test output instead of using the build runner's test protocol.
    const run_unit_tests = std.Build.Step.Run.create(b, "run zcached-tests");
    run_unit_tests.addArtifactArg(unit_tests);
    run_unit_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    run_unit_tests.stdio = .inherit;
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);
}
