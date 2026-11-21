//! tap-monitor: a long-running process reporting the offset of a timecard's PTP clock with OpenTelemetry.
//! It is configured with the standard OTEL_* environment variables, so that it fits in a systemd service.

const std = @import("std");
const argsParser = @import("args");
const otel = @import("opentelemetry");
const tap = @import("tap");
const cli = @import("cli");

const build_info = @import("build_info");

const log = std.log.scoped(.monitor);

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .info,
};

const reading_interval: std.Io.Duration = .fromSeconds(10);

/// Logs go to OpenTelemetry and to stderr, which journald collects
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    switch (scope) {
        .monitor, .timecard, .cli => otel.logs.std_log_bridge.logFn(level, scope, format, args),
        // Such as the SDK reporting an unreachable collector: exporting that could loop
        else => std.log.defaultLog(level, scope, format, args),
    }
}

const Options = struct {
    @"ocp-number": u8 = 0,
    @"timecard-name": ?[]const u8 = null,
    @"timecard-path": ?[]const u8 = null,
    root: []const u8 = "/",
    help: bool = false,
    version: bool = false,
    pub const wrap_len = 40;

    pub const shorthands = .{
        .N = "ocp-number",
        .n = "timecard-name",
        .P = "timecard-path",
        .r = "root",
        .h = "help",
        .v = "version",
    };
    pub const meta = .{
        .usage_summary = "[-N NUMBER | -n NAME | -P PATH] [-r ROOT] [-h] [-v]",
        .full_text =
        \\Report the offset between the PTP clock of a time card and the system clock every 10 seconds, with OpenTelemetry.
        \\Configure the export with the standard environment variables, such as OTEL_EXPORTER_OTLP_ENDPOINT and OTEL_SERVICE_NAME
        ,
        .option_docs = .{
            .@"ocp-number" = "Specify the number of the appliance. Its sysfs is then assumed to be at /sys/class/timecard/ocp<N>. Defaults to 0",
            .@"timecard-name" = "Specify the name of the appliance. Its sysfs is then assumed to be at /sys/class/timecard/<NAME>. Overrides --ocp-number",
            .@"timecard-path" = "Specify the absolute path of the appliance's sysfs. Overrides --timecard-name and --ocp-number",
            .root = "Resolve all absolute paths (sysfs and /dev) relative to this directory, like chroot. Defaults to /",
            .help = "Display this usage message on standard output and exit successfully",
            .version = "Show version information on standard output and exit successfully",
        },
    };
};

fn logArgsError(err: argsParser.Error) !void {
    std.log.scoped(.cli).err("{f}", .{err});
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    defer stdout.interface.flush() catch {};

    const options = argsParser.parseForCurrentProcess(Options, init, .{ .forward = logArgsError }) catch return 1;
    defer options.deinit();
    if (options.options.help) {
        try argsParser.printHelp(Options, build_info.name, &stdout.interface);
        return 0;
    }
    if (options.options.version) {
        try stdout.interface.writeAll(build_info.name ++ " version " ++ build_info.version ++ "\n");
        return 0;
    }

    // OpenTelemetry is set up before looking for the timecard, so that the collector also receives startup errors
    const config = try otel.config.Configuration.init(gpa, io, init.environ_map);
    defer config.deinit();
    otel.config.Configuration.set(config);
    const otlp_config = try otel.otlp.ConfigOptions.init(gpa, init.environ_map);
    defer otlp_config.deinit();

    const log_exporter = try otel.logs.OTLPExporter.init(gpa, io, otlp_config);
    defer log_exporter.deinit();
    const log_processor = try otel.logs.BatchingLogRecordProcessor.init(gpa, io, log_exporter.asLogRecordExporter(), .{});
    defer log_processor.deinit();
    const logger_provider = try otel.logs.LoggerProvider.init(gpa, io, null);
    defer logger_provider.deinit();
    try logger_provider.addLogRecordProcessor(log_processor.asLogRecordProcessor());
    defer logger_provider.shutdown() catch {}; // Flushes the logs
    try otel.logs.std_log_bridge.configure(.{
        .provider = logger_provider,
        .scope = .{ .name = build_info.name, .version = build_info.version },
        .include_source_location = false, // Only available as the location of the bridge itself
    });
    defer otel.logs.std_log_bridge.shutdown();

    const meter_provider = try otel.metrics.MeterProvider.init(gpa, io);
    defer meter_provider.deinit();
    const metric_exporter = try otel.metrics.MetricExporter.OTLP(gpa, io, null, null, otlp_config);
    defer metric_exporter.otlp.deinit();
    const metric_reader = try otel.metrics.MetricReader.init(gpa, io, metric_exporter.exporter);
    defer metric_reader.deinit();
    try meter_provider.addReader(metric_reader);

    const timecard_path = try cli.timecardPath(gpa, options.options);
    defer gpa.free(timecard_path);
    log.info("Starting {s} version {s}, with timecard at {s}", .{ build_info.name, build_info.version, timecard_path });
    var timecard: tap.Timecard = cli.openTimecard(gpa, io, options.options.root, timecard_path) catch |err| switch (err) {
        error.InvalidOption => return 1,
        else => |e| return e,
    };
    defer timecard.deinit();

    const meter = try meter_provider.getMeter(.{ .name = build_info.name, .version = build_info.version });
    const offset = try meter.createGauge(i64, .{
        .name = "timecard.ptp.offset",
        .unit = "ns",
        .description = "Time to add to the system clock to get the time of the timecard's PTP clock",
    });
    while (true) {
        const reading = timecard.ptp_info.readOffset(true) catch |err| {
            log.err("Unable to read the offset of {s}: {t}", .{ timecard.ptp_info.name, err });
            return err;
        };
        try offset.record(reading, .{
            "timecard.name",  timecard.name,
            "ptp.clock.name", timecard.ptp_info.name,
        });
        metric_reader.collect() catch |err| log.warn("Unable to export the metrics: {t}", .{err});
        try io.sleep(reading_interval, .awake);
    }
}
