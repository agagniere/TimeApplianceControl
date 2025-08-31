const std = @import("std");
const argsParser = @import("args");
const tap = @import("tap");
const cli = @import("cli.zig");

const builtin = @import("builtin");
const build_info = @import("build_info");

const log = tap.Log;
const Timecard = tap.Timecard;

pub const std_options: std.Options = .{
    .logFn = log.log,
    .log_level = .debug,
};

fn get_timecard_path(gpa: std.mem.Allocator, options: cli.ParsedArgs) ![]const u8 {
    if (options.options.@"timecard-path") |path| {
        return gpa.dupe(u8, path);
    }
    if (options.options.@"timecard-name") |name| {
        return std.fmt.allocPrint(gpa, "/sys/class/timecard/{s}", .{name});
    }
    return std.fmt.allocPrint(gpa, "/sys/class/timecard/ocp{}", .{options.options.@"ocp-number"});
}

pub fn main() !u8 {
    // Allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = switch (builtin.mode) {
        .Debug, .ReleaseSafe => debug_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };

    try log.init(gpa, null, null);
    defer log.deinit(gpa);

    // Output stream
    const out_buffer: []u8 = try gpa.alloc(u8, 4096);
    defer gpa.free(out_buffer);
    var stdout: std.fs.File.Writer = std.fs.File.stdout().writer(out_buffer);
    var output: *std.Io.Writer = &stdout.interface;
    defer output.flush() catch unreachable;

    const options: cli.ParsedArgs = (cli.parseCLI(gpa, output) catch return 1) orelse return 0;
    defer options.deinit();

    const timecard_path = try get_timecard_path(gpa, options);
    defer gpa.free(timecard_path);
    log.info("Starting {s} version {s}, with timecard at {s}", .{ build_info.name, build_info.version, timecard_path });
    if (!std.fs.path.isAbsolute(timecard_path)) {
        log.errAt(@src(), "Timecard's sysfs path required to be absolute. Provided path: '{s}'", .{timecard_path});
        return 1;
    }

    var timecard: Timecard = try .fromPath(gpa, timecard_path);
    defer timecard.deinit();

    switch (options.verb.?) {
        .info => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const json = try timecard.to_json(arena.allocator());
            try output.print("{f}\n", .{std.json.fmt(json, .{})});
        },
        .monitor => |opt| try tap.start_monitoring(gpa, timecard, opt.@"statsd-address", opt.@"statsd-port"),
        .mro => {},
    }
    return 0;
}
