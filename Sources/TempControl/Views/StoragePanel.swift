import SwiftUI
import Shared
import Dashboard

/// The STORAGE tab — modeled on what dedicated disk monitors show:
/// capacity per volume (with purgeable), live throughput, IOPS, I/O latency,
/// cumulative traffic since boot, and drive temperature.
struct StoragePanel: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        VStack(spacing: 8) {
            CapacityBox()
            ActivityBox()
            DriveBox()
        }
    }
}

// MARK: capacity

struct CapacityBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        let d = store.snap.disk
        BoxSection(title: "CAPACITY", accent: TUI.fan) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatCell(label: "INTERNAL SSD",
                             value: "\(Fmt.bytes(max(0, d.totalB - d.freeB))) / \(Fmt.bytes(d.totalB)) USED")
                    Spacer()
                    StatCell(label: "FREE", value: Fmt.bytes(d.freeB), color: TUI.mem)
                    if d.purgeableB > 100_000_000 {
                        StatCell(label: "PURGEABLE", value: Fmt.bytes(d.purgeableB), color: TUI.dim)
                    }
                }
                ForEach(d.volumes) { vol in
                    VolumeRow(vol: vol)
                }
                Text("PURGEABLE = SPACE MACOS FREES AUTOMATICALLY (SNAPSHOTS, CACHES)")
                    .font(TUI.mono(8)).foregroundStyle(TUI.faint)
            }
        }
    }
}

struct VolumeRow: View {
    let vol: VolumeInfo

    var body: some View {
        let usedFrac = vol.totalB > 0 ? Double(vol.totalB - vol.freeB) / Double(vol.totalB) : 0
        HStack(spacing: 8) {
            Text(vol.name.uppercased())
                .font(TUI.mono(9))
                .foregroundStyle(TUI.dim)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            HBar(fraction: usedFrac, color: usedFrac > 0.9 ? TUI.red : TUI.fan, height: 8)
            Text(Fmt.percentPadded(usedFrac))
                .font(TUI.mono(9))
                .frame(width: 30, alignment: .trailing)
                .foregroundStyle(TUI.fg)
        }
    }
}

// MARK: live activity

struct ActivityBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        let d = store.snap.disk
        BoxSection(title: "I/O ACTIVITY", accent: TUI.fan) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        StatCell(label: "READ", value: Fmt.rate(d.readBps), color: TUI.mem)
                        Sparkline(values: store.history.diskRead, maxValue: nil, color: TUI.mem)
                            .frame(height: 30)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        StatCell(label: "WRITE", value: Fmt.rate(d.writeBps), color: TUI.amber)
                        Sparkline(values: store.history.diskWrite, maxValue: nil, color: TUI.amber)
                            .frame(height: 30)
                    }
                }
                HStack(spacing: 18) {
                    StatCell(label: "READ IOPS", value: Fmt.count(d.readIOPS), color: TUI.mem)
                    StatCell(label: "WRITE IOPS", value: Fmt.count(d.writeIOPS), color: TUI.amber)
                    StatCell(label: "READ LAT",
                             value: d.readLatencyMs > 0 ? Fmt.ms(d.readLatencyMs) : Fmt.none,
                             color: latColor(d.readLatencyMs))
                    StatCell(label: "WRITE LAT",
                             value: d.writeLatencyMs > 0 ? Fmt.ms(d.writeLatencyMs) : Fmt.none,
                             color: latColor(d.writeLatencyMs))
                    Spacer()
                }
            }
        }
    }

    private func latColor(_ ms: Double) -> Color {
        if ms <= 0 { return TUI.dim }
        if ms < 1 { return TUI.fg }
        if ms < 5 { return TUI.amber }
        return TUI.red
    }
}

// MARK: drive-level

struct DriveBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        let d = store.snap.disk
        BoxSection(title: "DRIVE", accent: TUI.fan) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 18) {
                    StatCell(label: "READ SINCE BOOT", value: Fmt.bytes(d.bootReadB), color: TUI.mem)
                    StatCell(label: "WRITTEN SINCE BOOT", value: Fmt.bytes(d.bootWriteB), color: TUI.amber)
                    if let nand = nandTemp {
                        StatCell(label: "NAND TEMP",
                                 value: Fmt.temp(nand),
                                 color: nand > 60 ? TUI.red : TUI.fg)
                    }
                    Spacer()
                }
                Text("WRITTEN-SINCE-BOOT IS THE NUMBER THAT WEARS SSD CELLS — SUSTAINED HEAVY WRITES MATTER MORE THAN READS")
                    .font(TUI.mono(8)).foregroundStyle(TUI.faint)
            }
        }
    }

    private var nandTemp: Double? {
        store.snap.sensors.first { $0.name.lowercased().contains("nand") }?.celsius
    }
}
