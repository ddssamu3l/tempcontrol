import Foundation
import Shared

/// The temperature regulator. Runs inside the root helper every 2 seconds.
///
/// Control law (per spec):
///   error = hottest die sensor - target
///   - error > +2°C  -> engage boost; fan speed ramps EXPONENTIALLY with error
///                      (BoostCurve), hitting 100% at target+2+12°C.
///   - within ±2°C   -> stay engaged, boost eases off along the same curve.
///   - error < -2°C  -> release: fans go back to full macOS automatic control.
///
/// Safety invariants (see PROJECT_NOTES.md):
///   - Never command below the RPM the fans were already doing when boost
///     engaged (the "baseline") — we only ever speed fans up.
///   - Fanless Macs (fanCount == 0): controller refuses to enable at all.
///   - Anything that stops the loop (disable, app heartbeat lost, helper
///     exit) releases the fans to automatic.
final class FanController {
    private let smc: SMC?
    private let sensors: HIDSensors

    private(set) var enabled = false
    private(set) var targetTemp: Double = 80
    private(set) var engaged = false
    private(set) var commandedRPM: Double?
    private(set) var lastHottest: Double?
    private var baselineRPM: [Int: Double] = [:]

    var fanCount: Int { smc?.fanCount ?? 0 }

    init(smc: SMC?, sensors: HIDSensors) {
        self.smc = smc
        self.sensors = sensors
        // A previous helper crash could have left fans forced. Always start clean.
        release()
    }

    /// Returns false when control can't be enabled (fanless Mac / no SMC).
    @discardableResult
    func setControl(enabled: Bool, target: Double) -> Bool {
        targetTemp = min(max(target, TC.targetRange.lowerBound), TC.targetRange.upperBound)
        if enabled && fanCount == 0 {
            self.enabled = false
            return false
        }
        if self.enabled && !enabled { release() }
        self.enabled = enabled
        return true
    }

    func disableAndRelease() {
        enabled = false
        release()
    }

    func tick() {
        let hottest = sensors.hottestDie()
        lastHottest = hottest
        guard enabled, let smc, fanCount > 0, let hottest else {
            if engaged { release() }
            return
        }

        let error = hottest - targetTemp

        if !engaged {
            guard error > TC.deadband else { return }
            // Record what the fans were already doing under automatic control:
            // this is the floor we never command below.
            baselineRPM = Dictionary(uniqueKeysWithValues: smc.allFans().map { ($0.id, $0.actualRPM) })
            engaged = true
        }

        // Cooled to 2°C below target: hand fans back to macOS.
        if error < -TC.deadband {
            release()
            return
        }

        let fraction = BoostCurve.fraction(error: error)
        var commanded: Double = 0
        for fan in smc.allFans() {
            let span = max(0, fan.maxRPM - fan.minRPM)
            let curveRPM = fan.minRPM + fraction * span
            let rpm = min(fan.maxRPM, max(baselineRPM[fan.id] ?? fan.minRPM, curveRPM))
            smc.setFanMode(fan.id, forced: true)
            smc.setFanTarget(fan.id, rpm: rpm)
            commanded = max(commanded, rpm)
        }
        commandedRPM = commanded
    }

    func release() {
        engaged = false
        commandedRPM = nil
        baselineRPM = [:]
        guard let smc else { return }
        for i in 0..<smc.fanCount {
            smc.setFanMode(i, forced: false)
        }
    }

    func status() -> ControlStatus {
        var st = ControlStatus()
        st.enabled = enabled
        st.targetTemp = targetTemp
        st.engaged = engaged
        st.commandedRPM = commandedRPM
        st.hottestTemp = lastHottest
        st.fanCount = fanCount
        return st
    }
}
