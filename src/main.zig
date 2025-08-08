const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");
const argsParser = @import("args");

const CommonOptions = struct {
    @"ocp-number": u8 = 0,
    @"timecard-name": ?[]const u8 = null,
    @"timecard-path": ?[]const u8 = null,
    help: bool = false,
    version: bool = false,

    pub const shorthands = .{
        .N = "ocp-number",
        .n = "timecard-name",
        .P = "timecard-path",
        .h = "help",
        .v = "version",
    };
    pub const meta = .{
        .usage_summary = "[-N NUMBER | -n NAME | -P PATH] [-h] [-v] (mro | info)",
        .full_text = "Control a Time Appliance from the Open Compute Project's Time Appliance Project",
        .option_docs = .{
            .@"ocp-number" = "Specify the number of the appliance, that is then assumed to be at /sys/class/timecard/ocp<N>. Defaults to 0",
            .@"timecard-name" = "Specify the name of the appliance, that is then assumed to be at /sys/class/timecard/<NAME>. Overrides --ocp-number",
            .@"timecard-path" = "Specify the absolute path the appliance. Overrides --timecard-name and --ocp-number",
            .help = "Display this usage message on standard output and exit successfully",
            .version = "Show version information of the standard output and exit successfully",
        },
    };
};

const MroOptions = struct {
    path: ?[]const u8 = null,

    pub const shorthands = .{};
    pub const meta = .{
        .usage_summary = "[--path PATH]",
        .option_docs = .{
            .path = "Specify a custom path to the MRO's serial port. By default, it is determined from the ttyMAC attriibute of the timecard",
        },
    };
};

const Verbs = union(enum) {
    mro: MroOptions,
    info: void,
};

const ParsedArgs = argsParser.ParseArgsResult(CommonOptions, Verbs);

fn log_error(err: argsParser.Error) !void {
    std.log.err("{f}", .{err});
}

fn get_timecard_dir(options: ParsedArgs) !std.fs.Dir {
    if (options.options.@"timecard-path") |path| {
        return std.fs.openDirAbsolute(path, .{});
    }
    var parent = try std.fs.openDirAbsolute("/sys/class/timecard", .{});
    defer parent.close();
    if (options.options.@"timecard-name") |name| {
        return parent.openDir(name, .{});
    }
    var buffer: [4]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffer, "ocp{}", .{options.options.@"ocp-number"});
    return parent.openDir(name, .{});
}

pub fn main() !u8 {
    // Allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = switch (builtin.mode) {
        .Debug, .ReleaseSafe => debug_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };

    // Output stream
    const out_buffer: []u8 = try gpa.alloc(u8, 4096);
    defer gpa.free(out_buffer);
    var stdout: std.fs.File.Writer = std.fs.File.stdout().writer(out_buffer);
    var output: *std.Io.Writer = &stdout.interface;
    defer output.flush() catch unreachable;

    // CLI arguments
    const options: ParsedArgs = argsParser.parseWithVerbForCurrentProcess(CommonOptions, Verbs, gpa, .{ .forward = log_error }) catch return 1;
    defer options.deinit();
    if (options.options.help) {
        try argsParser.printHelp(CommonOptions, build_info.name, output);
        if (options.verb) |verb| {
            try output.writeByte('\n');
            switch (verb) {
                .mro => try argsParser.printHelp(MroOptions, build_info.name ++ " mro", output),
                .info => {},
            }
        }
        return 0;
    }
    if (options.options.version) {
        try output.writeAll(build_info.name ++ " version " ++ build_info.version ++ "\n");
        return 0;
    }

    var timecard_dir = try get_timecard_dir(options);
    defer timecard_dir.close();
    const timecard_path = try timecard_dir.realpathAlloc(gpa, ".");
    defer gpa.free(timecard_path);

    std.log.info("Starting {s} version {s}, with timecard at {s}", .{ build_info.name, build_info.version, timecard_path });

    return 0;
}
