const std = @import("std");

const Allocator = std.mem.Allocator;
const log = @import("log.zig").config.scoped(.timecard);

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
const sys_offset_extended: u32 = @truncate(linux.PTP_SYS_OFFSET_EXTENDED);

pub const pin_function_string = [_][]const u8{ "None", "ExternalTimeStamp", "PeriodicOutput", "PhysicalSynchronization" };

/// Collect info about the ptp clock
/// from the sysfs and from IOCTLs
pub const PtpInfo = struct {
    name: []const u8,
    capabilities: linux.struct_ptp_clock_caps,
    pins: []linux.struct_ptp_pin_desc,
    device: std.Io.File,

    pub fn init(alloc: Allocator, io: std.Io, timecard_root: std.Io.Dir) !PtpInfo {
        var dir = timecard_root.openDir(io, "ptp", .{}) catch |err| {
            log.errAt(@src(), "Timecard sysfs expected to have a folder called 'ptp': {t}", .{err});
            return err;
        };
        defer dir.close(io);
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const name = std.fs.path.basename(buffer[0..try dir.realPath(io, &buffer)]);
        var dev = try std.Io.Dir.openDirAbsolute(io, "/dev", .{});
        defer dev.close(io);
        const ptp_device = dev.openFile(io, name, .{}) catch |err| {
            log.errAt(@src(), "Error opening /dev/{s}: {t}", .{ name, err });
            return err;
        };
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
            .device = ptp_device,
        };
    }

    /// Returns the difference in nanosecond
    fn diff(a: linux.struct_ptp_clock_time, b: linux.struct_ptp_clock_time) i64 {
        const a_ns: i64 = a.nsec;
        const b_ns: i64 = b.nsec;
        const sec_diff: i64 = a.sec - b.sec;
        return a_ns - b_ns + std.time.ns_per_s * sec_diff;
    }

    /// Returns how many nanoseconds to add to system clock to find the card's time
    /// So the value is negative if the card is late,
    /// positive if the clock is early
    pub fn readOffset(
        self: PtpInfo,
        /// Wether to take UTC TAI offset into account
        tai: bool,
    ) !i64 {
        var readings: linux.struct_ptp_sys_offset_extended = .{ .n_samples = 1 };
        if (std.c.ioctl(self.device.handle, @bitCast(sys_offset_extended), &readings) != 0)
            return error.FailedIoctl;
        const sys_window = diff(readings.ts[0][2], readings.ts[0][0]);
        if (sys_window < 0) {
            log.errAt(@src(), "Non monotonic system clock, unable to make a reading. This might be due to an invalid ts_window_adjust value, consider setting it to 0", .{});
            return error.NonMonotonicSystemClock;
        }
        const offset: i64 = if (tai) (-37 * std.time.ns_per_s) else 0;
        return diff(readings.ts[0][1], readings.ts[0][0]) - @divTrunc(sys_window, 2) + offset;
    }

    pub fn deinit(self: *PtpInfo, gpa: Allocator, io: std.Io) void {
        self.device.close(io);
        gpa.free(self.name);
        gpa.free(self.pins);
    }
};
