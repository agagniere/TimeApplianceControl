const std = @import("std");

const readSerialNumber = @import("serialnumber.zig").readSerialNumber;
const PciInfo = @import("pci.zig").PciInfo;

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

/// Return the name of the ptp clock exposed by this card
fn getPtpName(gpa: Allocator, root: std.fs.Dir, card_name: []const u8) ![]const u8 {
    var buffer: [64]u8 = undefined;
    const relative = try root.readLink("ptp", &buffer);
    const name = std.fs.path.basename(relative);
    log.info("Card {s} exposes the PTP clock {s}", .{ card_name, name });
    return gpa.dupe(u8, name);
}

/// Time Appliance handle
pub const Timecard = struct {
    allocator: Allocator,
    root: std.fs.Dir,
    pci_device: std.fs.Dir,
    name: []const u8,
    serialnumber: u32,
    serial_ports_name: NameMap,
    ptp_name: []const u8,
    pci_info: PciInfo,

    const Self = @This();

    pub fn fromPath(gpa: Allocator, path: []const u8) !Self {
        const dir = try std.fs.openDirAbsolute(path, .{});
        return fromDir(gpa, std.fs.path.basename(path), dir);
    }

    fn fromDir(gpa: Allocator, name: []const u8, dir: std.fs.Dir) !Self {
        const pci_device = try dir.openDir("device", .{});
        if (comptime std.log.logEnabled(.debug, .timecard)) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            log.debug("Card {s} is part of the PCI device {s}", .{ name, try pci_device.realpath(".", &buffer) });
        }
        const pci_info: PciInfo = try .fromDir(gpa, pci_device);
        log.debug("Card {s} detected as {t} {t} rev. {}, PCI x{}", .{ name, pci_info.vendor.?, pci_info.device.?, pci_info.revision, pci_info.max_width });
        return .{
            .allocator = gpa,
            .name = try gpa.dupe(u8, name),
            .root = dir,
            .pci_device = pci_device,
            .serialnumber = try readSerialNumber(dir),
            .serial_ports_name = try getSerialPortsName(gpa, dir),
            .ptp_name = try getPtpName(gpa, dir, name),
            .pci_info = pci_info,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pci_info.deinit(self.allocator);
        var ttys = self.serial_ports_name.iterator();
        while (ttys.next()) |tty| {
            self.allocator.free(tty.key_ptr.*);
            self.allocator.free(tty.value_ptr.*);
        }
        self.pci_device.close();
        self.root.close();
        self.serial_ports_name.deinit(self.allocator);
        self.allocator.free(self.ptp_name);
        self.allocator.free(self.name);
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
            try ptp.put("name", .{ .string = self.ptp_name });
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
