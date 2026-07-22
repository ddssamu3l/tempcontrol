import Foundation
import IOKit

// MARK: - Live battery readings (AppleSmartBattery — no root needed)

public struct BatteryInfo: Codable {
    /// True pack state from the battery management system:
    /// AppleRawCurrentCapacity / AppleRawMaxCapacity. macOS's displayed
    /// percentage is smoothed/adjusted; this one isn't (AlDente's
    /// "hardware battery percentage").
    public var hwPercent: Double?
    public var osPercent: Int?
    public var isCharging = false
    public var externalConnected = false
    public var fullyCharged = false
    public var cycleCount: Int?
    public var designCapacitymAh: Int?
    public var nominalCapacitymAh: Int?
    public var rawMaxCapacitymAh: Int?
    /// NominalChargeCapacity / DesignCapacity, capped at 100.
    public var healthPct: Double?
    public var temperatureC: Double?
    public var voltageV: Double?
    /// Signed: positive while charging, negative while discharging.
    public var amperageA: Double?
    /// voltage × amperage — battery-side watts, signed like amperage.
    public var batteryPowerW: Double?
    public var timeRemainingMin: Int?
    public var adapterMaxW: Int?
    public var adapterName: String?
    public init() {}
}

public final class BatteryReader {
    public init() {}

    public func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any]
        else { return nil }

        var info = BatteryInfo()
        let rawCur = d["AppleRawCurrentCapacity"] as? Int
        let rawMax = d["AppleRawMaxCapacity"] as? Int
        if let rawCur, let rawMax, rawMax > 0 {
            info.hwPercent = Double(rawCur) / Double(rawMax) * 100
        }
        info.osPercent = d["CurrentCapacity"] as? Int
        info.isCharging = d["IsCharging"] as? Bool ?? false
        info.externalConnected = d["ExternalConnected"] as? Bool ?? false
        info.fullyCharged = d["FullyCharged"] as? Bool ?? false
        info.cycleCount = d["CycleCount"] as? Int
        info.designCapacitymAh = d["DesignCapacity"] as? Int
        info.nominalCapacitymAh = d["NominalChargeCapacity"] as? Int
        info.rawMaxCapacitymAh = rawMax
        if let nom = info.nominalCapacitymAh, let design = info.designCapacitymAh, design > 0 {
            info.healthPct = min(100, Double(nom) / Double(design) * 100)
        }
        if let t = d["Temperature"] as? Int { info.temperatureC = Double(t) / 100.0 }
        if let v = d["Voltage"] as? Int { info.voltageV = Double(v) / 1000.0 }
        if let a = d["Amperage"] as? Int {
            // Registry sometimes hands the signed value back as wrapped UInt64.
            let signed = a > Int(Int32.max) ? Int(Int32(truncatingIfNeeded: a)) : a
            info.amperageA = Double(signed) / 1000.0
        }
        if let v = info.voltageV, let a = info.amperageA {
            info.batteryPowerW = v * a
        }
        if let t = d["TimeRemaining"] as? Int, t > 0, t < 65535 {
            info.timeRemainingMin = t
        }
        if let adapter = d["AdapterDetails"] as? [String: Any] {
            info.adapterMaxW = adapter["Watts"] as? Int
            info.adapterName = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
        }
        return info
    }
}

// MARK: - Battery management settings (persisted by the helper)

public struct BatterySettings: Codable, Equatable {
    /// Master switch. Off = TempControl touches nothing battery-related and
    /// all control keys are reset to macOS defaults.
    public var enabled = true
    /// 100 = limiting off. Hardware-percentage based.
    public var limitPct: Int = 100
    /// Actively drain to the limit when above it (AlDente Pro "Discharge").
    public var autoDischarge = false
    /// Don't resume charging until this far below the limit — avoids
    /// micro-cycles (AlDente Pro "Sailing Mode").
    public var sailing = false
    public var sailBelowPct: Int = 5
    /// Pause charging when the battery is hot (AlDente Pro "Heat Protection").
    public var heatProtect = false
    public var heatLimitC: Double = 35
    /// Drive the MagSafe LED to match the real state: orange charging,
    /// green once held at the limit (AlDente Pro "Control MagSafe LED").
    public var magsafeLED = false
    public init() {}

