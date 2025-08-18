const std = @import("std");

const readSerialNumber = @import("serialnumber.zig").readSerialNumber;
pub const PciInfo = @import("pci.zig").PciInfo;
const _ptp = @import("ptp.zig");
pub const PtpInfo = _ptp.PtpInfo;
pub const Log = @import("log.zig").config;

const readfile = @import("readfile.zig");
const readListFromFile = readfile.readListFromFile;
const readIntegerFromFile = readfile.readIntegerFromFile;

const log = Log.scoped(.timecard);

const Allocator = std.mem.Allocator;
const NameMap = std.StringArrayHashMapUnmanaged([]const u8);
const assert = std.debug.assert;

/// Iterate through the tty folder and read each attribute
fn getSerialPortsName(gpa: Allocator, root: std.fs.Dir) !NameMap {
    var result: NameMap = .empty;
    var tty_dir = root.openDir("tty", .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                log.errAt(@src(), "This program only supports linux 6.9 and newer, where the driver groups the ttys read-only attributes in a folder", .{});
            },
            else => {},
        }
        return err;
    };
    defer tty_dir.close();
    var buffer: [32]u8 = undefined;
    var ttys = tty_dir.iterate();
    while (try ttys.next()) |tty_file| {
        assert(std.mem.startsWith(u8, tty_file.name, "tty"));
        assert(tty_file.kind == .file);
        try result.put(
            gpa,
            try gpa.dupe(u8, tty_file.name[3..]),
            try gpa.dupe(u8, try tty_dir.readFile(tty_file.name, &buffer)),
        );
    }
    return result;
}

