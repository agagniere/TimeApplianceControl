const std = @import("std");
const zon = @import("build.zig.zon");
const name = @tagName(zon.name);

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const argsParser = b.dependency("args", .{ .target = target, .optimize = optimize });
    const axe = b.dependency("axe", .{ .target = target, .optimize = optimize });

    const mod = b.addModule(name, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tap", .module = mod },
                .{ .name = "args", .module = argsParser.module("args") },
                .{ .name = "axe", .module = axe.module("axe") },
            },
        }),
        .use_llvm = true, // https://github.com/ziglang/zig/issues/24364
    });
    b.installArtifact(exe);

    { // Build info
        const build_info = b.addOptions();
        build_info.addOption([]const u8, "version", zon.version);
        build_info.addOption([]const u8, "name", name);
        exe.root_module.addOptions("build_info", build_info);
    }
    { // Run
        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }
    { // Test
        const test_step = b.step("test", "Run tests");
        const mod_tests = b.addTest(.{ .root_module = mod });
        //const exe_tests = b.addTest(.{ .root_module = exe.root_module });
        const run_mod_tests = b.addRunArtifact(mod_tests);
        //const run_exe_tests = b.addRunArtifact(exe_tests);
        test_step.dependOn(&run_mod_tests.step);
        //test_step.dependOn(&run_exe_tests.step);
    }
    { // Documentation
        const docs_step = b.step("docs", "Build the project documentation");
        const docs_obj = b.addObject(.{
            .name = name,
            .root_module = mod,
        });
        const install_docs = b.addInstallDirectory(.{
            .source_dir = docs_obj.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });
        docs_step.dependOn(&install_docs.step);
    }
}
