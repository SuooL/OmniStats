<div align="center">

# OmniStats

**A lightweight Apple Silicon menu-bar system monitor — with real fan control.**

[![CI](https://github.com/SuooL/OmniStats/actions/workflows/ci.yml/badge.svg)](https://github.com/SuooL/OmniStats/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Apple%20Silicon-black.svg)
![macOS](https://img.shields.io/badge/macOS-13%2B-lightgrey.svg)

English · [简体中文](README.zh-CN.md)

<img src="assets/curve-dark.png" width="720" alt="OmniStats fan curve">

</div>

## What it is

OmniStats lives in your menu bar and shows SoC / SSD / battery temperatures,
power draw, and fan RPM at a glance. Unlike most monitors, it can **actually
control the fans** on Apple Silicon Macs — with a temperature→speed curve and
hardware-friendly, gradual ramping.

> Thermals are the first module. Network, disk, and battery panels are on the
> roadmap — OmniStats is meant to grow into a full system dashboard.

Verified end-to-end on **M5 Pro (Mac17,8)**. Fan control works on Apple Silicon
Macs whose firmware exposes writable fan keys (see [How fan control works](#how-fan-control-works)).

## Features

- 🌡 Menu-bar readout of the hottest SoC temperature + ring gauges
- 📈 Interactive **temperature → fan-speed curve** with a live operating point
- 🌀 **Auto / Manual / Curve** modes; per-machine fan limits handled automatically
- 🧊 **Hardware-friendly control**: EMA temperature smoothing + hysteresis
  deadband + slew-rate limiting — fans never surge on a 1° blip
- 🎛 One-click curve presets (Quiet / Balanced / Cooler)
- 🎨 Dark & light "thermal instrument" themes
- 🔒 In-app privileged-helper install (single native prompt, no Terminal)
- ⬆️ Built-in update check with optional one-click self-update
- 🪶 Tiny native SwiftUI app — no Electron, no background bloat

## Screenshots

| Menu bar | Fan curve (dark) | Fan curve (light) |
|---|---|---|
| <img src="assets/menu.png" width="240"> | <img src="assets/curve-dark.png" width="240"> | <img src="assets/curve-light.png" width="240"> |

## Install

### Download (recommended)

Grab the latest **`OmniStats.dmg`** from the
[Releases page](https://github.com/SuooL/OmniStats/releases/latest), open it, and
drag **OmniStats** into Applications. Not notarized yet — on first launch,
right-click the app → **Open** (or run `xattr -dr com.apple.quarantine /Applications/OmniStats.app`).

### Build from source

Requires the Command Line Tools (`xcode-select --install`); full Xcode not needed.

```bash
git clone https://github.com/SuooL/OmniStats.git
cd OmniStats
make
open dist/OmniStats.app
```

First launch may be blocked by Gatekeeper (the app isn't notarized). Right-click →
**Open**, or:

```bash
xattr -dr com.apple.quarantine dist/OmniStats.app
```

### Enable fan control

Click **Enable fan control** in the app and authorize once — OmniStats installs a
small root helper (LaunchDaemon) for you. No Terminal required. Remove it anytime
from **About → Remove helper**.

## How fan control works

Apple Silicon fans are governed by the SMC. OmniStats controls a fan by writing
two SMC keys as root:

| Key       | Meaning                                       |
|-----------|-----------------------------------------------|
| `F<n>md`  | mode — `0` = firmware auto, `1` = manual       |
| `F<n>Tg`  | target RPM (clamped to `F<n>Mn`…`F<n>Mx`)      |

Sequence: set `F<n>md = 1`, then write `F<n>Tg`. Note the **lowercase** `md` on
M-series Macs (older/Intel used `F0Md`); OmniStats probes both. Machines without
fans (e.g. MacBook Air) fall back to monitor-only mode.

Temperatures are read from the private `IOHIDEventSystemClient` thermal sensors;
fan RPM and power from the SMC.

## Hardware-friendly control

Fan speed is never yanked around. Three layers keep it smooth:

1. **Temperature smoothing** — the driving temperature is an exponential moving
   average (~6 s), so brief spikes don't make fans surge.
2. **Hysteresis deadband** — if the new target is within a small band of the
   current command, nothing changes (no constant micro-adjusting).
3. **Slew-rate limiting** — when it does change, the commanded speed moves by a
   bounded step per second, ramping gradually.

All three are tunable under **Fans → Advanced**, with a one-click restore.

## Safety & security

- Targets are clamped to each fan's own `Mn`…`Mx` range.
- A **watchdog** reverts every fan to firmware auto if the app disconnects or
  hangs; quitting the app also reverts.
- Only the tiny `omnistats-smcd` helper runs as root; it verifies the peer uid so
  other local accounts can't hijack your fans.

## Updates

**About → Software update** checks GitHub Releases and can download & install a
newer build in place. Releases are produced by tagging `vX.Y.Z` (see
[CONTRIBUTING](CONTRIBUTING.md)).

## Roadmap

- [ ] Network throughput module
- [ ] CPU/GPU/memory utilization
- [ ] Disk activity & battery health
- [ ] Per-fan independent curves
- [ ] Homebrew cask

## Contributing

Branch workflow is `feature/*` → `dev` → `main`. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
