//! Selection of the timecard from the command line, shared by tapctl and tap-monitor.
//! Their options structs declare the same fields: `ocp-number`, `timecard-name`, `timecard-path` and `root`.

const std = @import("std");
const tap = @import("tap");

const log = std.log.scoped(.cli);

/// The path of the timecard's sysfs, from the most specific of the options given
pub fn timecardPath(gpa: std.mem.Allocator, options: anytype) ![]const u8 {
    if (options.@"timecard-path") |path|
        return gpa.dupe(u8, path);
    if (options.@"timecard-name") |name|
        return gpa.print("/sys/class/timecard/{s}", .{name});
    return gpa.print("/sys/class/timecard/ocp{}", .{options.@"ocp-number"});
}

/// Fails with `error.InvalidOption` after logging why, when the options can't be used
pub fn openTimecard(gpa: std.mem.Allocator, io: std.Io, root_path: []const u8, timecard_path: []const u8) !tap.Timecard {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{}) catch |err| {
        log.err("Unable to open root directory '{s}': {t}", .{ root_path, err });
        return error.InvalidOption;
    };
    defer root.close(io);
    return tap.Timecard.fromPath(gpa, io, root, timecard_path) catch |err| switch (err) {
        error.RelativePath => error.InvalidOption,
        else => err,
    };
}
