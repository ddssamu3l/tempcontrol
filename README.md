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
- It's a **PI controller**, not a fan curve. Curves need a permanent error to hold any fan speed, so the chip either anchors above your target or oscillates across it. Instead:
  - **Kick (P):** spikes above the target get an instant exponential response — barely audible 3° over, everything the fans have 12° over.
  - **Hold (I):** an integrator learns the steady fan speed that keeps the error at zero, so under constant load the fans settle at **one speed** with the chip sitting **at** your target.
- Fans rise fast but only glide down (~1%/s), with sub-audible adjustments suppressed — no pitch-wandering.
- When the chip stays comfortably below target with the boost fully unwound, fans are handed back to macOS automatic control.
- If fans hit 100% and the chip is still over target, the UI says so plainly — some workloads aren't holdable at low targets.

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

After install, the thermometer lands in your menu bar. Click it for the dashboard; hit `[ LAUNCH ON MAC START: ON ]` in the footer to start it at every boot.

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
| **BATTERY** (its own tab) | Hardware battery % (the pack's real number, not macOS's smoothed one), live power flow (adapter → system → battery watts), health/cycles/capacity/temp — plus full charge management below |

## Battery management (replaces AlDente)

The BATTERY tab replicates AlDente's paid feature set, running in TempControl's root helper — which means limits keep working with the app closed and across reboots, no separate purchase:

- **Charge limit** (50–100%) — charging stops at your limit, marked on the charge bar
- **Discharge to limit** — actively drains back down when you're above the limit while plugged in
- **Sailing mode** — lets charge drift ~5% below the limit before recharging, avoiding micro-cycles
- **Heat protection** — pauses charging when the battery runs hot (35°C threshold)
- **Calibration** — automated full cycle (100% → hold 1h → 15% → back to limit) to recalibrate the battery gauge
- **Top Up** — one-shot charge to 100% for a travel day, then back to your limit
- **MagSafe LED control** — LED goes green when held at limit, orange while charging

Capability is detected at runtime: the charge-control SMC keys vary across Apple Silicon generations and are only visible to root, so the panel tells you honestly which features your machine supports. Uninstalling always resets charging to macOS defaults.

Menu bar shows the live hottest die temp; the icon becomes a flame 🔥 while boost is engaged.

## `tempcontrol-cli` — the dashboard from your terminal

Everything the menu bar shows is also available as a command, one subcommand per
dashboard panel. `install.sh` puts it on your `PATH`:

```bash
tempcontrol-cli temp        # the TEMP panel
tempcontrol-cli soc         # the SOC panel
tempcontrol-cli storage     # the STORAGE panel
tempcontrol-cli battery     # the BATTERY panel
tempcontrol-cli all         # every panel
tempcontrol-cli --help      # usage
```

```
$ tempcontrol-cli soc

══ SOC ═════════════════════════════════════════════════════

CPU
  CHIP                        APPLE M4 PRO
  CORES                       10P + 4E (14 TOTAL)
  CPU           [#         ]    6%
  POWER                       4.1W
  E00           [##        ]   16%  1.02G
  E01           [#         ]   11%  1.02G
  ...
  P13           [          ]    0%  3.87G
  DIE °C                      MAX 59.1°C  AVG 56.7°C  (14 SENSORS)
    PMU TDIE1                 56.2°C
    PMU TDIE8                 59.1°C
    ...

GPU
  GPU           [######    ]   61%
  DEVICE        [######    ]   61%
  RENDERER      [#         ]    5%
  TILER         [          ]    3%
  FREQ                        1284MHz
  POWER                       9.2W
  MEM USED                    7.1G
  GPU CORES                   20
  · APPLE EXPOSES THE GPU AS ONE BLOCK — PER-CORE GPU LOAD/TEMP
  · DOESN'T EXIST ON ANY APP

UNIFIED MEMORY
  UNIFIED MEMORY                  34.4G / 48.0G
  USED            [#######   ]     72%
  APP                             19.6G
  WIRED                            9.6G
  COMPRESSED                       5.1G
  SWAP                             196M
  PRESSURE                        OK
```

### For agents and scripts: `--json`

Add `--json` to any command. Stdout is **only** JSON — every numeric row carries
a machine-readable `raw` and `unit` next to the formatted string, so nothing has
to be parsed out of display text:

```bash
$ tempcontrol-cli battery --json | jq '.sections[0].rows[0]'
{
  "label": "CHARGE (HARDWARE)",
  "raw": 74.40826625015019,
  "unit": "%",
  "value": "74.4%"
}
```

The shape is `{"panel": ..., "sections": [{"title": ..., "note": ..., "rows":
[{"label", "value", "raw", "unit"}]}]}`; `all --json` returns an array of those
objects. Keys are always present (`null` rather than absent) and sorted, so two
runs diff cleanly. Exit code is 0 on success, 1 for an unknown panel (which
lists the valid names on stderr).

The CLI runs unprivileged. Root-only data — per-core frequency and power
(`powermetrics`), fan control state, battery charge-control keys — comes from
the helper daemon; without it the report still prints, with those rows marked
`NOT RUNNING` rather than failing.

**It cannot drift from the app.** The panel list, the values and the formatting
all come from one shared `Dashboard` module: adding a panel to the app is a
compile error until the CLI has a reporter for it. See "Adding a new panel" in
[PROJECT_NOTES.md](PROJECT_NOTES.md).

## Troubleshooting

- **"NO HELPER" in the header** — the helper isn't running. Re-run `./scripts/install.sh`.
- **Weird or missing sensors** — run `swift run tempcontrol-probe` and open an issue with the output. Sensor names vary across M1–M4; the probe output is exactly what's needed to add support.
- **No frequencies shown** — per-core frequency comes from `powermetrics`, which needs the helper. Load/temps work without it.
- **`tempcontrol-cli` says the helper isn't running, but it is** — the app and helper exchange a versioned struct; a helper left over from an older build can fail to decode. Re-run `./scripts/install.sh` to rebuild both together.
- **Per-GPU-core stats?** — Apple doesn't expose them to anyone; the GPU is reported as one block. Nothing to fix.

## Architecture (for the curious)

Two processes plus a shared library, plain SwiftPM, no Xcode project:

- **`TempControl.app`** (menu bar, SwiftUI) — reads everything it can *without* root: per-core load (`host_processor_info`), die temps (IOHID sensor services), memory, storage, GPU utilization (IORegistry), fan RPMs (SMC reads).
- **`Dashboard`** (library) — the samplers, the snapshot collector, the shared
  `Fmt` formatters and one `PanelReporting` type per dashboard panel. Both the
  app and the CLI render *this*, which is why they can't disagree.
- **`tempcontrol-cli`** — subcommands derived from the same `Panel` enum the app
  switches on; text for humans, `--json` for agents.
- **`com.tempcontrol.helper`** (root LaunchDaemon) — the only privileged code: streams `powermetrics`, writes SMC fan keys, runs the 2-second control loop, enforces every safety rule. Talks to the app over XPC; runs `powermetrics` only while the dashboard is open, so it idles at ~0% CPU.

## License

MIT — see [LICENSE](LICENSE).
