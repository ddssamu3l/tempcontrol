# TempControl — project requirements (pinned)

Owner: Samuel (@ddsamu3l). These are standing requirements from the project owner — re-read before any release or refactor.

## Distribution
- This repo is **public on GitHub**. Anyone with the README must be able to clone and install.
- README must be engaging and carry complete install/uninstall instructions (no Xcode GUI steps — everything through `scripts/`).
- No hardcoded machine assumptions anywhere: works on **any Apple Silicon Mac** (M1 through M4 families, any core count, any fan count).

## Hardware robustness rules
- Detect chip name, P/E core counts, fan count, and sensors at runtime. Never assume M4 Pro.
- **Fanless Macs (MacBook Air): fan control must be cleanly rejected** — dashboard still works, control section explains why fan control is unavailable. Never write SMC fan keys when `FNum == 0`.
- Intel Macs: out of scope — app should detect and say so, not crash.

## Safety rules (do not relax)
- Fans may only ever be driven **faster** than they already were when boost engaged, never slower than that baseline.
- Helper reverts fans to macOS automatic control: on app quit (heartbeat timeout), on helper exit/crash-restart, on control disable, and at helper startup.
- Target temp range clamped to 50–95 °C, ±2 °C deadband.
- Control law is **PI, not a curve** (July 21): BoostCurve = P kick for spikes; integrator learns and HOLDS the steady fan speed that zeroes the error (user-identified: curve-only control anchors above target or limit-cycles). Bumpless takeover seeds from actual RPM at engage. Do not regress to curve-only.

## Control law: power-aware PID (July 22, rev 3)

Temperature alone cannot control temperature. Three signals, all required:

- **temp** — error vs target.
- **slope** — smoothed dT/dt. Silicon heats far faster than a fan spins up, so
  a loop that reacts only to present error always overshoots. The loop drives
  on `max(error, predicted error)` and is never talked out of cooling by a
  favourable instantaneous reading.
- **power** — feedforward. **What the loop learns is CONDUCTANCE (fan level per
  watt), not a fan level.** That is the point: when load jumps, commanded speed
  scales immediately instead of being rediscovered by letting the chip get hot.
  Do not "simplify" this back into a raw integrator on fan level.

Rules that must not be relaxed:

- **Relaxation is gated on margin, never on a timer.** The loop only eases off
  while the chip is below target AND not trending back up; the rate fades to
  zero approaching the target and stops `relaxGuard` (~1 °C) short of it.
  Removing the guard reintroduces the exact reported bug: raise the target from
  50 → 65 and the chip sails to 73 before the loop notices.
- **The lead term is smoothed (20 s) and capped (±5 °C).** Slope is a
  derivative and die sensors are jumpy — uncapped, a *steady* load makes the
  fans hunt across a 30-point range. Verified in simulation, not by ear.
- Prefer real SoC watts (powermetrics) over the whole-machine SMC rail; the
  rail also carries display brightness, which is not die heat. The helper keeps
  powermetrics alive while engaged. Switching source **rescales the learned
  conductance** so the fans don't jolt.
- Anti-windup: stop learning demand once output is saturated. Report it —
  `atMax` after 20 s pinned means the target is likely unreachable at this
  load, and the UI must say so rather than silently sitting above target.

## It is a CEILING, not a setpoint (naming rule)

The dial sets the temperature the chip is **not allowed to exceed**. The loop
only ever cools toward it; nothing in it heats the chip *up* to it. An idle
machine sitting at 32 °C with the dial on 60 is the loop working correctly.

Calling that "TARGET" made it read as a bug — a target implies something is
seeking it. All user-facing wording is therefore **MAX TEMP / LIMIT /
HEADROOM**, in the app and in `tempcontrol-cli` alike:

| shown | means |
| --- | --- |
| `MAX TEMP` | the ceiling you set |
| `HEADROOM` | `22.5°C SPARE` / `AT LIMIT` / `OVER +3.2°C` |
| `FANS DRIVEN BY` | `MACOS (UNDER LIMIT)` when the loop hasn't engaged |

**The wire field is still `targetTemp`, and stays that way.** Renaming a
`Codable` property renames its JSON key, which breaks decoding against an
already-installed helper (see the next section). Rename labels, never keys.

## Per-process sampling (the TASKS panel)

"What's eating my CPU and GPU cores." Two data sources, each doing what it's
best at, merged by pid:

