const std = @import("std");
const argsParser = @import("args");
const axe = @import("axe");
const tap = @import("tap");
const cli = @import("cli");

const build_info = @import("build_info");

const log = axe.Axe(.{
    .format = "[%l%s%L] %m\n",
    .scope_format = " %",
    .loc_format = " %f:%F:%l",
    .level_text = .{
        .debug = "DEBUG",
        .info = "INFO ",
        .warn = "WARN ",
        .err = "ERROR",
    },
    .styles = .{
        .debug = &.{.dim},
    },
});
const Timecard = tap.Timecard;

pub const std_options: std.Options = .{
    .logFn = log.log,
    .log_level = .debug,
};

const CommonOptions = struct {
    @"ocp-number": u8 = 0,
    @"timecard-name": ?[]const u8 = null,
    @"timecard-path": ?[]const u8 = null,
    root: []const u8 = "/",
    help: bool = false,
    version: bool = false,
    pub const wrap_len = 40;

    pub const shorthands = .{
        .N = "ocp-number",
        .n = "timecard-name",
        .P = "timecard-path",
        .r = "root",
        .h = "help",
        .v = "version",
    };
    pub const meta = .{
        .usage_summary = "[-N NUMBER | -n NAME | -P PATH] [-r ROOT] [-h] [-v] COMMAND",
        .full_text =
        \\Control a time card from Open Compute Project's Time Appliance Project
        \\
        \\Commands:
        ++
            "\n  info     " ++ InfoOptions.meta.full_text ++
            "\n  mro      " ++ MroOptions.meta.full_text ++
            "\n\nMonitoring is done by tap-monitor",
        .option_docs = .{
            .@"ocp-number" = "Specify the number of the appliance. Its sysfs is then assumed to be at /sys/class/timecard/ocp<N>. Defaults to 0",
            .@"timecard-name" = "Specify the name of the appliance. Its sysfs is then assumed to be at /sys/class/timecard/<NAME>. Overrides --ocp-number",
            .@"timecard-path" = "Specify the absolute path of the appliance's sysfs. Overrides --timecard-name and --ocp-number",
            .root = "Resolve all absolute paths (sysfs and /dev) relative to this directory, like chroot. Defaults to /",
            .help = "Display this usage message on standard output and exit successfully",
            .version = "Show version information on standard output and exit successfully",
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

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    try log.init(io, null, init.environ_map);
    defer log.deinit();

    // Output stream
    const out_buffer: []u8 = try gpa.alloc(u8, 4096);
    defer gpa.free(out_buffer);
    var stdout: std.Io.File.Writer = std.Io.File.stdout().writer(io, out_buffer);
    var output: *std.Io.Writer = &stdout.interface;
    defer output.flush() catch {};

    // CLI arguments
    const options: ParsedArgs = argsParser.parseWithVerbForCurrentProcess(CommonOptions, Verbs, init, .{ .forward = log_error }) catch return 1;
    defer options.deinit();
    if (options.options.help or (options.verb == null and !options.options.version)) {
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

    const timecard_path = try cli.timecardPath(gpa, options.options);
    defer gpa.free(timecard_path);
    log.info("Starting {s} version {s}, with timecard at {s}", .{ build_info.name, build_info.version, timecard_path });
    var timecard: Timecard = cli.openTimecard(gpa, io, options.options.root, timecard_path) catch |err| switch (err) {
        error.InvalidOption => return 1,
        else => |e| return e,
    };
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
