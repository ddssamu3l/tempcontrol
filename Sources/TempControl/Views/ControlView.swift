import SwiftUI
import Shared

/// The TEMP tab — the app's default view. Layout is deliberate:
/// live temperature FIRST (big, colored), then the target controls (dial
/// clearly labeled as the SET target, with the live temp marked on the same
/// arc), then die sensors and fans.
struct TempPanel: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        VStack(spacing: 8) {
            ChipTempBox()
            TempControlBox()
            FansView()
            BatteryTempBox()
        }
    }
}

/// Battery temperature in its own section: the pack heats from charging and
/// chassis heat, ages faster hot, and is the other thing cooling protects.
struct BatteryTempBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        BoxSection(title: "BATTERY TEMP", accent: TUI.mem) {
            let temp = store.snap.battery?.temperatureC
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 18) {
                    StatCell(label: "NOW",
                             value: temp.map { String(format: "%.1f°C", $0) } ?? "-",
                             color: batteryTempColor(temp))
                    StatCell(label: "SAFE RANGE", value: "<35°C IDEAL", color: TUI.dim)
                    if store.batterySettings.enabled && store.batterySettings.heatProtect {
                        StatCell(label: "HEAT PROTECT",
                                 value: "PAUSES CHARGE >\(Int(store.batterySettings.heatLimitC))°C",
                                 color: TUI.mem)
                    }
                    Spacer()
                }
                Sparkline(values: store.history.batteryTemp,
                          maxValue: max(45, (store.history.batteryTemp.max() ?? 0) + 3),
                          color: TUI.mem,
                          refValue: store.batterySettings.enabled && store.batterySettings.heatProtect
                              ? store.batterySettings.heatLimitC : nil,
                          refColor: TUI.red)
                    .frame(height: 28)
            }
        }
    }

    private func batteryTempColor(_ t: Double?) -> Color {
        guard let t else { return TUI.dim }
        if t > 40 { return TUI.red }
        if t > 35 { return TUI.amber }
        return TUI.mem
    }
}

// MARK: live temperature (first, so "what is it NOW" is never ambiguous)

struct ChipTempBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        let now = store.snap.hottest
        let target = store.desiredEnabled ? store.desiredTarget : nil
        BoxSection(title: "CHIP TEMP — LIVE", accent: now.map(TUI.tempColor) ?? TUI.dim) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("NOW").font(TUI.mono(9)).foregroundStyle(TUI.dim)
                        Text(now.map { String(format: "%.1f°C", $0) } ?? "-")
                            .font(TUI.mono(26, .bold))
                            .foregroundStyle(now.map(TUI.tempColor) ?? TUI.dim)
                    }
                    StatCell(label: "TARGET",
                             value: target.map { "\(Int($0))°C" } ?? "OFF",
                             color: target != nil ? TUI.amber : TUI.dim)
                    if let now, let target {
                        StatCell(label: "DELTA", value: deltaText(now - target),
                                 color: deltaColor(now - target))
                    }
                    StatCell(label: "AVG DIE",
                             value: avgDie.map { String(format: "%.1f°C", $0) } ?? "-",
                             color: TUI.dim)
                    if let pressure = store.snap.pm?.thermalPressure {
                        StatCell(label: "THERMAL",
                                 value: pressure.uppercased(),
                                 color: pressure == "Nominal" ? TUI.mem : TUI.red)
                    }
                    Spacer()
                }
                Sparkline(values: store.history.temp,
                          maxValue: max(store.history.temp.max() ?? 0, (target ?? 0) + 8, 60),
                          color: now.map(TUI.tempColor) ?? TUI.dim,
                          refValue: target)
                    .frame(height: 42)
                Text(target != nil
                     ? "─ HOTTEST DIE SENSOR   ┄ YOUR TARGET"
                     : "─ HOTTEST DIE SENSOR (LAST 2 MIN)")
                    .font(TUI.mono(8)).foregroundStyle(TUI.faint)
            }
        }
    }

    private var avgDie: Double? {
        let die = store.snap.sensors.filter(\.isDie).map(\.celsius)
        return die.isEmpty ? nil : die.reduce(0, +) / Double(die.count)
    }

    private func deltaText(_ d: Double) -> String {
        if abs(d) <= TC.deadband { return "IN BAND" }
        return String(format: "%+.1f°C", d)
    }

    private func deltaColor(_ d: Double) -> Color {
        if abs(d) <= TC.deadband { return TUI.mem }
        return d > 0 ? TUI.red : TUI.cpu
    }
}

// MARK: target + mode controls

