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

/// Unless OTEL_METRIC_EXPORT_INTERVAL is set: the specification's default of 60s is too long for a clock
const default_export_interval_ms = "10000";

// The SDK does not export the types of a meter and of its observable instruments: they are the ones of its functions
const Meter = @typeInfo(@typeInfo(@TypeOf(otel.metrics.MeterProvider.getMeter)).@"fn".return_type.?).error_union.payload;
const create_observable_gauge = @typeInfo(@TypeOf(@typeInfo(Meter).pointer.child.createObservableGauge)).@"fn";
const ObservedContext = create_observable_gauge.param_types[2].?;
const ObserveMeasures = @typeInfo(@typeInfo(create_observable_gauge.param_types[3].?).optional.child).pointer.child;
const ObserveResult = @typeInfo(@typeInfo(ObserveMeasures).pointer.child).@"fn".return_type.?;
const MeasurementsData = @typeInfo(ObserveResult).error_union.payload;
const DataPoint = @typeInfo(@FieldType(MeasurementsData, "int")).pointer.child;

/// What the gauge reads, on the thread of the metric reader
const Observed = struct {
    io: std.Io,
    timecard: *const tap.Timecard,
    /// Set when a reading fails, to stop
    failed: std.Io.Event = .unset,
};

fn observeOffset(context: ObservedContext, gpa: std.mem.Allocator) ObserveResult {
    const observed = context.into(Observed).?;
    const timecard = observed.timecard;
    const reading = timecard.ptp_info.readOffset(true) catch |err| {
        log.err("Unable to read the offset of {s}: {t}", .{ timecard.ptp_info.name, err });
        observed.failed.set(observed.io);
        return error.CallbackExecutionFailed;
    };
    const points = try gpa.alloc(DataPoint, 1);
    errdefer gpa.free(points);
    points[0] = try DataPoint.new(gpa, reading, .{
        "timecard.name",  timecard.name,
        "ptp.clock.name", timecard.ptp_info.name,
    });
    return .{ .int = points };
}

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
        \\Report the offset between the PTP clock of a time card and the system clock with OpenTelemetry, at each export of the metrics.
        \\Configure the export with the standard environment variables, such as OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME, and OTEL_METRIC_EXPORT_INTERVAL (10000 ms by default)
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
    if (init.environ_map.get("OTEL_METRIC_EXPORT_INTERVAL") == null)
        try init.environ_map.put("OTEL_METRIC_EXPORT_INTERVAL", default_export_interval_ms);
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

    const timecard_path = try cli.timecardPath(gpa, options.options);
    defer gpa.free(timecard_path);
    log.info("Starting {s} version {s}, with timecard at {s}", .{ build_info.name, build_info.version, timecard_path });
    var timecard: tap.Timecard = cli.openTimecard(gpa, io, options.options.root, timecard_path) catch |err| switch (err) {
        error.InvalidOption => return 1,
        else => |e| return e,
    };
    defer timecard.deinit();

    // Stopped before the timecard is freed, since its last export reads the timecard
    const metric_reader = try otel.metrics.PeriodicExportingReader.init(
        gpa,
        io,
        meter_provider,
        metric_exporter.exporter,
        config.metrics_config.export_interval_ms,
        config.metrics_config.export_timeout_ms,
    );
    defer metric_reader.shutdown() catch {};

    var observed: Observed = .{ .io = io, .timecard = &timecard };
    var callbacks = [_]ObserveMeasures{observeOffset};
    const meter = try meter_provider.getMeter(.{ .name = build_info.name, .version = build_info.version });
    _ = try meter.createObservableGauge(.{
        .name = "timecard.ptp.offset",
        .unit = "ns",
        .description = "Time to add to the system clock to get the time of the timecard's PTP clock",
    }, .from(&observed), &callbacks);

    try observed.failed.wait(io);
    return error.ReadingFailed;
}
