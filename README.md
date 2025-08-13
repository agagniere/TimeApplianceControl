# TAP control

A command line interface for timecards of Open Compute's Time Appliance Project

## Roadmap of features
- [x] Dump all user-space info as JSON
- [ ] Monitor the clock offset accross time
- [ ] Monitor GNSS signal status
- [ ] Monitor oscillator state

## Requirement

[Zig](https://ziglang.org/download/) master (`0.15.0-dev.1380` or newer)

## Demo

Using [yq](https://github.com/mikefarah/yq) to make the JSON output human-readable

### Meta Timecard

```console
# ./zig-out/bin/tapctl info | yq -P
[INFO ] Starting tapctl version 0.0.0, with timecard at /sys/class/timecard/ocp0
[DEBUG timecard] Card ocp0 is part of the PCI device /sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0
[INFO  timecard] Card ocp0 detected as Facebook Timecard rev. 0, PCI x1
[INFO  timecard] Card ocp0 exposes PTP clock ptp1
[ERROR timecard root.zig:fromDir:135] Unable to read serial number of ocp0: InvalidCharacter
card:
  name: ocp0
  connectors:
    - name: sma4
      way: output
      current: PHC
    - name: sma2
      way: input
      current: PPS1
    - name: sma3
      way: output
      current: 10Mhz
    - name: sma1
      way: input
      current: 10Mhz
serial_ports:
  GNSS: ttyS4
  NMEA: ttyS7
  MAC: ttyS6
  GNSS2: ttyS5
ptp:
  name: ptp1
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
  vendor: Facebook
  device: Timecard
  revision: 0
  max_speed: |
    2.5 GT/s PCIe
  max_width: 1
```

Note how the parsing of the serial number failed because it was garbage

### Orolia ART Card

```console
# ./zig-out/bin/tapctl info --ocp-number 1 | yq -P
[INFO ] Starting tapctl version 0.0.0, with timecard at /sys/class/timecard/ocp1
[DEBUG timecard] Card ocp1 is part of the PCI device /sys/devices/pci0000:00/0000:00:01.1/0000:02:00.0
[INFO  timecard] Card ocp1 detected as Orolia ART Card rev. 6, PCI x4
[INFO  timecard] Card ocp1 exposes PTP clock ptp2
card:
  serial_number: 210345
  name: ocp1
  connectors:
    - name: sma4
      way: output
      current: PHC
    - name: sma2
      way: input
      current: PPS1
    - name: sma3
      way: output
      current: GNSS
    - name: sma1
      way: output
      current: 10Mhz
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
  max_speed: |
    2.5 GT/s PCIe
  max_width: 4
```
