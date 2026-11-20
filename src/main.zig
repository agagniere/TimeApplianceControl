const std = @import("std");
const argsParser = @import("args");
const tap = @import("tap");

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
            "\n  monitor  " ++ MonitorOptions.meta.full_text ++
            "\n  mro      " ++ MroOptions.meta.full_text,
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

const MonitorOptions = struct {
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

const InfoOptions = struct {
    pub const meta = .{
        .full_text = "Dump all info collected about the time card as a single JSON object to standard output",
    };
};

const Verbs = union(enum) {
    mro: MroOptions,
    info: InfoOptions,
    monitor: MonitorOptions,
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
        return gpa.print("/sys/class/timecard/{s}", .{name});
    }
    return gpa.print("/sys/class/timecard/ocp{}", .{options.options.@"ocp-number"});
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
                .monitor => try argsParser.printHelp(MonitorOptions, build_info.name ++ " monitor", output),
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
    if (!std.Io.Dir.path.isAbsolute(timecard_path)) {
        log.errAt(@src(), "Timecard's sysfs path required to be absolute. Provided path: '{s}'", .{timecard_path});
        return 1;
    }

    var root = std.Io.Dir.cwd().openDir(io, options.options.root, .{}) catch |err| {
        log.errAt(@src(), "Unable to open root directory '{s}': {t}", .{ options.options.root, err });
        return 1;
    };
    defer root.close(io);

    var timecard: Timecard = try .fromPath(gpa, io, root, timecard_path);
    defer timecard.deinit();

    switch (options.verb.?) {
        .info => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const json = try timecard.to_json(arena.allocator());
            try output.print("{f}\n", .{std.json.fmt(json, .{})});
        },
        .monitor => |monitor_options| try start_monitoring(io, timecard, monitor_options),
        .mro => {},
    }
    return 0;
}

fn start_monitoring(
    io: std.Io,
    timecard: Timecard,
    options: MonitorOptions,
) !void {
    const HostName = std.Io.net.HostName;
    var buffer: [2048]u8 = undefined;
    var canonical_name_buffer: [HostName.max_len]u8 = undefined;
    var lookup_buffer: [16]HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(HostName.LookupResult) = .init(&lookup_buffer);
    const host_name: HostName = try .init(options.@"statsd-address");
    try host_name.lookup(io, &lookup_queue, .{
        .port = options.@"statsd-port",
        .canonical_name_buffer = &canonical_name_buffer,
    });

    while (lookup_queue.getOne(io)) |result| switch (result) {
        .canonical_name => |name| log.debug("Statsd canonical address: {s}", .{name.bytes}),
        .address => |address| {
            const statsd = address.connect(io, .{ .mode = .dgram }) catch |err| {
                log.warnAt(@src(), "{f}: {t}", .{ address, err });
                continue;
            };
            defer statsd.close(io);
            var statsd_writer = statsd.writer(io, &buffer);
            log.info("Will send statsd metrics to {f}", .{address});
            return monitor(io, timecard, &statsd_writer.interface);
        },
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        error.Closed => {},
    }
    log.errAt(@src(), "Failed to connect to {s}:{}", .{ options.@"statsd-address", options.@"statsd-port" });
    return error.ConnectionFailed;
}

fn monitor(
    io: std.Io,
    timecard: Timecard,
    socket: *std.Io.Writer,
) !void {
    while (true) {
        const reading = try timecard.ptp_info.readOffset(true);
        std.log.debug("{s}: {f}", .{ timecard.ptp_info.name, std.Io.Duration.fromNanoseconds(reading) });
        try socket.print("{s}.offset:0|g\n{s}.offset:{}|g", .{ timecard.ptp_info.name, timecard.ptp_info.name, reading });

        try socket.flush();

        try io.sleep(.fromSeconds(10), .awake);
    }
}
