//! tap-monitor: a long-running process reporting the offset of a timecard's PTP clock with OpenTelemetry.
//! It is configured with the standard OTEL_* environment variables, so that it fits in a systemd service.

const std = @import("std");
const argsParser = @import("args");
const otel = @import("opentelemetry");
const semconv = @import("semconv");
const tap = @import("tap");
const cli = @import("cli.zig");

const build_info = @import("build_info");

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .info,
};

/// Unless OTEL_METRIC_EXPORT_INTERVAL is set: the specification's default of 60s is too long for a clock
const default_export_interval_ms = "10000";

/// Whether the service is named by OTEL_SERVICE_NAME or OTEL_RESOURCE_ATTRIBUTES, read like the SDK does.
/// Otherwise the SDK would fall back to unknown_service:tap-monitor.
/// It has no way to give a default instead: https://github.com/open-telemetry/opentelemetry-zig/issues/194
fn isServiceNamed(environ_map: *const std.process.Environ.Map) bool {
    if (environ_map.get("OTEL_SERVICE_NAME") != null)
        return true;
    var entries = std.mem.tokenizeScalar(u8, environ_map.get("OTEL_RESOURCE_ATTRIBUTES") orelse return false, ',');
    while (entries.next()) |entry| {
        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, entry[0..separator], &std.ascii.whitespace), "service.name"))
            return true;
    }
    return false;
}

// The SDK does not export the types of a meter and of its observable instruments: they are the ones of its functions
const Meter = @typeInfo(@typeInfo(@TypeOf(otel.metrics.MeterProvider.getMeter)).@"fn".return_type.?).error_union.payload;
const create_observable_gauge = @typeInfo(@TypeOf(@typeInfo(Meter).pointer.child.createObservableGauge)).@"fn";
const ObservedContext = create_observable_gauge.param_types[2].?;
const ObserveMeasures = @typeInfo(@typeInfo(create_observable_gauge.param_types[3].?).optional.child).pointer.child;
const ObserveResult = @typeInfo(@typeInfo(ObserveMeasures).pointer.child).@"fn".return_type.?;
const MeasurementsData = @typeInfo(ObserveResult).error_union.payload;
const DataPoint = @typeInfo(@FieldType(MeasurementsData, "int")).pointer.child;

/// The attributes of tap-monitor, as semantic convention definitions so that `fromPairs` checks their values
const attribute = struct {
    const timecard_name: semconv.types.StringAttribute = .init("timecard.name", "The name of the timecard in its sysfs class, following the probe order", .development, .required);
    const timecard_path: semconv.types.StringAttribute = .init("timecard.path", "The path of the timecard's sysfs, as given in the options", .development, .recommended);
    const ptp_clock_name: semconv.types.StringAttribute = .init("ptp.clock.name", "The name of the timecard's PTP clock in /dev, following the probe order", .development, .required);
    // Defined by versions of the semantic conventions newer than the SDK's
    const hw_serial_number: semconv.types.StringAttribute = .init("hw.serial_number", "Serial number of the hardware component", .development, .recommended);
    const hw_vendor: semconv.types.StringAttribute = .init("hw.vendor", "Vendor name of the hardware component", .development, .recommended);
    const hw_model: semconv.types.StringAttribute = .init("hw.model", "Descriptive model name of the hardware component", .development, .recommended);
};

/// The logs of tap-monitor itself, which unlike std.log's give their source location.
/// Like the bridge's, they are written to stderr too
const Log = struct {
    logger: *otel.logs.Logger,

    fn emit(self: Log, comptime level: std.log.Level, location: std.builtin.SourceLocation, comptime format: []const u8, args: anytype) void {
        if (comptime !std.log.logEnabled(level, .monitor))
            return;
        var buffer: [4096]u8 = undefined;
        var body: std.Io.Writer = .fixed(&buffer);
        body.print(format, args) catch {}; // Truncated
        const severity: otel.logs.Severity = switch (level) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
        };
        self.logger.emit(severity, body.buffered(), .{ .severity_text = level.asText(), .location = location });
        std.log.defaultLog(level, .monitor, format, args);
    }
};

/// What the gauge reads, on the thread of the metric reader
const Observed = struct {
    io: std.Io,
    log: Log,
    timecard: *const tap.Timecard,
    /// Of every data point, which each own a copy of the slice
    attributes: []const otel.Attribute,
    /// Set when a reading fails, to stop
    failed: std.Io.Event = .unset,
};

fn observeOffset(context: ObservedContext, gpa: std.mem.Allocator) ObserveResult {
    const observed = context.into(Observed).?;
    const timecard = observed.timecard;
    const reading = timecard.ptp_info.readOffset(true) catch |err| {
        observed.log.emit(.err, @src(), "Unable to read the offset of {s}: {t}", .{ timecard.ptp_info.name, err });
        observed.failed.set(observed.io);
        return error.CallbackExecutionFailed;
    };
    const points = try gpa.alloc(DataPoint, 1);
    errdefer gpa.free(points);
    points[0] = .{ .value = reading, .attributes = try gpa.dupe(otel.Attribute, observed.attributes) };
    return .{ .int = points };
}

