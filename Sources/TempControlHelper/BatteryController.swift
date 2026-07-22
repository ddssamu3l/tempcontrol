import Foundation
import Shared

/// Battery charge management — the AlDente feature set, running in the root
/// helper so it keeps working with the app closed and across reboots.
///
/// Control keys differ across Apple Silicon generations/macOS builds, so we
/// discover at startup (as root) which set this machine has and report
/// capability honestly instead of assuming:
///   - charge inhibit: CH0B+CH0C (write 02), or CHIE (write 08), or CHTE (01)
///   - forced discharge (adapter off): CH0I (write 01)
///   - MagSafe LED: ACLC (0 auto, 3 green, 4 orange)
///
/// Unlike fan control, battery settings PERSIST when the app quits — holding
/// a charge limit unattended is the whole point. `reset()` (used by
/// uninstall) puts every key back to macOS defaults.
final class BatteryController {
    static let settingsDir = "/Library/Application Support/TempControl"
    static let settingsPath = settingsDir + "/battery-settings.json"

    private let smc: SMC?
    private let reader = BatteryReader()

    private(set) var settings = BatterySettings()
    private var inhibitWrites: [(key: String, inhibit: UInt8)] = []
    private var dischargeKey: String?
    private var ledSupported = false

    private var inhibited = false
    private var discharging = false
    private var topUp = false
    private var calibration: CalibrationPhase = .idle
    private var holdUntil: Date?
    private var lastLED: UInt8?

    init(smc: SMC?) {
        self.smc = smc
        loadSettings()
        discoverKeys()
        // Re-apply the persisted limit right away (helper starts at boot).
        tick()
    }

    private func discoverKeys() {
        guard let smc else { return }
        let candidates: [[(String, UInt8)]] = [
            [("CH0B", 2), ("CH0C", 2)],
            [("CHIE", 8)],
            [("CHTE", 1)],
        ]
        for set in candidates where set.allSatisfy({ smc.keyExists($0.0) }) {
            inhibitWrites = set.map { (key: $0.0, inhibit: $0.1) }
            break
        }
        dischargeKey = smc.keyExists("CH0I") ? "CH0I" : nil
        ledSupported = smc.keyExists("ACLC")
        // If a previous run left charging inhibited, adopt that state instead
        // of clobbering it.
        if let first = inhibitWrites.first {
            inhibited = (smc.double(first.key) ?? 0) != 0
        }
        if let dischargeKey {
            discharging = (smc.double(dischargeKey) ?? 0) != 0
        }
    }

    var supported: Bool { !inhibitWrites.isEmpty }

    // MARK: settings & one-shot modes

    func apply(_ new: BatterySettings) {
        settings = new
        settings.limitPct = min(100, max(50, settings.limitPct))
        settings.sailBelowPct = min(20, max(2, settings.sailBelowPct))
        settings.heatLimitC = min(45, max(30, settings.heatLimitC))
        saveSettings()
        tick()
    }

    func setTopUp(_ on: Bool) {
        topUp = on
        if on { calibration = .idle }
        tick()
    }

    func setCalibration(_ on: Bool) {
        calibration = on ? .charging : .idle
        if on { topUp = false }
        holdUntil = nil
        tick()
    }

    // MARK: control loop (called every ~10s)

    func tick() {
        guard supported, let smc, let info = reader.read(), let pct = info.hwPercent else { return }

        // -- figure out the current charge target ----------------------------
        var target = Double(settings.limitPct)
        switch calibration {
        case .charging:
            target = 100
            if pct >= 99.5 { calibration = .holding; holdUntil = Date().addingTimeInterval(3600) }
        case .holding:
            target = 100
            if let holdUntil, Date() >= holdUntil { calibration = .discharging; self.holdUntil = nil }
        case .discharging:
            target = 15
            if pct <= 15.5 { calibration = .recharging }
        case .recharging:
            if pct >= Double(settings.limitPct) - 0.5 { calibration = .idle }
        case .idle:
            if topUp {
                target = 100
                if pct >= 99.5 { topUp = false; target = Double(settings.limitPct) }
            }
        }

        // -- discharge decision ----------------------------------------------
        let needsDischarge: Bool
        if calibration == .discharging {
            needsDischarge = true
        } else {
            needsDischarge = settings.autoDischarge && pct > target + 0.5
        }
        let wantDischarge = needsDischarge && dischargeKey != nil && info.externalConnected

        // -- charging decision (with sailing hysteresis) ---------------------
        var wantInhibit = inhibited
        if pct >= target {
            wantInhibit = true
        } else {
            let resumeAt = target - (settings.sailing ? Double(settings.sailBelowPct) : 0.5)
            if pct <= resumeAt { wantInhibit = false }
        }
        if wantDischarge { wantInhibit = true }
        if settings.heatProtect, let t = info.temperatureC, t > settings.heatLimitC {
            wantInhibit = true
        }

        // -- write only on change --------------------------------------------
        if wantDischarge != discharging, let dischargeKey {
            smc.writeUInt8(dischargeKey, wantDischarge ? 1 : 0)
            discharging = wantDischarge
        }
        if wantInhibit != inhibited {
            for w in inhibitWrites { smc.writeUInt8(w.key, wantInhibit ? w.inhibit : 0) }
            inhibited = wantInhibit
        }
        updateLED(info: info, pct: pct, target: target)
    }

    private func updateLED(info: BatteryInfo, pct: Double, target: Double) {
        guard ledSupported, let smc else { return }
        let value: UInt8
        if !settings.magsafeLED {
            value = 0                                   // macOS default behavior
        } else if !info.externalConnected {
            value = 0
        } else if pct >= target - 0.5 {
            value = 3                                   // green: held at limit
        } else {
            value = 4                                   // orange: charging
        }
        if value != lastLED {
            smc.writeUInt8("ACLC", value)
            lastLED = value
        }
    }

    // MARK: status for the app

    func state() -> BatteryControlState {
        var s = BatteryControlState()
        s.settings = settings
        s.supported = supported
        s.dischargeSupported = dischargeKey != nil
        s.ledSupported = ledSupported
        s.chargingInhibited = inhibited
        s.forcingDischarge = discharging
        s.topUpActive = topUp
        s.calibration = calibration
        s.inhibitKeys = inhibitWrites.map(\.key)
        s.dischargeKey = dischargeKey
        return s
    }

    // MARK: reset to macOS defaults (uninstall / --reset-battery)

    func reset() {
        guard let smc else { return }
        for w in inhibitWrites { smc.writeUInt8(w.key, 0) }
        if let dischargeKey { smc.writeUInt8(dischargeKey, 0) }
        if ledSupported { smc.writeUInt8("ACLC", 0) }
        inhibited = false
        discharging = false
    }

    /// Standalone reset for `tempcontrol-helper --reset-battery` (run as root
    /// by uninstall.sh after the daemon is stopped).
    static func resetStandalone() {
        let controller = BatteryController(smc: SMC())
        controller.reset()
        try? FileManager.default.removeItem(atPath: settingsPath)
    }

    // MARK: persistence

    private func loadSettings() {
        guard let data = FileManager.default.contents(atPath: Self.settingsPath),
              let s = try? JSONDecoder().decode(BatterySettings.self, from: data)
        else { return }
        settings = s
    }

    private func saveSettings() {
        try? FileManager.default.createDirectory(atPath: Self.settingsDir,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: URL(fileURLWithPath: Self.settingsPath))
        }
    }
}
