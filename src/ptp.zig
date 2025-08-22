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
    device: std.fs.File,

    pub fn init(alloc: Allocator, timecard_root: std.fs.Dir) !PtpInfo {
        var dir = timecard_root.openDir("ptp", .{}) catch |err| {
            log.errAt(@src(), "Timecard sysfs expected to have a folder called 'ptp': {t}", .{err});
            return err;
        };
        defer dir.close();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const name = std.fs.path.basename(try dir.realpath(".", &buffer));
        var dev = try std.fs.openDirAbsolute("/dev", .{});
        defer dev.close();
        const ptp_device = dev.openFile(name, .{}) catch |err| {
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
        return a.nsec - b.nsec + std.time.ns_per_s * (a.sec - b.nsec);
    }

    pub fn readOffset(self: *PtpInfo) !i64 {
        var offset: linux.struct_ptp_sys_offset_extended = .{ .n_samples = 1 };
        if (std.c.ioctl(self.device.handle, @bitCast(sys_offset_extended), &offset) != 0)
            return error.FailedIoctl;
        log.debug("sys offset extended: {} samples, clock {}", .{ offset.n_samples, offset.clockid });
        for (0..1) |i| {
            log.debug("[{}]  pre {any}", .{ i, offset.ts[i][0] });
            log.debug("[{}]   ts {any}", .{ i, offset.ts[i][1] });
            log.debug("[{}] post {any}", .{ i, offset.ts[i][2] });
        }
        const left = diff(offset.ts[0][1], offset.ts[0][0]);
        const right = diff(offset.ts[0][2], offset.ts[0][1]);
        if (left < 0 or right < 0) {
            log.warnAt(@src(), "Non monotonic clock readings ! This might be due to an invalid ts_window_adjust value, set it to 0", .{});
        }
        return if (@abs(left) < @abs(right)) left else right;
    }

    pub fn deinit(self: *PtpInfo, gpa: Allocator) void {
        self.device.close();
        gpa.free(self.name);
        gpa.free(self.pins);
    }
};
