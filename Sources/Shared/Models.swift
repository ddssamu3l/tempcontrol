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
    public init() {}
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
