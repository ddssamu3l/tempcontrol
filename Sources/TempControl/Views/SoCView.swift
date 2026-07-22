import SwiftUI
import Shared

/// CPU + GPU + unified memory presented as ONE box, because on Apple Silicon
/// they are one piece of silicon sharing one memory pool and one power budget.
/// The POWER row at the bottom shows how the shared budget is being split.
struct SoCView: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        BoxSection(title: "SOC ─ \(store.sysInfo.chipName.uppercased())", accent: TUI.fg) {
            VStack(alignment: .leading, spacing: 10) {
                CPUSection()
                divider
                GPUSection()
                divider
                MemorySection()
                if store.snap.pm != nil {
                    divider
                    PowerRow()
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(TUI.grid).frame(height: 1)
    }
}

// MARK: CPU

struct CPUSection: View {
    @EnvironmentObject var store: MetricsStore

    /// Per-core frequency from powermetrics, keyed by core ID (helper only).
    private var coreFreqs: [Int: Double] {
        guard let pm = store.snap.pm else { return [:] }
        var out: [Int: Double] = [:]
        for cluster in pm.clusters {
            for core in cluster.cores { out[core.id] = core.freqMHz }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                StatCell(label: "CPU",
                         value: String(format: "%3.0f%%", store.snap.totalLoad * 100),
                         color: TUI.cpu)
                StatCell(label: "POWER",
                         value: store.snap.pm?.cpuPowerW.map { String(format: "%.1fW", $0) } ?? "-",
                         color: TUI.fg)
                Spacer()
                Sparkline(values: store.history.cpu, maxValue: 1, color: TUI.cpu)
                    .frame(width: 240, height: 26)
            }

            let loads = store.snap.coreLoads
            let freqs = coreFreqs
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                      alignment: .leading, spacing: 3) {
                ForEach(Array(loads.enumerated()), id: \.offset) { id, load in
                    CoreRow(id: id,
                            isP: store.sysInfo.isPCore(id),
                            load: load,
                            freqMHz: freqs[id])
                }
            }

            // M1/M2-era chips name their sensors per block (pACC/eACC/GPU);
            // M3+ exposes anonymous die sensors ("PMU tdieN") that land in SOC.
            if store.snap.sensors.contains(where: { $0.group == .pCore || $0.group == .eCore }) {
                SensorStrips(groups: [.pCore, .eCore])
            } else {
                SensorStrips(groups: [.soc], label: "DIE °C")
            }
        }
    }
}

struct CoreRow: View {
    let id: Int
    let isP: Bool
    let load: Double
    let freqMHz: Double?

