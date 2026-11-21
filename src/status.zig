//! Attributes of the timecard's sysfs that change over time, only exposed by some cards (Facebook, Adva)

const std = @import("std");
const readfile = @import("readfile.zig");
const readFileFitting = readfile.readFileFitting;
const max_attribute_size = readfile.max_attribute_size;

const log = std.log.scoped(.timecard);

/// Whether the card receives a valid GNSS signal, from the `gnss_sync` attribute
pub const GnssSync = union(enum) {
    synchronized,
    /// When the driver noticed the loss of the signal, as it prints it: UTC, as YYYY-mm-ddTHH:MM:SS
    lost: [timestamp_pattern.len]u8,

    const timestamp_pattern = "dddd-dd-ddTdd:dd:dd";
    const lost_prefix = "LOST @ ";

    /// Parse the content of the attribute, without its newline
    pub fn parse(content: []const u8) !GnssSync {
        if (std.mem.eql(u8, content, "SYNC"))
            return .synchronized;
        if (std.mem.startsWith(u8, content, lost_prefix)) {
            const time = content[lost_prefix.len..];
            if (isTimestamp(time))
                return .{ .lost = time[0..timestamp_pattern.len].* };
        }
        return error.InvalidFormat;
    }

    fn isTimestamp(text: []const u8) bool {
        if (text.len != timestamp_pattern.len)
            return false;
        for (text, timestamp_pattern) |c, p| {
            if (if (p == 'd') !std.ascii.isDigit(c) else c != p)
                return false;
        }
        return true;
    }

    /// Fails with `error.FileNotFound` without logging when the card doesn't expose it
    pub fn read(io: std.Io, dir: std.Io.Dir) !GnssSync {
        var buffer: [max_attribute_size]u8 = undefined;
        const content = std.mem.trimEnd(u8, try readFileFitting(io, dir, "gnss_sync", &buffer), "\n");
        return parse(content) catch |err| {
            log.err("Expected attribute 'gnss_sync' to be 'SYNC' or 'LOST @ YYYY-mm-ddTHH:MM:SS', got instead: '{s}'", .{content});
            return err;
        };
    }
};

/// The corrections the firmware of the card applies to its clock, to discipline it to its source.
/// Read from the `clock_status_offset` and `clock_status_drift` attributes, whose units the kernel doesn't document:
/// they are those of the registers of the FPGA's AdjustableClock
pub const ClockStatus = struct {
    /// The last phase correction, in nanoseconds
    offset: i32,
    /// The frequency correction, accumulated over the successive corrections,
    /// in nanoseconds per adjustment interval, which the PPS slave keeps at about a second
    drift: i32,

    /// Fails with `error.FileNotFound` without logging when the card doesn't expose them
    pub fn read(io: std.Io, dir: std.Io.Dir) !ClockStatus {
        return .{
            .offset = try readStatus(io, dir, "clock_status_offset"),
            .drift = try readStatus(io, dir, "clock_status_drift"),
        };
    }

    fn readStatus(io: std.Io, dir: std.Io.Dir, filename: []const u8) !i32 {
        var buffer: [max_attribute_size]u8 = undefined;
        const content = std.mem.trimEnd(u8, try readFileFitting(io, dir, filename, &buffer), "\n");
        return std.fmt.parseInt(i32, content, 10) catch |err| {
            log.err("Expected attribute '{s}' to be an integer, got instead: '{s}'", .{ filename, content });
            return err;
        };
    }
};

test "GnssSync.parse" {
    try std.testing.expectEqual(GnssSync.synchronized, try GnssSync.parse("SYNC"));
    try std.testing.expectEqualStrings("2026-11-21T14:03:36", &(try GnssSync.parse("LOST @ 2026-11-21T14:03:36")).lost);
    try std.testing.expectError(error.InvalidFormat, GnssSync.parse("SYNC\n"));
    try std.testing.expectError(error.InvalidFormat, GnssSync.parse("LOST @ 2026-11-21 14:03:36"));
    try std.testing.expectError(error.InvalidFormat, GnssSync.parse("LOST @ 2026-11-21T14:03"));
    try std.testing.expectError(error.InvalidFormat, GnssSync.parse("LOST"));
}