const Connector = struct {
    name: []const u8,
    way: Way,
    value: []const u8,

    pub const Way = enum { input, output };

    pub fn fromFile(alloc: Allocator, parent: std.fs.Dir, filename: []const u8) !Connector {
        var buffer: [32]u8 = undefined;
        const content = try parent.readFile(filename, &buffer);
        const comma = std.mem.indexOfScalar(u8, content, ':');
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
            log.errAt(@src(), "Expected attribute '{s}' to be of the form '(IN|OUT): <format>', got instead: '{s}'", .{ filename, content });
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

fn findConnectors(alloc: Allocator, dir: std.fs.Dir) ![]Connector {
    var result: std.ArrayListUnmanaged(Connector) = .empty;
    var files = dir.iterate();
    while (try files.next()) |file| {
        if (std.mem.startsWith(u8, file.name, "sma")) {
            try result.append(alloc, try .fromFile(alloc, dir, file.name));
        }
    }
    return result.toOwnedSlice(alloc);
}

/// Time Appliance handle
pub const Timecard = struct {
    allocator: Allocator,
    name: []const u8,
    path: []const u8,
    serialnumber: ?u32,
    serial_ports_name: NameMap,
    pci_info: PciInfo,
    ptp_info: PtpInfo,
    ios: []Connector,
    clock_source: []const u8,
    available_clock_sources: [][]const u8,
    available_input_formats: [][]const u8,
    available_output_formats: [][]const u8,
    pci_delay_compensation: u32,

    pub fn fromPath(gpa: Allocator, path: []const u8) !Timecard {
        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();

        const name = try gpa.dupe(u8, std.fs.path.basename(path));
        errdefer gpa.free(name);

        var pci_device = dir.openDir("device", .{}) catch |err| {
            log.errAt(@src(), "Expected a 'device' folder in the sysfs of {s}: {t}", .{ name, err });
            return err;
        };
        defer pci_device.close();
        if (comptime std.log.logEnabled(.debug, .timecard)) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            log.debug("Card {s} is part of the PCI device {s}", .{ name, try pci_device.realpath(".", &buffer) });
        }

        var pci_info: PciInfo = try .fromDir(gpa, pci_device);
        errdefer pci_info.deinit(gpa);
        log.info("Card {s} detected as {s} {s} rev. {}, PCI x{}", .{
            name,
            if (pci_info.vendor) |vendor| @tagName(vendor) else "(unknown vendor)",
            if (pci_info.device) |device| @tagName(device) else "(unknown device)",
            pci_info.revision,
            pci_info.max_width,
        });

        var ptp_info: PtpInfo = try .init(gpa, dir);
        errdefer ptp_info.deinit(gpa);
        log.info("Card {s} exposes PTP clock {s}", .{ name, ptp_info.name });

        var buffer: [16]u8 = undefined;
        const clock_source = dir.readFile("clock_source", &buffer) catch |err| {
            log.errAt(@src(), "Expecting a file called 'clock_source' in {s}'s sysfs: {t}", .{ name, err });
            return err;
        };

        const pci_delay: i64 = try readIntegerFromFile("timecard's sysfs", i64, dir, "ts_window_adjust");
        if (pci_delay < std.math.minInt(u32) or pci_delay > std.math.maxInt(u32)) {
            log.errAt(@src(), "Timecard {s}'s timestamp window adjustement value {} doesn't fit in an u32. This is a known bug from linux 6.12 to 6.17. To fix: sudo bash -c 'echo 0 > {s}/ts_window_adjust'", .{ name, pci_delay, path });
        }

        return .{
            .allocator = gpa,
            .name = name,
            .path = try gpa.dupe(u8, path),
            .serialnumber = readSerialNumber(dir) catch |err| blk: {
                log.errAt(@src(), "Unable to read serial number of {s}: {t}", .{ name, err });
                break :blk null;
            },
            .serial_ports_name = try getSerialPortsName(gpa, dir),
            .pci_info = pci_info,
            .ptp_info = ptp_info,
            .ios = try findConnectors(gpa, dir),
            .clock_source = try gpa.dupe(u8, std.mem.trim(u8, clock_source, "\n")),
            .available_clock_sources = try readListFromFile("timecard's sysfs", gpa, dir, "available_clock_sources"),
            .available_input_formats = try readListFromFile("timecard's sysfs", gpa, dir, "available_sma_inputs"),
            .available_output_formats = try readListFromFile("timecard's sysfs", gpa, dir, "available_sma_outputs"),
            .pci_delay_compensation = @truncate(@as(u64, @bitCast(pci_delay))),
        };
    }

    pub fn deinit(self: *Timecard) void {
        self.pci_info.deinit(self.allocator);
        self.ptp_info.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.free(self.path);
        self.allocator.free(self.clock_source);

        var ttys = self.serial_ports_name.iterator();
        while (ttys.next()) |tty| {
            self.allocator.free(tty.key_ptr.*);
            self.allocator.free(tty.value_ptr.*);
        }
        self.serial_ports_name.deinit(self.allocator);

        for (self.ios) |*io| {
            io.deinit(self.allocator);
        }
        self.allocator.free(self.ios);
        for (self.available_clock_sources) |s|
            self.allocator.free(s);
        self.allocator.free(self.available_clock_sources);
        for (self.available_input_formats) |s|
            self.allocator.free(s);
        self.allocator.free(self.available_input_formats);
        for (self.available_output_formats) |s|
            self.allocator.free(s);
        self.allocator.free(self.available_output_formats);
    }

    pub fn to_json(self: Timecard, arena: Allocator) !std.json.Value {
        var top: std.json.ObjectMap = .init(arena);
        try top.ensureTotalCapacity(8);
        {
            var card: std.json.ObjectMap = .init(arena);
            if (self.serialnumber) |num| {
                try card.put("serial_number", .{ .integer = num });
            }
            try card.put("name", .{ .string = self.name });
            try card.put("path", .{ .string = self.path });
            try card.put("clock_source", .{ .string = self.clock_source });
            try card.put("timestamp_window_adjustment", .{ .integer = self.pci_delay_compensation });
            {
                var smas: std.json.Array = .init(arena);
                for (self.ios) |io| {
                    var sma: std.json.ObjectMap = .init(arena);
                    try sma.put("name", .{ .string = io.name });
                    try sma.put("way", .{ .string = try arena.dupe(u8, @tagName(io.way)) });
                    try sma.put("format", .{ .string = io.value });
                    try smas.append(.{ .object = sma });
                }
                try card.put("connectors", .{ .array = smas });
            }
            {
                var available: std.json.ObjectMap = .init(arena);
                {
                    var clocksrcs: std.json.Array = .init(arena);
                    for (self.available_clock_sources) |clcksrc|
                        try clocksrcs.append(.{ .string = clcksrc });
                    try available.put("clock_source", .{ .array = clocksrcs });
                }
                {
                    var formats: std.json.ObjectMap = .init(arena);
                    {
                        var input: std.json.Array = .init(arena);
                        for (self.available_input_formats) |fmt|
                            try input.append(.{ .string = fmt });
                        try formats.put("input", .{ .array = input });
                    }
                    {
                        var output: std.json.Array = .init(arena);
                        for (self.available_output_formats) |fmt|
                            try output.append(.{ .string = fmt });
                        try formats.put("output", .{ .array = output });
                    }
                    try available.put("formats", .{ .object = formats });
                }
                try card.put("available", .{ .object = available });
            }
            try top.put("card", .{ .object = card });
        }
        {
            var ttys: std.json.ObjectMap = .init(arena);
            try ttys.ensureTotalCapacity(self.serial_ports_name.count());
            var ite = self.serial_ports_name.iterator();
            while (ite.next()) |tty| {
                try ttys.put(tty.key_ptr.*, .{ .string = tty.value_ptr.* });
            }
            try top.put("serial_ports", .{ .object = ttys });
        }
        {
            var ptp: std.json.ObjectMap = .init(arena);

            try ptp.put("name", .{ .string = self.ptp_info.name });
            {
                var caps: std.json.ObjectMap = .init(arena);
                try caps.ensureTotalCapacity(8);
                {
                    var freqadj: std.json.ObjectMap = .init(arena);
                    try freqadj.put("value", .{ .integer = self.ptp_info.capabilities.max_adj });
                    try freqadj.put("unit", .{ .string = try arena.dupe(u8, "ppb") });
                    try caps.put("max_frequency_adjustment", .{ .object = freqadj });
                }
                try caps.put("programmable_alarms", .{ .integer = self.ptp_info.capabilities.n_alarm });
                try caps.put("external_timestamp_channels", .{ .integer = self.ptp_info.capabilities.n_ext_ts });
                try caps.put("periodic_output_signals", .{ .integer = self.ptp_info.capabilities.n_per_out });
                try caps.put("pps_callback", .{ .bool = (self.ptp_info.capabilities.pps != 0) });
                try caps.put("cross_timestamping", .{ .bool = (self.ptp_info.capabilities.cross_timestamping != 0) });
                try caps.put("phase_adjustment", .{ .bool = (self.ptp_info.capabilities.adjust_phase != 0) });
                {
                    var phaseadj: std.json.ObjectMap = .init(arena);
                    try phaseadj.put("value", .{ .integer = self.ptp_info.capabilities.max_phase_adj });
                    try phaseadj.put("unit", .{ .string = try arena.dupe(u8, "ns") });
                    try caps.put("max_phase_adjustment", .{ .object = phaseadj });
                }
                try ptp.put("capabilities", .{ .object = caps });
            }
            {
                var pins: std.json.Array = .init(arena);
                try pins.ensureTotalCapacity(@intCast(self.ptp_info.capabilities.n_pins));
                for (self.ptp_info.pins) |pin| {
                    const name: [*:0]const u8 = pin.name[0..(pin.name.len - 1) :0];
                    var obj: std.json.ObjectMap = .init(arena);
                    try obj.put("name", .{ .string = try arena.dupe(u8, std.mem.span(name)) });
                    try obj.put("function", .{ .string = _ptp.pin_function_string[pin.func] });
                    try obj.put("channel", .{ .integer = pin.chan });
                    try pins.append(.{ .object = obj });
                }
                try ptp.put("pins", .{ .array = pins });
            }
            try top.put("ptp", .{ .object = ptp });
        }
        {
            var pci: std.json.ObjectMap = .init(arena);
            try pci.put("vendor", if (self.pci_info.vendor) |vendor| .{ .string = try arena.dupe(u8, @tagName(vendor)) } else .null);
            try pci.put("device", if (self.pci_info.device) |device| .{ .string = try arena.dupe(u8, @tagName(device)) } else .null);
            try pci.put("revision", .{ .integer = self.pci_info.revision });
            try pci.put("max_speed", .{ .string = self.pci_info.max_speed });
            try pci.put("max_width", .{ .integer = self.pci_info.max_width });
            try top.put("pci", .{ .object = pci });
        }
        return .{ .object = top };
    }
};
