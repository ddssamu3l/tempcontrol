import SwiftUI

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

/// Line + soft fill history chart.
struct Sparkline: View {
    var values: [Double]
    var maxValue: Double?
    var color: Color

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
        Text(String(format: "%.0f", temp))
            .font(TUI.mono(9, hottest ? .bold : .regular))
            .foregroundStyle(hottest ? TUI.bg : TUI.tempColor(temp))
            .frame(width: 24, height: 15)
            .background(hottest ? TUI.tempColor(temp) : TUI.tempColor(temp).opacity(0.14))
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
