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

The dashboard also shows network throughput and CPU process rankings. Its resource
card shows CPU usage, memory, GPU utilization (where supported), and startup-disk
capacity in that order. Resource readings need no administrator permission and
stop when the panel is hidden.
Click the network row for history and per-app rates in a compact adjacent panel;
the dashboard keeps its size and position.

Verified end-to-end on **M5 Pro (Mac17,8)**. Fan control works on Apple Silicon
Macs whose firmware exposes writable fan keys (see [How fan control works](#how-fan-control-works)).

## Features

- 💻 System CPU usage, memory, GPU utilization, and startup-disk used/total capacity
- 📉 Smooth history charts that preserve sample values and real data gaps
- 🔋 Default 10 / 3 / 10 s and Eco 30 / 10 / 30 s display sampling; opening a panel uses Default
- 🌡 Menu-bar readout of the hottest SoC temperature + ring gauges
- 📈 Interactive **temperature → fan-speed curve** with a live operating point
- 🌀 **Auto / Manual / Curve** modes; per-machine fan limits handled automatically
- 🧊 **Hardware-friendly control**: EMA temperature smoothing + hysteresis
  deadband + slew-rate limiting — fans never surge on a 1° blip
- 🎛 One-click curve presets (Quiet / Balanced / Cooler)
- 🎨 Dark & light "thermal instrument" themes
- 🔒 In-app privileged-helper install (single native prompt, no Terminal)
- 🚀 Optional launch at login (General → Startup)
- 🔋 Battery: charge, hardware charge, health (maximum capacity, cycles), and live power flow — read-only, no administrator access
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
drag **OmniStats** into Applications. It isn't notarized, so the first launch is
blocked: on macOS 15 and later choose **System Settings → Privacy & Security →
Open Anyway**; on macOS 13–14 right-click the app → **Open**. Or run
`xattr -dr com.apple.quarantine /Applications/OmniStats.app`.

Releases are signed with a fixed OmniStats certificate (self-signed, not Apple
Developer ID), so permissions you grant macOS keep working across updates.

### Build from source

Requires the Command Line Tools (`xcode-select --install`); full Xcode not needed.

```bash
git clone https://github.com/SuooL/OmniStats.git
cd OmniStats
make
open dist/OmniStats.app
```

Source builds are signed ad-hoc (pass `SIGN_ID="<certificate name>"` to sign
with your own certificate). If Gatekeeper blocks the first launch, use **Open
Anyway** as above, or:

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
  other local accounts can't hijack your fans. In release builds it also checks
  the connecting app's code signature, so only OmniStats signed with the same
  certificate can send it commands.

## Updates

**About → Software update** checks GitHub Releases and can download & install a
newer build in place. Releases are produced by tagging `vX.Y.Z` (see
[CONTRIBUTING](CONTRIBUTING.md)).

## Roadmap

- [x] Network throughput module
- [x] CPU process rankings, GPU utilization and system memory
- [x] Startup-disk capacity
- [ ] Disk activity & battery health
- [ ] Per-fan independent curves
- [ ] Homebrew cask

## Contributing

Branch workflow is `feature/*` → `dev` → `main`. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
