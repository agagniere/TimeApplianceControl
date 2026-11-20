# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`tapctl`: a Zig CLI for timecards from Open Compute's Time Appliance Project (Facebook/Meta Timecard, Celestica, Orolia ART Card, Adva). It reads the Linux `ptp_ocp` driver's sysfs (`/sys/class/timecard/ocp<N>`) and the matching `/dev/ptp<N>` character device.

## Commands

The project targets Zig **0.16.0** (`build.zig.zon` `minimum_zig_version`). Dependencies are fetched into a project-local `zig-pkg/` folder, which is gitignored. To update one, run `zig fetch --save=<name> "git+https://...#<commit-or-tag>"`.

```sh
zig build                         # builds zig-out/bin/tapctl (Debug)
zig build --release               # ReleaseSafe (preferred_optimize_mode)
zig build run -- info -N 1        # run with args
zig build test                    # tests of the `tap` library module (src/root.zig)
zig build docs                    # emits docs to zig-out/docs
zig test src/serialnumber.zig --test-filter parseSerialNumber   # single test, only for files that import nothing beyond std
```

`zig build test` currently runs 0 tests. `root.zig` never references the test declarations of the files it imports, so `parseSerialNumber`'s test is only reached through `zig test src/serialnumber.zig`. The executable's own tests (src/main.zig) are commented out in `build.zig`.

The program only works on Linux with a real timecard present. It needs Linux ≥ 6.9 (the tty attributes are grouped in a `tty/` folder) and root access to open `/dev/ptp<N>`. It uses `@cImport` of `linux/ptp_clock.h` and links libc, so it can't run on macOS. Cross-compile with `-Dtarget=x86_64-linux-gnu` (or `aarch64-linux-gnu`). On an Apple Silicon host, the resulting binary (or test binary from `.zig-cache/o/*/test`) can be run in an aarch64 Linux container. With a fake sysfs tree passed through `-P`, it gets as far as opening `/dev/ptpN`.

## Architecture

- **`src/main.zig`**: the CLI only. `main` takes a `std.process.Init` and passes `init.io` down to everything that touches the filesystem or network. It parses arguments with `zig-args` (`parseWithVerbForCurrentProcess`). The verbs are the `Verbs` union: `info`, `monitor`, and `mro` (a stub). Help text is built from each options struct's `meta`. To add a verb, add an options struct, a `Verbs` field, a line in `CommonOptions.meta.full_text`, and a branch in the help and dispatch `switch`es. `monitor` reads the PTP offset every 10s and sends it to statsd over UDP as the gauge `<ptpN>.offset`. It resolves the address with `std.Io.net.HostName.lookup` and uses the first address that a `.dgram` connect succeeds on.
- **`src/root.zig`**: the `tap` library module, which the exe imports as `tap`. `Timecard.fromPath` collects everything from sysfs into one struct, and `Timecard.to_json` builds a `std.json.Value` by hand, using an arena. The JSON shape is the output contract of `tapctl info` (see the README examples). Any new field must be added in three places: the struct, `deinit`, and `to_json`. `Timecard` stores the `Io` it was created with, because `deinit` needs it to close the PTP device. `std.json.ObjectMap` is unmanaged, so `put` takes the arena.
- **`src/ptp.zig`**: talks to `/dev/ptpN` with raw `ioctl`s (`PTP_CLOCK_GETCAPS`, `PTP_PIN_GETFUNC`, `PTP_SYS_OFFSET_EXTENDED`). The ioctl request constants are `@truncate`d to `u32` for `std.c.ioctl`. `readOffset` subtracts a hard-coded 37s TAI-UTC offset.
- **`src/pci.zig`**: maps PCI vendor and device IDs to enums. Their `@tagName`s are the display strings, hence names like `@"ART Card"`.
- **`src/readfile.zig`**: helpers for reading sysfs attributes (an integer, or a space-separated list) that log a descriptive error on failure. Pass `.mandatory = false` for optional attributes so no error gets logged.
- **`src/log.zig`**: configures logging with the upstream `axe` library (Ratakor/axe, pinned by release tag). The exe installs it as `std_options.logFn`. Modules use `Log.scoped(.timecard)`, and use `log.errAt(@src(), ...)` / `warnAt` to include the source location.

## Conventions

- Memory is managed explicitly. Structs own duped strings and free them in `deinit(gpa)`. `main` uses `init.gpa`, which leak-checks in Debug builds only (because libc is linked).
- Sysfs attributes that only exist on some cards or kernel versions (for example `clock_source`, `available_clock_sources`, `serialnum`) are optional fields (`?T`). Failing to read them gives `null` and does not abort, and `to_json` leaves the key out.
- Known hardware and kernel quirks get a log message that tells the user how to fix them. For example, `ts_window_adjust` overflows on Linux 6.12–6.17 (fix: write `0` to it).
