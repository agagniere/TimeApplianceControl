const std = @import("std");

const log = std.log.scoped(.timecard);

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

/// Info exposed
pub const PciInfo = struct {
    vendor: ?Vendor,
    device: ?Device,
    revision: u8,

    pub fn fromDir(dir: std.fs.Dir) !@This() {
        return .{
            .vendor = .fromID(try readFileInteger(u16, dir, "vendor")),
            .device = .fromID(try readFileInteger(u16, dir, "device")),
            .revision = try readFileInteger(u8, dir, "revision"),
        };
    }
};
