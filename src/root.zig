const std = @import("std");

const log = std.log.scoped(.timecard);

fn read_serial_number(root: std.fs.Dir) !u32 {
    // The serial number is given in the form aa:bb:cc:dd:ee:ff
    var buffer: [6 * 2 + 5]u8 = undefined;
    const raw = try root.readFile("serialnum", &buffer);
    return parse_serial_number(raw);
}

fn parse_serial_number(raw: []const u8) !u32 {
    var result: u32 = 0;
    var pairs = std.mem.tokenizeScalar(u8, raw, ':');
    while (pairs.next()) |pair| {
        const chr = try std.fmt.parseUnsigned(u8, pair, 16);
        result *= 10;
        result += try std.fmt.charToDigit(chr, 10);
    }
    return result;
}

test parse_serial_number {
    try std.testing.expectEqual(123456, try parse_serial_number("31:32:33:34:35:36"));
    try std.testing.expectEqual(230541, try parse_serial_number("32:33:30:35:34:31"));
}

pub const Timecard = struct {
    root: std.fs.Dir,
    serialnumber: u32,

    const Self = @This();

    pub fn fromPath(path: []const u8) !Self {
        var dir = try std.fs.openDirAbsolute(path, .{});
        if (comptime std.log.logEnabled(.debug, .timecard)) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            log.debug("{s} resolved to {s}", .{ path, try dir.realpath(".", &buffer) });
        }

        return fromDir(dir);
    }

    pub fn fromDir(dir: std.fs.Dir) !Self {
        return .{ .root = dir, .serialnumber = try read_serial_number(dir) };
    }

    pub fn close(self: *Self) void {
        self.root.close();
    }
};
