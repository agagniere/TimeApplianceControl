const std = @import("std");
const zon = @import("build.zig.zon");
const name = @tagName(zon.name);

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const argsParser = b.dependency("args", .{ .target = target, .optimize = optimize });
    const axe = b.dependency("axe", .{ .target = target, .optimize = optimize });
    // Its build only offers to choose between Debug and its preferred release mode
    const opentelemetry = b.dependency("opentelemetry", .{ .target = target, .release = optimize != .debug });

    const ptp_clock_stub = b.createModule(.{
        .root_source_file = b.path("test/port.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Non-Linux targets are not supported, a stand-in for linux/ptp_clock.h only allows running tests on a development machine
    const ptp_clock = if (target.result.os.tag == .linux) b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("ptp_clock.h", "#include <linux/ptp_clock.h>\n"),
        .target = target,
        .optimize = optimize,
    }).createModule() else ptp_clock_stub;

    const mod = b.addModule(name, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ptp_clock", .module = ptp_clock },
        },
    });

    // One-off actions, with readable logs
    const tapctl: Program = .{ .name = name, .root_source_file = "src/main.zig", .imports = &.{
        .{ .name = "args", .module = argsParser.module("args") },
        .{ .name = "axe", .module = axe.module("axe") },
    } };
    // Long-running, reporting with OpenTelemetry
    const monitor: Program = .{ .name = "tap-monitor", .root_source_file = "src/monitor.zig", .imports = &.{
        .{ .name = "args", .module = argsParser.module("args") },
        .{ .name = "opentelemetry", .module = opentelemetry.module("sdk") },
    } };
    const exe = addExecutable(b, tapctl.name, tapctl, target, optimize, mod);
    b.installArtifact(exe);
    const monitor_exe = addExecutable(b, monitor.name, monitor, target, optimize, mod);
    b.installArtifact(monitor_exe);

    { // Run
        const run_step = b.step("run", "Run tapctl");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();

        const run_monitor_step = b.step("run-monitor", "Run tap-monitor");
        const run_monitor_cmd = b.addRunArtifact(monitor_exe);
        run_monitor_step.dependOn(&run_monitor_cmd.step);
        run_monitor_cmd.step.dependOn(b.getInstallStep());
        run_monitor_cmd.addPassthruArgs();
    }
    { // Test
        const test_step = b.step("test", "Run tests");
        const mod_tests = b.addTest(.{ .root_module = mod });
        //const exe_tests = b.addTest(.{ .root_module = exe.root_module });
        const run_mod_tests = b.addRunArtifact(mod_tests);
        //const run_exe_tests = b.addRunArtifact(exe_tests);
        test_step.dependOn(&run_mod_tests.step);
        //test_step.dependOn(&run_exe_tests.step);

        // End-to-end: run on fake timecards, with the PTP ioctls answered by the stand-in, whatever the target
        const e2e_step = b.step("e2e", "Run end-to-end tests on the fake timecards of test/fixtures and test/failures");
        const e2e_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ptp_clock", .module = ptp_clock_stub },
            },
        });
        const e2e_exe = addExecutable(b, name ++ "-e2e", tapctl, target, optimize, e2e_mod);
        const cases = [_]struct { []const u8, E2eCase }{
            .{ "test/fixtures/facebook", .{ .args = &.{ "--ocp-number", "0" } } },
            .{ "test/fixtures/art", .{ .args = &.{ "--ocp-number", "2" } } },
            .{ "test/failures/pci-delay-estimation", .{ .stderr_match = "adjustment is 4294967293ns (displayed by the driver as -3)" } },
            .{ "test/failures/unflashed-eeprom", .{ .stderr_match = "Unable to read serial number of ocp0: InvalidCharacter" } },
            .{ "test/failures/linux-6.8", .{ .exit_code = 1, .stderr_match = "only supports linux 6.9 and newer" } },
        };
        for (cases) |case|
            addE2eRun(b, e2e_step, e2e_exe, std.fs.path.basename(case[0]), b.path(case[0]), case[1]);

        // Git doesn't store file permissions, so this root is generated. Root can open the device anyway
        if (!isRoot()) {
            const no_sudo = b.addRunArtifact(b.addExecutable(.{
                .name = "no-sudo",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/no-sudo.zig"),
                    .target = b.graph.host,
                }),
            }));
            no_sudo.addDirectoryArg(b.path("test/fixtures/facebook"));
            no_sudo.addArg("ptp1");
            const root = no_sudo.addOutputDirectoryArg("no-sudo");
            addE2eRun(b, e2e_step, e2e_exe, "no-sudo", root, .{ .exit_code = 1, .stderr_match = "Reading the PTP clock requires root access, for example with sudo" });
        }
        test_step.dependOn(e2e_step);
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

const E2eCase = struct {
    args: []const []const u8 = &.{},
    exit_code: u8 = 0,
    /// The failure is expected to be detected and reported
    stderr_match: ?[]const u8 = null,
};

fn addE2eRun(b: *std.Build, step: *std.Build.Step, exe: *std.Build.Step.Compile, case_name: []const u8, root: std.Build.LazyPath, case: E2eCase) void {
    const run = b.addRunArtifact(exe);
    run.setName(b.fmt("e2e {s}", .{case_name}));
    run.addArg("--root");
    run.addDirectoryArg(root);
    run.addArgs(case.args);
    run.addArg("info");
    run.expectExitCode(case.exit_code);
    if (case.stderr_match) |match|
        run.expectStdErrMatch(match)
    else
        _ = run.captureStdErr(.{}); // Logs, rerun the command printed on failure to see them
    run.has_side_effects = true; // The content of the fixture is not tracked by the cache
    step.dependOn(&run.step);
}

fn isRoot() bool {
    return switch (@import("builtin").os.tag) {
        .linux => std.os.linux.geteuid() == 0,
        .windows => false,
        else => std.c.geteuid() == 0,
    };
}

/// An executable of this package, built on the `tap` library
const Program = struct {
    name: []const u8,
    root_source_file: []const u8,
    imports: []const std.Build.Module.Import,
};

fn addExecutable(
    b: *std.Build,
    exe_name: []const u8,
    program: Program,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    tap: *std.Build.Module,
) *std.Build.Step.Compile {
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", zon.version);
    build_info.addOption([]const u8, "name", program.name);
    const root_module = b.createModule(.{
        .root_source_file = b.path(program.root_source_file),
        .target = target,
        .optimize = optimize,
        .imports = program.imports,
    });
    root_module.addImport("tap", tap);
    root_module.addImport("cli", b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tap", .module = tap }},
    }));
    root_module.addOptions("build_info", build_info);
    return b.addExecutable(.{
        .name = exe_name,
        .root_module = root_module,
        .use_llvm = true, // https://github.com/ziglang/zig/issues/24364
    });
}
