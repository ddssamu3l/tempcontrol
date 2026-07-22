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

    // Smoothing state: fans kick up instantly on spikes, hold, then glide
    // down slowly instead of chasing every temperature wiggle.
    private var emaError: Double?
    private var boostFraction: Double = 0
    private var lastKickUp = Date.distantPast
    private var belowBandSince: Date?
    private var lastWrittenRPM: [Int: Double] = [:]

    /// Fastest allowed decay: fraction of the fan span per 2s tick (~1%/s).
    private let decayPerTick = 0.02
    /// After any kick-up, don't start decaying for this long.
    private let holdAfterKickUp: TimeInterval = 10
    /// Stay below target−2°C this long before handing fans back to macOS
    /// (prevents engage/release flapping right at the band edge).
    private let releaseAfter: TimeInterval = 30
    /// Ignore commanded-RPM changes smaller than this (write suppression).
    private let minRPMChange: Double = 60

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
        let ema = emaError.map { $0 * 0.7 + error * 0.3 } ?? error
        emaError = ema

        if !engaged {
            guard error > TC.deadband else { return }
            // Record what the fans were already doing under automatic control:
            // this is the floor we never command below.
            baselineRPM = Dictionary(uniqueKeysWithValues: smc.allFans().map { ($0.id, $0.actualRPM) })
            engaged = true
            boostFraction = 0
        }

        // Cooled to 2°C below target — but only release after staying there
        // for a while, so a brief dip doesn't bounce control back and forth.
        if error < -TC.deadband {
            if belowBandSince == nil { belowBandSince = Date() }
            if Date().timeIntervalSince(belowBandSince!) >= releaseAfter {
                release()
                return
            }
        } else {
            belowBandSince = nil
        }

        // Spikes act on the instantaneous error (fast attack); the way down
        // follows the smoothed error, held then rate-limited (slow decay).
        let targetFraction = BoostCurve.fraction(error: max(error, ema))
        if targetFraction > boostFraction {
            boostFraction = targetFraction
            lastKickUp = Date()
        } else if Date().timeIntervalSince(lastKickUp) >= holdAfterKickUp {
            boostFraction = max(targetFraction, boostFraction - decayPerTick)
        }

        var commanded: Double = 0
        for fan in smc.allFans() {
            let span = max(0, fan.maxRPM - fan.minRPM)
            let curveRPM = fan.minRPM + boostFraction * span
            let rpm = min(fan.maxRPM, max(baselineRPM[fan.id] ?? fan.minRPM, curveRPM))
            // Skip sub-audible adjustments so the pitch isn't constantly wandering.
            if abs((lastWrittenRPM[fan.id] ?? -1000) - rpm) >= minRPMChange {
                smc.setFanMode(fan.id, forced: true)
                smc.setFanTarget(fan.id, rpm: rpm)
                lastWrittenRPM[fan.id] = rpm
            }
            commanded = max(commanded, lastWrittenRPM[fan.id] ?? rpm)
        }
        commandedRPM = commanded
    }

    func release() {
        engaged = false
        commandedRPM = nil
        baselineRPM = [:]
        emaError = nil
        boostFraction = 0
        belowBandSince = nil
        lastWrittenRPM = [:]
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
