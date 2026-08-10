# Contributing to OmniStats

Thanks for your interest! OmniStats is a lightweight Apple Silicon menu-bar
system monitor. This document describes the branch workflow, how to build, and
project layout.

## Branch workflow — `feature/*` → `dev` → `main`

```
feature/xxx ──PR──▶ dev ──PR──▶ main ──tag vX.Y.Z──▶ Release
```

- **`main`** — always stable and release-ready. Protected. Releases are cut by
  tagging a commit here `vX.Y.Z` (triggers `.github/workflows/release.yml`).
- **`dev`** — integration branch. All features land here first via PR.
- **`feature/<short-name>`** — branch off `dev` for each change; open a PR back
  into `dev`. Keep them focused.
- **`fix/<short-name>`** — same as feature, for bug fixes.

Typical loop:

```bash
git switch dev && git pull
git switch -c feature/network-module
# ...work, commit...
git push -u origin feature/network-module
gh pr create --base dev            # PR into dev
# after review + CI green, squash-merge into dev
```

Cutting a release:

```bash
git switch main && git merge --no-ff dev
git tag v1.1.0 && git push origin main --tags   # release.yml builds & publishes
```

Bump `CFBundleShortVersionString` in `packaging/Info.plist` to match the tag —
the in-app updater compares against it.

## Build

Requires the Command Line Tools (`xcode-select --install`); full Xcode is not
needed.

```bash
make            # build dist/OmniStats.app + helper
make run        # build and launch
make test       # CLI smoke test of the sensor/control layer
make clean
```

CI (`.github/workflows/ci.yml`) builds every push/PR to `main`/`dev` on an
Apple Silicon runner.

## Project layout

| Path                    | Role                                              |
|-------------------------|---------------------------------------------------|
| `src/smc.h`             | AppleSMC read/write + fan-key probing (shared C)  |
| `src/sensors.{h,m}`     | Temperature/fan/power sampling → clean C API       |
| `src/control.{h,m}`     | Persistent client to the privileged helper         |
| `src/smcd.m`            | `omnistats-smcd` — root helper daemon              |
| `src/*.swift`           | SwiftUI app (Theme, Config, Model/Engine, Curve, Panels, Updater) |
| `packaging/`            | LaunchDaemon plist, Info.plist, install scripts    |
| `.github/workflows/`    | CI + Release                                       |

## Design notes

- **Temperatures** come from the private `IOHIDEventSystemClient` HID sensors
  (the Apple Silicon path); **fans/power** from AppleSMC.
- **Fan control** writes `F<n>md=1` (manual) then `F<n>Tg` (target rpm), clamped
  to `[F<n>Mn, F<n>Mx]`. Note the lowercase `md` on M-series.
- The **engine** smooths temperature (EMA), applies a hysteresis deadband, and
  slew-limits the commanded speed so fans never surge.
- The **helper** verifies the peer uid, and a watchdog reverts to firmware auto
  if the app disconnects or hangs.

## Code style

Match the surrounding code. Keep the C layer free of Objective-C objects where a
plain C API is exposed to Swift. Prefer small, focused PRs.

## Adding a new module

OmniStats will grow beyond thermals (network, disk, battery, …). A module is
typically: a C/Swift sampler exposed through a small API, a published field on
`Monitor`, and a section in the menu panel / settings. Open an issue to discuss
before large additions.
