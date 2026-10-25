# Resources, history interpolation and sampling

## Display cadence

Intervals are seconds, ordered temperature / aggregate network / CPU ranking:

| State | Temperature | Network | CPU ranking |
| --- | ---: | ---: | ---: |
| Default background | 10 | 3 | 10 |
| Eco background | 30 | 10 | 30 |
| Panel or settings visible | 10 | 3 | 10 |
| Explicit Fast background | 3 | 1 | 5 |

Low Power Mode selects Eco in the background. Opening a panel selects Default,
including when Eco is selected. Hidden realtime CPU rankings and hidden network
displays remain stopped. The expanded per-process network reader now samples at
3 s instead of 2 s. Resources (memory, startup disk, GPU) sample only while the
menu panel is visible, immediately on opening and then every 10 s.

Curve safety remains independent: its internal sensor snapshot refreshes at 2 s,
with the existing 6 s freshness limit and 1.5 s fan-control loop. Display values
and histories publish at the selected 10/30 s cadence. Fixed manual RPM no longer
requires rapid temperature sampling. Display sleep stops resource/display work;
system sleep invalidates the internal snapshot and requests firmware auto.

## Resource definitions

- **Memory:** estimated used physical memory, anonymous resident minus purgeable
  pages plus wired and physical compressor pages. Reclaimable file cache is
  excluded. Total is physical RAM. Binary GiB avoids silently mixing units.
  This is occupancy, not macOS Memory Pressure or per-process app memory.
- **Startup disk:** total minus available bytes on the startup Data volume,
  falling back to root on systems without that mount. Shared APFS volumes are
  not summed. Decimal GB matches disk capacity conventions. Finder may include
  purgeable-space estimates that this fast, read-only measurement excludes.
  This is capacity occupancy, not disk I/O throughput.
- **GPU:** the IOAccelerator driver's Device Utilization % counter. It is a
  driver-reported sample, not a 10 s average. The registry handle is reused and
  released correctly. Missing, nonfinite or out-of-range counters are shown as
  Unavailable, never as zero. Availability depends on the device/OS driver.

No administrator permission, disk enumeration, subprocess or GPU workload is
required for these readings. A single-flight utility queue discards stale results
when a panel closes; quick reopen primes a fresh snapshot.

## Smooth history

Only history charts change. The temperature-to-fan-speed curve and control
interpolation remain untouched. Shape-preserving cubic tangents connect measured
points without overshooting adjacent values or filtering away peaks. Each
contiguous sample run is drawn independently; sleep/missing-data gaps remain gaps.
Log network charts interpolate in display coordinates. Raw readings, retention
and bar charts are unchanged. No animation timer or synthetic samples are added.

## Validation

- Logic tests cover requested cadence/Low Power Mode, independent display/control
  timing, stale temperatures, capacity/GPU validation, resource close/reopen,
  interpolation endpoints, flat runs, extrema and irregular sample spacing.
- Read-only API smoke checks require memory and startup capacity; GPU can be
  unavailable on CI. The development machine exposes all three readings.
- Runtime tests exercise resource visibility, scroll overflow and repeated window
  release/reopening. Optional OMNISTATS_TEST_SNAPSHOT_DIR captures test UI with
  simulated readings for visual review; these images are not measurements.
- Existing helper-safety and socket-transport regressions remain required.