/// The logs of std.log, from the shared code, go to OpenTelemetry and to stderr, which journald collects
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    switch (scope) {
        .timecard, .cli => otel.logs.std_log_bridge.logFn(level, scope, format, args),
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
        \\Configure the export with the standard environment variables, such as OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME (tap-monitor by default), and OTEL_METRIC_EXPORT_INTERVAL (10000 ms by default)
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

    const timecard_path = try cli.timecardPath(gpa, options.options);
    defer gpa.free(timecard_path);

    // OpenTelemetry is set up before looking for the timecard, so that the collector also receives startup errors
    if (init.environ_map.get("OTEL_METRIC_EXPORT_INTERVAL") == null)
        try init.environ_map.put("OTEL_METRIC_EXPORT_INTERVAL", default_export_interval_ms);
    if (!isServiceNamed(init.environ_map))
        try init.environ_map.put("OTEL_SERVICE_NAME", build_info.name);
    const config = try otel.config.Configuration.init(gpa, io, init.environ_map);
    defer config.deinit();
    otel.config.Configuration.set(config);
    const otlp_config = try otel.otlp.ConfigOptions.init(gpa, init.environ_map);
    defer otlp_config.deinit();

    const log_exporter = try otel.logs.OTLPExporter.init(gpa, io, otlp_config);
    defer log_exporter.deinit();
    const log_processor = try otel.logs.BatchingLogRecordProcessor.init(gpa, io, log_exporter.asLogRecordExporter(), .{});
    defer log_processor.deinit();
    // Each instance monitors one card: its name and path, known from the options, also identify the logs of the library
    const resource = otel.attributes.fromPairs(.{
        .{ attribute.timecard_name, std.Io.Dir.path.basename(timecard_path) },
        .{ attribute.timecard_path, timecard_path },
    });
    const logger_provider = try otel.logs.LoggerProvider.init(gpa, io, &resource);
    defer logger_provider.deinit();
    try logger_provider.addLogRecordProcessor(log_processor.asLogRecordProcessor());
    defer logger_provider.shutdown() catch {}; // Flushes the logs
    try otel.logs.std_log_bridge.configure(.{
        .provider = logger_provider,
        .scope = .{ .name = build_info.name, .version = build_info.version },
        .include_source_location = false, // Only adds the level, already in the severity: std.log doesn't give the caller's location
    });
    defer otel.logs.std_log_bridge.shutdown();
    const log: Log = .{ .logger = try logger_provider.getLogger(.{ .name = build_info.name, .version = build_info.version }) };

    const meter_provider = try otel.metrics.MeterProvider.init(gpa, io);
    defer meter_provider.deinit();
    const metric_exporter = try otel.metrics.MetricExporter.OTLP(gpa, io, null, null, otlp_config);
    defer metric_exporter.otlp.deinit();
    // Until the reader is created, which then shuts the exporter down
    var unread_exporter: ?*otel.metrics.MetricExporter = metric_exporter.exporter;
    defer if (unread_exporter) |exporter| exporter.shutdown();

    log.emit(.info, @src(), "Starting {s} version {s}, with timecard at {s}", .{ build_info.name, build_info.version, timecard_path });
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
    unread_exporter = null;
    defer metric_reader.shutdown() catch {};

    // The names of the card and of its clock follow the probe order, so they can change when cards are added or moved
    var attributes_buffer: [6]otel.Attribute = undefined;
    var attributes: std.ArrayList(otel.Attribute) = .initBuffer(&attributes_buffer);
    attributes.appendSliceAssumeCapacity(&otel.attributes.fromPairs(.{
        .{ attribute.timecard_name, timecard.name },
        .{ attribute.timecard_path, timecard.path },
        .{ attribute.ptp_clock_name, timecard.ptp_info.name },
    }));
    // Left out when unknown
    var serial_number_buffer: [std.fmt.count("{}", .{std.math.maxInt(u32)})]u8 = undefined;
    if (timecard.serialnumber) |serial_number|
        attributes.appendSliceAssumeCapacity(&otel.attributes.fromPairs(.{.{ attribute.hw_serial_number, std.fmt.bufPrint(&serial_number_buffer, "{}", .{serial_number}) catch unreachable }}));
    if (timecard.pci_info.vendor) |vendor|
        attributes.appendSliceAssumeCapacity(&otel.attributes.fromPairs(.{.{ attribute.hw_vendor, @tagName(vendor) }}));
    if (timecard.pci_info.device) |device|
        attributes.appendSliceAssumeCapacity(&otel.attributes.fromPairs(.{.{ attribute.hw_model, @tagName(device) }}));

    var observed: Observed = .{ .io = io, .log = log, .timecard = &timecard, .attributes = attributes.items };
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
