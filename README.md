# TAP control

A command line interface for timecards of Open Compute's Time Appliance Project

## Roadmap of features
- [x] Dump all user-space info as JSON
- [x] Monitor the clock offset accross time
- [ ] Monitor GNSS signal status
- [ ] Monitor oscillator state

## Requirement

[Zig](https://ziglang.org/download/) version `0.17.0`

## Usage

Two executables share the same options to select the timecard:
- `tapctl` for one-off actions, logging to stderr in a readable format
- `tap-monitor`, a long-running process meant for a systemd service, reporting metrics and logs with OpenTelemetry

```console
$ zig build run
Usage: tapctl [-N NUMBER | -n NAME | -P PATH] [-r ROOT] [-h] [-v] COMMAND

Control a time card from Open Compute Project's Time Appliance Project

Commands:
  info     Dump all info collected about the time card as a single JSON object to standard output
  mro      Interact with an mRO50

Monitoring is done by tap-monitor

Options:
  -N, --ocp-number      Specify the number of the appliance. Its sysfs is
                        then assumed to be at /sys/class/timecard/ocp<N>.
                        Defaults to 0
  -n, --timecard-name   Specify the name of the appliance. Its sysfs is then
                        assumed to be at /sys/class/timecard/<NAME>.
                        Overrides --ocp-number
  -P, --timecard-path   Specify the absolute path of the appliance's sysfs.
                        Overrides --timecard-name and --ocp-number
  -r, --root            Resolve all absolute paths (sysfs and /dev) relative
                        to this directory, like chroot. Defaults to /
  -h, --help            Display this usage message on standard output and
                        exit successfully
  -v, --version         Show version information on standard output and
                        exit successfully
```

```console
$ zig build run-monitor -- --help
Usage: tap-monitor [-N NUMBER | -n NAME | -P PATH] [-r ROOT] [-h] [-v]

Report the offset between the PTP clock of a time card and the system clock every 10 seconds, with OpenTelemetry.
Configure the export with the standard environment variables, such as OTEL_EXPORTER_OTLP_ENDPOINT and OTEL_SERVICE_NAME

Options:
  -N, --ocp-number      Specify the number of the appliance. Its sysfs is
                        then assumed to be at /sys/class/timecard/ocp<N>.
                        Defaults to 0
  -n, --timecard-name   Specify the name of the appliance. Its sysfs is then
                        assumed to be at /sys/class/timecard/<NAME>.
                        Overrides --ocp-number
  -P, --timecard-path   Specify the absolute path of the appliance's sysfs.
                        Overrides --timecard-name and --ocp-number
  -r, --root            Resolve all absolute paths (sysfs and /dev) relative
                        to this directory, like chroot. Defaults to /
  -h, --help            Display this usage message on standard output and
                        exit successfully
  -v, --version         Show version information on standard output and
                        exit successfully
```

## Demo

Note: Super user privilege is required to access `/dev/ptp<N>`

### Monitor clock offset

A measurement is done every 10 seconds, and reported as the gauge `timecard.ptp.offset`, in nanoseconds, with the attributes `timecard.name` and `ptp.clock.name`.
Logs are exported too, and also written to stderr for journald.
OpenTelemetry is set up before looking for the timecard, so that the collector also receives startup errors.

```console
# OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 OTEL_SERVICE_NAME=tap-monitor ./zig-out/bin/tap-monitor --ocp-number 1
```

### Meta Timecard

```console
# ./zig-out/bin/tapctl info
[INFO ] Starting tapctl version 0.0.2, with timecard at /sys/class/timecard/ocp0
[DEBUG timecard] Card ocp0 is part of the PCI device /sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0
[INFO  timecard] Card ocp0 detected as Facebook Timecard rev. 0, PCI x1
[INFO  timecard] Card ocp0 exposes PTP clock ptp1
[ERROR timecard] Unable to read serial number of ocp0: InvalidCharacter
{"card":{"name":"ocp0","path":"/sys/class/timecard/ocp0","clock_source":"PPS","timestamp_window_adjustment":0,"connectors":[{"name":"sma4","way":"output","format":"PHC"},{"name":"sma2","way":"input","format":"PPS1"},{"name":"sma3","way":"output","format":"10Mhz"},{"name":"sma1","way":"input","format":"10Mhz"}],"available":{"clock_source":["NONE","TOD","IRIG","PPS","PTP","RTC","DCF","REGS","EXT"],"formats":{"input":["10Mhz","PPS1","PPS2","TS1","TS2","IRIG","DCF","TS3","TS4","FREQ1","FREQ2","FREQ3","FREQ4","None"],"output":["10Mhz","PHC","MAC","GNSS1","GNSS2","IRIG","DCF","GEN1","GEN2","GEN3","GEN4","GND","VCC"]}}},"serial_ports":{"GNSS":"ttyS4","NMEA":"ttyS7","MAC":"ttyS6","GNSS2":"ttyS5"},"ptp":{"name":"ptp1","capabilities":{"max_frequency_adjustment":{"value":100000000,"unit":"ppb"},"programmable_alarms":0,"external_timestamp_channels":6,"periodic_output_signals":5,"pps_callback":true,"cross_timestamping":false,"phase_adjustment":true,"max_phase_adjustment":{"value":0,"unit":"ns"}},"pins":[{"name":"sma1","function":"None","channel":0},{"name":"sma2","function":"None","channel":0},{"name":"sma3","function":"None","channel":0},{"name":"sma4","function":"None","channel":0}]},"pci":{"vendor":"Facebook","device":"Timecard","revision":0,"max_speed":"2.5 GT/s PCIe","max_width":1}}
```

Note that the parsing of the serial number failed, because the only such card I have access to doesn't have a correctly flashed serial number in its EEPROM.

### Orolia ART Card

This time using [yq](https://github.com/mikefarah/yq) to make the JSON output human-readable

```console
# ./zig-out/bin/tapctl info --ocp-number 2 | yq -P
[INFO ] Starting tapctl version 0.0.1, with timecard at /sys/class/timecard/ocp2
[DEBUG timecard] Card ocp2 is part of the PCI device /sys/devices/pci0000:00/0000:00:1c.4/0000:06:00.0
[INFO  timecard] Card ocp2 detected as Orolia ART Card rev. 6, PCI x4
[INFO  timecard] Card ocp2 exposes PTP clock ptp2
card:
  serial_number: 240697
  name: ocp2
  path: /sys/class/timecard/ocp2
  timestamp_window_adjustment: 261
  connectors:
    - name: sma4
      way: output
      format: MAC
    - name: sma2
      way: output
      format: MAC
    - name: sma3
      way: input
      format: PPS1
    - name: sma1
      way: output
      format: MAC
  available:
    formats:
      input:
        - PPS1
        - 10Mhz
      output:
        - MAC
        - GNSS
        - 10Mhz
serial_ports:
  GNSS: ttyS12
  NMEA: ttyS14
  MAC: ttyS15
  GNSS2: ttyS13
ptp:
  name: ptp2
  capabilities:
    max_frequency_adjustment:
      value: 100000000
      unit: ppb
    programmable_alarms: 0
    external_timestamp_channels: 6
    periodic_output_signals: 5
    pps_callback: true
    cross_timestamping: false
    phase_adjustment: false
    max_phase_adjustment:
      value: 0
      unit: ns
  pins: []
pci:
  vendor: Orolia
  device: ART Card
  revision: 6
  max_speed: 2.5 GT/s PCIe
  max_width: 4
```
(Note: A custom driver version was in use at that time)
