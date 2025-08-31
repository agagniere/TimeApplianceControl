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

fn monitor(
    gpa: Allocator,
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
