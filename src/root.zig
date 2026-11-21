const std = @import("std");

const parseSerialNumber = @import("serialnumber.zig").parseSerialNumber;
pub const PciInfo = @import("pci.zig").PciInfo;
const _ptp = @import("ptp.zig");
pub const PtpInfo = _ptp.PtpInfo;

const readfile = @import("readfile.zig");
const readFileFitting = readfile.readFileFitting;
const max_attribute_size = readfile.max_attribute_size;
const readListFromFile = readfile.readListFromFile;
const readIntegerFromFile = readfile.readIntegerFromFile;

const log = std.log.scoped(.timecard);

const Allocator = std.mem.Allocator;
const NameMap = std.array_hash_map.String([]const u8);
const assert = std.debug.assert;

/// Iterate through the tty folder and read each attribute
fn getSerialPortsName(alloc: Allocator, io: std.Io, root: std.Io.Dir) !NameMap {
    var result: NameMap = .empty;
    var tty_dir = root.openDir(io, "tty", .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                log.err("This program only supports linux 6.9 and newer, where the driver groups the ttys' read-only attributes in a folder", .{});
            },
            else => {},
        }
        return err;
    };
    defer tty_dir.close(io);
    var buffer: [max_attribute_size]u8 = undefined;
    var ttys = tty_dir.iterate();
    while (try ttys.next(io)) |tty_file| {
        if (!std.mem.startsWith(u8, tty_file.name, "tty")) {
            log.warn("Ignoring unexpected attribute '{s}' in the tty folder", .{tty_file.name});
            continue;
        }
        assert(tty_file.kind == .file); // sysfs attributes are files
        try result.put(
            alloc,
            try alloc.dupe(u8, tty_file.name[3..]),
            try alloc.dupe(u8, try readFileFitting(io, tty_dir, tty_file.name, &buffer)),
        );
    }
    return result;
}

const Connector = struct {
    name: []const u8,
    way: Way,
    value: []const u8,

    pub const Way = enum { input, output };

    pub fn fromFile(alloc: Allocator, io: std.Io, parent: std.Io.Dir, filename: []const u8) !Connector {
        var buffer: [max_attribute_size]u8 = undefined;
        const content = try readFileFitting(io, parent, filename, &buffer);
        const comma = std.mem.findScalar(u8, content, ':');
        const way: ?Way = blk: {
            if (comma) |c| {
                if (std.mem.eql(u8, content[0..c], "IN"))
                    break :blk .input;
                if (std.mem.eql(u8, content[0..c], "OUT"))
                    break :blk .output;
            }
            break :blk null;
        };

        if (comma == null or way == null) {
            log.err("Expected attribute '{s}' to be of the form '(IN|OUT): <format>', got instead: '{s}'", .{ filename, content });
            return error.InvalidFormat;
        }

        return .{
            .name = try alloc.dupe(u8, filename),
            .way = way.?,
            .value = try alloc.dupe(u8, std.mem.trim(u8, content[(comma.? + 1)..], " \n")),
        };
    }

    pub fn deinit(self: *Connector, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.value);
    }
};

fn findConnectors(alloc: Allocator, io: std.Io, dir: std.Io.Dir) ![]Connector {
    var result: std.ArrayList(Connector) = .empty;
    var files = dir.iterate();
    while (try files.next(io)) |file| {
        if (std.mem.startsWith(u8, file.name, "sma")) {
            try result.append(alloc, try .fromFile(alloc, io, dir, file.name));
        }
    }
    return result.toOwnedSlice(alloc);
}

fn readSerialNumber(io: std.Io, dir: std.Io.Dir) !u32 {
    var buffer: [max_attribute_size]u8 = undefined;
    const content = try readFileFitting(io, dir, "serialnum", &buffer);
    return parseSerialNumber(std.mem.trimEnd(u8, content, "\n"));
}

/// Opening an absolute path ignores the directory it is opened from
fn relativeToRoot(path: []const u8) []const u8 {
    const relative = std.mem.trimStart(u8, path, "/");
    return if (relative.len == 0) "." else relative;
}