    // Tolerant decoding: settings JSON persists on disk across app updates,
    // so newly added fields must fall back to defaults instead of failing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        limitPct = try c.decodeIfPresent(Int.self, forKey: .limitPct) ?? 100
        autoDischarge = try c.decodeIfPresent(Bool.self, forKey: .autoDischarge) ?? false
        sailing = try c.decodeIfPresent(Bool.self, forKey: .sailing) ?? false
        sailBelowPct = try c.decodeIfPresent(Int.self, forKey: .sailBelowPct) ?? 5
        heatProtect = try c.decodeIfPresent(Bool.self, forKey: .heatProtect) ?? false
        heatLimitC = try c.decodeIfPresent(Double.self, forKey: .heatLimitC) ?? 35
        magsafeLED = try c.decodeIfPresent(Bool.self, forKey: .magsafeLED) ?? false
    }
}

public enum CalibrationPhase: String, Codable {
    case idle, charging, holding, discharging, recharging

    public var label: String {
        switch self {
        case .idle: return "—"
        case .charging: return "1/4 CHARGING TO 100%"
        case .holding: return "2/4 HOLDING AT 100% (1H)"
        case .discharging: return "3/4 DISCHARGING TO 15%"
        case .recharging: return "4/4 RECHARGING TO LIMIT"
        }
    }
}

/// What the helper's battery controller is actually doing right now.
/// Lid state, via IOPMrootDomain.
///
/// This matters far more than it looks. A Mac running with the lid shut
/// ("clamshell") stays awake ONLY while it has AC power — that's a macOS rule,
/// not a setting. So anything that briefly drops the machine onto battery is a
/// harmless flicker with the lid open, and an immediate full system sleep with
/// the lid closed: fans stop mid-load, external displays go black, and it looks
/// exactly like a crash. See PROJECT_NOTES.md.
public enum Lid {
    /// True when shut. nil on desktops, or if the key isn't published.
    public static func isClosed() -> Bool? {
        // Match the service rather than hardcoding a registry path — the path
        // is not stable and resolved to nothing on macOS 26.
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let cf = IORegistryEntryCreateCFProperty(
            entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return (cf as? NSNumber)?.boolValue
    }
}

public struct BatteryControlState: Codable {
    public var settings = BatterySettings()
    /// Charge-inhibit SMC keys were found (root). False = this Mac/macOS
    /// build doesn't expose them and charge limiting is unavailable.
    public var supported = false
    public var dischargeSupported = false
    public var ledSupported = false
    public var chargingInhibited = false
    public var forcingDischarge = false
    public var topUpActive = false
    public var calibration: CalibrationPhase = .idle
    /// Which keys were discovered — shown in diagnostics.
    public var inhibitKeys: [String] = []
    public var dischargeKey: String?
    /// Lid shut right now — charge-control writes are held off (see `Lid`).
    public var lidClosed = false
    /// EDID names of attached external displays. Non-empty = forced discharge
    /// is unavailable, because cutting the adapter can drop their link or
    /// power (see `ExternalDisplay`).
    public var externalDisplays: [String] = []
    /// True when a monitor is attached but didn't publish a usable name.
    public var externalDisplayAttached = false
    /// Set when a wanted change was deliberately NOT written, and why.
    public var heldOffReason: String?
    public init() {}

    /// Tolerant decoding — see the note on `ControlStatus.init(from:)`. A
    /// helper that predates a field must degrade, not sink the whole payload.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent(BatterySettings.self, forKey: .settings) ?? BatterySettings()
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        dischargeSupported = try c.decodeIfPresent(Bool.self, forKey: .dischargeSupported) ?? false
        ledSupported = try c.decodeIfPresent(Bool.self, forKey: .ledSupported) ?? false
        chargingInhibited = try c.decodeIfPresent(Bool.self, forKey: .chargingInhibited) ?? false
        forcingDischarge = try c.decodeIfPresent(Bool.self, forKey: .forcingDischarge) ?? false
        topUpActive = try c.decodeIfPresent(Bool.self, forKey: .topUpActive) ?? false
        calibration = try c.decodeIfPresent(CalibrationPhase.self, forKey: .calibration) ?? .idle
        inhibitKeys = try c.decodeIfPresent([String].self, forKey: .inhibitKeys) ?? []
        dischargeKey = try c.decodeIfPresent(String.self, forKey: .dischargeKey)
        lidClosed = try c.decodeIfPresent(Bool.self, forKey: .lidClosed) ?? false
        externalDisplays = try c.decodeIfPresent([String].self, forKey: .externalDisplays) ?? []
        externalDisplayAttached = try c.decodeIfPresent(Bool.self, forKey: .externalDisplayAttached) ?? false
        heldOffReason = try c.decodeIfPresent(String.self, forKey: .heldOffReason)
    }
}