    var body: some View {
        HStack(spacing: 5) {
            Text("\(isP ? "P" : "E")\(String(format: "%02d", id))")
                .font(TUI.mono(9))
                .foregroundStyle(isP ? TUI.cpu : TUI.dim)
                .frame(width: 22, alignment: .leading)
            HBar(fraction: load, color: TUI.loadColor(load), height: 7)
            Text(String(format: "%3.0f", load * 100))
                .font(TUI.mono(9))
                .foregroundStyle(TUI.fg)
                .frame(width: 22, alignment: .trailing)
            Text(freqMHz.map { String(format: "%4.2fG", $0 / 1000) } ?? "  -  ")
                .font(TUI.mono(9))
                .foregroundStyle(TUI.dim)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// Rows of per-sensor die temperatures, grouped (P-cores / E-cores / GPU / SoC).
struct SensorStrips: View {
    @EnvironmentObject var store: MetricsStore
    let groups: [TempSensor.Group]
    var label: String?

    var body: some View {
        let sensors = store.snap.sensors
        let hottest = store.snap.hottest
        VStack(alignment: .leading, spacing: 3) {
            ForEach(groups, id: \.self) { group in
                let inGroup = sensors.filter { $0.group == group }
                if !inGroup.isEmpty {
                    HStack(alignment: .top, spacing: 3) {
                        Text(label ?? group.rawValue)
                            .font(TUI.mono(9))
                            .foregroundStyle(TUI.dim)
                            .frame(width: 52, alignment: .leading)
                            .padding(.top, 2)
                        // Adaptive grid wraps on chips with many sensors (Max/Ultra).
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 24), spacing: 3)],
                                  alignment: .leading, spacing: 3) {
                            ForEach(inGroup) { s in
                                HeatCell(temp: s.celsius, hottest: s.celsius == hottest)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: GPU

struct GPUSection: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                StatCell(label: "GPU",
                         value: store.snap.gpu.deviceUtil.map { String(format: "%3.0f%%", $0 * 100) } ?? "  -",
                         color: TUI.gpu)
                Spacer()
                Sparkline(values: store.history.gpu, maxValue: 1, color: TUI.gpu)
                    .frame(width: 240, height: 26)
            }
            HStack(spacing: 18) {
                if let util = store.snap.gpu.deviceUtil {
                    HBar(fraction: util, color: TUI.gpu, height: 7).frame(width: 120)
                }
                StatCell(label: "FREQ",
                         value: store.snap.pm?.gpuFreqMHz.map { String(format: "%.0fMHz", $0) } ?? "-",
                         color: TUI.fg)
                StatCell(label: "POWER",
                         value: store.snap.pm?.gpuPowerW.map { String(format: "%.1fW", $0) } ?? "-",
                         color: TUI.fg)
                StatCell(label: "MEM USED",
                         value: store.snap.gpu.inUseMemB.map(formatBytes) ?? "-",
                         color: TUI.fg)
            }
            SensorStrips(groups: [.gpu])
        }
    }
}

// MARK: Unified memory

struct MemorySection: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        let m = store.snap.mem
        let total = max(Double(m.totalB), 1)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                StatCell(label: "UNIFIED MEMORY (CPU+GPU SHARED)",
                         value: "\(formatBytes(m.usedB)) / \(formatBytes(m.totalB))",
                         color: TUI.mem)
                Spacer()
                if m.swapUsedB > 0 {
                    StatCell(label: "SWAP", value: formatBytes(m.swapUsedB), color: TUI.amber)
                }
                StatCell(label: "PRESSURE",
                         value: pressureText,
                         color: pressureColor)
            }
            // Segmented like Activity Monitor: app / wired / compressed.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(TUI.mem)
                        .frame(width: geo.size.width * CGFloat(Double(m.appB) / total))
                    Rectangle().fill(TUI.amber)
                        .frame(width: geo.size.width * CGFloat(Double(m.wiredB) / total))
                    Rectangle().fill(TUI.gpu)
                        .frame(width: geo.size.width * CGFloat(Double(m.compressedB) / total))
                    Rectangle().fill(Color(white: 0.09))
                }
            }
            .frame(height: 9)
            HStack(spacing: 14) {
                legend("APP", formatBytes(m.appB), TUI.mem)
                legend("WIRED", formatBytes(m.wiredB), TUI.amber)
                legend("COMPRESSED", formatBytes(m.compressedB), TUI.gpu)
            }
        }
    }

    private func legend(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(color).frame(width: 7, height: 7)
            Text("\(label) \(value)").font(TUI.mono(9)).foregroundStyle(TUI.dim)
        }
    }

    private var pressureText: String {
        switch store.snap.mem.pressureLevel {
        case 4: return "CRIT"
        case 2: return "WARN"
        default: return "OK"
        }
    }

    private var pressureColor: Color {
        switch store.snap.mem.pressureLevel {
        case 4: return TUI.red
        case 2: return TUI.amber
        default: return TUI.mem
        }
    }
}

// MARK: Shared power budget (helper only)

struct PowerRow: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        HStack(spacing: 18) {
            StatCell(label: "CPU PWR",
                     value: store.snap.pm?.cpuPowerW.map { String(format: "%.1fW", $0) } ?? "-")
            StatCell(label: "GPU PWR",
                     value: store.snap.pm?.gpuPowerW.map { String(format: "%.1fW", $0) } ?? "-")
            StatCell(label: "ANE PWR",
                     value: store.snap.pm?.anePowerW.map { String(format: "%.1fW", $0) } ?? "-")
            StatCell(label: "PACKAGE",
                     value: store.snap.pm?.combinedPowerW.map { String(format: "%.1fW", $0) } ?? "-",
                     color: TUI.amber)
            Spacer()
            Sparkline(values: store.history.power, maxValue: nil, color: TUI.amber)
                .frame(width: 120, height: 22)
        }
    }
}
