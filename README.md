# TempControl 🌡️

**A terminal-styled menu bar dashboard and fan controller for Apple Silicon Macs.**

Set a target temperature for your chip. When it runs hotter than that, TempControl drives your fans *exponentially* harder the further you drift from the target — and hands them straight back to macOS the moment you cool off. In between, you get a black-and-white, TUI-styled dashboard of everything your SoC is doing: every CPU core's load and frequency, every die temperature sensor, GPU load and power, unified memory, storage, and fan RPMs — live, once a second.

```
┌ SOC ─ APPLE M4 PRO ────────────────────────────┐
│ CPU  34%   ▁▂▄▆█▆▄▂▁▂▃▅▇█▇▅▃                   │
│ E00 [██        ]  21%  1.02G   P05 [███████ ] … │
│ DIE °C  46 45 46 47 48 51 47 46 …               │
│ GPU  61%   FREQ 1284MHz  POWER 9.2W             │
│ UNIFIED MEMORY  31.2G / 48G  ███████▒▒▒         │
│ CPU PWR 4.1W  GPU PWR 9.2W  PACKAGE 14.8W       │
└─────────────────────────────────────────────────┘
  FANS   fan0 3420 RPM ████████▒▒   1350–5777
  TEMP CONTROL   ◔ 80°C target   MODE: BOOST
```

## Why

macOS keeps Apple Silicon quiet by letting it run hot. If you regularly push your chip hard — training runs, long compiles, sustained renders — you may prefer it cooler at the cost of fan noise. TempControl gives you one dial: pick a temperature, and the fans do whatever it takes.

## How the control works

- You set a **target temp** (50–95 °C) on the dial. The controller regulates against the **hottest sensor on the die**.
- Inside **±2 °C** of the target: nothing to do, you're in the band.
- Above **target +2 °C**: fan boost engages. Fan speed follows an **exponential curve** — barely audible 3° over, everything the fans have 12° over.
- Below **target −2 °C**: fans are handed back to macOS automatic control.

Safety is non-negotiable and baked in:

- Fans are only ever driven **faster** than they already were when boost engaged — TempControl never slows your fans below what macOS wanted.
- If the app quits, crashes, or stops responding, the helper reverts fans to automatic within 20 seconds. If the *helper* crashes, launchd restarts it and its first act is reverting fans to automatic.
- **Fanless Macs (MacBook Air):** the dashboard works fully; fan control is detected as impossible and cleanly disabled.

## Install

Requirements: **any Apple Silicon Mac** (M1 through M4, any variant), macOS 14+, and Xcode or the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/ddssamu3l/tempcontrol.git
cd tempcontrol
./scripts/install.sh
```

You'll be asked for your password **once**. That installs the privileged helper that fan control and `powermetrics` (per-core frequency/power) require — there is no way to control fans on macOS without root, which is also why this can't ship through the App Store.

After install, the thermometer lands in your menu bar. Click it for the dashboard; hit `[ LOGIN: ON ]` in the footer to start it at every boot.

### Uninstall

```bash
./scripts/uninstall.sh
```

Removes the app, the helper, and the daemon completely. Fans revert to macOS control immediately.

## What you get

| Section | Metrics |
|---|---|
| **SOC** (one box, because CPU/GPU/RAM share one die) | Per-core load bars (P/E labeled), per-core frequency, all die temperature sensors as a heat strip, GPU load/frequency/power, unified memory split (app/wired/compressed), swap, memory pressure, CPU/GPU/ANE/package watts |
| **FANS** | Live RPM per fan, min–max range, boost state |
| **STORAGE** | SSD capacity, live read/write throughput |
| **TEMP CONTROL** | Target dial, hottest-sensor readout, live boost curve with your current position on it, low power mode toggle |

Menu bar shows the live hottest die temp; the icon becomes a flame 🔥 while boost is engaged.

## Troubleshooting

- **"NO HELPER" in the header** — the helper isn't running. Re-run `./scripts/install.sh`.
- **Weird or missing sensors** — run `swift run tempcontrol-probe` and open an issue with the output. Sensor names vary across M1–M4; the probe output is exactly what's needed to add support.
- **No frequencies shown** — per-core frequency comes from `powermetrics`, which needs the helper. Load/temps work without it.
- **Per-GPU-core stats?** — Apple doesn't expose them to anyone; the GPU is reported as one block. Nothing to fix.

## Architecture (for the curious)

Two processes, plain SwiftPM, no Xcode project:

- **`TempControl.app`** (menu bar, SwiftUI) — reads everything it can *without* root: per-core load (`host_processor_info`), die temps (IOHID sensor services), memory, storage, GPU utilization (IORegistry), fan RPMs (SMC reads).
- **`com.tempcontrol.helper`** (root LaunchDaemon) — the only privileged code: streams `powermetrics`, writes SMC fan keys, runs the 2-second control loop, enforces every safety rule. Talks to the app over XPC; runs `powermetrics` only while the dashboard is open, so it idles at ~0% CPU.

## License

MIT — see [LICENSE](LICENSE).
