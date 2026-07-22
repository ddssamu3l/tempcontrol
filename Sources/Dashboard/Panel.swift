import Foundation

/// The dashboard's top-level sections. This enum is the single source of
/// truth for *both* surfaces:
///
///   - the app renders one SwiftUI view per case (`DashboardView`)
///   - the CLI exposes one subcommand per case (`tempcontrol-cli <name>`)
///
/// Adding a case here is a compile error until `PanelReports.reporter(for:)`
/// gains a branch for it, which in turn requires a `PanelReporting` type.
/// That is the whole anti-drift mechanism — see PROJECT_NOTES.md.
public enum Panel: String, CaseIterable, Sendable {
    case temp = "TEMP"
    case soc = "SOC"
    case storage = "STORAGE"
    case battery = "BATTERY"

    /// Lowercase name used on the command line (`tempcontrol-cli soc`).
    public var cliName: String { rawValue.lowercased() }

    /// Case-insensitive lookup from a CLI argument.
    public static func named(_ s: String) -> Panel? {
        let want = s.lowercased()
        return allCases.first { $0.cliName == want }
    }

    /// Every valid CLI panel name, in declaration order.
    public static var cliNames: [String] { allCases.map(\.cliName) }
}
