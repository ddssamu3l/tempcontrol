import SwiftUI
import Shared

/// The BATTERY tab: AlDente's feature set — charge limit, auto-discharge,
/// sailing, heat protection, calibration, top-up, MagSafe LED — plus live
/// power flow and health. Reads work without the helper; controls need it.
struct BatteryPanel: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        VStack(spacing: 8) {
            BatteryStatusBox()
            PowerFlowBox()
            BatteryHealthBox()
            ChargeControlBox()
        }
    }
}

// MARK: status

struct BatteryStatusBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        BoxSection(title: "BATTERY", accent: TUI.mem) {
            if let b = store.snap.battery {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(b.hwPercent.map { String(format: "%.1f%%", $0) } ?? "-")
                            .font(TUI.mono(24, .bold))
                            .foregroundStyle(TUI.mem)
                        StatCell(label: "MACOS SHOWS",
                                 value: b.osPercent.map { "\($0)%" } ?? "-",
                                 color: TUI.dim)
                        StatCell(label: "STATE", value: stateText(b), color: stateColor(b))
                        if let t = b.timeRemainingMin {
                            StatCell(label: b.isCharging ? "TO FULL" : "REMAINING",
                                     value: String(format: "%d:%02d", t / 60, t % 60))
                        }
                        Spacer()
                    }
                    // Charge bar with the limit marker notched into it.
                    ZStack(alignment: .leading) {
                        HBar(fraction: (b.hwPercent ?? 0) / 100, color: barColor(b), height: 9)
                        if let limit = limitPct, limit < 100 {
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(TUI.amber)
                                    .frame(width: 2)
                                    .offset(x: geo.size.width * CGFloat(limit) / 100)
                            }
                        }
                    }
                    .frame(height: 9)
                    Text("HARDWARE % IS THE PACK'S REAL STATE — MACOS SMOOTHS ITS NUMBER")
                        .font(TUI.mono(8)).foregroundStyle(TUI.faint)
                }
            } else {
                Text("NO BATTERY DETECTED").font(TUI.mono(10)).foregroundStyle(TUI.dim)
            }
        }
    }

    private var limitPct: Int? {
        let l = store.snap.batteryControl?.settings.limitPct ?? store.batterySettings.limitPct
        return l < 100 ? l : nil
    }

    private func stateText(_ b: BatteryInfo) -> String {
        if store.snap.batteryControl?.forcingDischarge == true { return "DISCHARGING" }
        if b.isCharging { return "CHARGING" }
        if store.snap.batteryControl?.chargingInhibited == true, b.externalConnected { return "HELD AT LIMIT" }
        if b.externalConnected { return b.fullyCharged ? "FULL" : "IDLE" }
        return "ON BATTERY"
    }

    private func stateColor(_ b: BatteryInfo) -> Color {
        if store.snap.batteryControl?.forcingDischarge == true { return TUI.amber }
        if b.isCharging { return TUI.mem }
        if store.snap.batteryControl?.chargingInhibited == true, b.externalConnected { return TUI.cyanish }
        return TUI.fg
    }

    private func barColor(_ b: BatteryInfo) -> Color {
        guard let p = b.hwPercent else { return TUI.dim }
        if p < 15 { return TUI.red }
        if p < 30 { return TUI.amber }
        return TUI.mem
    }
}

extension TUI {
    static let cyanish = TUI.cpu
}

// MARK: power flow

struct PowerFlowBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        BoxSection(title: "POWER FLOW", accent: TUI.mem) {
            let b = store.snap.battery
            let adapterIn = store.snap.adapterPowerW
            let system = store.snap.systemPowerW
            let batteryW = b?.batteryPowerW
            VStack(alignment: .leading, spacing: 4) {
                flowLine(label: adapterLabel,
                         watts: adapterIn,
                         arrow: "──▶", color: TUI.amber)
                flowLine(label: "SYSTEM", watts: system, arrow: "   ", color: TUI.fg)
                flowLine(label: batteryW.map { $0 >= 0.05 ? "▶ BATTERY (CHARGING)" : ($0 <= -0.05 ? "◀ BATTERY (DRAINING)" : "  BATTERY (IDLE)") } ?? "  BATTERY",
                         watts: batteryW.map(abs), arrow: "   ", color: TUI.mem)
                HStack {
                    Spacer()
                    Sparkline(values: store.history.batteryW.map(abs), maxValue: nil, color: TUI.mem)
                        .frame(width: 160, height: 20)
                }
            }
        }
    }

    private var adapterLabel: String {
        let b = store.snap.battery
        guard b?.externalConnected == true else { return "ADAPTER (UNPLUGGED)" }
        if let w = b?.adapterMaxW { return "ADAPTER (\(w)W MAX)" }
        return "ADAPTER"
    }

    private func flowLine(label: String, watts: Double?, arrow: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(TUI.mono(10)).foregroundStyle(color)
            Spacer()
            Text(watts.map { String(format: "%5.1fW", $0) } ?? "    -")
                .font(TUI.mono(11, .semibold)).foregroundStyle(color)
        }
    }
}

// MARK: health

