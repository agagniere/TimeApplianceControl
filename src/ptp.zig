const std = @import("std");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.timecard);

const linux = @cImport({
    @cInclude("linux/ptp_clock.h");
});

/// Hmmmmmmmmmmm
/// https://elixir.bootlin.com/linux/v6.14.11/source/tools/testing/selftests/ptp/testptp.c#L89
fn getClockID(fd: std.posix.fd_t) std.posix.clockid_t {
    const hmm: u32 = @intCast(fd);
    return @enumFromInt((~hmm << 3) | 3);
}

const clock_getcaps: u32 = @truncate(linux.PTP_CLOCK_GETCAPS);
const pin_getfunc: u32 = @truncate(linux.PTP_PIN_GETFUNC);

/// Collect info about the ptp clock
/// from the sysfs and from IOCTLs
pub const PtpInfo = struct {
    name: []const u8,
    capabilities: linux.struct_ptp_clock_caps,
    pins: []linux.struct_ptp_pin_desc,

    const Self = @This();

    pub fn init(alloc: Allocator, timecard_root: std.fs.Dir) !Self {
        var dir = try timecard_root.openDir("ptp", .{});
        defer dir.close();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const name = std.fs.path.basename(try dir.realpath(".", &buffer));
        var dev = try std.fs.openDirAbsolute("/dev", .{});
        defer dev.close();
        var ptp_device = dev.openFile(name, .{}) catch |err| {
            log.err("Error opening /dev/{s}: {t}", .{ name, err });
            return err;
        };
        defer ptp_device.close();
        //const clock_id = getClockID(ptp_device.handle);
        var caps: linux.struct_ptp_clock_caps = undefined;
        if (std.c.ioctl(ptp_device.handle, @bitCast(clock_getcaps), &caps) != 0)
            return error.FailedIoctl;
        var pin_list: std.ArrayListUnmanaged(linux.struct_ptp_pin_desc) = try .initCapacity(alloc, @intCast(caps.n_pins));
        defer pin_list.deinit(alloc);
        for (0..@intCast(caps.n_pins)) |i| {
            const pin: *linux.struct_ptp_pin_desc = pin_list.addOneAssumeCapacity();
            pin.index = @intCast(i);
            if (std.c.ioctl(ptp_device.handle, @bitCast(pin_getfunc), pin) != 0)
                return error.FailedIoctl;
        }
        return .{
            .name = try alloc.dupe(u8, name),
            .capabilities = caps,
            .pins = try pin_list.toOwnedSlice(alloc),
        };
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.pins);
    }
};