struct TempControlBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        BoxSection(title: "TEMP CONTROL", accent: TUI.amber) {
            if !store.snap.helperAvailable {
                VStack(alignment: .leading, spacing: 5) {
                    Text("HELPER NOT RUNNING")
                        .font(TUI.mono(11, .bold)).foregroundStyle(TUI.red)
                    Text("Fan control and per-core frequency need the root helper.\nInstall it from the repo:  ./scripts/install.sh")
                        .font(TUI.mono(10)).foregroundStyle(TUI.dim)
                }
            } else if store.snap.fanCount == 0 {
                Text("THIS MAC HAS NO FANS — TEMPERATURE CONTROL IS NOT POSSIBLE.\nDASHBOARD REMAINS FULLY FUNCTIONAL.")
                    .font(TUI.mono(10)).foregroundStyle(TUI.dim)
            } else {
                controls
            }
        }
    }

    @ViewBuilder private var controls: some View {
        let control = store.snap.control
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TUIButton(label: "[ MACOS DEFAULT ]",
                          active: !store.desiredEnabled,
                          activeColor: TUI.mem) {
                    guard store.desiredEnabled else { return }
                    store.desiredEnabled = false
                    store.pushControl()
                }
                TUIButton(label: "[ MAX COOLING ]",
                          active: store.desiredEnabled,
                          activeColor: TUI.amber) {
                    guard !store.desiredEnabled else { return }
                    store.desiredEnabled = true
                    store.pushControl()
                }
                Spacer()
                TUIButton(label: "[ LOW POWER MODE ]",
                          active: control?.lowPowerMode == true,
                          activeColor: TUI.mem) {
                    store.setLowPower(!(control?.lowPowerMode ?? false))
                }
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 4) {
                    TempDial(value: $store.desiredTarget,
                             current: store.snap.hottest) { store.pushControl() }
                        .opacity(store.desiredEnabled ? 1 : 0.4)
                    Text("○ TARGET (DRAG)   ● NOW")
                        .font(TUI.mono(8)).foregroundStyle(TUI.faint)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        StatCell(label: "FANS DRIVEN BY", value: modeText, color: modeColor)
                        StatCell(label: "FAN CMD",
                                 value: control?.commandedRPM.map { String(format: "%.0f RPM", $0) } ?? "-",
                                 color: TUI.fan)
                        StatCell(label: "FAN LEVEL",
                                 value: control?.fanLevel.map { String(format: "%.0f%%", $0 * 100) } ?? "-",
                                 color: TUI.fan)
                    }
                    if control?.atMax == true {
                        Text("FANS AT 100% AND STILL OVER TARGET — THIS WORKLOAD MAY\nNOT BE HOLDABLE AT \(Int(store.desiredTarget))°C. RAISE THE TARGET OR REDUCE LOAD.")
                            .font(TUI.mono(8, .bold)).foregroundStyle(TUI.red)
                    }
                    Text(store.desiredEnabled
                         ? "HOLDING THE CHIP AT \(Int(store.desiredTarget))°C: SPIKES GET AN INSTANT\nKICK, THEN THE CONTROLLER LEARNS THE STEADY FAN SPEED THAT\nHOLDS YOUR TARGET AND SITS THERE."
                         : "MACOS IS CONTROLLING THE FANS AS USUAL —\nTEMPCONTROL IS ONLY MONITORING.")
                        .font(TUI.mono(8))
                        .foregroundStyle(store.desiredEnabled ? TUI.amber : TUI.dim)
                    if store.desiredEnabled {
                        ControlActivityView(temps: store.history.temp,
                                            fanLevels: store.history.fanLevel,
                                            target: store.desiredTarget)
                            .frame(height: 48)
                        Text("─ CHIP TEMP   ┄ TARGET   ▒ FAN LEVEL\nFANS FLATTEN OUT AS TEMP LOCKS ONTO THE TARGET")
                            .font(TUI.mono(8)).foregroundStyle(TUI.faint)
                    }
                }
            }
        }
    }

    private var modeText: String {
        guard store.desiredEnabled else { return "MACOS" }
        return store.snap.control?.engaged == true ? "TEMPCONTROL" : "MACOS (IN BAND)"
    }

    private var modeColor: Color {
        guard store.desiredEnabled else { return TUI.mem }
        return store.snap.control?.engaged == true ? TUI.amber : TUI.mem
    }
}

/// 270° drag dial for the TARGET temperature. The white ring/knob is the
/// target you set; the small colored dot is the live temp on the same scale,
/// so the two can never be confused for each other.
struct TempDial: View {
    @Binding var value: Double
    var current: Double?
    var onCommit: () -> Void

