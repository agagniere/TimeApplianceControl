const std = @import("std");

const Allocator = std.mem.Allocator;
const NameMap = std.StringArrayHashMapUnmanaged([]const u8);

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

fn getSerialPortsName(gpa: Allocator, root: std.fs.Dir) !NameMap {
    var result: NameMap = .empty;
    const tty_dir = root.openDir("tty", .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.log.err("This program only supports linux 6.9 and newer, where the driver groups the ttys read-only attributes in a folder", .{});
            },
            else => {},
        }
        return err;
    };
    var buffer: [32]u8 = undefined;
    var ttys = tty_dir.iterate();
    while (try ttys.next()) |tty_file| {
        std.log.info("{s}: {t}", .{ tty_file.name, tty_file.kind });
        try result.put(gpa, tty_file.name, try tty_dir.readFile(tty_file.name, &buffer));
    }
    return result;
}

pub const Timecard = struct {
    allocator: Allocator,
    root: std.fs.Dir,
    serialnumber: u32,
    serial_ports_name: NameMap,

    const Self = @This();

    pub fn fromPath(gpa: Allocator, path: []const u8) !Self {
        var dir = try std.fs.openDirAbsolute(path, .{});
        if (comptime std.log.logEnabled(.debug, .timecard)) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            log.debug("{s} resolved to {s}", .{ path, try dir.realpath(".", &buffer) });
        }
        return fromDir(gpa, dir);
    }

    pub fn fromDir(gpa: Allocator, dir: std.fs.Dir) !Self {
        return .{ .allocator = gpa, .root = dir, .serialnumber = try read_serial_number(dir), .serial_ports_name = try getSerialPortsName(gpa, dir) };
    }

    pub fn deinit(self: *Self) void {
        self.root.close();
        //var ports = self.serial_ports_name.iterator();
        //while (ports.next()) |port| {
        //self.allocator.free(port.key_ptr.*);
        //self.allocator.free(port.value_ptr.*);
        //}
        self.serial_ports_name.deinit(self.allocator);
    }

    pub fn to_json(self: Self, arena: Allocator) !std.json.Value {
        var top: std.json.ObjectMap = .init(arena);
        try top.ensureTotalCapacity(8);
        {
            var card: std.json.ObjectMap = .init(arena);
            try card.ensureTotalCapacity(1);
            try card.put("serial_number", .{ .integer = self.serialnumber });
            try top.put("card", .{ .object = card });
        }
        {
            var ttys: std.json.ObjectMap = .init(arena);
            try ttys.ensureTotalCapacity(4);
            var ite = self.serial_ports_name.iterator();
            while (ite.next()) |tty| {
                try ttys.put(tty.key_ptr.*, .{ .string = tty.value_ptr.* });
            }
            try top.put("serial_ports", .{ .object = ttys });
        }
        return .{ .object = top };
    }
};
