import Foundation
import Shared

/// Mirrors the TEMP tab (`Views/ControlView.swift`: ChipTempBox,
/// TempControlBox, FansView, BatteryTempBox).
///
/// The app's dial reflects local UI intent (`store.desiredTarget`); the CLI is
/// a separate process, so the authoritative equivalent is the helper's
/// `ControlStatus` — what the machine is *actually* doing right now.
public enum TempReport: PanelReporting {
    public static let panel = Panel.temp

    public static func sections(_ s: Snapshot, _ sys: SystemInfo) -> [ReportSection] {
        [chipTemp(s), tempControl(s), fans(s), batteryTemp(s)]
    }

    // MARK: CHIP TEMP — LIVE

    private static func chipTemp(_ s: Snapshot) -> ReportSection {
        let die = s.sensors.filter(\.isDie).map(\.celsius)
        let avgDie = die.isEmpty ? nil : die.reduce(0, +) / Double(die.count)
        let control = s.control
        let target = (control?.enabled == true) ? control?.targetTemp : nil

        var rows: [ReportRow] = [
            .temp("NOW", s.hottest),
            ReportRow("MAX TEMP", target.map(Fmt.tempWhole) ?? "OFF", raw: target, unit: "C"),
        ]
        if let now = s.hottest, let target {
            let d = now - target
            rows.append(ReportRow("HEADROOM", headroomText(d), raw: d, unit: "C"))
        }
        rows.append(.temp("AVG DIE", avgDie))
        rows.append(.temp("HOTTEST DIE", s.hottest))
        rows.append(.int("DIE SENSORS", die.count))
        rows.append(.text("THERMAL", s.pm?.thermalPressure?.uppercased() ?? Fmt.none))

        return ReportSection("CHIP TEMP — LIVE", rows,
                             note: "MAX TEMP IS A CEILING, NOT A SETPOINT — THE CONTROLLER ONLY ACTS WHEN THE HOTTEST DIE SENSOR APPROACHES IT, AND NEVER HEATS THE CHIP UP TO IT")
    }

    // MARK: TEMP CONTROL

    private static func tempControl(_ s: Snapshot) -> ReportSection {
        guard s.helperAvailable else {
            return ReportSection("TEMP CONTROL",
                                 [.text("HELPER", "NOT RUNNING")],
                                 note: "FAN CONTROL AND PER-CORE FREQUENCY NEED THE ROOT HELPER — RUN ./scripts/install.sh")
        }
        guard s.fanCount > 0 else {
            return ReportSection("TEMP CONTROL",
                                 [.text("FANS", "NONE")],
                                 note: "THIS MAC HAS NO FANS — TEMPERATURE CONTROL IS NOT POSSIBLE. MONITORING REMAINS FULLY FUNCTIONAL.")
        }

        let c = s.control
        let avgFan = s.fans.isEmpty ? nil : s.fans.map(\.actualRPM).reduce(0, +) / Double(s.fans.count)
        var rows: [ReportRow] = [
            .text("FANS DRIVEN BY", modeText(c)),
            .optional("FAN CMD", c?.commandedRPM, Fmt.rpm, unit: "RPM"),
            .fraction("FAN LEVEL", c?.fanLevel),
            .optional("FAN AVG", avgFan, Fmt.rpm, unit: "RPM"),
            .watts("SYS POWER", s.systemPowerW),
            .text("LOW POWER MODE", c?.lowPowerMode.map(Fmt.onOff) ?? Fmt.none),
            .text("MODE", c?.enabled == true ? "MAX COOLING" : "MACOS DEFAULT"),
            .optional("CONTROL MAX TEMP", c?.targetTemp, Fmt.tempWhole, unit: "C"),
            .text("ENGAGED", c.map { Fmt.yesNo($0.engaged) } ?? Fmt.none),
            .text("AT MAX", c.map { Fmt.yesNo($0.atMax) } ?? Fmt.none),
            .temp("HELPER HOTTEST", c?.hottestTemp),
            .int("CONTROLLABLE FANS", c?.fanCount),
            // Control-loop diagnostics — the CLI is the main way to see these.
            .watts("CONTROL POWER", c?.controlPowerW),
            .text("POWER SOURCE", c.map { $0.powerIsSoC ? "SOC (POWERMETRICS)" : "SYSTEM (SMC RAIL)" } ?? Fmt.none),
            .optional("TEMP SLOPE", c?.tempSlopeCPerMin, { String(format: "%+.2f°C/min", $0) }, unit: "C/min"),
            .optional("CONDUCTANCE", c?.conductance, { String(format: "%.4f", $0) }, unit: "level/W"),
            .int("HELPER VERSION", c?.helperVersion),
        ]
        if c?.atMax == true {
            rows.append(.text("WARNING", "FANS AT 100% AND STILL OVER THE LIMIT"))
        }
        return ReportSection("TEMP CONTROL", rows,
                             note: "POWER-AWARE PID: FEEDFORWARD FROM WATTS, P KICKS ON SPIKES, LEARNED CONDUCTANCE HOLDS THE CHIP UNDER THE LIMIT")
    }

    /// Headroom under the ceiling, phrased the same way as the app's cell.
    private static func headroomText(_ d: Double) -> String {
        if d > TC.deadband { return "OVER +" + Fmt.temp(d) }
        if d >= -TC.deadband { return "AT LIMIT" }
        return Fmt.temp(-d) + " SPARE"
    }

    private static func modeText(_ c: ControlStatus?) -> String {
        guard c?.enabled == true else { return "MACOS" }
        return c?.engaged == true ? "TEMPCONTROL" : "MACOS (UNDER LIMIT)"
    }

    // MARK: FANS

    private static func fans(_ s: Snapshot) -> ReportSection {
        guard s.fanCount > 0 else {
            return ReportSection("FANS", [.int("FAN COUNT", 0)],
                                 note: "FANLESS MAC — PASSIVE COOLING ONLY, FAN CONTROL UNAVAILABLE")
        }
        var rows: [ReportRow] = [.int("FAN COUNT", s.fanCount)]
        for fan in s.fans {
            rows.append(ReportRow("FAN\(fan.id)",
                                  "\(Fmt.rpmPadded(fan.actualRPM))   \(Fmt.rpmRange(fan.minRPM, fan.maxRPM))",
                                  raw: fan.actualRPM, unit: "RPM"))
            rows.append(ReportRow("FAN\(fan.id) TARGET", Fmt.rpm(fan.targetRPM),
                                  raw: fan.targetRPM, unit: "RPM"))
        }
        return ReportSection("FANS", rows)
    }

    // MARK: BATTERY TEMP

    private static func batteryTemp(_ s: Snapshot) -> ReportSection {
        var rows: [ReportRow] = [
            .temp("NOW", s.battery?.temperatureC),
            .text("SAFE RANGE", "<35°C IDEAL"),
        ]
        if let settings = s.batteryControl?.settings, settings.enabled, settings.heatProtect {
            rows.append(ReportRow("HEAT PROTECT",
                                  "PAUSES CHARGE >\(Int(settings.heatLimitC))°C",
                                  raw: settings.heatLimitC, unit: "C"))
        }
        return ReportSection("BATTERY TEMP", rows,
                             note: "THE PACK HEATS FROM CHARGING AND CHASSIS HEAT, AND AGES FASTER HOT")
    }
}