    private let range = TC.targetRange
    private let startAngle = 135.0
    private let sweep = 270.0
    private let size: CGFloat = 132

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Canvas { ctx, canvasSize in
                    let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    let r = min(canvasSize.width, canvasSize.height) / 2 - 8

                    func arc(_ from: Double, _ to: Double) -> Path {
                        var p = Path()
                        p.addArc(center: c, radius: r,
                                 startAngle: .degrees(from), endAngle: .degrees(to),
                                 clockwise: false)
                        return p
                    }

                    ctx.stroke(arc(startAngle, startAngle + sweep),
                               with: .color(Color(white: 0.14)),
                               style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                    let f = fraction(of: value)
                    ctx.stroke(arc(startAngle, startAngle + sweep * f),
                               with: .linearGradient(
                                   Gradient(colors: [TUI.mem, TUI.amber, TUI.red]),
                                   startPoint: CGPoint(x: 0, y: canvasSize.height),
                                   endPoint: CGPoint(x: canvasSize.width, y: 0)),
                               style: StrokeStyle(lineWidth: 7, lineCap: .butt))

                    var t = range.lowerBound
                    while t <= range.upperBound {
                        let a = Angle.degrees(startAngle + sweep * fraction(of: t)).radians
                        var tick = Path()
                        tick.move(to: CGPoint(x: c.x + cos(a) * (r + 4), y: c.y + sin(a) * (r + 4)))
                        tick.addLine(to: CGPoint(x: c.x + cos(a) * (r + 7), y: c.y + sin(a) * (r + 7)))
                        ctx.stroke(tick, with: .color(TUI.dim), lineWidth: 1)
                        t += 5
                    }

                    // Live temperature marker (inside the track, colored).
                    if let current {
                        let cf = fraction(of: min(max(current, range.lowerBound), range.upperBound))
                        let ca = Angle.degrees(startAngle + sweep * cf).radians
                        let p = CGPoint(x: c.x + cos(ca) * (r - 11), y: c.y + sin(ca) * (r - 11))
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)),
                                 with: .color(TUI.tempColor(current)))
                    }

                    // Target knob (white, on the track).
                    let ka = Angle.degrees(startAngle + sweep * f).radians
                    let knob = CGPoint(x: c.x + cos(ka) * r, y: c.y + sin(ka) * r)
                    ctx.stroke(Path(ellipseIn: CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10)),
                               with: .color(TUI.fg), lineWidth: 2)
                }
                VStack(spacing: 0) {
                    Text("SET TARGET")
                        .font(TUI.mono(8)).foregroundStyle(TUI.dim)
                    Text("\(Int(value))°C")
                        .font(TUI.mono(22, .bold)).foregroundStyle(TUI.amber)
                    if let current {
                        Text(String(format: "NOW %.0f°", current))
                            .font(TUI.mono(9))
                            .foregroundStyle(TUI.tempColor(current))
                    }
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let c = CGPoint(x: size / 2, y: size / 2)
                        var deg = atan2(g.location.y - c.y, g.location.x - c.x) * 180 / .pi
                        deg = (deg - startAngle + 360).truncatingRemainder(dividingBy: 360)
                        guard deg <= sweep + 30 else { return }
                        let f = min(1, max(0, deg / sweep))
                        value = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
                    }
                    .onEnded { _ in onCommit() }
            )
        }
    }

    private func fraction(of v: Double) -> Double {
        (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}

/// Live controller activity: chip temp (line, own scale, dashed target) over
/// fan level (filled area, 0–100%) on one timeline — the cause-and-effect
/// view of the PI loop doing its job.
struct ControlActivityView: View {
    let temps: [Double]
    let fanLevels: [Double]
    let target: Double

    var body: some View {
        Canvas { ctx, size in
            let stepX = size.width / CGFloat(History.capacity - 1)

            // Fan level: filled area on a fixed 0...1 scale.
            if fanLevels.count > 1 {
                let startX = size.width - CGFloat(fanLevels.count - 1) * stepX
                var fill = Path()
                fill.move(to: CGPoint(x: startX, y: size.height))
                for (i, v) in fanLevels.enumerated() {
                    let x = startX + CGFloat(i) * stepX
                    let y = size.height - CGFloat(min(max(v, 0), 1)) * (size.height - 2) - 1
                    fill.addLine(to: CGPoint(x: x, y: y))
                }
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(TUI.fan.opacity(0.28)))
            }

            // Temp: line on its own scale, window sized to include the target.
            let visible = temps.filter { $0 > 0 }
            if visible.count > 1 {
                let lo = min(visible.min() ?? target, target) - 3
                let hi = max(visible.max() ?? target, target) + 3
                let span = max(hi - lo, 1)
                func y(_ t: Double) -> CGFloat {
                    size.height - CGFloat((t - lo) / span) * (size.height - 4) - 2
                }
                let startX = size.width - CGFloat(temps.count - 1) * stepX
                var line = Path()
                var started = false
                for (i, t) in temps.enumerated() where t > 0 {
                    let p = CGPoint(x: startX + CGFloat(i) * stepX, y: y(t))
                    if started { line.addLine(to: p) } else { line.move(to: p); started = true }
                }
                ctx.stroke(line, with: .color(TUI.amber), lineWidth: 1.2)

                var ref = Path()
                ref.move(to: CGPoint(x: 0, y: y(target)))
                ref.addLine(to: CGPoint(x: size.width, y: y(target)))
                ctx.stroke(ref, with: .color(TUI.fg.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .background(Color(white: 0.04))
        .overlay(Rectangle().strokeBorder(TUI.grid, lineWidth: 1))
    }
}
