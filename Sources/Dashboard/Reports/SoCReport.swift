import Foundation
import Shared

/// Mirrors the SOC tab (`Views/SoCView.swift`: CPUSection, GPUSection,
/// MemorySection, PowerRow) — CPU, GPU and unified memory reported as one
/// piece of silicon sharing one memory pool and one power budget.
public enum SoCReport: PanelReporting {
    public static let panel = Panel.soc

    public static func sections(_ s: Snapshot, _ sys: SystemInfo) -> [ReportSection] {
        var out = [cpu(s, sys), gpu(s), memory(s)]
        // The app only draws the power row when powermetrics data exists.
        if s.pm != nil { out.append(power(s)) }
        return out
    }

    // MARK: CPU

    private static func cpu(_ s: Snapshot, _ sys: SystemInfo) -> ReportSection {
        // Per-core frequency comes from powermetrics (helper only), keyed by core ID.
        var freqs: [Int: Double] = [:]
        var actives: [Int: Double] = [:]
        for cluster in s.pm?.clusters ?? [] {
            for core in cluster.cores {
                freqs[core.id] = core.freqMHz
                actives[core.id] = core.activeRatio
            }
        }

        var rows: [ReportRow] = [
            .text("CHIP", sys.chipName.uppercased()),
            .text("CORES", "\(sys.pCores)P + \(sys.eCores)E (\(sys.totalCores) TOTAL)"),
            .fraction("CPU", s.totalLoad),
            .watts("POWER", s.pm?.cpuPowerW),
        ]

        for cluster in s.pm?.clusters ?? [] {
            rows.append(ReportRow("CLUSTER \(cluster.name.uppercased())",
                                  "\(Fmt.percent(cluster.activeRatio))  \(Fmt.mhz(cluster.freqMHz))",
                                  raw: cluster.activeRatio * 100, unit: "%"))
        }

        for (id, load) in s.coreLoads.enumerated() {
            let name = "\(sys.isPCore(id) ? "P" : "E")\(String(format: "%02d", id))"
            let freq = freqs[id].map(Fmt.ghz(fromMHz:)) ?? "  -  "
            let active = actives[id].map { "  ACTIVE \(Fmt.percent($0))" } ?? ""
            rows.append(ReportRow(name,
                                  "\(Fmt.percentPadded(load))  \(freq)\(active)",
                                  raw: load * 100, unit: "%"))
        }

        // M1/M2-era chips name their sensors per block (pACC/eACC); M3+ exposes
        // anonymous die sensors ("PMU tdieN") that classify as SOC. Same
        // fallback the app uses so both surfaces show the same strip.
        let perBlock = s.sensors.contains { $0.group == .pCore || $0.group == .eCore }
        rows += sensorRows(s, groups: perBlock ? [.pCore, .eCore] : [.soc],
                           label: perBlock ? nil : "DIE °C")

        return ReportSection("CPU", rows)
    }

    // MARK: GPU

    private static func gpu(_ s: Snapshot) -> ReportSection {
        var rows: [ReportRow] = [
            .fraction("GPU", s.gpu.deviceUtil),
            .fraction("DEVICE", s.gpu.deviceUtil),
            .fraction("RENDERER", s.gpu.rendererUtil),
            .fraction("TILER", s.gpu.tilerUtil),
            .optional("FREQ", s.pm?.gpuFreqMHz, Fmt.mhz, unit: "MHz"),
            .watts("POWER", s.pm?.gpuPowerW),
            .bytes("MEM USED", s.gpu.inUseMemB),
            .bytes("MEM ALLOC", s.gpu.allocMemB),
            .int("GPU CORES", s.gpu.coreCount),
        ]
        if let active = s.pm?.gpuActiveRatio {
            rows.append(.fraction("ACTIVE RESIDENCY", active))
        }
        rows += sensorRows(s, groups: [.gpu], label: nil)

        return ReportSection("GPU", rows,
                             note: "APPLE EXPOSES THE GPU AS ONE BLOCK — PER-CORE GPU LOAD/TEMP DOESN'T EXIST ON ANY APP")
    }

    // MARK: unified memory

    private static func memory(_ s: Snapshot) -> ReportSection {
        let m = s.mem
        let usedFrac = m.totalB > 0 ? Double(m.usedB) / Double(m.totalB) : 0
        let rows: [ReportRow] = [
            ReportRow("UNIFIED MEMORY", "\(Fmt.bytes(m.usedB)) / \(Fmt.bytes(m.totalB))",
                      raw: Double(m.usedB), unit: "B"),
            .fraction("USED", usedFrac),
            .bytes("APP", m.appB),
            .bytes("WIRED", m.wiredB),
            .bytes("COMPRESSED", m.compressedB),
            .bytes("SWAP", m.swapUsedB),
            ReportRow("PRESSURE", pressureText(m.pressureLevel),
                      raw: Double(m.pressureLevel), unit: "level"),
        ]
        return ReportSection("UNIFIED MEMORY", rows,
                             note: "CPU AND GPU SHARE THIS POOL — THE SPLIT IS APP / WIRED / COMPRESSED")
    }

    private static func pressureText(_ level: Int) -> String {
        switch level {
        case 4: return "CRIT"
        case 2: return "WARN"
        default: return "OK"
        }
    }

    // MARK: shared power budget (helper only)

    private static func power(_ s: Snapshot) -> ReportSection {
        let rows: [ReportRow] = [
            .watts("CPU PWR", s.pm?.cpuPowerW),
            .watts("GPU PWR", s.pm?.gpuPowerW),
            .watts("ANE PWR", s.pm?.anePowerW),
            // socPowerW, not combinedPowerW: combined_power isn't reported on
            // every chip/OS combo and falls back to summing the blocks.
            .watts("PACKAGE", s.pm?.socPowerW),
            .watts("SYSTEM (SMC)", s.systemPowerW),
            .text("THERMAL PRESSURE", s.pm?.thermalPressure?.uppercased() ?? Fmt.none),
        ]
        return ReportSection("POWER", rows,
                             note: "ONE BUDGET SHARED BY CPU, GPU AND ANE — POWERMETRICS VIA THE ROOT HELPER")
    }

    // MARK: die sensor strips

    /// One row per sensor plus a per-group summary, matching the heat strips
    /// the app draws for the same groups.
    private static func sensorRows(_ s: Snapshot,
                                   groups: [TempSensor.Group],
                                   label: String?) -> [ReportRow] {
        var rows: [ReportRow] = []
        for group in groups {
            let inGroup = s.sensors.filter { $0.group == group }
            guard !inGroup.isEmpty else { continue }
            let temps = inGroup.map(\.celsius)
            let max = temps.max() ?? 0
            let avg = temps.reduce(0, +) / Double(temps.count)
            rows.append(ReportRow(label ?? group.rawValue,
                                  "MAX \(Fmt.temp(max))  AVG \(Fmt.temp(avg))  (\(inGroup.count) SENSORS)",
                                  raw: max, unit: "C"))
            for sensor in inGroup {
                rows.append(ReportRow("  \(sensor.name.uppercased())",
                                      Fmt.temp(sensor.celsius),
                                      raw: sensor.celsius, unit: "C"))
            }
        }
        return rows
    }
}
