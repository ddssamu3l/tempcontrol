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

## Battery rules (AlDente-replacement feature, added July 2026)
- Battery settings deliberately **persist** across app quit and reboot (that's the feature) — the ONE exception to "revert on exit".
- Consequence: `uninstall.sh` MUST run `tempcontrol-helper --reset-battery` before deleting the helper, or a charge limit could outlive the app. Never remove that step.
- Charge-control SMC keys are discovered at runtime as root (CH0B/CH0C → CHIE → CHTE; discharge CH0I; LED ACLC) — they are invisible to unprivileged reads, so the probe CANNOT verify them; only the running helper can. UI must report per-feature capability honestly.
- Limit clamped to 50–100%; discharge floor 15% (calibration only).

## First milestone
- Iteration 1 = user can run `scripts/install.sh` and get: menu bar app with live dashboard + working fan boost control. Ship this before polish.
