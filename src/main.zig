const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");
const argsParser = @import("args");

const CommonOptions = struct {
    @"ocp-number": u8 = 0,
    @"timecard-name": ?[]const u8 = null,
    @"timecard-path": ?[]const u8 = null,
    help: bool = false,
    version: bool = false,

    pub const shorthands = .{
        .N = "ocp-number",
        .n = "timecard-name",
        .P = "timecard-path",
        .h = "help",
        .v = "version",
    };
    pub const meta = .{
        //.name = "Time Appliance control",
        .usage_summary = "[-N NUMBER | -n NAME | -P PATH] [-h] [-v]",
        .full_text = "Control a Time Appliance from the Open Compute Project's Time Appliance Project",
        .option_docs = .{
            .@"ocp-number" = "Specify the number of the appliance, that is then assumed to be at /sys/class/timecard/ocp<N>. Defaults to 0",
            .@"timecard-name" = "Specify the name of the appliance, that is then assumed to be at /sys/class/timecard/<NAME>. Overrides --ocp-number",
            .@"timecard-path" = "Specify the absolute path the appliance. Overrides --timecard-name and --ocp-number",
            .help = "Display this usage message on standard output and exit successfully",
            .version = "Show version information of the standard output and exit successfully",
        },
    };
};

const MroOptions = struct {
    path: ?[]const u8 = null,

    pub const shorthands = .{};
    pub const meta = .{ .option_docs = .{
        .path = "Specify a custom path to the MRO's serial port. By default, it is determined from the ttyMAC attriibute of the timecard",
    } };
};

pub fn main() !u8 {
    // Allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = switch (builtin.mode) {
        .Debug, .ReleaseSafe => debug_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };

    // Output stream
    const out_buffer: []u8 = try gpa.alloc(u8, 4096);
    defer gpa.free(out_buffer);
    var stdout: std.fs.File.Writer = std.fs.File.stdout().writer(out_buffer);
    var output: *std.Io.Writer = &stdout.interface;
    defer output.flush() catch unreachable;

    // CLI arguments
    const options = argsParser.parseForCurrentProcess(CommonOptions, gpa, .print) catch return 1;
    defer options.deinit();
    if (options.options.help) {
        try argsParser.printHelp(CommonOptions, build_info.name, output);
        //if (options.verb) |verb| {}
        return 0;
    }

    std.log.info("Starting {s} version {s}", .{ build_info.name, build_info.version });
    return 0;
}
