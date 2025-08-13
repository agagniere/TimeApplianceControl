const std = @import("std");
const argsParser = @import("args");
const tap = @import("tap");

const builtin = @import("builtin");
const build_info = @import("build_info");

const log = tap.Log;
const Timecard = tap.Timecard;

pub const std_options: std.Options = .{
    .logFn = log.log,
    .log_level = .debug,
};

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
        .usage_summary = "[-N NUMBER | -n NAME | -P PATH] [-h] [-v] COMMAND",
        .full_text =
        \\Control a time card from Open Compute Project's Time Appliance Project
        \\
        \\Commands:
    ++
        "\n  info  " ++ InfoOptions.meta.full_text ++
        "\n  mro   " ++ MroOptions.meta.full_text,
    .option_docs = .{
        .@"ocp-number" = "Specify the number of the appliance. Its sysfs is then assumed to be at /sys/class/timecard/ocp<N>. Defaults to 0",
        .@"timecard-name" = "Specify the name of the appliance. Its sysfs is then assumed to be at /sys/class/timecard/<NAME>. Overrides --ocp-number",
        .@"timecard-path" = "Specify the absolute path of the appliance's sysfs. Overrides --timecard-name and --ocp-number",
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
        .full_text = "Interact with an mRO50",
        .option_docs = .{
            .path = "Specify a custom path to the MRO's serial port. By default, it is determined from the ttyMAC attribute of the timecard",
        },
    };
};

const InfoOptions = struct {
    pub const meta = .{
        .full_text = "Dump all info collected about the time card as a single JSON object to standard output",
    };
};

const Verbs = union(enum) {
    mro: MroOptions,
    info: InfoOptions,
};

const ParsedArgs = argsParser.ParseArgsResult(CommonOptions, Verbs);

fn log_error(err: argsParser.Error) !void {
    log.scoped(.cli).err("{f}", .{err});
}

fn get_timecard_path(gpa: std.mem.Allocator, options: ParsedArgs) ![]const u8 {
    if (options.options.@"timecard-path") |path| {
        return gpa.dupe(u8, path);
    }
    if (options.options.@"timecard-name") |name| {
        return std.fmt.allocPrint(gpa, "/sys/class/timecard/{s}", .{name});
    }
    return std.fmt.allocPrint(gpa, "/sys/class/timecard/ocp{}", .{options.options.@"ocp-number"});
}

pub fn main() !u8 {
    // Allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = switch (builtin.mode) {
        .Debug, .ReleaseSafe => debug_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };

    try log.init(gpa, null, null);

    // Output stream
    const out_buffer: []u8 = try gpa.alloc(u8, 4096);
    defer gpa.free(out_buffer);
    var stdout: std.fs.File.Writer = std.fs.File.stdout().writer(out_buffer);
    var output: *std.Io.Writer = &stdout.interface;
    defer output.flush() catch unreachable;

    // CLI arguments
    const options: ParsedArgs = argsParser.parseWithVerbForCurrentProcess(CommonOptions, Verbs, gpa, .{ .forward = log_error }) catch return 1;
    defer options.deinit();
    if (options.options.help or options.verb == null) {
        if (options.verb) |verb| {
            switch (verb) {
                .mro => try argsParser.printHelp(MroOptions, build_info.name ++ " mro", output),
                .info => {},
            }
        } else {
            try argsParser.printHelp(CommonOptions, build_info.name, output);
        }
        return 0;
    }
    if (options.options.version) {
        try output.writeAll(build_info.name ++ " version " ++ build_info.version ++ "\n");
        return 0;
    }

    const timecard_path = try get_timecard_path(gpa, options);
    defer gpa.free(timecard_path);
    log.info("Starting {s} version {s}, with timecard at {s}", .{ build_info.name, build_info.version, timecard_path });
    if (!std.fs.path.isAbsolute(timecard_path)) {
        log.errAt(@src(), "Timecard's sysfs path required to be absolute. Provided path: '{s}'", .{timecard_path});
        return 1;
    }

    var timecard: Timecard = try .fromPath(gpa, timecard_path);
    defer timecard.deinit();

    switch (options.verb.?) {
        .info => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const json = try timecard.to_json(arena.allocator());
            try output.print("{f}\n", .{std.json.fmt(json, .{})});
        },
        .mro => {},
    }
    return 0;
}
