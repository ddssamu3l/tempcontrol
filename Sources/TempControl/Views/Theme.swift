import SwiftUI
import Dashboard

/// Black terminal aesthetic: monospace, thin rule lines, color only where it
/// carries meaning.
enum TUI {
    static let bg = Color.black
    static let fg = Color.white
    static let dim = Color(white: 0.52)
    static let faint = Color(white: 0.25)
    static let grid = Color(white: 0.13)

    static let cpu = Color(red: 0.36, green: 0.84, blue: 1.00)     // cyan
    static let gpu = Color(red: 0.79, green: 0.58, blue: 0.99)     // purple
    static let mem = Color(red: 0.62, green: 0.82, blue: 0.44)     // green
    static let fan = Color(red: 0.49, green: 0.65, blue: 0.98)     // blue
    static let amber = Color(red: 1.00, green: 0.70, blue: 0.30)
    static let red = Color(red: 1.00, green: 0.35, blue: 0.35)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func tempColor(_ c: Double) -> Color {
        switch c {
        case ..<50: return dim
        case ..<70: return mem
        case ..<85: return amber
        default: return red
        }
    }

    static func loadColor(_ f: Double) -> Color {
        switch f {
        case ..<0.5: return mem
        case ..<0.8: return amber
        default: return red
        }
    }
}

// Number formatting deliberately lives in `Fmt` (Sources/Dashboard/Fmt.swift)
// so the views and `tempcontrol-cli` render identical strings. Call Fmt.bytes,
// Fmt.rate, Fmt.temp, Fmt.watts, Fmt.percent, ... rather than String(format:).
