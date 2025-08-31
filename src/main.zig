const std = @import("std");
const argsParser = @import("args");
const tap = @import("tap");
const cli = @import("cli.zig");

const builtin = @import("builtin");
const build_info = @import("build_info");

const log = tap.Log;
const Timecard = tap.Timecard;

pub const std_options: std.Options = .{
    .logFn = log.log,
    .log_level = .debug,
};

fn get_timecard_path(gpa: std.mem.Allocator, options: cli.ParsedArgs) ![]const u8 {
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
    defer log.deinit(gpa);

    // Output stream
    const out_buffer: []u8 = try gpa.alloc(u8, 4096);
    defer gpa.free(out_buffer);
    var stdout: std.fs.File.Writer = std.fs.File.stdout().writer(out_buffer);
    var output: *std.Io.Writer = &stdout.interface;
    defer output.flush() catch unreachable;

    const options: cli.ParsedArgs = (cli.parseCLI(gpa, output) catch return 1) orelse return 0;
    defer options.deinit();

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
        .monitor => |monitor_options| try start_monitoring(gpa, timecard, monitor_options),
        .mro => {},
    }
    return 0;
}

fn start_monitoring(
    gpa: std.mem.Allocator,
    timecard: Timecard,
    options: cli.MonitorOptions,
) !void {
    var buffer: [2048]u8 = undefined;
    const udp_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, 0);
    var statsd_file: std.fs.File = .{ .handle = udp_socket };
    var statsd_writer = statsd_file.writer(&buffer);
    const addresses = try std.net.getAddressList(gpa, options.@"statsd-address", options.@"statsd-port");
    defer addresses.deinit();

    if (addresses.canon_name) |name| {
        log.debug("Statsd canonical address: {s}", .{name});
    }
    for (addresses.addrs) |address| {
        std.posix.connect(udp_socket, &address.any, address.getOsSockLen()) catch |err| {
            log.warnAt(@src(), "{f}: {t}", .{ address, err });
            continue;
        };
        log.info("Will send statds metrics to {f}", .{address});
        try monitor(gpa, timecard, &statsd_writer.interface);
        break;
    } else {
        log.errAt(@src(), "Failed to connect to {s}:{}", .{ options.@"statsd-address", options.@"statsd-port" });
        return error.ConnexionFailed;
    }
}

fn monitor(
    gpa: std.mem.Allocator,
    timecard: Timecard,
    socket: *std.Io.Writer,
) !void {
    _ = gpa;

    var oscillator: ?std.fs.File = null;
    defer if (oscillator) |f| f.close();

    {
        var dev: std.fs.Dir = try std.fs.openDirAbsolute("/dev", .{});
        defer dev.close();

        // First try to use ttyGNSS2, to leave ttyGNSS to oscillatord
        if (timecard.serial_ports_name.get("GNSS2")) |port_name| {
            log.debug("Monitor GNSS receiver via /dev/{s}", .{port_name});
        } else if (timecard.serial_ports_name.get("GNSS")) |port_name| {
            log.debug("Monitor GNSS receiver via /dev/{s}", .{port_name});
        } else {
            log.warnAt(@src(), "No GNSS serial port, ublox will not be monitored", .{});
        }

        if (timecard.serial_ports_name.get("MAC")) |port_name| {
            if (timecard.pci_info.device == .@"ART Card") {
                log.debug("Monitoring MRO50 via /dev/{s}", .{port_name});
                oscillator = try dev.openFile(port_name, .{ .mode = .read_write });
            }
        }
    }

    while (true) {
        const reading = try timecard.ptp_info.readOffset(true);
        log.debug("{s}: {D}", .{ timecard.ptp_info.name, reading });
        try socket.print("{s}.offset:0|g\n{s}.offset:{}|g\n", .{ timecard.ptp_info.name, timecard.ptp_info.name, reading });

        if (oscillator) |osc| {
            var buffer_in: [64]u8 = undefined;
            var reader = osc.reader(&buffer_in);

            var writer = osc.writer(&.{});
            try writer.interface.writeAll("monitor1\r");

            const line = std.mem.trim(u8, try reader.interface.takeDelimiterExclusive('\n'), "\n\r");
            log.debug("> {s}", .{line});
            if (line.len == 60) {
                const hex = line[52..56];
                const raw: f32 = @floatFromInt(try std.fmt.parseUnsigned(u16, hex, 16));
                const x = 1 - raw / 4800;
                const res = 10000 * x / (1 - x);
                const temp = 4100 * 298.15 / (298.15 * @log(1e-5 * 4.7 * res) + 4100) - 273.15;
                log.debug("mro temp: {}", .{temp});
                try socket.print("mro50.board_temperature:{}|g\n", .{temp});
            }
        }

        socket.flush() catch |err| log.errAt(@src(), "{t}", .{err});

        std.Thread.sleep(5 * std.time.ns_per_s);
    }
}
