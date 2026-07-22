import Foundation
import Shared

/// Mirrors the BATTERY tab (`Views/BatteryPanel.swift`: BatteryStatusBox,
/// PowerFlowBox, BatteryHealthBox, ChargeControlBox).
///
/// Reads work unprivileged; everything under CHARGE CONTROL comes from the
/// root helper and degrades to an explanatory row when it isn't installed.
public enum BatteryReport: PanelReporting {
    public static let panel = Panel.battery

    public static func sections(_ s: Snapshot, _ sys: SystemInfo) -> [ReportSection] {
        [status(s), powerFlow(s), health(s), chargeControl(s)]
    }

    // MARK: BATTERY

    private static func status(_ s: Snapshot) -> ReportSection {
        guard let b = s.battery else {
            return ReportSection("BATTERY", [.text("BATTERY", "NO BATTERY DETECTED")])
        }
        var rows: [ReportRow] = [
            ReportRow("CHARGE (HARDWARE)", b.hwPercent.map(Fmt.percentOf100) ?? Fmt.none,
                      raw: b.hwPercent, unit: "%"),
            ReportRow("MACOS SHOWS", b.osPercent.map { "\($0)%" } ?? Fmt.none,
                      raw: b.osPercent.map(Double.init), unit: "%"),
            .text("STATE", stateText(s, b)),
            .text("EXTERNAL POWER", Fmt.yesNo(b.externalConnected)),
            .text("FULLY CHARGED", Fmt.yesNo(b.fullyCharged)),
        ]
        if let t = b.timeRemainingMin {
            rows.append(ReportRow(b.isCharging ? "TO FULL" : "REMAINING",
                                  Fmt.duration(minutes: t), raw: Double(t), unit: "min"))
        }
        let limit = s.batteryControl?.settings.limitPct
        rows.append(ReportRow("CHARGE LIMIT",
                              limit.map { $0 >= 100 ? "OFF" : "\($0)%" } ?? Fmt.none,
                              raw: limit.map(Double.init), unit: "%"))
        return ReportSection("BATTERY", rows,
                             note: "HARDWARE % IS THE PACK'S REAL STATE — MACOS SMOOTHS ITS NUMBER")
    }

    private static func stateText(_ s: Snapshot, _ b: BatteryInfo) -> String {
        if s.batteryControl?.forcingDischarge == true { return "DISCHARGING" }
        if b.isCharging { return "CHARGING" }
        if s.batteryControl?.chargingInhibited == true, b.externalConnected { return "HELD AT LIMIT" }
        if b.externalConnected { return b.fullyCharged ? "FULL" : "IDLE" }
        return "ON BATTERY"
    }

    // MARK: POWER FLOW

    private static func powerFlow(_ s: Snapshot) -> ReportSection {
        let b = s.battery
        let batteryW = b?.batteryPowerW
        let rows: [ReportRow] = [
            ReportRow(adapterLabel(b), Fmt.opt(s.adapterPowerW, Fmt.wattsPadded),
                      raw: s.adapterPowerW, unit: "W"),
            ReportRow("SYSTEM", Fmt.opt(s.systemPowerW, Fmt.wattsPadded),
                      raw: s.systemPowerW, unit: "W"),
            ReportRow(batteryFlowLabel(batteryW), Fmt.opt(batteryW.map(abs), Fmt.wattsPadded),
                      raw: batteryW, unit: "W"),
            .optional("BATTERY VOLTAGE", b?.voltageV, { String(format: "%.2fV", $0) }, unit: "V"),
            .optional("BATTERY CURRENT", b?.amperageA, { String(format: "%+.2fA", $0) }, unit: "A"),
            .int("ADAPTER RATING", b?.adapterMaxW, unit: "W"),
            .text("ADAPTER NAME", b?.adapterName ?? Fmt.none),
        ]
        return ReportSection("POWER FLOW", rows,
                             note: "BATTERY WATTS ARE SIGNED: POSITIVE = CHARGING, NEGATIVE = DRAINING")
    }

    private static func adapterLabel(_ b: BatteryInfo?) -> String {
        guard b?.externalConnected == true else { return "ADAPTER (UNPLUGGED)" }
        if let w = b?.adapterMaxW { return "ADAPTER (\(w)W MAX)" }
        return "ADAPTER"
    }

    private static func batteryFlowLabel(_ w: Double?) -> String {
        guard let w else { return "BATTERY" }
        if w >= 0.05 { return "BATTERY (CHARGING)" }
        if w <= -0.05 { return "BATTERY (DRAINING)" }
        return "BATTERY (IDLE)"
    }

    // MARK: HEALTH

