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
- **Discharge (CH0I) flips the adapter off → power-delivery renegotiation can blank displays/hubs sharing the power path** (user hit this July 21 — looked like a crash, wasn't). Mitigations that must stay: turning discharge ON is rate-limited to once/60s (OFF is immediate), and the UI warns about it. Never add logic that toggles CH0I rapidly.
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
