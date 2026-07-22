import Foundation
import CShims

public struct TempSensor: Identifiable {
    public enum Group: String, CaseIterable {
        case pCore = "P-CORES"
        case eCore = "E-CORES"
        case gpu = "GPU"
        case soc = "SOC"
        case other = "OTHER"
    }
    public var id: String { name }
    public let name: String
    public let celsius: Double
    public let group: Group
    public let isDie: Bool
}

/// Reads the Apple Silicon die temperature sensors through the private
/// IOHID sensor interface. Works without root.
public final class HIDSensors {
    private var client: IOHIDEventSystemClient?

    public init() {
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        let match: [String: Int] = [
            "PrimaryUsagePage": Int(kShimHIDVendorTempUsagePage),
            "PrimaryUsage": Int(kShimHIDVendorTempUsage),
        ]
        _ = IOHIDEventSystemClientSetMatching(c, match as CFDictionary)
        client = c
    }

    public func read() -> [TempSensor] {
        guard let client,
              let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]
        else { return [] }

        // The same physical sensor often shows up as several HID services;
        // collect every reading per name and average them.
        var byName: [String: [Double]] = [:]
        for service in services {
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
                  let event = IOHIDServiceClientCopyEvent(service, Int64(kShimHIDEventTypeTemperature), 0, 0)
            else { continue }
            let temp = IOHIDEventGetFloatValue(event, Int32(kShimHIDTemperatureField))
            guard temp > -40, temp < 130 else { continue }
            byName[name, default: []].append(temp)
        }

        return byName
            .map { name, temps in Self.classify(name: name, celsius: temps.reduce(0, +) / Double(temps.count)) }
            .sorted { naturalKey($0.name).lexicographicallyPrecedes(naturalKey($1.name)) { cmp($0, $1) } }
    }

    // Natural sort so "tdie2" comes before "tdie10".
    private enum Chunk: Equatable { case num(Int), text(String) }
    private func naturalKey(_ s: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var digits = ""
        var text = ""
        func flush() {
            if !digits.isEmpty { chunks.append(.num(Int(digits) ?? 0)); digits = "" }
            if !text.isEmpty { chunks.append(.text(text)); text = "" }
        }
        for ch in s {
            if ch.isNumber {
                if !text.isEmpty { flush() }
                digits.append(ch)
            } else {
                if !digits.isEmpty { flush() }
                text.append(ch)
            }
        }
        flush()
        return chunks
    }
    private func cmp(_ a: Chunk, _ b: Chunk) -> Bool {
        switch (a, b) {
        case let (.num(x), .num(y)): return x < y
        case let (.text(x), .text(y)): return x < y
        case (.num, .text): return true
        case (.text, .num): return false
        }
    }

    /// Hottest sensor that is actually on the SoC die — this is what the
    /// fan controller regulates against ("hottest sensor" per spec).
    public func hottestDie() -> Double? {
        read().filter(\.isDie).map(\.celsius).max()
    }

    /// Sensor names differ across M1–M4 generations; match loosely.
    /// Die sensors carry names like "pACC MTR Temp Sensor4", "eACC MTR Temp
    /// Sensor0", "GPU MTR Temp Sensor1", "SOC MTR Temp Sensor2", "PMU tdie...",
    /// "PMGR SOC Die Temp Sensor". Battery/NAND/etc. are not die sensors.
    static func classify(name: String, celsius: Double) -> TempSensor {
        let lower = name.lowercased()
        let group: TempSensor.Group
        var isDie = true

        if lower.contains("pacc") {
            group = .pCore
        } else if lower.contains("eacc") {
            group = .eCore
        } else if lower.contains("gpu") {
            group = .gpu
        } else if lower.contains("soc") || lower.contains("tdie") || lower.contains("ane") || lower.contains("pmgr") {
            group = .soc
        } else {
            group = .other
            isDie = false
        }
        return TempSensor(name: name, celsius: celsius, group: group, isDie: isDie)
    }
}