    private static func health(_ s: Snapshot) -> ReportSection {
        guard let b = s.battery else {
            return ReportSection("HEALTH", [.text("HEALTH", Fmt.none)])
        }
        var rows: [ReportRow] = [
            ReportRow("HEALTH", b.healthPct.map(Fmt.percentOf100Whole) ?? Fmt.none,
                      raw: b.healthPct, unit: "%"),
            .int("CYCLES", b.cycleCount),
            .text("CAPACITY", capacityText(b)),
            .int("DESIGN CAPACITY", b.designCapacitymAh, unit: "mAh"),
            .int("NOMINAL CAPACITY", b.nominalCapacitymAh, unit: "mAh"),
            .int("RAW MAX CAPACITY", b.rawMaxCapacitymAh, unit: "mAh"),
            .temp("TEMP", b.temperatureC),
        ]
        if let h = b.healthPct, h < 80 {
            rows.append(.text("WARNING", "HEALTH BELOW 80% — APPLE'S SERVICE THRESHOLD"))
        }
        return ReportSection("HEALTH", rows)
    }

    private static func capacityText(_ b: BatteryInfo) -> String {
        guard let max = b.rawMaxCapacitymAh, let design = b.designCapacitymAh else { return Fmt.none }
        return "\(max)/\(design)mAh"
    }

    // MARK: CHARGE CONTROL

    private static func chargeControl(_ s: Snapshot) -> ReportSection {
        guard s.helperAvailable else {
            return ReportSection("CHARGE CONTROL", [.text("STATUS", "HELPER NOT RUNNING")],
                                 note: "NEEDS THE ROOT HELPER — RUN ./scripts/install.sh")
        }
        guard let c = s.batteryControl else {
            return ReportSection("CHARGE CONTROL", [.text("STATUS", "NO STATE REPORTED")],
                                 note: "THE HELPER ANSWERED BUT SENT NO BATTERY STATE")
        }
        guard c.supported else {
            return ReportSection("CHARGE CONTROL", [
                .text("STATUS", "UNSUPPORTED"),
                .text("SUPPORTED", "NO"),
            ], note: "THIS MAC DOESN'T EXPOSE THE CHARGE-CONTROL SMC KEYS. MONITORING WORKS; CHARGE LIMITING ISN'T POSSIBLE HERE.")
        }

        let g = c.settings
        var rows: [ReportRow] = [
            .text("BATTERY MANAGEMENT", Fmt.onOff(g.enabled)),
            ReportRow("CHARGE LIMIT", g.limitPct >= 100 ? "OFF" : "\(g.limitPct)%",
                      raw: Double(g.limitPct), unit: "%"),
            .text("DISCHARGE TO LIMIT", capability(g.autoDischarge, available: c.dischargeSupported)),
            ReportRow("SAILING", g.sailing ? "ON (−\(g.sailBelowPct)%)" : "OFF",
                      raw: Double(g.sailBelowPct), unit: "%"),
            ReportRow("HEAT PROTECT", g.heatProtect ? "ON (<\(Int(g.heatLimitC))°C)" : "OFF",
                      raw: g.heatLimitC, unit: "C"),
            .text("MAGSAFE LED", capability(g.magsafeLED, available: c.ledSupported)),
            .text("TOP UP", Fmt.onOff(c.topUpActive)),
            .text("CALIBRATION", c.calibration == .idle ? "IDLE" : c.calibration.label),
            .text("CHARGING INHIBITED", Fmt.yesNo(c.chargingInhibited)),
            .text("FORCING DISCHARGE", Fmt.yesNo(c.forcingDischarge)),
            .text("INHIBIT KEYS", c.inhibitKeys.isEmpty ? Fmt.none : c.inhibitKeys.joined(separator: "+")),
            .text("DISCHARGE KEY", c.dischargeKey ?? "NOT FOUND"),
        ]
        rows.append(.text("STATUS", statusLine(c)))
        return ReportSection("CHARGE CONTROL", rows,
                             note: "DISCHARGING FLIPS THE MAC TO BATTERY POWER — DISPLAYS/HUBS SHARING THAT POWER PATH CAN BLANK BRIEFLY. SWITCHES ARE RATE-LIMITED TO ONCE PER MINUTE.")
    }

    private static func capability(_ on: Bool, available: Bool) -> String {
        available ? Fmt.onOff(on) : "UNAVAILABLE"
    }

    private static func statusLine(_ c: BatteryControlState) -> String {
        var parts: [String] = []
        if c.chargingInhibited { parts.append("CHARGING PAUSED") }
        if c.forcingDischarge { parts.append("FORCING DISCHARGE") }
        if parts.isEmpty { parts.append("CHARGING ALLOWED") }
        parts.append("LIMIT SURVIVES APP QUIT + REBOOT (HELPER DAEMON)")
        return parts.joined(separator: " • ")
    }
}
