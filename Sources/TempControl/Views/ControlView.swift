import SwiftUI
import Shared

/// Performance controls: the target-temperature dial, the boost enable
/// switch, the live controller state, and low power mode.
struct ControlView: View {
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
                HStack(alignment: .top, spacing: 16) {
                    TempDial(value: $store.desiredTarget) { store.pushControl() }
                        .opacity(store.desiredEnabled ? 1 : 0.35)
                    ControlStatusPanel()
                }
            }
        }
    }
}

/// 270° drag dial, 50–95°C.
struct TempDial: View {
    @Binding var value: Double
    var onCommit: () -> Void

    private let range = TC.targetRange
    private let startAngle = 135.0   // degrees, pointing down-left
    private let sweep = 270.0

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r = min(size.width, size.height) / 2 - 8

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
                                   startPoint: CGPoint(x: 0, y: size.height),
                                   endPoint: CGPoint(x: size.width, y: 0)),
                               style: StrokeStyle(lineWidth: 7, lineCap: .butt))

                    // Tick marks every 5°C.
                    var t = range.lowerBound
                    while t <= range.upperBound {
                        let a = Angle.degrees(startAngle + sweep * fraction(of: t)).radians
                        var tick = Path()
                        tick.move(to: CGPoint(x: c.x + cos(a) * (r + 4), y: c.y + sin(a) * (r + 4)))
                        tick.addLine(to: CGPoint(x: c.x + cos(a) * (r + 7), y: c.y + sin(a) * (r + 7)))
                        ctx.stroke(tick, with: .color(TUI.dim), lineWidth: 1)
                        t += 5
                    }

                    // Knob dot at the current value.
                    let ka = Angle.degrees(startAngle + sweep * f).radians
                    let knob = CGPoint(x: c.x + cos(ka) * r, y: c.y + sin(ka) * r)
                    ctx.fill(Path(ellipseIn: CGRect(x: knob.x - 4, y: knob.y - 4, width: 8, height: 8)),
                             with: .color(TUI.fg))
                }
                VStack(spacing: 0) {
                    Text("\(Int(value))°C")
                        .font(TUI.mono(20, .bold)).foregroundStyle(TUI.fg)
                    Text("TARGET")
                        .font(TUI.mono(8)).foregroundStyle(TUI.dim)
                }
            }
            .frame(width: 120, height: 120)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let c = CGPoint(x: 60, y: 60)
                        var deg = atan2(g.location.y - c.y, g.location.x - c.x) * 180 / .pi
                        deg = (deg - startAngle + 360).truncatingRemainder(dividingBy: 360)
                        guard deg <= sweep + 30 else { return } // ignore the dead zone
                        let f = min(1, max(0, deg / sweep))
                        value = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
                    }
                    .onEnded { _ in onCommit() }
            )
            Text("±\(Int(TC.deadband))°C BAND")
                .font(TUI.mono(8)).foregroundStyle(TUI.faint)
        }
    }

    private func fraction(of v: Double) -> Double {
        (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}

struct ControlStatusPanel: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        let control = store.snap.control
        let hottest = store.snap.hottest
        VStack(alignment: .leading, spacing: 8) {
            // Explicit two-state selector: who is driving the fans?
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
            }

            Text(store.desiredEnabled
                 ? "TEMPCONTROL HOLDS THE CHIP AT \(Int(store.desiredTarget))°C —\nFANS RAMP EXPONENTIALLY HARDER THE HOTTER IT GETS"
                 : "MACOS IS CONTROLLING THE FANS AS USUAL —\nTEMPCONTROL IS ONLY MONITORING")
                .font(TUI.mono(8))
                .foregroundStyle(store.desiredEnabled ? TUI.amber : TUI.dim)

            HStack(spacing: 14) {
                StatCell(label: "HOTTEST",
                         value: hottest.map { String(format: "%.1f°C", $0) } ?? "-",
                         color: hottest.map(TUI.tempColor) ?? TUI.dim)
                StatCell(label: "FANS DRIVEN BY",
                         value: modeText,
                         color: modeColor)
                StatCell(label: "FAN CMD",
                         value: control?.commandedRPM.map { String(format: "%.0f RPM", $0) } ?? "-",
                         color: TUI.fan)
            }

            if store.desiredEnabled {
                BoostCurveView(target: store.desiredTarget, hottest: hottest)
                    .frame(height: 40)
            }

            TUIButton(label: "[ LOW POWER MODE ]",
                      active: store.snap.control?.lowPowerMode == true,
                      activeColor: TUI.mem) {
                store.setLowPower(!(store.snap.control?.lowPowerMode ?? false))
            }
        }
    }

    /// Three honest states: macOS has the fans; max cooling is armed but the
    /// chip is under target (fans still macOS's); or we're actively boosting.
    private var modeText: String {
        guard store.desiredEnabled else { return "MACOS" }
        return store.snap.control?.engaged == true ? "TEMPCONTROL" : "MACOS (IN BAND)"
    }

    private var modeColor: Color {
        guard store.desiredEnabled else { return TUI.mem }
        return store.snap.control?.engaged == true ? TUI.amber : TUI.mem
    }
}

/// Live plot of the exact boost curve the helper runs, with a marker at the
/// current temperature error.
struct BoostCurveView: View {
    let target: Double
    let hottest: Double?

    var body: some View {
        Canvas { ctx, size in
            let maxErr = BoostCurve.fullBoostError + TC.deadband

            func point(_ error: Double) -> CGPoint {
                let x = CGFloat((error + TC.deadband) / (maxErr + TC.deadband)) * size.width
                let y = size.height - CGFloat(BoostCurve.fraction(error: error)) * (size.height - 3) - 1.5
                return CGPoint(x: x, y: y)
            }

            var curve = Path()
            var e = -TC.deadband
            curve.move(to: point(e))
            while e <= maxErr {
                curve.addLine(to: point(e))
                e += 0.25
            }
            ctx.stroke(curve, with: .color(TUI.amber), lineWidth: 1.2)

            if let hottest {
                let err = min(max(hottest - target, -TC.deadband), maxErr)
                let p = point(err)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                         with: .color(TUI.fg))
            }
        }
        .background(Color(white: 0.04))
        .overlay(Rectangle().strokeBorder(TUI.grid, lineWidth: 1))
    }
}
