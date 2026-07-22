import Foundation
import Shared

/// The temperature regulator: a power-aware PID loop on 2-second ticks.
///
/// Three signals go into every decision, because temperature alone is not
/// enough to control temperature:
///
///   TEMP  — where the chip is now (error = hottest die − target).
///   SLOPE — where it is *heading*. Silicon heats far faster than a fan can
///           spin up, so reacting only after the error appears guarantees
///           overshoot. Slope is the D term: the loop acts on the predicted
///           error a few seconds out.
///   POWER — how much heat is being produced right now. This is the
///           feedforward: at steady state the fan speed a workload needs is
///           essentially a function of watts, so when load jumps we can go
///           straight to the right speed instead of rediscovering it by
///           letting the chip get hot first.
///
/// What the loop actually learns is CONDUCTANCE — fan level required per watt
/// of load (`output ≈ conductance × watts`). Learning that instead of a raw
/// fan level is what makes the hold stable: when power moves, the commanded
/// speed tracks it immediately and the learned term doesn't have to change.
///
/// Asymmetry is deliberate and is the fix for the classic failure mode: raise
/// the target from 50 °C to 65 °C and a naive loop dumps fan speed on a fixed
/// timer, so the chip sails straight past 65 to 73 before the loop notices and
/// claws back. Here, relaxation is gated on *margin*: the loop only unwinds
/// while the chip is below target AND not trending back up, and the unwind
/// rate fades to zero as it approaches the target from below. It coasts into
/// the target instead of overshooting it.
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

    /// Learned fan level per watt — the loop's memory of this machine.
    private(set) var conductance: Double = 0
    /// Smoothed control power (watts) and where it came from.
    private(set) var controlPowerW: Double?
    private(set) var powerIsSoC = false
    /// Smoothed dT/dt of the hottest die, °C per second.
    private(set) var tempSlope: Double = 0

    private var lastTemp: Double?
    private var lastTempAt: Date?
    private var baselineRPM: [Int: Double] = [:]
    private var belowBandSince: Date?
    private var atMaxSince: Date?
    private var lastWrittenRPM: [Int: Double] = [:]

    private let dt: Double = 2                 // tick period, seconds

    // -- tuning ------------------------------------------------------------
    /// How far ahead the slope term looks. Roughly the time it takes a fan
    /// change to show up in die temperature on this class of machine.
    private let lookahead: Double = 10
    /// Hard cap on the lead term. Die sensors are jumpy and slope is a
    /// derivative, so it amplifies noise; without this clamp a quiet, steady
    /// load makes the fans hunt over a 30-point range for no thermal reason.
    private let maxLead: Double = 5
    /// Learning rates, expressed directly in fan-level per °C per second
    /// (the power division below cancels against the feedforward multiply).
    /// Winding is fast enough to erase a 2 °C offset in well under a minute —
    /// a slow integral is exactly what leaves the chip parked above target.
    private let kUp = 0.004
    private let kDown = 0.006
    /// Cap on how much error may drive a single unwind step, so a big cold
    /// margin can't crater the learned term in one go.
    private let maxRelaxError: Double = 5
    /// Hard bound on the learned term (fan level per watt). Generous — it
    /// only exists to stop runaway if the power signal misbehaves.
    private let maxConductance = 0.2
    /// Used when no power reading is available at all; the loop then behaves
    /// like a plain PI controller instead of failing.
    private let nominalPowerW: Double = 30
    private let minPowerW: Double = 5
    /// Smoothing time constants (seconds).
    private let powerTau: Double = 8
    private let slopeTau: Double = 20
    /// Slew limits per tick: fans may rise quickly but only glide down.
    private let maxUpStep = 0.25
    private let maxDownStep = 0.02
    /// Margin below target at which the glide-down is allowed to run at full
    /// rate; it scales linearly to zero as the chip approaches the target.
    private let relaxBand: Double = 10
    /// Relaxation stops this far BELOW the target rather than exactly at it.
    /// Cooling is never instant, so a loop that keeps easing off right up to
    /// the target always coasts past it. Giving up ~1°C of headroom is what
    /// buys "settles at the number you set" instead of "circles it".
    private let relaxGuard: Double = 1.0
    /// Severe overheat bypasses the up-slew limit entirely.
    private let panicError: Double = 8
    /// Release to macOS only after the output has fully unwound AND the chip
    /// has stayed below target−2°C this long (no flapping at the band edge).
    private let releaseAfter: TimeInterval = 30
    /// "Target unreachable" only after the fans have been pinned this long.
    private let atMaxAfter: TimeInterval = 20
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

    /// - Parameter socPowerW: live SoC draw from powermetrics when the helper
    ///   has it; nil falls back to the whole-machine SMC rail.
    func tick(socPowerW: Double? = nil) {
        let hottest = sensors.hottestDie()
        lastHottest = hottest
        updateSlope(hottest)
        updatePower(socPowerW)

        guard enabled, let smc, fanCount > 0, let hottest else {
            if engaged { release() }
            return
        }

        let power = max(controlPowerW ?? nominalPowerW, minPowerW)
        let error = hottest - targetTemp
        // What the error will be once the current trend plays out. Positive
        // means "heading over target" even if we're under it right now.
        let lead = min(maxLead, max(-maxLead, tempSlope * lookahead))
        let predictedError = error + lead
        // Act on whichever is worse — never be talked out of cooling by a
        // favourable instantaneous reading.
        let driveError = max(error, predictedError)

        if !engaged {
            // Engage as the chip reaches the target, or earlier if the trend
            // says it's about to blow through it. Takeover is bumpless, so
            // engaging early costs nothing but buys reaction time.
            guard error > 0 || predictedError > TC.deadband else { return }
            let fans = smc.allFans()
            baselineRPM = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.actualRPM) })
            // Bumpless takeover: seed from what the fans are already doing
            // under macOS control, expressed in conductance so it stays valid
            // as load moves.
            let seed = fans.map { fan in
                let span = max(1.0, fan.maxRPM - fan.minRPM)
                return max(0, (fan.actualRPM - fan.minRPM) / span)
            }.max() ?? 0
            conductance = min(maxConductance, seed / power)
            output = seed
            engaged = true
        }

        learn(driveError: driveError, error: error, predictedError: predictedError, power: power)

        // -- feedforward + proportional kick ---------------------------------
        let feedforward = conductance * power
        let kick = BoostCurve.fraction(error: driveError)
        let targetOut = min(1, max(0, feedforward + kick))

        if targetOut > output {
            output = driveError >= panicError ? targetOut : min(targetOut, output + maxUpStep)
        } else {
            // Glide down only as fast as the margin below target allows. Near
            // the target the descent freezes: that's what stops the chip from
            // being handed back to a fan speed that can't hold it.
            let margin = max(0, -driveError - relaxGuard)
            let allowed = maxDownStep * min(1, margin / relaxBand)
            output = max(targetOut, output - allowed)
        }

        // -- release: chip comfortably below target with no help needed ------
        if error < -TC.deadband && predictedError < 0 && output <= 0.05 {
            if belowBandSince == nil { belowBandSince = Date() }
            if Date().timeIntervalSince(belowBandSince!) >= releaseAfter {
                release()
                return
            }
        } else {
            belowBandSince = nil
        }

        // -- honest saturation reporting -------------------------------------
        if output >= 0.99 && error > TC.deadband {
            if atMaxSince == nil { atMaxSince = Date() }
        } else {
            atMaxSince = nil
        }

        apply(smc: smc)
    }

    /// Smoothed dT/dt of the hottest die. Kept running even when disengaged so
    /// the trend is already meaningful the moment control takes over.
    private func updateSlope(_ hottest: Double?) {
        let now = Date()
        guard let hottest else { lastTemp = nil; lastTempAt = nil; return }
        defer { lastTemp = hottest; lastTempAt = now }
        guard let lastTemp, let lastTempAt else { return }
        let elapsed = now.timeIntervalSince(lastTempAt)
        guard elapsed > 0.2 else { return }
        let raw = (hottest - lastTemp) / elapsed
        let alpha = min(1, elapsed / slopeTau)
        tempSlope += alpha * (raw - tempSlope)
    }

    /// Prefer true SoC draw; fall back to the whole-machine SMC rail so the
    /// loop still works headless. The two are on different scales, so switching
    /// source rescales the learned term rather than jolting the fans.
    private func updatePower(_ socPowerW: Double?) {
        let fromSoC = socPowerW != nil
        guard let raw = socPowerW ?? smc?.double("PSTR"), raw > 0 else { return }
        if controlPowerW == nil || fromSoC != powerIsSoC {
            if let old = controlPowerW, old > 0 {
                conductance = min(maxConductance, conductance * old / raw)
            }
            controlPowerW = raw
            powerIsSoC = fromSoC
        } else {
            let alpha = min(1, dt / powerTau)
            controlPowerW = (controlPowerW ?? raw) + alpha * (raw - (controlPowerW ?? raw))
        }
    }

    /// Update the learned conductance. Winding on the predicted error means we
    /// spin up before the heat lands; unwinding requires the chip to be both
    /// below target and not trending back up, and fades out near the target.
    private func learn(driveError: Double, error: Double, predictedError: Double, power: Double) {
        let saturated = output >= 0.999
        if driveError > 0 {
            // Anti-windup: no point learning more demand than the fans can deliver.
            guard !saturated else { return }
            conductance += kUp * driveError * dt / power
        } else if error < -relaxGuard {
            // Both the actual and the predicted error must clear the guard
            // band: being cool right now doesn't license backing off if the
            // trend says we're on the way back up.
            let relax = min(-error, -predictedError) - relaxGuard
            guard relax > 0 else { return }
            conductance -= kDown * min(relax, maxRelaxError) * dt / power
        }
        conductance = min(maxConductance, max(0, conductance))
    }

    private func apply(smc: SMC) {
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
        conductance = 0
        output = 0
        belowBandSince = nil
        atMaxSince = nil
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
        st.atMax = atMaxSince.map { Date().timeIntervalSince($0) >= atMaxAfter } ?? false
        st.controlPowerW = controlPowerW
        st.powerIsSoC = powerIsSoC
        st.tempSlopeCPerMin = lastHottest != nil ? tempSlope * 60 : nil
        st.conductance = engaged ? conductance : nil
        return st
    }
}
