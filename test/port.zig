//! Stand-in for linux/ptp_clock.h on non-Linux targets and in end-to-end tests,
//! so that the module compiles and its tests can run on a development machine.
//! Non-Linux targets are not supported: this is only a testing convenience.
//! Only the declarations used by ptp.zig are provided, with the same layout as the Linux UAPI.
//! The ioctls are faked too: the PTP device is expected to be a ZON file describing the clock, see test/fixtures.

const std = @import("std");

pub const PTP_CLOCK_GETCAPS = 1;
pub const PTP_PIN_GETFUNC = 2;
pub const PTP_SYS_OFFSET_EXTENDED = 3;

pub const PTP_MAX_SAMPLES = 25;

pub const struct_ptp_clock_time = extern struct {
    sec: i64 = 0,
    nsec: u32 = 0,
    reserved: u32 = 0,
};

pub const struct_ptp_clock_caps = extern struct {
    max_adj: c_int = 0,
    n_alarm: c_int = 0,
    n_ext_ts: c_int = 0,
    n_per_out: c_int = 0,
    pps: c_int = 0,
    n_pins: c_int = 0,
    cross_timestamping: c_int = 0,
    adjust_phase: c_int = 0,
    max_phase_adj: c_int = 0,
    rsv: [11]c_int = @splat(0),
};

pub const struct_ptp_pin_desc = extern struct {
    name: [64]u8 = @splat(0),
    index: c_uint = 0,
    func: c_uint = 0,
    chan: c_uint = 0,
    rsv: [5]c_uint = @splat(0),
};

pub const struct_ptp_sys_offset_extended = extern struct {
    n_samples: c_uint = 0,
    clockid: c_int = 0,
    rsv: [2]c_uint = @splat(0),
    ts: [PTP_MAX_SAMPLES][3]struct_ptp_clock_time = @splat(@splat(.{})),
};

/// Content of a fake PTP device
const FakeClock = struct {
    capabilities: struct_ptp_clock_caps,
    pins: []const struct {
        name: []const u8,
        function: c_uint = 0,
        channel: c_uint = 0,
    } = &.{},
};

/// Answer the ioctls from the ZON description of the clock.
/// Reading the clock's time is not supported
pub fn ioctl(fd: std.c.fd_t, request: c_int, arg: *anyopaque) c_int {
    var source: [4096]u8 = undefined;
    const length = std.c.pread(fd, &source, source.len - 1, 0);
    if (length < 0)
        return -1;
    source[@intCast(length)] = 0;

    var buffer: [16 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const clock = std.zon.parse.fromSlice(FakeClock, .{
        .gpa = fba.allocator(),
        .arena = fba.allocator(),
        .source = source[0..@intCast(length) :0],
        .diagnostics = &diagnostics,
    }) catch {
        diagnostics.log("fake PTP device");
        return -1;
    };

    switch (request) {
        PTP_CLOCK_GETCAPS => {
            const caps: *struct_ptp_clock_caps = @ptrCast(@alignCast(arg));
            caps.* = clock.capabilities;
            caps.n_pins = @intCast(clock.pins.len);
        },
        PTP_PIN_GETFUNC => {
            const desc: *struct_ptp_pin_desc = @ptrCast(@alignCast(arg));
            if (desc.index >= clock.pins.len)
                return -1;
            const pin = clock.pins[desc.index];
            if (pin.name.len >= desc.name.len)
                return -1;
            desc.name = @splat(0);
            @memcpy(desc.name[0..pin.name.len], pin.name);
            desc.func = pin.function;
            desc.chan = pin.channel;
        },
        else => return -1,
    }
    return 0;
}
