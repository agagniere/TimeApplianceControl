const std = @import("std");
const tap = @import("root.zig");

const log = tap.Log.scoped(.monitor);
const Timecard = tap.Timecard;
const Allocator = std.mem.Allocator;

pub fn start_monitoring(
    gpa: Allocator,
    timecard: Timecard,
    statsd_address: []const u8,
    statsd_port: u16,
) !void {
    var buffer: [2048]u8 = undefined;
    const udp_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(udp_socket);
    const statsd_file: std.fs.File = .{ .handle = udp_socket };
    var statsd_writer = statsd_file.writer(&buffer);
    const addresses = try std.net.getAddressList(gpa, statsd_address, statsd_port);
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
        log.errAt(@src(), "Failed to connect to {s}:{}", .{ statsd_address, statsd_port });
        return error.ConnexionFailed;
    }
}

const Mro50 = struct {
    file: std.fs.File,
    buffer: [64]u8 = undefined,
    reader: std.fs.File.Reader,
    writer: std.fs.File.Writer,

    pub fn init(target: std.fs.File) Mro50 {
        var result: Mro50 = .{
            .file = target,
            .reader = undefined,
            .writer = undefined,
        };
        result.reader = result.file.reader(&result.buffer);
        result.writer = result.file.writer(&.{});
        return result;
    }

    pub fn deinit(self: Mro50) void {
        self.file.close();
    }

    pub fn monitor(self: *Mro50) !Monitor {
        try self.writer.interface.writeAll("monitor1\r");
        const line = try self.reader.interface.takeDelimiterExclusive('\n');
        if (line.len != 61 or line[line.len - 1] != '\r')
            return error.UnexpectedFormat;

        return .{
            .line = line[0 .. line.len - 1],
            .board_temperature = temperature(try fromHex(line[52..56]), 47e3),
        };
    }

    const Monitor = struct {
        line: []const u8,
        board_temperature: f32,
    };
};

fn fromHex(string: []u8) !f32 {
    std.debug.assert(string.len == 4);
    return @floatFromInt(try std.fmt.parseUnsigned(u16, string, 16));
}

fn resistance(raw: f32, factor: comptime_int) f32 {
    const adc_max = 4095;
    const x = raw / adc_max;
    return factor * x / (1 - x);
}

fn temperature(raw: f32, factor: comptime_int) f32 {
    const deg0 = 273.15;
    const deg25 = 25 + deg0;
    const A = 4100;
    return A * deg25 / (deg25 * @log(1e-5 * resistance(raw, factor)) + A) - deg0;
}

fn monitor(
    gpa: Allocator,
    timecard: Timecard,
    socket: *std.Io.Writer,
) !void {
    _ = gpa;

    var oscillator: ?Mro50 = null;
    defer if (oscillator) |*f| f.deinit();

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
                oscillator = .init(try dev.openFile(port_name, .{ .mode = .read_write }));
            }
        }
    }

    while (true) {
        const reading = try timecard.ptp_info.readOffset(true);
        log.debug("{s}: {D}", .{ timecard.ptp_info.name, reading });
        try socket.print("{s}.offset:0|g\n{s}.offset:{}|g\n", .{ timecard.ptp_info.name, timecard.ptp_info.name, reading });

        if (oscillator) |*mro| {
            const mon = try mro.monitor();
            try socket.print("mro50.board_temperature:{}|g\n", .{mon.board_temperature});
        }

        socket.flush() catch |err| log.errAt(@src(), "{t}", .{err});

        std.Thread.sleep(5 * std.time.ns_per_s);
    }
}