/// Time Appliance handle
pub const Timecard = struct {
    /// Owns all the memory of the fields, freed at once
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    name: []const u8,
    path: []const u8,
    serialnumber: ?u32,
    serial_ports_name: NameMap,
    pci_info: PciInfo,
    ptp_info: PtpInfo,
    ios: []Connector,
    clock_source: ?[]const u8,
    available_clock_sources: ?[][]const u8,
    available_input_formats: [][]const u8,
    available_output_formats: [][]const u8,
    pci_delay_compensation: u32,

    /// `root` is the directory absolute paths are resolved from, `/` outside of tests
    pub fn fromPath(gpa: Allocator, io: std.Io, root: std.Io.Dir, path: []const u8) !Timecard {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        var dir = try root.openDir(io, relativeToRoot(path), .{ .iterate = true });
        defer dir.close(io);

        const name = try arena.dupe(u8, std.Io.Dir.path.basename(path));

        var pci_device = dir.openDir(io, "device", .{}) catch |err| {
            log.err("Expected a 'device' folder in the sysfs of {s}: {t}", .{ name, err });
            return err;
        };
        defer pci_device.close(io);
        if (comptime std.log.logEnabled(.debug, .timecard)) {
            var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            log.debug("Card {s} is part of the PCI device {s}", .{ name, buffer[0..try pci_device.realPath(io, &buffer)] });
        }

        const pci_info: PciInfo = try .fromDir(arena, io, pci_device);
        log.info("Card {s} detected as {s} {s} rev. {}, PCI x{}", .{
            name,
            if (pci_info.vendor) |vendor| @tagName(vendor) else "(unknown vendor)",
            if (pci_info.device) |device| @tagName(device) else "(unknown device)",
            pci_info.revision,
            pci_info.max_width,
        });

        var ptp_info: PtpInfo = try .init(arena, io, root, dir);
        errdefer ptp_info.close(io);
        log.info("Card {s} exposes PTP clock {s}", .{ name, ptp_info.name });

        var buffer: [max_attribute_size]u8 = undefined;
        const clock_source = readFileFitting(io, dir, "clock_source", &buffer) catch null;

        const printed_pci_delay: i64 = try readIntegerFromFile("timecard's sysfs", i64, io, dir, "ts_window_adjust");
        // The driver prints its u32 with %d, so large values show up negative
        const pci_delay: u32 = @truncate(@as(u64, @bitCast(printed_pci_delay)));
        if (printed_pci_delay < std.math.minInt(u32) or printed_pci_delay > std.math.maxInt(u32)) {
            log.err("Timecard {s}'s timestamp window adjustment is {}ns (displayed by the driver as {}), so the system timestamps of PTP readings are off by seconds. This is a known bug of linux 6.12 to 7.2, fixed in 7.3 and backported to 6.12.y, 6.18.y and 7.2.y in October 2026. To fix: sudo bash -c 'echo 0 > {s}/ts_window_adjust'", .{ name, pci_delay, printed_pci_delay, path });
        }

        // Allocate everything before copying the arena into the result
        var result: Timecard = .{
            .arena = undefined,
            .io = io,
            .name = name,
            .path = try arena.dupe(u8, path),
            .serialnumber = readSerialNumber(io, dir) catch |err| blk: {
                log.err("Unable to read serial number of {s}: {t}", .{ name, err });
                break :blk null;
            },
            .serial_ports_name = try getSerialPortsName(arena, io, dir),
            .pci_info = pci_info,
            .ptp_info = ptp_info,
            .ios = try findConnectors(arena, io, dir),
            .clock_source = if (clock_source) |src| try arena.dupe(u8, std.mem.trim(u8, src, "\n")) else null,
            .available_clock_sources = readListFromFile(arena, io, dir, "available_clock_sources", .{ .location = "timecard's sysfs", .mandatory = false }) catch null,
            .available_input_formats = try readListFromFile(arena, io, dir, "available_sma_inputs", .{ .location = "timecard's sysfs" }),
            .available_output_formats = try readListFromFile(arena, io, dir, "available_sma_outputs", .{ .location = "timecard's sysfs" }),
            .pci_delay_compensation = pci_delay,
        };
        result.arena = arena_state;
        return result;
    }

    pub fn deinit(self: *Timecard) void {
        self.ptp_info.close(self.io);
        self.arena.deinit();
    }

    pub fn to_json(self: Timecard, arena: Allocator) !std.json.Value {
        var top: std.json.ObjectMap = .empty;
        try top.ensureTotalCapacity(arena, 8);
        {
            var card: std.json.ObjectMap = .empty;
            if (self.serialnumber) |num| {
                try card.put(arena, "serial_number", .{ .integer = num });
            }
            try card.put(arena, "name", .{ .string = self.name });
            try card.put(arena, "path", .{ .string = self.path });
            if (self.clock_source) |source|
                try card.put(arena, "clock_source", .{ .string = source });
            try card.put(arena, "timestamp_window_adjustment", .{ .integer = self.pci_delay_compensation });
            {
                var smas: std.json.Array = .init(arena);
                for (self.ios) |io| {
                    var sma: std.json.ObjectMap = .empty;
                    try sma.put(arena, "name", .{ .string = io.name });
                    try sma.put(arena, "way", .{ .string = try arena.dupe(u8, @tagName(io.way)) });
                    try sma.put(arena, "format", .{ .string = io.value });
                    try smas.append(.{ .object = sma });
                }
                try card.put(arena, "connectors", .{ .array = smas });
            }
            {
                var available: std.json.ObjectMap = .empty;
                if (self.clock_source != null) {
                    var clocksrcs: std.json.Array = .init(arena);
                    if (self.available_clock_sources) |clock_sources| {
                        for (clock_sources) |clcksrc|
                            try clocksrcs.append(.{ .string = clcksrc });
                    }
                    try available.put(arena, "clock_source", .{ .array = clocksrcs });
                }
                {
                    var formats: std.json.ObjectMap = .empty;
                    {
                        var input: std.json.Array = .init(arena);
                        for (self.available_input_formats) |fmt|
                            try input.append(.{ .string = fmt });
                        try formats.put(arena, "input", .{ .array = input });
                    }
                    {
                        var output: std.json.Array = .init(arena);
                        for (self.available_output_formats) |fmt|
                            try output.append(.{ .string = fmt });
                        try formats.put(arena, "output", .{ .array = output });
                    }
                    try available.put(arena, "formats", .{ .object = formats });
                }
                try card.put(arena, "available", .{ .object = available });
            }
            try top.put(arena, "card", .{ .object = card });
        }
        {
            var ttys: std.json.ObjectMap = .empty;
            try ttys.ensureTotalCapacity(arena, self.serial_ports_name.count());
            var ite = self.serial_ports_name.iterator();
            while (ite.next()) |tty| {
                try ttys.put(arena, tty.key_ptr.*, .{ .string = tty.value_ptr.* });
            }
            try top.put(arena, "serial_ports", .{ .object = ttys });
        }
        {
            var ptp: std.json.ObjectMap = .empty;

            try ptp.put(arena, "name", .{ .string = self.ptp_info.name });
            {
                var caps: std.json.ObjectMap = .empty;
                try caps.ensureTotalCapacity(arena, 8);
                {
                    var freqadj: std.json.ObjectMap = .empty;
                    try freqadj.put(arena, "value", .{ .integer = self.ptp_info.capabilities.max_adj });
                    try freqadj.put(arena, "unit", .{ .string = try arena.dupe(u8, "ppb") });
                    try caps.put(arena, "max_frequency_adjustment", .{ .object = freqadj });
                }
                try caps.put(arena, "programmable_alarms", .{ .integer = self.ptp_info.capabilities.n_alarm });
                try caps.put(arena, "external_timestamp_channels", .{ .integer = self.ptp_info.capabilities.n_ext_ts });
                try caps.put(arena, "periodic_output_signals", .{ .integer = self.ptp_info.capabilities.n_per_out });
                try caps.put(arena, "pps_callback", .{ .bool = (self.ptp_info.capabilities.pps != 0) });
                try caps.put(arena, "cross_timestamping", .{ .bool = (self.ptp_info.capabilities.cross_timestamping != 0) });
                try caps.put(arena, "phase_adjustment", .{ .bool = (self.ptp_info.capabilities.adjust_phase != 0) });
                {
                    var phaseadj: std.json.ObjectMap = .empty;
                    try phaseadj.put(arena, "value", .{ .integer = self.ptp_info.capabilities.max_phase_adj });
                    try phaseadj.put(arena, "unit", .{ .string = try arena.dupe(u8, "ns") });
                    try caps.put(arena, "max_phase_adjustment", .{ .object = phaseadj });
                }
                try ptp.put(arena, "capabilities", .{ .object = caps });
            }
            {
                var pins: std.json.Array = .init(arena);
                try pins.ensureTotalCapacity(@intCast(self.ptp_info.capabilities.n_pins));
                for (self.ptp_info.pins) |pin| {
                    var obj: std.json.ObjectMap = .empty;
                    // The driver is trusted with neither terminating nor zero-padding the name
                    try obj.put(arena, "name", .{ .string = try arena.dupe(u8, std.mem.sliceTo(&pin.name, 0)) });
                    try obj.put(arena, "function", .{ .string = _ptp.pin_function_string[pin.func] });
                    try obj.put(arena, "channel", .{ .integer = pin.chan });
                    try pins.append(.{ .object = obj });
                }
                try ptp.put(arena, "pins", .{ .array = pins });
            }
            try top.put(arena, "ptp", .{ .object = ptp });
        }
        {
            var pci: std.json.ObjectMap = .empty;
            try pci.put(arena, "vendor", if (self.pci_info.vendor) |vendor| .{ .string = try arena.dupe(u8, @tagName(vendor)) } else .null);
            try pci.put(arena, "device", if (self.pci_info.device) |device| .{ .string = try arena.dupe(u8, @tagName(device)) } else .null);
            try pci.put(arena, "revision", .{ .integer = self.pci_info.revision });
            try pci.put(arena, "max_speed", .{ .string = self.pci_info.max_speed });
            try pci.put(arena, "max_width", .{ .integer = self.pci_info.max_width });
            try top.put(arena, "pci", .{ .object = pci });
        }
        return .{ .object = top };
    }
};

test {
    _ = @import("pci.zig");
    _ = @import("ptp.zig");
    _ = @import("readfile.zig");
    _ = @import("serialnumber.zig");
}
