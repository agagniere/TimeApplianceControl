# TAP control

A command line interface for timecards of Open Compute's Time Appliance Project

## Roadmap of features
- [x] Dump all user-space info as JSON
- [x] Monitor the clock offset accross time
- [ ] Monitor GNSS signal status
- [ ] Monitor oscillator state

## Requirement

[Zig](https://ziglang.org/download/) version `0.15.1`

## Usage

```console
$ zig build run
Usage: tapctl [-N NUMBER | -n NAME | -P PATH] [-h] [-v] COMMAND

Control a time card from Open Compute Project's Time Appliance Project

Commands:
  info     Dump all info collected about the time card as a single JSON object to standard output
  monitor  Collect metrics from the clock and possibly the oscillator, pushed to statsd
  mro      Interact with an mRO50

Options:
  -N, --ocp-number      Specify the number of the appliance. Its sysfs is
                        then assumed to be at /sys/class/timecard/ocp<N>.
                        Defaults to 0
  -n, --timecard-name   Specify the name of the appliance. Its sysfs is then
                        assumed to be at /sys/class/timecard/<NAME>.
                        Overrides --ocp-number
  -P, --timecard-path   Specify the absolute path of the appliance's sysfs.
                        Overrides --timecard-name and --ocp-number
  -h, --help            Display this usage message on standard output and
                        exit successfully
  -v, --version         Show version information of the standard output
                        and exit successfully
```

## Demo

Note: Super user privilege is required to access `/dev/ptp<N>`

### Monitor clock offset

A measurement is done every 10 seconds

```console
# ./zig-out/bin/tapctl monitor --ocp-number 1
[INFO ] Starting tapctl version 0.0.1, with timecard at /sys/class/timecard/ocp1
[DEBUG timecard] Card ocp1 is part of the PCI device /sys/devices/pci0000:00/0000:00:01.1/0000:02:00.0
[INFO  timecard] Card ocp1 detected as Orolia ART Card rev. 6, PCI x4
[INFO  timecard] Card ocp1 exposes PTP clock ptp2
[INFO ] Will send statds metrics to 127.0.0.1:8125
[DEBUG] ptp2: 23ns
[DEBUG] ptp2: 3ns
[DEBUG] ptp2: 21ns
[DEBUG] ptp2: 30ns
[DEBUG] ptp2: 13ns
```

### Meta Timecard

```console
# ./zig-out/bin/tapctl info
[INFO ] Starting tapctl version 0.0.0, with timecard at /sys/class/timecard/ocp0
[DEBUG timecard] Card ocp0 is part of the PCI device /sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0
[INFO  timecard] Card ocp0 detected as Facebook Timecard rev. 0, PCI x1
[INFO  timecard] Card ocp0 exposes PTP clock ptp1
[ERROR timecard root.zig:fromPath:159] Unable to read serial number of ocp0: InvalidCharacter
{"card":{"name":"ocp0","path":"/sys/class/timecard/ocp0","clock_source":"PPS","connectors":[{"name":"sma4","way":"output","format":"PHC"},{"name":"sma2","way":"input","format":"PPS1"},{"name":"sma3","way":"output","format":"10Mhz"},{"name":"sma1","way":"input","format":"10Mhz"}],"available":{"clock_source":["NONE","TOD","IRIG","PPS","PTP","RTC","DCF","REGS","EXT"],"formats":{"input":["10Mhz","PPS1","PPS2","TS1","TS2","IRIG","DCF","TS3","TS4","FREQ1","FREQ2","FREQ3","FREQ4","None"],"output":["10Mhz","PHC","MAC","GNSS1","GNSS2","IRIG","DCF","GEN1","GEN2","GEN3","GEN4","GND","VCC"]}}},"serial_ports":{"GNSS":"ttyS4","NMEA":"ttyS7","MAC":"ttyS6","GNSS2":"ttyS5"},"ptp":{"name":"ptp1","capabilities":{"max_frequency_adjustment":{"value":100000000,"unit":"ppb"},"programmable_alarms":0,"external_timestamp_channels":6,"periodic_output_signals":5,"pps_callback":true,"cross_timestamping":false,"phase_adjustment":true,"max_phase_adjustment":{"value":0,"unit":"ns"}},"pins":[{"name":"sma1","function":"None","channel":0},{"name":"sma2","function":"None","channel":0},{"name":"sma3","function":"None","channel":0},{"name":"sma4","function":"None","channel":0}]},"pci":{"vendor":"Facebook","device":"Timecard","revision":0,"max_speed":"2.5 GT/s PCIe","max_width":1}}
```

Note that the parsing of the serial number failed, because the only such card I have access to doesn't have a correctly flashed serial number in its EEPROM.

### Orolia ART Card

This time using [yq](https://github.com/mikefarah/yq) to make the JSON output human-readable

```console
# ./zig-out/bin/tapctl info --ocp-number 1 | yq -P
[INFO ] Starting tapctl version 0.0.0, with timecard at /sys/class/timecard/ocp1
[DEBUG timecard] Card ocp1 is part of the PCI device /sys/devices/pci0000:00/0000:00:01.1/0000:02:00.0
[INFO  timecard] Card ocp1 detected as Orolia ART Card rev. 6, PCI x4
[INFO  timecard] Card ocp1 exposes PTP clock ptp2
card:
  serial_number: 210345
  name: ocp1
  path: /sys/class/timecard/ocp1
  clock_source: NONE
  connectors:
    - name: sma4
      way: output
      format: PHC
    - name: sma2
      way: input
      format: PPS1
    - name: sma3
      way: output
      format: GNSS
    - name: sma1
      way: output
      format: 10Mhz
  available:
    clock_source:
      - NONE
      - TOD
      - IRIG
      - PPS
      - PTP
      - RTC
      - DCF
      - REGS
      - EXT
    formats:
      input:
        - PPS1
        - 10Mhz
      output:
        - PHC
        - GNSS
        - 10Mhz
serial_ports:
  GNSS: ttyS8
  MAC: ttyS9
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
    phase_adjustment: true
    max_phase_adjustment:
      value: 0
      unit: ns
  pins:
    - name: sma1
      function: None
      channel: 0
    - name: sma2
      function: None
      channel: 0
    - name: sma3
      function: None
      channel: 0
    - name: sma4
      function: None
      channel: 0
pci:
  vendor: Orolia
  device: ART Card
  revision: 6
  max_speed: 2.5 GT/s PCIe
  max_width: 4
```
