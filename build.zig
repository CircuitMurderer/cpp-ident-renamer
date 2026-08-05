const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const llvm_prefix = b.option(
        []const u8,
        "llvm-prefix",
        "LLVM installation prefix containing include/clang-c and lib/libclang",
    );
    const clang_resource_dir = b.option(
        []const u8,
        "clang-resource-dir",
        "Clang resource directory containing include/stddef.h",
    ) orelse "";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "clang_resource_dir", clang_resource_dir);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.link_libc = true;
    root_module.linkSystemLibrary("clang", .{});
    root_module.addOptions("build_options", build_options);

    if (llvm_prefix) |prefix| {
        root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        root_module.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    }

    const exe = b.addExecutable(.{
        .name = "cpp-ident-renamer",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run cpp-ident-renamer");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.link_libc = true;
    test_module.linkSystemLibrary("clang", .{});
    test_module.addOptions("build_options", build_options);
    if (llvm_prefix) |prefix| {
        test_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        test_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        test_module.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    }
    const tests = b.addTest(.{ .root_module = test_module });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);

    const e2e_run = b.addSystemCommand(&.{"sh"});
    e2e_run.addFileArg(b.path("test/test-scan.sh"));
    e2e_run.addArtifactArg(exe);
    e2e_run.addFileInput(b.path("test/fixture/compile_commands.json"));
    e2e_run.addFileInput(b.path("test/fixture/cpp-ident-renamer.toml"));
    e2e_run.addFileInput(b.path("test/fixture/sample.cpp"));
    e2e_run.addFileInput(b.path("test/fixture/sample.hpp"));
    const e2e_step = b.step("test-e2e", "Run the checker against the C++ fixture");
    e2e_step.dependOn(&e2e_run.step);

    const fix_test_run = b.addSystemCommand(&.{"sh"});
    fix_test_run.addFileArg(b.path("test/test-fix.sh"));
    fix_test_run.addArtifactArg(exe);
    fix_test_run.addFileInput(b.path("test/fixture/compile_commands.json"));
    fix_test_run.addFileInput(b.path("test/fixture/cpp-ident-renamer.toml"));
    fix_test_run.addFileInput(b.path("test/fixture/sample.cpp"));
    fix_test_run.addFileInput(b.path("test/fixture/sample.hpp"));
    fix_test_run.addFileInput(b.path("test/safety_fixture/collision.cpp"));
    fix_test_run.addFileInput(b.path("test/safety_fixture/macro.cpp"));
    fix_test_run.addFileInput(b.path("test/safety_fixture/collision_commands.json"));
    fix_test_run.addFileInput(b.path("test/safety_fixture/macro_commands.json"));
    fix_test_run.addFileInput(b.path("test/safety_fixture/cpp-ident-renamer.toml"));
    const fix_test_step = b.step("test-fix", "Test successful fixes, safety refusal, and rollback");
    fix_test_step.dependOn(&fix_test_run.step);
}