- **libproc** (`Sources/Shared/ProcessSampler.swift`) — `proc_listpids` +
  `proc_pid_rusage(RUSAGE_INFO_V6)` gives CPU time, memory footprint, disk I/O
  and energy. Works unprivileged for **same-uid** processes (the app's fallback
  list), and as **root** in the helper it reaches every process. libproc is not
  in Swift's Darwin module map, so the C symbols are bound with `@_silgen_name`;
  `proc_pid_rusage` writes the whole struct into the buffer, so pass a real
  `rusage_info_v6`, never a pointer-sized slot (silent heap smash otherwise).
- **powermetrics `tasks` sampler** (helper only, root) — the ONLY source of
  **per-process GPU** (`gputime_ms_per_s`, via `--show-process-gpu`). rusage has
  no GPU field on this OS. The man page warns it's "only available on certain
  hardware", so `HelperSample.gpuAccounting` reports whether a real number was
  ever seen and the UI shows "N/A" rather than a silently empty column.

**THE mach-timebase GOTCHA — do not regress.** `ri_user_time` /
`ri_system_time` (and `proc_pidinfo` task times) come back in **mach time units,
not nanoseconds, on Apple Silicon**. The timebase here is numer/denom = 125/3
(~41.7 ns/tick). Treat them as ns and every process reads ~2% — a fully pinned
core looks idle. Convert with `mach_timebase_info` (queried at runtime, never
hardcoded — it differs across chip families). Verified against `ps`: a busy
loop reads 100.4% after conversion, 2.4% without. Energy (nanojoules) and disk
(bytes) are NOT times and must not be scaled.

The panel only samples while it's on screen (`store.showingTasks` → the
`sample` XPC request's `wantTasks` flag → the helper keeps the tasks sampler
alive). GPU ms/s is a rate, so a cold sampler returns nothing: the CLI pre-warms
the helper and waits ~1.4 s before the reading that counts.

## Cross-process compatibility (app ↔ helper)

The app and helper are separate binaries and nothing forces a user to keep them
in lockstep. Swift's *synthesized* `init(from:)` requires every key to be
**present** even when the property has a default — so one new field on a helper
payload makes the app report "no helper" instead of degrading.

Every type sent over XPC (`ControlStatus`, `PMSample`, `BatteryControlState`,
`BatterySettings`) therefore has a **hand-written tolerant `init(from:)` using
`decodeIfPresent`**. Adding a field to any of them means adding a line there
too. Never delete these in favour of the synthesized version.

