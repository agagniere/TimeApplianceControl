const std = @import("std");

const readSerialNumber = @import("serialnumber.zig").readSerialNumber;

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
fn getPtpName(gpa: Allocator, root: std.fs.Dir) ![]const u8 {
    var buffer: [64]u8 = undefined;
    const relative = try root.readLink("ptp", &buffer);
    return gpa.dupe(u8, std.fs.path.basename(relative));
}

/// Time Appliance handle
pub const Timecard = struct {
    allocator: Allocator,
    root: std.fs.Dir,
    serialnumber: u32,
    serial_ports_name: NameMap,
    ptp_name: []const u8,

    const Self = @This();

    pub fn fromPath(gpa: Allocator, path: []const u8) !Self {
        var dir = try std.fs.openDirAbsolute(path, .{});
        if (comptime std.log.logEnabled(.debug, .timecard)) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            log.debug("{s} resolved to {s}", .{ path, try dir.realpath(".", &buffer) });
        }
        return fromDir(gpa, dir);
    }

    fn fromDir(gpa: Allocator, dir: std.fs.Dir) !Self {
        return .{
            .allocator = gpa,
            .root = dir,
            .serialnumber = try readSerialNumber(dir),
            .serial_ports_name = try getSerialPortsName(gpa, dir),
            .ptp_name = try getPtpName(gpa, dir),
        };
    }

    pub fn deinit(self: *Self) void {
        var ttys = self.serial_ports_name.iterator();
        while (ttys.next()) |tty| {
            self.allocator.free(tty.key_ptr.*);
            self.allocator.free(tty.value_ptr.*);
        }
        self.root.close();
        self.serial_ports_name.deinit(self.allocator);
        self.allocator.free(self.ptp_name);
    }

    pub fn to_json(self: Self, arena: Allocator) !std.json.Value {
        var top: std.json.ObjectMap = .init(arena);
        try top.ensureTotalCapacity(8);
        {
            var card: std.json.ObjectMap = .init(arena);
            try card.put("serial_number", .{ .integer = self.serialnumber });
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
        return .{ .object = top };
    }
};
