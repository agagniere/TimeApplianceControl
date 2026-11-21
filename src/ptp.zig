const std = @import("std");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.timecard);

const linux = @import("ptp_clock");

/// Hmmmmmmmmmmm
/// A PTP device is a dynamic POSIX clock, usable with clock_gettime through a clockid built from its fd:
/// the inverted fd makes the id negative, unlike static clocks such as CLOCK_REALTIME,
/// and the low 3 bits set to 3 (CLOCKFD) tell it apart from the negative ids of CPU-time clocks.
/// This is FD_TO_CLOCKID in https://elixir.bootlin.com/linux/v6.14.11/source/tools/testing/selftests/ptp/testptp.c#L89
fn getClockID(fd: std.posix.fd_t) std.posix.clockid_t {
    const hmm: u32 = @intCast(fd);
    return @fromBackingInt(@intCast((~hmm << 3) | 3));
}

const clock_getcaps: u32 = @truncate(linux.PTP_CLOCK_GETCAPS);
const pin_getfunc: u32 = @truncate(linux.PTP_PIN_GETFUNC);
const sys_offset_extended: u32 = @truncate(linux.PTP_SYS_OFFSET_EXTENDED);

/// The test stand-in for linux/ptp_clock.h fakes the ioctls too
const ioctl = if (@hasDecl(linux, "ioctl")) linux.ioctl else std.c.ioctl;

pub const pin_function_string = [_][]const u8{ "None", "ExternalTimeStamp", "PeriodicOutput", "PhysicalSynchronization" };

/// Collect info about the ptp clock
/// from the sysfs and from IOCTLs
pub const PtpInfo = struct {
    name: []const u8,
    capabilities: linux.struct_ptp_clock_caps,
    pins: []linux.struct_ptp_pin_desc,
    device: std.Io.File,

    pub fn init(alloc: Allocator, io: std.Io, root: std.Io.Dir, timecard_root: std.Io.Dir) !PtpInfo {
        var dir = timecard_root.openDir(io, "ptp", .{}) catch |err| {
            log.err("Timecard sysfs expected to have a folder called 'ptp': {t}", .{err});
            return err;
        };
        defer dir.close(io);
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const name = std.Io.Dir.path.basename(buffer[0..try dir.realPath(io, &buffer)]);
        var dev = try root.openDir(io, "dev", .{});
        defer dev.close(io);
        const ptp_device = dev.openFile(io, name, .{}) catch |err| {
            switch (err) {
                error.AccessDenied, error.PermissionDenied => log.err("Not allowed to open /dev/{s}: {t}. Reading the PTP clock requires root access, run tapctl with sudo", .{ name, err }),
                else => log.err("Error opening /dev/{s}: {t}", .{ name, err }),
            }
            return err;
        };
        //const clock_id = getClockID(ptp_device.handle);
        var caps: linux.struct_ptp_clock_caps = undefined;
        if (ioctl(ptp_device.handle, @bitCast(clock_getcaps), &caps) != 0)
            return error.FailedIoctl;
        var pin_list: std.ArrayList(linux.struct_ptp_pin_desc) = try .initCapacity(alloc, @intCast(caps.n_pins));
        defer pin_list.deinit(alloc);
        for (0..@intCast(caps.n_pins)) |i| {
            const pin: *linux.struct_ptp_pin_desc = pin_list.addOneAssumeCapacity();
            pin.index = @intCast(i);
            if (ioctl(ptp_device.handle, @bitCast(pin_getfunc), pin) != 0)
                return error.FailedIoctl;
        }
        return .{
            .name = try alloc.dupe(u8, name),
            .capabilities = caps,
            .pins = try pin_list.toOwnedSlice(alloc),
            .device = ptp_device,
        };
    }

    /// Returns the difference in nanoseconds
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
        /// Whether to take the TAI-UTC offset into account
        tai: bool,
    ) !i64 {
        var readings: linux.struct_ptp_sys_offset_extended = .{ .n_samples = 1 };
        if (ioctl(self.device.handle, @bitCast(sys_offset_extended), &readings) != 0)
            return error.FailedIoctl;
        const sys_window = diff(readings.ts[0][2], readings.ts[0][0]);
        if (sys_window < 0) {
            log.err("Non monotonic system clock, unable to make a reading. This might be due to an invalid ts_window_adjust value, consider setting it to 0", .{});
            return error.NonMonotonicSystemClock;
        }
        const offset: i64 = if (tai) (-37 * std.time.ns_per_s) else 0;
        return diff(readings.ts[0][1], readings.ts[0][0]) - @divTrunc(sys_window, 2) + offset;
    }

    pub fn deinit(self: *PtpInfo, gpa: Allocator, io: std.Io) void {
        self.close(io);
        gpa.free(self.name);
        gpa.free(self.pins);
    }

    /// Release the device only, for when the memory is freed by other means
    pub fn close(self: *PtpInfo, io: std.Io) void {
        self.device.close(io);
    }
};
