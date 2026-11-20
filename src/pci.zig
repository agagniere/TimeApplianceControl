const std = @import("std");
const readfile = @import("readfile.zig");
const readFileFitting = readfile.readFileFitting;
const readFileInteger = readfile.readIntegerFromFile;
const max_attribute_size = readfile.max_attribute_size;

const Vendor = enum {
    Facebook,
    Celestica,
    Orolia,
    Adva,

    pub fn fromID(id: u16) ?Vendor {
        return switch (id) {
            0x1d9b => .Facebook,
            0x18d4 => .Celestica,
            0x1ad7 => .Orolia,
            0xad5a => .Adva,
            else => null,
        };
    }
};

const Device = enum {
    /// Facebook and Adva use the same device ID
    Timecard,
    @"Celestica Timecard",
    @"ART Card",

    pub fn fromID(id: u16) ?Device {
        return switch (id) {
            0x0400 => .Timecard,
            0x1008 => .@"Celestica Timecard",
            0xa000 => .@"ART Card",
            else => null,
        };
    }
};

/// Info exposed by the sysfs about the PCI device
pub const PciInfo = struct {
    vendor: ?Vendor,
    device: ?Device,
    revision: u8,
    max_speed: []const u8,
    max_width: u8,

    pub fn fromDir(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !PciInfo {
        var buffer: [max_attribute_size]u8 = undefined;
        const content = try readFileFitting(io, dir, "max_link_speed", &buffer);
        return .{
            .vendor = .fromID(try readFileInteger("PCI sysfs", u16, io, dir, "vendor")),
            .device = .fromID(try readFileInteger("PCI sysfs", u16, io, dir, "device")),
            .revision = try readFileInteger("PCI sysfs", u8, io, dir, "revision"),
            .max_width = try readFileInteger("PCI sysfs", u8, io, dir, "max_link_width"),
            .max_speed = try alloc.dupe(u8, std.mem.trim(u8, content, "\n ")),
        };
    }

    pub fn deinit(self: *PciInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.max_speed);
    }
};
