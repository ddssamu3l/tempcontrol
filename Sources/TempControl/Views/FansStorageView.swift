import SwiftUI
import Shared
import Dashboard

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
                    Sparkline(values: store.history.fanRPM,
                              maxValue: store.snap.fans.map(\.maxRPM).max(),
                              color: TUI.fan)
                        .frame(height: 26)
                        .frame(maxWidth: .infinity)
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
            Text(Fmt.rpmPadded(fan.actualRPM))
                .font(TUI.mono(11, .semibold))
                .foregroundStyle(boosting ? TUI.amber : TUI.fg)
                .frame(width: 68, alignment: .trailing)
            HBar(fraction: frac, color: boosting ? TUI.amber : TUI.fan, height: 7)
            Text(Fmt.rpmRange(fan.minRPM, fan.maxRPM))
                .font(TUI.mono(8))
                .foregroundStyle(TUI.faint)
                .frame(width: 66, alignment: .trailing)
        }
    }
}
