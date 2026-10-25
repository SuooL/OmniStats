# Runtime, energy and control audit — October 2026

Scope: sampling, retained UI, histories, process lifetimes, fan control,
persistence, and delivery. This records evidence, not an energy guarantee.

## Findings and fixes

- High: main-thread HID, process enumeration and socket I/O. Sensors/processes
  now use single-flight utility queues; control has one latest pending intention.
- High: stale curve temperature and invalid hardware bounds. Curve input expires
  after six seconds; invalid inputs revert to firmware auto. Commands expire,
  reconnection reapplies all targets, and long stalls reapply even on the same socket.
- High: PING renewed the helper watchdog. Protocol 2 renews only valid SET/HB;
  invalid commands/NaN/Inf are rejected. Failed auto writes remain retryable.
  Socket requests have a total 750 ms deadline and handle partial replies/SIGPIPE.
- Medium: fixed background cadence. A central policy now follows visibility,
  Low Power Mode, display/session activity and sleep. Sensor classification and
  SMC metadata are cached; fan bounds refresh every minute and on resumed discovery.
- Medium: biased variable-cadence CPU averages, PID reuse and interface resets.
  Averages are duration weighted; PID birth times and actual interface indices
  prevent counter errors. Rates use actual elapsed monotonic time.
- Medium: nettop parsing, buffering and lifecycle. A bounded streaming parser,
  nonblocking PTY, serial read cancellation and session generations keep output
  prompt and prevent old callbacks from disturbing a replacement process.
  nettop stops when collapsed/asleep; warmup/failure/empty states are distinct.
- Medium: bounded chart retention and cadence-aware gaps; debounced preference
  persistence (300 ms, flushed on exit); reduced settings-root invalidation.
- Interaction: curve drag coordinates/spacing/bounds, Fahrenheit menu display,
  accessibility labels, keyboard toggles, and nested-scroll removal.
- Delivery: signing failure is fatal; CI/release run isolated safety regressions;
  tags must match both bundle versions.

## Sampling intervals (seconds)

| State | Sensors | Aggregate network | CPU ranking |
| --- | ---: | ---: | ---: |
| Previous background defaults | 2 | 1 | 2 |
| Fast background | 3 | 1 | 5 |
| Balanced background (default) | 5 | 2 | 10 |
| Eco background / Low Power Mode | 10 | 5 | 15 |
| Menu panel visible | 2 | 1 | 2 |

Settings visibility accelerates sensors only. Hidden network displays and hidden
realtime CPU rankings stop sampling; CPU rolling averages continue in background.
Display sleep/inactive login pauses display work; manual/curve mode keeps 2 s
sensors. System sleep stops timers and requests firmware auto. The independent
1.5 s fan loop exists only in active manual/curve mode, unaffected by energy mode.

## Validation and measurements

Run **make test-logic test-runtime app helper** on a logged-in macOS desktop.
Logic/helper/transport tests use mocks and a temporary socket, never the installed
helper. Runtime checks exercise real read-only nettop replacement/cleanup,
visibility transitions and 12 panel/settings release/reopen cycles.
GUI runtime tests stay local because they require an interactive desktop.

Installed v1.3.4 baseline: 0.9–1.3% CPU over three short top intervals and about
119 MiB footprint. This is not a cross-machine resource budget. The earlier large
UI-retention improvement was already in v1.3.4, not part of this release.

Read-only sensor benchmark: three alternating runs, one warmup and 30 consecutive
reads per run, ms/read (initialization excluded):

| Run | Baseline wall | New wall | Baseline CPU | New CPU |
| --- | ---: | ---: | ---: | ---: |
| 1 | 76.614 | 31.106 | 1.854 | 0.952 |
| 2 | 78.228 | 33.004 | 2.175 | 1.127 |
| 3 | 82.689 | 34.637 | 2.852 | 1.755 |

Reproduce with **python3 tools/benchmark-sensors.py v1.3.4**. This compiles sensor
reads only, never control writes. Readings were finite with two fans on this
machine. Load and temperature varied. This isolates per-read cost; it does not
establish battery-life gains or whole-app steady-state memory/energy consumption.

## Limits and follow-up

- App update does not replace the privileged daemon. Existing users must choose
  **Update service** in fan settings and authorize the macOS admin prompt for
  protocol-2 watchdog protection. The app detects old helpers explicitly.
- HID temperature access is private API; SMC layouts differ. Automated tests do
  not perform real fan writes. Hardware/OS coverage and long sleep/wake trials
  remain necessary, as does long-duration whole-app memory/energy profiling.
- Unsampled sleep periods remain gaps. CPU averages describe observed intervals;
  short-lived processes entirely between samples cannot be captured.
- Minimized settings retain their native hosting tree with reduced-rate updates;
  further teardown needs separate UX validation.
- Existing ad-hoc app signing plus signed Sparkle distribution remains unchanged;
  this release does not introduce Developer ID notarization.
