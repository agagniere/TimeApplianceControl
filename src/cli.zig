const std = @import("std");
const argsParser = @import("args");
const tap = @import("tap");
const build_info = @import("build_info");

const log = tap.Log.scoped(.cli);
const Allocator = std.mem.Allocator;

pub const ParsedArgs = argsParser.ParseArgsResult(CommonOptions, Verbs);

pub const CommonOptions = struct {
    @"ocp-number": u8 = 0,
    @"timecard-name": ?[]const u8 = null,
    @"timecard-path": ?[]const u8 = null,
    help: bool = false,
    version: bool = false,
    pub const wrap_len = 40;

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
        "\n  info     " ++ InfoOptions.meta.full_text ++
        "\n  monitor  " ++ MonitorOptions.meta.full_text ++
        "\n  mro      " ++ MroOptions.meta.full_text,
    .option_docs = .{
        .@"ocp-number" = "Specify the number of the appliance. Its sysfs is then assumed to be at /sys/class/timecard/ocp<N>. Defaults to 0",
        .@"timecard-name" = "Specify the name of the appliance. Its sysfs is then assumed to be at /sys/class/timecard/<NAME>. Overrides --ocp-number",
        .@"timecard-path" = "Specify the absolute path of the appliance's sysfs. Overrides --timecard-name and --ocp-number",
        .help = "Display this usage message on standard output and exit successfully",
        .version = "Show version information of the standard output and exit successfully",
    },
    };
};

pub const MroOptions = struct {
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

pub const MonitorOptions = struct {
    @"statsd-address": []const u8 = "localhost",
    @"statsd-port": u16 = 8125,

    pub const shorthands = .{
        .S = "statsd-address",
        .s = "statsd-port",
    };
    pub const meta = .{
        .usage_summary = "[-S ADDRESS] [-s PORT]",
        .full_text = "Collect metrics from the clock and possibly the oscillator, pushed to statsd",
        .option_docs = .{
            .@"statsd-address" = "Specify which address to push statsd metrics to. Defaults to localhost",
            .@"statsd-port" = "Specify which port to push statsd metrics to. Defaults to 8125",
        },
    };
};

pub const InfoOptions = struct {
    pub const meta = .{
        .full_text = "Dump all info collected about the time card as a single JSON object to standard output",
    };
};

const Verbs = union(enum) {
    mro: MroOptions,
    info: InfoOptions,
    monitor: MonitorOptions,
};

fn log_error(err: argsParser.Error) !void {
    log.err("{f}", .{err});
}

fn printHelp(options: ParsedArgs, output: *std.Io.Writer) !void {
    if (options.verb) |verb| {
        switch (verb) {
            .mro => try argsParser.printHelp(MroOptions, build_info.name ++ " mro", output),
            .monitor => try argsParser.printHelp(MonitorOptions, build_info.name ++ " monitor", output),
            .info => try argsParser.printHelp(InfoOptions, build_info.name ++ " info", output),
        }
    } else {
        try argsParser.printHelp(CommonOptions, build_info.name, output);
    }
}

/// Parse command line arguments
/// return an error in case of invalid arguments
/// returns null if the version or help was output and the program needs to stop
pub fn parseCLI(gpa: Allocator, output: *std.Io.Writer) !?ParsedArgs {
    const options: ParsedArgs = try argsParser.parseWithVerbForCurrentProcess(CommonOptions, Verbs, gpa, .{ .forward = log_error });
    errdefer options.deinit();

    if (options.options.help) {
        try printHelp(options, output);
    } else if (options.options.version) {
        try output.writeAll(build_info.name ++ " version " ++ build_info.version ++ "\n");
    } else if (options.verb == null) {
        try printHelp(options, output);
    } else {
        return options;
    }
    options.deinit();
    return null;
}
