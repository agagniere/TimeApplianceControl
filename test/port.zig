//! Stand-in for linux/ptp_clock.h on non-Linux targets,
//! so that the module compiles and its tests can run on a development machine.
//! Non-Linux targets are not supported: this is only a testing convenience.
//! Only the declarations used by ptp.zig are provided, with the same layout as the Linux UAPI.

/// There is no PTP character device outside of Linux, so the ioctl requests are never issued
pub const PTP_CLOCK_GETCAPS = 0;
pub const PTP_PIN_GETFUNC = 0;
pub const PTP_SYS_OFFSET_EXTENDED = 0;

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
