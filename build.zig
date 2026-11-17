//! Defines executable, test, install, benchmark, and profiling steps for zcached.

const std = @import("std");

comptime {
    if (@import("builtin").zig_version.order(.{ .major = 0, .minor = 17, .patch = 1 }) == .lt) {
        @compileError("zcached requires Zig 0.17.1 or newer");
    }
}

/// Configures all build targets and exposes the project's run and test steps.
/// Target and optimization settings are shared where appropriate; TLS variants
/// are installed only when `-Dtls-enabled` is selected.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tls_enabled = b.option(bool, "tls-enabled", "Enable TLS") orelse false;

    const libc = b.addTranslateC(.{
        .root_source_file = b.path("src/runtime/libc.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
    const openssl_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/server/network/openssl.h"),
        .target = target,
        .optimize = optimize,
    });
    openssl_headers.linkSystemLibrary("ssl", .{});
    openssl_headers.linkSystemLibrary("crypto", .{});
    const openssl = openssl_headers.createModule();

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
        .{ .name = "c", .module = libc },
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
    const io_tests = b.addTest(.{
        .name = "zcached-io-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/evented.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    for ([_]*std.Build.Module{ exe.root_module, e2e.root_module, unit_tests.root_module, server }) |module| {
        module.addOptions("build_options", options);
    }
    exe_tls.root_module.addOptions("build_options", tls_options);
    exe_tls.root_module.addImport("openssl", openssl);
    server.addImport("openssl", openssl);
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
        run.addPassthruArgs();
    }
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.addPassthruArgs();
    b.step("benchmark", "Run the benchmark").dependOn(&run_benchmark.step);

    const profile = b.addExecutable(.{
        .name = "profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_profile = b.addRunArtifact(profile);
    run_profile.addArg("--server");
    run_profile.addArtifactArg(exe);
    run_profile.addArg("--benchmark");
    run_profile.addArtifactArg(benchmark);
    run_profile.addPassthruArgs();
    b.step("profile", "Benchmark an isolated server with macOS Time Profiler").dependOn(&run_profile.step);

    const install_exe = b.addInstallArtifact(exe, .{});
    const install_exe_tls = b.addInstallArtifact(exe_tls, .{});
    const e2e_step = b.step("e2e", "Run e2e tests");
    run_e2e.step.dependOn(&install_exe.step);
    run_e2e.step.dependOn(&install_exe_tls.step);
    e2e_step.dependOn(&run_e2e.step);

    // Preserve terminal test output instead of using the build runner's test protocol.
    const run_unit_tests = std.Build.Step.Run.create(b, "run zcached-tests");
    run_unit_tests.addArtifactArg(unit_tests);
    run_unit_tests.addPassthruArgs();
    run_unit_tests.stdio = .inherit;
    const run_io_tests = std.Build.Step.Run.create(b, "run zcached-io-tests");
    run_io_tests.addArtifactArg(io_tests);
    run_io_tests.addPassthruArgs();
    run_io_tests.stdio = .inherit;
    const benchmark_tests = b.addTest(.{ .root_module = benchmark.root_module });
    const run_benchmark_tests = std.Build.Step.Run.create(b, "run benchmark-tests");
    run_benchmark_tests.addArtifactArg(benchmark_tests);
    run_benchmark_tests.addPassthruArgs();
    run_benchmark_tests.stdio = .inherit;
    const profile_tests = b.addTest(.{ .root_module = profile.root_module });
    const run_profile_tests = std.Build.Step.Run.create(b, "run profile-tests");
    run_profile_tests.addArtifactArg(profile_tests);
    run_profile_tests.addPassthruArgs();
    run_profile_tests.stdio = .inherit;
    const test_step = b.step("test", "Run unit, native I/O, and benchmark tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_io_tests.step);
    test_step.dependOn(&run_benchmark_tests.step);
    test_step.dependOn(&run_profile_tests.step);
    b.step("test-io", "Run native I/O backend tests").dependOn(&run_io_tests.step);
}
