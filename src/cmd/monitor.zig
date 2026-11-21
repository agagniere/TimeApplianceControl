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

/// Exponential histograms adapt their buckets to the values, which range from nanoseconds to seconds, of either sign
fn aggregation(kind: otel.metrics.Kind) otel.metrics.View.Aggregation {
    const options: otel.metrics.View.ExponentialBucketHistogramConfig.Options = .{};
    return switch (kind) {
        .Histogram => .{ .ExponentialBucketHistogram = .{ .max_scale = options.max_scale, .max_size = options.max_size, .record_min_max = options.record_min_max } },
        else => otel.metrics.View.DefaultAggregation(kind),
    };
}

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
    /// What was discovered about the card, once it is
    attributes: []const otel.Attribute = &.{},

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
        self.logger.emit(severity, body.buffered(), .{ .severity_text = level.asText(), .location = location, .attributes = self.attributes });
        std.log.defaultLog(level, .monitor, format, args);
    }
};

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
    interval: u32 = 2000,
    samples: u8 = 5,
    help: bool = false,
    version: bool = false,
    pub const wrap_len = 40;

    pub const shorthands = .{
        .N = "ocp-number",
        .n = "timecard-name",
        .P = "timecard-path",
        .r = "root",
        .i = "interval",
        .s = "samples",
        .h = "help",
        .v = "version",
    };
    pub const meta = .{
        .usage_summary = "[-N NUMBER | -n NAME | -P PATH] [-r ROOT] [-i MILLISECONDS] [-s SAMPLES] [-h] [-v]",
        .full_text =
        \\Report the offset between the PTP clock of a time card and the system clock with OpenTelemetry, as histograms of the samples read between two exports of the metrics.
        \\Configure the export with the standard environment variables, such as OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME (tap-monitor by default), and OTEL_METRIC_EXPORT_INTERVAL (10000 ms by default)
        ,
        .option_docs = .{
            .@"ocp-number" = "Specify the number of the appliance. Its sysfs is then assumed to be at /sys/class/timecard/ocp<N>. Defaults to 0",
            .@"timecard-name" = "Specify the name of the appliance. Its sysfs is then assumed to be at /sys/class/timecard/<NAME>. Overrides --ocp-number",
            .@"timecard-path" = "Specify the absolute path of the appliance's sysfs. Overrides --timecard-name and --ocp-number",
            .root = "Resolve all absolute paths (sysfs and /dev) relative to this directory, like chroot. Defaults to /",
            .interval = "Specify how often to read the offset, in milliseconds. Defaults to 2000",
            .samples = std.fmt.comptimePrint("Specify how many samples each reading makes, from 1 to {}. Defaults to 5", .{tap.PtpInfo.max_samples}),
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
    if (options.options.interval == 0) {
        std.log.scoped(.cli).err("The interval between readings must be at least 1 ms", .{});
        return 1;
    }
    if (options.options.samples < 1 or options.options.samples > tap.PtpInfo.max_samples) {
        std.log.scoped(.cli).err("The number of samples per reading must be from 1 to {}, not {}", .{ tap.PtpInfo.max_samples, options.options.samples });
        return 1;
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
    var log: Log = .{ .logger = try logger_provider.getLogger(.{ .name = build_info.name, .version = build_info.version }) };

    const meter_provider = try otel.metrics.MeterProvider.init(gpa, io);
    defer meter_provider.deinit();
    const metric_exporter = try otel.metrics.MetricExporter.OTLP(gpa, io, otel.metrics.View.TemporalityDelta, aggregation, otlp_config);
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

    // The names of the card and of its clock follow the probe order, so they can change when cards are added or moved
    var attributes: std.ArrayList(otel.Attribute) = .empty;
    defer attributes.deinit(gpa);
    try attributes.appendSlice(gpa, &otel.attributes.fromPairs(.{
        .{ attribute.timecard_name, timecard.name },
        .{ attribute.timecard_path, timecard.path },
    }));
    // The logs get only what was discovered, since their resource has the attributes above.
    // The metrics can't have a resource from the application: https://github.com/open-telemetry/opentelemetry-zig/issues/195
    const first_discovered = attributes.items.len;
    try attributes.appendSlice(gpa, &otel.attributes.fromPairs(.{.{ attribute.ptp_clock_name, timecard.ptp_info.name }}));
    // Left out when unknown
    var serial_number_buffer: [std.fmt.count("{}", .{std.math.maxInt(u32)})]u8 = undefined;
    if (timecard.serialnumber) |serial_number|
        try attributes.appendSlice(gpa, &otel.attributes.fromPairs(.{.{ attribute.hw_serial_number, std.fmt.bufPrint(&serial_number_buffer, "{}", .{serial_number}) catch unreachable }}));
    if (timecard.pci_info.vendor) |vendor|
        try attributes.appendSlice(gpa, &otel.attributes.fromPairs(.{.{ attribute.hw_vendor, @tagName(vendor) }}));
    if (timecard.pci_info.device) |device|
        try attributes.appendSlice(gpa, &otel.attributes.fromPairs(.{.{ attribute.hw_model, @tagName(device) }}));

    // Taken once the list stops growing
    log.attributes = attributes.items[first_discovered..];

    // Stopped before the timecard is freed: its last export reads the strings the attributes borrow from it
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

    const meter = try meter_provider.getMeter(.{ .name = build_info.name, .version = build_info.version });
    // Of the readings since the previous export, as the temporality is delta
    const offset = try meter.createHistogram(i64, .{
        .name = "timecard.ptp.offset",
        .unit = "ns",
        .description = "Time to add to the system clock to get the time of the timecard's PTP clock",
    });
    const window = try meter.createHistogram(i64, .{
        .name = "timecard.ptp.offset.window",
        .unit = "ns",
        .description = "System time elapsed around the reading of the PTP clock: the offset is known to within half of it",
    });

    const interval: std.Io.Duration = .fromMilliseconds(options.options.interval);
    var samples_buffer: [tap.PtpInfo.max_samples]tap.Offset = undefined;
    const samples = samples_buffer[0..options.options.samples];
    while (true) {
        timecard.ptp_info.readOffsets(true, samples) catch |err| {
            log.emit(.err, @src(), "Unable to read the offset of {s}: {t}", .{ timecard.ptp_info.name, err });
            return error.ReadingFailed;
        };
        for (samples) |sample| {
            try offset.recordWithSlice(sample.value, attributes.items);
            try window.recordWithSlice(sample.window, attributes.items);
        }
        try io.sleep(interval, .awake);
    }
}
