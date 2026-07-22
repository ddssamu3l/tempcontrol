import Foundation
import Shared

/// The temperature regulator: a PI controller on 2-second ticks.
///
/// Why PI and not just a fan curve: a curve maps "degrees over target" to a
/// fan speed, so holding any speed requires a permanent error — the chip
/// anchors ABOVE your target, or bounces across it as fans kick and decay.
/// The integral term fixes that: it accumulates error over time and settles
/// on whatever steady fan speed makes the error zero, then holds it.
///
///   P (kick):  BoostCurve.fraction(error) — the exponential response to
///              being over target. Instant, handles spikes, zero at target.
///   I (hold):  slowly learns the sustained fan level the workload needs.
///              At steady state P≈0 and I carries the whole output — fans
///              sit at ONE speed while the chip sits AT the target.
///
/// Safety invariants (see PROJECT_NOTES.md):
///   - Never command below the RPM the fans were doing when boost engaged.
///   - Fanless Macs: controller refuses to enable.
///   - Disable, app-gone watchdog, and helper exit all release to macOS auto.
final class FanController {
    private let smc: SMC?
    private let sensors: HIDSensors

    private(set) var enabled = false
    private(set) var targetTemp: Double = 80
    private(set) var engaged = false
    private(set) var commandedRPM: Double?
    private(set) var lastHottest: Double?
    private(set) var output: Double = 0        // 0...1 of fan span
    private var integrator: Double = 0
    private var baselineRPM: [Int: Double] = [:]
    private var belowBandSince: Date?
    private var lastWrittenRPM: [Int: Double] = [:]

    private let dt: Double = 2                 // tick period, seconds
    /// Integral gains (fraction per °C per second). Unwinding (cooling) runs
    /// faster than winding so we don't overstay after load drops.
    private let kiUp = 0.0015
    private let kiDown = 0.003
    /// Slew limits per tick: fans may rise quickly but only glide down
    /// (~1% of range per second) — this is what keeps the pitch calm.
    private let maxUpStep = 0.25
    private let maxDownStep = 0.02
    /// Severe overheat bypasses the up-slew limit entirely.
    private let panicError: Double = 8
    /// Release to macOS only after the output has fully unwound AND the chip
    /// has stayed below target−2°C this long (no flapping at the band edge).
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

        if !engaged {
            guard error > TC.deadband else { return }
            let fans = smc.allFans()
            baselineRPM = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.actualRPM) })
            // Bumpless takeover: seed the integrator so our first command
            // matches what the fans are already doing under macOS control.
            integrator = fans.map { fan in
                let span = max(1.0, fan.maxRPM - fan.minRPM)
                return max(0, (fan.actualRPM - fan.minRPM) / span)
            }.max() ?? 0
            engaged = true
            output = integrator
        }

        // -- integral: learn the steady level that zeroes the error ----------
        integrator += (error >= 0 ? kiUp : kiDown) * error * dt
        integrator = min(1, max(0, integrator))

        // -- proportional kick + slew-limited output -------------------------
        let kick = BoostCurve.fraction(error: error)
        let targetOut = min(1, max(0, kick + integrator))
        if targetOut > output {
            output = error >= panicError ? targetOut : min(targetOut, output + maxUpStep)
        } else {
            output = max(targetOut, output - maxDownStep)
        }

        // -- release: chip comfortably below target with no help needed ------
        if error < -TC.deadband && output <= 0.05 {
            if belowBandSince == nil { belowBandSince = Date() }
            if Date().timeIntervalSince(belowBandSince!) >= releaseAfter {
                release()
                return
            }
        } else {
            belowBandSince = nil
        }

        var commanded: Double = 0
        for fan in smc.allFans() {
            let span = max(0, fan.maxRPM - fan.minRPM)
            let rpm = min(fan.maxRPM,
                          max(baselineRPM[fan.id] ?? fan.minRPM, fan.minRPM + output * span))
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
        integrator = 0
        output = 0
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
        st.fanLevel = engaged ? output : nil
        st.atMax = engaged && output >= 0.99 && (lastHottest ?? 0) - targetTemp > 1
        return st
    }
}
