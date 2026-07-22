import SwiftUI
import Dashboard

/// Bordered section with the title punched into the top rule, like a TUI box:
/// ┌ CPU ──────────┐
struct BoxSection<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().strokeBorder(TUI.faint, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(" \(title) ")
                    .font(TUI.mono(10, .bold))
                    .foregroundStyle(accent)
                    .background(TUI.bg)
                    .offset(x: 8, y: -7)
            }
            .padding(.top, 7)
    }
}

/// htop-style horizontal bar with 10% tick marks.
struct HBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.09))
                Rectangle()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                HStack(spacing: 0) {
                    ForEach(1..<10, id: \.self) { _ in
                        Spacer()
                        Rectangle().fill(TUI.bg.opacity(0.55)).frame(width: 1)
                    }
                    Spacer()
                }
            }
        }
        .frame(height: height)
    }
}

/// Line + soft fill history chart. `refValue` draws a dashed horizontal
/// reference line (e.g. the temp target) on the same scale.
struct Sparkline: View {
    var values: [Double]
    var maxValue: Double?
    var color: Color
    var refValue: Double?
    var refColor: Color = TUI.amber

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let top = max(maxValue ?? values.max() ?? 1, 0.0001)
            let stepX = size.width / CGFloat(History.capacity - 1)
            let startX = size.width - CGFloat(values.count - 1) * stepX

            var line = Path()
            var fill = Path()
            for (i, v) in values.enumerated() {
                let x = startX + CGFloat(i) * stepX
                let y = size.height - CGFloat(min(v / top, 1.0)) * (size.height - 2) - 1
                if i == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                    fill.move(to: CGPoint(x: x, y: size.height))
                    fill.addLine(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                    fill.addLine(to: CGPoint(x: x, y: y))
                }
            }
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.closeSubpath()

            // Faint horizontal gridlines keep the terminal look.
            for frac in [0.25, 0.5, 0.75] {
                var grid = Path()
                let y = size.height * CGFloat(frac)
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(grid, with: .color(TUI.grid), lineWidth: 1)
            }
            ctx.fill(fill, with: .color(color.opacity(0.14)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.2)

            if let refValue, refValue > 0, refValue <= top {
                let y = size.height - CGFloat(min(refValue / top, 1.0)) * (size.height - 2) - 1
                var ref = Path()
                ref.move(to: CGPoint(x: 0, y: y))
                ref.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(ref, with: .color(refColor),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .background(Color(white: 0.04))
        .overlay(Rectangle().strokeBorder(TUI.grid, lineWidth: 1))
    }
}

/// Small labeled value, e.g.  FREQ
///                            3.87GHz
struct StatCell: View {
    let label: String
    let value: String
    var color: Color = TUI.fg

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(TUI.mono(9)).foregroundStyle(TUI.dim)
            Text(value).font(TUI.mono(12, .semibold)).foregroundStyle(color)
        }
    }
}

/// Temperature cell for the sensor heat strip.
struct HeatCell: View {
    let temp: Double
    let hottest: Bool

    var body: some View {
        Text(Fmt.tempBare(temp))
            .font(TUI.mono(9, hottest ? .bold : .regular))
            .foregroundStyle(hottest ? TUI.bg : TUI.tempColor(temp))
            .frame(width: 24, height: 15)
            .background(hottest ? TUI.tempColor(temp) : TUI.tempColor(temp).opacity(0.14))
    }
}

/// Reusable top tab bar: ─[ SYSTEM ]─[ BATTERY ]─ … add cases to the app's
/// Panel enum and a view for each; the bar scales automatically.
struct TUITabBar<Tab: Hashable>: View {
    let tabs: [(Tab, String)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(TUI.faint).frame(height: 1).frame(width: 8)
            ForEach(tabs, id: \.0) { tab, label in
                let active = selection == tab
                Button {
                    selection = tab
                } label: {
                    Text("[ \(label) ]")
                        .font(TUI.mono(10, active ? .bold : .regular))
                        .foregroundStyle(active ? TUI.bg : TUI.dim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(active ? TUI.fg : TUI.bg)
                }
                .buttonStyle(.plain)
                Rectangle().fill(TUI.faint).frame(height: 1).frame(width: 8)
            }
            Rectangle().fill(TUI.faint).frame(height: 1)
        }
    }
}

/// Horizontal drag slider with the value printed at the right.
struct TUISlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var color: Color = TUI.fg
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var onCommit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(white: 0.09))
                    Rectangle().fill(color.opacity(0.55))
                        .frame(width: max(0, min(1, frac)) * geo.size.width)
                    Rectangle().fill(color)
                        .frame(width: 3)
                        .offset(x: max(0, min(1, frac)) * (geo.size.width - 3))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let f = min(1, max(0, g.location.x / geo.size.width))
                            let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                            value = (raw / step).rounded() * step
                        }
                        .onEnded { _ in onCommit() }
                )
            }
            .frame(height: 14)
            Text(format(value))
                .font(TUI.mono(11, .semibold))
                .foregroundStyle(color)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

/// [ LABEL ] toggle-style TUI button.
struct TUIButton: View {
    let label: String
    var active = false
    var activeColor: Color = TUI.amber
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(TUI.mono(10, .bold))
                .foregroundStyle(active ? TUI.bg : TUI.fg)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(active ? activeColor : Color(white: 0.10))
                .overlay(Rectangle().strokeBorder(active ? activeColor : TUI.faint, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
