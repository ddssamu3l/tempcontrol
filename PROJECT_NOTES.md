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

## First milestone
- Iteration 1 = user can run `scripts/install.sh` and get: menu bar app with live dashboard + working fan boost control. Ship this before polish.
