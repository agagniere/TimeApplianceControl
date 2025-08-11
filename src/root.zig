const std = @import("std");

const readSerialNumber = @import("serialnumber.zig").readSerialNumber;
pub const PciInfo = @import("pci.zig").PciInfo;
pub const PtpInfo = @import("ptp.zig").PtpInfo;

const Allocator = std.mem.Allocator;
const NameMap = std.StringArrayHashMapUnmanaged([]const u8);
const assert = std.debug.assert;

const log = std.log.scoped(.timecard);

/// Iterate through the tty folder a read each attribute
fn getSerialPortsName(gpa: Allocator, root: std.fs.Dir) !NameMap {
    var result: NameMap = .empty;
    var tty_dir = root.openDir("tty", .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.log.err("This program only supports linux 6.9 and newer, where the driver groups the ttys read-only attributes in a folder", .{});
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
        try result.put(gpa, try gpa.dupe(u8, tty_file.name[3..]), try gpa.dupe(u8, try tty_dir.readFile(tty_file.name, &buffer)));
    }
    return result;
}

/// Time Appliance handle
pub const Timecard = struct {
    allocator: Allocator,
    name: []const u8,
    serialnumber: u32,
    serial_ports_name: NameMap,
    pci_info: PciInfo,
    ptp_info: PtpInfo,

    const Self = @This();

    pub fn fromPath(gpa: Allocator, path: []const u8) !Self {
        var dir = try std.fs.openDirAbsolute(path, .{});
        defer dir.close();
        return fromDir(gpa, std.fs.path.basename(path), dir);
    }

    fn fromDir(gpa: Allocator, name: []const u8, dir: std.fs.Dir) !Self {
        var pci_device = try dir.openDir("device", .{});
        defer pci_device.close();
        if (comptime std.log.logEnabled(.debug, .timecard)) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            log.debug("Card {s} is part of the PCI device {s}", .{ name, try pci_device.realpath(".", &buffer) });
        }

        var pci_info: PciInfo = try .fromDir(gpa, pci_device);
        errdefer pci_info.deinit(gpa);
        //if (pci_info.vendor != null and pci_info.device != null)
        log.info("Card {s} detected as {t} {t} rev. {}, PCI x{}", .{ name, pci_info.vendor.?, pci_info.device.?, pci_info.revision, pci_info.max_width });

        var ptp_info: PtpInfo = try .init(gpa, dir);
        errdefer ptp_info.deinit(gpa);
        log.info("Card {s} exposes PTP clock {s}", .{ name, ptp_info.name });

        return .{
            .allocator = gpa,
            .name = try gpa.dupe(u8, name),
            .serialnumber = try readSerialNumber(dir),
            .serial_ports_name = try getSerialPortsName(gpa, dir),
            .pci_info = pci_info,
            .ptp_info = ptp_info,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pci_info.deinit(self.allocator);
        self.ptp_info.deinit(self.allocator);
        self.allocator.free(self.name);

        var ttys = self.serial_ports_name.iterator();
        while (ttys.next()) |tty| {
            self.allocator.free(tty.key_ptr.*);
            self.allocator.free(tty.value_ptr.*);
        }
        self.serial_ports_name.deinit(self.allocator);
    }

    pub fn to_json(self: Self, arena: Allocator) !std.json.Value {
        var top: std.json.ObjectMap = .init(arena);
        try top.ensureTotalCapacity(8);
        {
            var card: std.json.ObjectMap = .init(arena);
            try card.put("serial_number", .{ .integer = self.serialnumber });
            try card.put("name", .{ .string = self.name });
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
            var caps: std.json.ObjectMap = .init(arena);
            var pins: std.json.Array = .init(arena);
            try caps.ensureTotalCapacity(8);
            try pins.ensureTotalCapacity(@intCast(self.ptp_info.capabilities.n_pins));
            try caps.put("programmable_alarms", .{ .integer = self.ptp_info.capabilities.n_alarm });
            try caps.put("external_timestamp_channels", .{ .integer = self.ptp_info.capabilities.n_ext_ts });
            try caps.put("periodic_signals", .{ .integer = self.ptp_info.capabilities.n_per_out });
            try caps.put("pps_callback", .{ .bool = (self.ptp_info.capabilities.pps != 0) });
            try caps.put("cross_timestamping", .{ .bool = (self.ptp_info.capabilities.cross_timestamping != 0) });
            try caps.put("phase_adjustment", .{ .bool = (self.ptp_info.capabilities.adjust_phase != 0) });
            for (self.ptp_info.pins) |pin| {
                var obj: std.json.ObjectMap = .init(arena);
                try obj.put("name", .{ .string = pin.name[0..std.mem.indexOfScalar(u8, pin.name[0..64], 0).?] });
                try pins.append(.{ .object = obj });
            }
            try ptp.put("name", .{ .string = self.ptp_info.name });
            try ptp.put("capabilities", .{ .object = caps });
            try ptp.put("pins", .{ .array = pins });
            try top.put("ptp", .{ .object = ptp });
        }
        {
            var pci: std.json.ObjectMap = .init(arena);
            try pci.ensureTotalCapacity(8);
            try pci.put("vendor", if (self.pci_info.vendor) |vendor| .{ .string = @tagName(vendor) } else .null);
            try pci.put("device", if (self.pci_info.device) |device| .{ .string = @tagName(device) } else .null);
            try pci.put("revision", .{ .integer = self.pci_info.revision });
            try pci.put("max_speed", .{ .string = self.pci_info.max_speed });
            try pci.put("max_width", .{ .integer = self.pci_info.max_width });
            try top.put("pci", .{ .object = pci });
        }
        return .{ .object = top };
    }
};