## Battery rules (AlDente-replacement feature, added July 2026)
- Battery settings deliberately **persist** across app quit and reboot (that's the feature) — the ONE exception to "revert on exit".
- Consequence: `uninstall.sh` MUST run `tempcontrol-helper --reset-battery` before deleting the helper, or a charge limit could outlive the app. Never remove that step.
- Charge-control SMC keys are discovered at runtime as root (CH0B/CH0C → CHIE → CHTE; discharge CH0I; LED ACLC) — they are invisible to unprivileged reads, so the probe CANNOT verify them; only the running helper can. UI must report per-feature capability honestly.
- Limit clamped to 50–100%; discharge floor 15% (calibration only).
- **NEVER engage charge control while the lid is shut.** This is the most important rule in the file.

  Applying a charge limit briefly drops the machine onto battery power. Lid open, that's an invisible flicker. Lid **closed**, macOS ends clamshell operation the instant AC goes away — closed-display operation *requires* AC — and sleeps the entire Mac. Fans stop mid-load, external displays go black, and it is indistinguishable from a hard crash.

  Confirmed from `pmset -g log` on July 22 (limit set to 70% at 78% charge):
  ```
  00:48:09  Using Batt (78%)                      <- charge control applied
  00:48:24  Entering Sleep — 'Clamshell Sleep'
  00:48:28/33/37  DarkWake / Sleep / Wake         <- sleep-wake thrash
  00:48:42  Using AC (78%)                        <- ~33s total
  ```
  No panic report existed, because nothing panicked. The July 21 "blackout" has the same signature (20:39, 79%, `Using Batt`).

  **This supersedes an earlier, wrong diagnosis** that blamed CH0I forced discharge + USB-C PD renegotiation blanking downstream displays. This machine has **no CH0I at all** (`DISCHARGE KEY: NOT FOUND`; only `CHIE` is present), so discharge was never involved and "the displays lost power" was never the mechanism — *the whole Mac slept*.

  The guard in `BatteryController.tick()`: engaging is refused while `Lid.isClosed()`, disengaging is always allowed (never strand a limit). Read lid state via `IOServiceGetMatchingService(..., IOServiceMatching("IOPMrootDomain"))` and `AppleClamshellState` — the registry *path* `IOService:/IOResources/IOPMrootDomain` does not resolve on macOS 26.
- The app and CLI read lid state **locally**, not from the helper's reported field: an older helper omits it, and tolerant decoding turns that into "open" — wrong in the one direction that can sleep the machine.
- **NEVER force-discharge while an external display is connected.** Forced
  discharge (CH0I) cuts the adapter off outright, so a monitor on the Mac's
  USB-C/Thunderbolt path can lose its link or its power — and if the lid also
  happens to be shut, losing AC sleeps the whole machine. Charge *inhibit* is
  NOT gated on displays: it's the everyday feature and it doesn't cut the
  adapter.

  The fallback is the point, not an apology: when discharge is withheld the
  limit still holds via inhibit, so the pack simply drains through normal use
  instead of being forced down. The UI says so, and the DISCHARGE toggle greys
  out with the monitor named.

  Detection is `ExternalDisplay.read()` in `Sources/Shared/Displays.swift`, and
  it is **IOKit-based on purpose**. CoreGraphics is the obvious API but needs a
  window-server session; the helper is a root LaunchDaemon without one, so CG
  would report "no displays" and cheerfully do the dangerous thing. The rule
  that separates "you have Thunderbolt ports" from "you have a monitor":
  an `IOMobileFramebufferShim` counts only when `external == Yes` **and** it
  carries `DisplayAttributes` (a real EDID). Empty ports publish the flag but
  no EDID. `ProductAttributes.ProductName` gives the name for the message.
- Discharge (CH0I), where it exists: turning ON is rate-limited to once/60s (OFF is immediate). Never add logic that toggles CH0I rapidly.
- Master `enabled` switch in BatterySettings: off = cancel all modes + reset every key. Settings JSON decodes with per-field defaults (decodeIfPresent) so on-disk settings survive schema additions.

## Adding a new panel (the enum → switch → reporter contract)

The dashboard has **two surfaces** — the SwiftUI app and `tempcontrol-cli` — and
they must never disagree. That is enforced by the compiler, not by discipline:

1. **`Panel`** (`Sources/Dashboard/Panel.swift`) is the single source of truth
   for what sections exist. The CLI derives its subcommands, its usage text and
   its error messages from `Panel.allCases` — there is **no hardcoded command
   list anywhere**, so a new case is a new subcommand for free.
2. **`PanelReports.reporter(for:)`** (`Sources/Dashboard/PanelReport.swift`) is
   an **exhaustive switch with no `default:`**. Add a case to `Panel` and the
   package stops compiling until that case has a reporter. Never add a
   `default:` branch — that would silently re-open the drift the switch exists
   to close.
3. **`DashboardView`**'s switch over `panel` is exhaustive for the same reason,
   so the app can't be missing a view either.

So, to add a panel:

- add the case to `Panel`
- `swift build` → two errors tell you exactly what's missing
- write `Sources/Dashboard/Reports/<Name>Report.swift` conforming to
  `PanelReporting`, mirroring the view's section names and values
- add the SwiftUI view to the switch in `DashboardView`

Two more rules that keep the surfaces identical:

- **All formatting goes through `Fmt`** (`Sources/Dashboard/Fmt.swift`). Views
  and reporters call the same function, so a number is formatted in exactly one
  place. Don't reintroduce inline `String(format:)` for temps, watts, RPM,
  percentages, bytes, rates, frequencies or durations.
- **Every numeric row carries `raw` + `unit`** alongside the formatted string,
  because `--json` is the agent-facing path and agents need numbers, not text.

`Dashboard` depends on `Shared` only. It must **never** become a dependency of
`TempControlHelper` — the helper is the privileged process and stays minimal.
The CLI runs unprivileged: anything root-only (powermetrics per-core data, fan
control status, battery control keys) arrives via `HelperClient` and must
degrade to a stated "not running" row rather than hanging or crashing.

## First milestone
- Iteration 1 = user can run `scripts/install.sh` and get: menu bar app with live dashboard + working fan boost control. Ship this before polish.