struct BatteryHealthBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        BoxSection(title: "HEALTH", accent: TUI.mem) {
            if let b = store.snap.battery {
                HStack(spacing: 18) {
                    StatCell(label: "HEALTH",
                             value: b.healthPct.map { String(format: "%.0f%%", $0) } ?? "-",
                             color: (b.healthPct ?? 100) < 80 ? TUI.amber : TUI.mem)
                    StatCell(label: "CYCLES", value: b.cycleCount.map(String.init) ?? "-")
                    StatCell(label: "CAPACITY",
                             value: capText(b), color: TUI.dim)
                    StatCell(label: "TEMP",
                             value: b.temperatureC.map { String(format: "%.1f°C", $0) } ?? "-",
                             color: (b.temperatureC ?? 0) > 35 ? TUI.red : TUI.fg)
                    Spacer()
                    Sparkline(values: store.history.batteryPct, maxValue: 100, color: TUI.mem)
                        .frame(width: 120, height: 22)
                }
            }
        }
    }

    private func capText(_ b: BatteryInfo) -> String {
        guard let max = b.rawMaxCapacitymAh, let design = b.designCapacitymAh else { return "-" }
        return "\(max)/\(design)mAh"
    }
}

// MARK: charge control

struct ChargeControlBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        BoxSection(title: "CHARGE CONTROL", accent: TUI.mem) {
            if !store.snap.helperAvailable {
                Text("NEEDS THE ROOT HELPER — RUN ./scripts/install.sh")
                    .font(TUI.mono(10)).foregroundStyle(TUI.red)
            } else if let control = store.snap.batteryControl, !control.supported {
                Text("THIS MAC DOESN'T EXPOSE THE CHARGE-CONTROL SMC KEYS.\nMONITORING WORKS; CHARGE LIMITING ISN'T POSSIBLE HERE.")
                    .font(TUI.mono(10)).foregroundStyle(TUI.dim)
            } else {
                controls
            }
        }
    }

    @ViewBuilder private var controls: some View {
        let control = store.snap.batteryControl
        let mgmtOn = store.batterySettings.enabled
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TUIButton(label: mgmtOn ? "[ BATTERY MANAGEMENT: ON ]" : "[ BATTERY MANAGEMENT: OFF ]",
                          active: mgmtOn,
                          activeColor: TUI.mem) {
                    store.batterySettings.enabled.toggle()
                    store.pushBatterySettings()
                }
                Spacer()
            }
            if !mgmtOn {
                Text("EVERYTHING OFF — MACOS MANAGES CHARGING. ALL CONTROL KEYS RESET TO DEFAULTS.")
                    .font(TUI.mono(9)).foregroundStyle(TUI.dim)
            } else {
                enabledControls(control)
            }
        }
    }

    @ViewBuilder private func enabledControls(_ control: BatteryControlState?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("CHARGE LIMIT").font(TUI.mono(9)).foregroundStyle(TUI.dim)
                TUISlider(value: limitBinding, range: 50...100, step: 5,
                          color: TUI.amber,
                          format: { $0 >= 100 ? "OFF" : String(format: "%.0f%%", $0) },
                          onCommit: { store.pushBatterySettings() })
            }

            HStack(spacing: 6) {
                toggle("DISCHARGE TO LIMIT", \.autoDischarge,
                       disabled: control?.dischargeSupported == false)
                toggle("SAILING −\(store.batterySettings.sailBelowPct)%", \.sailing)
                toggle("HEAT <\(Int(store.batterySettings.heatLimitC))°C", \.heatProtect)
                toggle("MAGSAFE LED", \.magsafeLED,
                       disabled: control?.ledSupported == false)
            }

            HStack(spacing: 6) {
                TUIButton(label: control?.topUpActive == true ? "[ TOP UP: CANCEL ]" : "[ TOP UP → 100% ]",
                          active: control?.topUpActive == true,
                          activeColor: TUI.mem) {
                    store.setTopUp(!(control?.topUpActive ?? false))
                }
                TUIButton(label: control?.calibration != .idle ? "[ CALIBRATION: CANCEL ]" : "[ CALIBRATE ]",
                          active: control?.calibration != .idle,
                          activeColor: TUI.amber) {
                    store.setCalibration(control?.calibration == .idle)
                }
            }

            if let c = control, c.calibration != .idle {
                Text("CALIBRATION \(c.calibration.label)")
                    .font(TUI.mono(9, .bold)).foregroundStyle(TUI.amber)
            }

            Text("⚠ DISCHARGING FLIPS THE MAC TO BATTERY POWER — IF YOUR DISPLAY/HUB\nSHARES THAT POWER PATH, SCREENS CAN BLANK FOR A FEW SECONDS.\nSWITCHES ARE RATE-LIMITED TO ONCE PER MINUTE.")
                .font(TUI.mono(8)).foregroundStyle(TUI.amber.opacity(0.8))

            Text(statusLine)
                .font(TUI.mono(8)).foregroundStyle(TUI.faint)
        }
    }

    private var limitBinding: Binding<Double> {
        Binding(get: { Double(store.batterySettings.limitPct) },
                set: { store.batterySettings.limitPct = Int($0) })
    }

    private func toggle(_ label: String, _ keyPath: WritableKeyPath<BatterySettings, Bool>,
                        disabled: Bool = false) -> some View {
        TUIButton(label: "[ \(label) ]",
                  active: store.batterySettings[keyPath: keyPath],
                  activeColor: TUI.mem) {
            guard !disabled else { return }
            store.batterySettings[keyPath: keyPath].toggle()
            store.pushBatterySettings()
        }
        .opacity(disabled ? 0.35 : 1)
    }

    private var statusLine: String {
        guard let c = store.snap.batteryControl else { return "" }
        var parts: [String] = []
        if c.chargingInhibited { parts.append("CHARGING PAUSED") }
        if c.forcingDischarge { parts.append("FORCING DISCHARGE") }
        if parts.isEmpty { parts.append("CHARGING ALLOWED") }
        parts.append("LIMIT SURVIVES APP QUIT + REBOOT (HELPER DAEMON)")
        return parts.joined(separator: " • ")
    }
}
