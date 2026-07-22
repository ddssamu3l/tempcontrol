import Foundation

public enum TC {
    public static let helperMachName = "com.tempcontrol.helper"
    public static let appBundleID = "com.tempcontrol.app"
    public static let helperVersion = 1
    /// Fans revert to auto if the app hasn't pinged the helper for this long.
    public static let heartbeatTimeout: TimeInterval = 20
    public static let targetRange: ClosedRange<Double> = 50...95
    public static let deadband: Double = 2.0
}

// MARK: - powermetrics data (root-only, sampled by the helper)

public struct PMCore: Codable, Identifiable {
    public var id: Int
    public var freqMHz: Double
    public var activeRatio: Double
    public init(id: Int, freqMHz: Double, activeRatio: Double) {
        self.id = id; self.freqMHz = freqMHz; self.activeRatio = activeRatio
    }
}

public struct PMCluster: Codable {
    public var name: String
    public var freqMHz: Double
    public var activeRatio: Double
    public var cores: [PMCore]
    public init(name: String, freqMHz: Double, activeRatio: Double, cores: [PMCore]) {
        self.name = name; self.freqMHz = freqMHz; self.activeRatio = activeRatio; self.cores = cores
    }
}

public struct PMSample: Codable {
    public var clusters: [PMCluster] = []
    public var cpuPowerW: Double?
    public var gpuPowerW: Double?
    public var anePowerW: Double?
    public var combinedPowerW: Double?
    public var gpuFreqMHz: Double?
    public var gpuActiveRatio: Double?
    public var thermalPressure: String?
    public var timestamp: Double = 0
    public init() {}

    /// Tolerant decoding — see the note on `ControlStatus.init(from:)`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clusters = try c.decodeIfPresent([PMCluster].self, forKey: .clusters) ?? []
        cpuPowerW = try c.decodeIfPresent(Double.self, forKey: .cpuPowerW)
        gpuPowerW = try c.decodeIfPresent(Double.self, forKey: .gpuPowerW)
        anePowerW = try c.decodeIfPresent(Double.self, forKey: .anePowerW)
        combinedPowerW = try c.decodeIfPresent(Double.self, forKey: .combinedPowerW)
        gpuFreqMHz = try c.decodeIfPresent(Double.self, forKey: .gpuFreqMHz)
        gpuActiveRatio = try c.decodeIfPresent(Double.self, forKey: .gpuActiveRatio)
        thermalPressure = try c.decodeIfPresent(String.self, forKey: .thermalPressure)
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp) ?? 0
    }

    /// Total SoC draw. `combined_power` isn't reported on every chip/OS combo,
    /// so fall back to summing the blocks powermetrics does give us.
    public var socPowerW: Double? {
        if let c = combinedPowerW, c > 0 { return c }
        let parts = [cpuPowerW, gpuPowerW, anePowerW].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let sum = parts.reduce(0, +)
        return sum > 0 ? sum : nil
    }
}

// MARK: - Fans

public struct FanState: Codable, Identifiable {
    public var id: Int
    public var actualRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double
    public init(id: Int, actualRPM: Double, minRPM: Double, maxRPM: Double, targetRPM: Double) {
        self.id = id; self.actualRPM = actualRPM; self.minRPM = minRPM
        self.maxRPM = maxRPM; self.targetRPM = targetRPM
    }
}

// MARK: - Helper control state

public struct ControlStatus: Codable {
    public var helperVersion: Int = TC.helperVersion
    public var enabled: Bool = false
    public var targetTemp: Double = 80
    /// True while the helper is actively forcing fan speed (temp went past target + 2).
    public var engaged: Bool = false
    public var commandedRPM: Double?
    public var hottestTemp: Double?
    public var fanCount: Int = 0
    public var lowPowerMode: Bool?
    /// Current controller output, 0...1 of the fan range (engaged only).
    public var fanLevel: Double?
    /// Fans pinned at 100% but still over target — target may be unreachable.
    public var atMax = false
    /// Smoothed power the controller is currently regulating against (watts).
    public var controlPowerW: Double?
    /// True when that power is real SoC draw (powermetrics); false when it's
    /// the whole-machine SMC rail, which is the headless fallback.
    public var powerIsSoC = false
    /// Smoothed rate of change of the hottest die, °C per minute. The loop
    /// leans on this to act before heat lands rather than after.
    public var tempSlopeCPerMin: Double?
    /// Learned cooling demand: fan level per watt. Exposed for diagnostics —
    /// it's the state that lets the loop hold a steady speed at target.
    public var conductance: Double?
    public init() {}

    /// Tolerant decoding, deliberately hand-written.
    ///
    /// Swift's synthesized `init(from:)` requires every key to be PRESENT even
    /// when the property has a default value — so the moment the app gains a
    /// field the helper doesn't send yet, the whole payload fails to decode and
    /// the app reports "no helper" instead of degrading. App and helper are
    /// installed together by scripts/install.sh, but nothing forces a user to
    /// keep them in lockstep. Every field here is optional on the wire.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        helperVersion = try c.decodeIfPresent(Int.self, forKey: .helperVersion) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        targetTemp = try c.decodeIfPresent(Double.self, forKey: .targetTemp) ?? 80
        engaged = try c.decodeIfPresent(Bool.self, forKey: .engaged) ?? false
        commandedRPM = try c.decodeIfPresent(Double.self, forKey: .commandedRPM)
        hottestTemp = try c.decodeIfPresent(Double.self, forKey: .hottestTemp)
        fanCount = try c.decodeIfPresent(Int.self, forKey: .fanCount) ?? 0
        lowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .lowPowerMode)
        fanLevel = try c.decodeIfPresent(Double.self, forKey: .fanLevel)
        atMax = try c.decodeIfPresent(Bool.self, forKey: .atMax) ?? false
        controlPowerW = try c.decodeIfPresent(Double.self, forKey: .controlPowerW)
        powerIsSoC = try c.decodeIfPresent(Bool.self, forKey: .powerIsSoC) ?? false
        tempSlopeCPerMin = try c.decodeIfPresent(Double.self, forKey: .tempSlopeCPerMin)
        conductance = try c.decodeIfPresent(Double.self, forKey: .conductance)
    }
}

public struct HelperSample: Codable {
    public var pm: PMSample?
    public var control: ControlStatus
    public var battery: BatteryControlState?
    public init(pm: PMSample?, control: ControlStatus, battery: BatteryControlState? = nil) {
        self.pm = pm; self.control = control; self.battery = battery
    }
}

// MARK: - Fan boost curve (shared so the UI can draw exactly what the helper runs)

public enum BoostCurve {
    /// How far past (target + deadband) the boost reaches 100% fan.
    public static let fullBoostError: Double = 12
    /// Exponent scale: smaller = more aggressive early ramp.
    public static let tau: Double = 3

    /// 0...1 boost fraction for a given error (hottest - target).
    /// Exponential per spec: gentle just past the deadband, aggressive fast.
    public static func fraction(error: Double) -> Double {
        guard error > 0 else { return 0 }
        let e = min(error, fullBoostError)
        let f = (exp(e / tau) - 1) / (exp(fullBoostError / tau) - 1)
        return min(1, max(0, f))
    }
}
