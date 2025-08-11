const std = @import("std");

const Vendor = enum {
    Facebook,
    Celestica,
    Orolia,
    Adva,

    pub fn fromID(id: u16) ?@This() {
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

    pub fn fromID(id: u16) ?@This() {
        return switch (id) {
            0x0400 => .Timecard,
            0x1008 => .@"Celestica Timecard",
            0xa000 => .@"ART Card",
            else => null,
        };
    }
};

/// Interpret the contents of the file as an integer
fn readFileInteger(T: type, dir: std.fs.Dir, filename: []const u8) !T {
    var buffer: [64]u8 = undefined;
    const content = std.mem.trim(u8, try dir.readFile(filename, &buffer), "\n");
    return try std.fmt.parseInt(T, content, 0);
}

/// Info exposed by the sysfs about the PCI device
pub const PciInfo = struct {
    vendor: ?Vendor,
    device: ?Device,
    revision: u8,
    max_speed: []const u8,
    max_width: u8,

    pub fn fromDir(gpa: std.mem.Allocator, dir: std.fs.Dir) !@This() {
        return .{
            .vendor = .fromID(try readFileInteger(u16, dir, "vendor")),
            .device = .fromID(try readFileInteger(u16, dir, "device")),
            .revision = try readFileInteger(u8, dir, "revision"),
            .max_width = try readFileInteger(u8, dir, "max_link_width"),
            .max_speed = try dir.readFileAlloc(gpa, "max_link_speed", 64),
        };
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        gpa.free(self.max_speed);
    }
};
