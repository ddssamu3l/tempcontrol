import SwiftUI
import Shared

struct FansView: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        BoxSection(title: "FANS", accent: TUI.fan) {
            if store.snap.fanCount == 0 {
                Text("FANLESS MAC — PASSIVE COOLING ONLY, FAN CONTROL UNAVAILABLE")
                    .font(TUI.mono(10))
                    .foregroundStyle(TUI.dim)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.snap.fans) { fan in
                        FanRow(fan: fan, boosting: store.snap.control?.engaged == true)
                    }
                    HStack {
                        Spacer()
                        Sparkline(values: store.history.fanRPM,
                                  maxValue: store.snap.fans.map(\.maxRPM).max(),
                                  color: TUI.fan)
                            .frame(width: 240, height: 22)
                    }
                }
            }
        }
    }
}

struct FanRow: View {
    let fan: FanState
    let boosting: Bool

    var body: some View {
        let span = max(fan.maxRPM - fan.minRPM, 1)
        let frac = (fan.actualRPM - fan.minRPM) / span
        HStack(spacing: 8) {
            Text("FAN\(fan.id)")
                .font(TUI.mono(9))
                .foregroundStyle(TUI.dim)
                .frame(width: 32, alignment: .leading)
            Text(String(format: "%4.0f RPM", fan.actualRPM))
                .font(TUI.mono(11, .semibold))
                .foregroundStyle(boosting ? TUI.amber : TUI.fg)
                .frame(width: 68, alignment: .trailing)
            HBar(fraction: frac, color: boosting ? TUI.amber : TUI.fan, height: 7)
            Text(String(format: "%.0f–%.0f", fan.minRPM, fan.maxRPM))
                .font(TUI.mono(8))
                .foregroundStyle(TUI.faint)
                .frame(width: 66, alignment: .trailing)
        }
    }
}

struct StorageView: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        BoxSection(title: "STORAGE", accent: TUI.fan) {
            let d = store.snap.disk
            let used = max(0, d.totalB - d.freeB)
            let frac = d.totalB > 0 ? Double(used) / Double(d.totalB) : 0
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    StatCell(label: "SSD",
                             value: "\(formatBytes(used)) / \(formatBytes(d.totalB))")
                    Spacer()
                    StatCell(label: "READ", value: formatRate(d.readBps), color: TUI.mem)
                    StatCell(label: "WRITE", value: formatRate(d.writeBps), color: TUI.amber)
                }
                HBar(fraction: frac, color: frac > 0.9 ? TUI.red : TUI.fan, height: 7)
                HStack(spacing: 6) {
                    Sparkline(values: store.history.diskRead, maxValue: nil, color: TUI.mem)
                        .frame(height: 20)
                    Sparkline(values: store.history.diskWrite, maxValue: nil, color: TUI.amber)
                        .frame(height: 20)
                }
            }
        }
    }
}
