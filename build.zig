const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    const tls_enabled = b.option(bool, "tls-enabled", "Enable TLS") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "tls_enabled", false);

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zcached",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = b.createModule(.{
            .root_source_file = .{
                .src_path = .{ .owner = b, .sub_path = "src/main.zig" },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addOptions("build_options", options);

    exe.linkLibC();

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    const e2e = b.addExecutable(.{
        .name = "zcached_e2e",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = b.createModule(.{
            .root_source_file = .{
                .src_path = .{ .owner = b, .sub_path = "src/tests/e2e/main.zig" },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    e2e.root_module.addOptions("build_options", options);

    const server = b.addModule(
        "server",
        .{
            .root_source_file = .{
                .src_path = .{
                    .owner = b,
                    .sub_path = "src/server/server.zig",
                },
            },
        },
    );

    server.addOptions("build_options", options);

    e2e.root_module.addImport("server", server);
    e2e.linkSystemLibrary("openssl");
    e2e.linkSystemLibrary("crypto");

    e2e.linkLibC();

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(e2e);

    const tls_options = b.addOptions();
    tls_options.addOption(bool, "tls_enabled", true);
    const exe_tls = b.addExecutable(.{
        .name = "zcached_tls",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = b.createModule(.{
            .root_source_file = .{
                .src_path = .{ .owner = b, .sub_path = "src/main.zig" },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    exe_tls.root_module.addOptions("build_options", tls_options);

    exe_tls.linkSystemLibrary("openssl");
    exe_tls.linkSystemLibrary("crypto");
    exe_tls.linkLibC();

    if (tls_enabled) {
        // This declares intent for the executable to be installed into the
        // standard location when the user invokes the "install" step (the default
        // step when running `zig build`).
        b.installArtifact(exe_tls);
    }

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const run_e2e = b.addRunArtifact(e2e);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_e2e.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_e2e.addArgs(args);
    }

    const install_exe = b.addInstallArtifact(exe, .{});
    const install_exe_tls = b.addInstallArtifact(exe_tls, .{});

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_e2e_step = b.step("e2e", "Run e2e tests");
    run_e2e_step.dependOn(&install_exe.step);
    run_e2e_step.dependOn(&install_exe_tls.step);
    run_e2e_step.dependOn(&run_e2e.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .name = "zcached-tests",
        .root_module = b.createModule(.{
            .root_source_file = .{
                .src_path = .{ .owner = b, .sub_path = "src/test.zig" },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    unit_tests.root_module.addOptions("build_options", options);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    unit_tests.linkLibC();

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    if (tls_enabled) {
        unit_tests.linkSystemLibrary("crypto");
        unit_tests.linkSystemLibrary("openssl");
    }

    b.installArtifact(unit_tests);
}
