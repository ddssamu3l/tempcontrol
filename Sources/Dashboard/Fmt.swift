import Foundation

/// The one place quantities get turned into strings.
///
/// Both surfaces render through this: the SwiftUI views in
/// `Sources/TempControl/Views/` and the `PanelReporting` reporters that back
/// `tempcontrol-cli`. If a number looks different in the terminal than in the
/// app, that's a bug in exactly one function here rather than a drift between
/// two independent `String(format:)` calls.
public enum Fmt {
    /// What every surface prints when a value isn't available.
    public static let none = "-"

    // MARK: temperature

    /// `46.2°C`
    public static func temp(_ c: Double) -> String { String(format: "%.1f°C", c) }
    /// `46` — bare degrees for dense heat strips.
    public static func tempBare(_ c: Double) -> String { String(format: "%.0f", c) }
    /// `80°C` — whole degrees, used for the target.
    public static func tempWhole(_ c: Double) -> String { "\(Int(c.rounded()))°C" }
    /// `+3.4°C` — signed difference.
    public static func tempDelta(_ d: Double) -> String { String(format: "%+.1f°C", d) }

    // MARK: power

    /// `12.3W`
    public static func watts(_ w: Double) -> String { String(format: "%.1fW", w) }
    /// `` 12.3W`` — right-aligned in 5 columns for flow diagrams.
    public static func wattsPadded(_ w: Double) -> String { String(format: "%5.1fW", w) }

    // MARK: fans

    /// `3420 RPM`
    public static func rpm(_ r: Double) -> String { String(format: "%.0f RPM", r) }
    /// `` 420 RPM`` — right-aligned in 4 columns so fan rows line up.
    public static func rpmPadded(_ r: Double) -> String { String(format: "%4.0f RPM", r) }
    /// `1350–5777`
    public static func rpmRange(_ lo: Double, _ hi: Double) -> String {
        String(format: "%.0f–%.0f", lo, hi)
    }

    // MARK: ratios

    /// `34%` from a 0...1 fraction.
    public static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
    /// `` 34%`` — right-aligned in 3 columns.
    public static func percentPadded(_ fraction: Double) -> String {
        String(format: "%3.0f%%", fraction * 100)
    }
    /// `` 34`` — right-aligned in 3 columns, no `%` sign (the column header
    /// already says so).
    public static func percentBare(_ fraction: Double) -> String {
        String(format: "%3.0f", fraction * 100)
    }
    /// `78.4%` from an already-percentage value (battery hardware %).
    public static func percentOf100(_ pct: Double) -> String { String(format: "%.1f%%", pct) }
    /// `82%` from an already-percentage value.
    public static func percentOf100Whole(_ pct: Double) -> String { String(format: "%.0f%%", pct) }

    // MARK: bytes

    /// `31.2G` / `512G` / `840M` — the compact form the dashboard uses.
    public static func bytes(_ b: Int64) -> String {
        let t = Double(b) / 1_099_511_627_776
        if t >= 1 { return String(format: "%.1fT", t) }
        let g = Double(b) / 1_073_741_824
        if g >= 100 { return String(format: "%.0fG", g) }
        if g >= 1 { return String(format: "%.1fG", g) }
        return String(format: "%.0fM", Double(b) / 1_048_576)
    }

    /// `412M/s` / `1.4G/s` / `36K/s`
    public static func rate(_ bps: Double) -> String {
        let m = bps / 1_048_576
        if m >= 1000 { return String(format: "%.1fG/s", m / 1024) }
        if m >= 1 { return String(format: "%.0fM/s", m) }
        return String(format: "%.0fK/s", bps / 1024)
    }

    // MARK: processes (TASKS panel)

    /// `246%` — top-style CPU where 100% is one core. Already a percentage.
    public static func cpuPercent(_ pct: Double) -> String { String(format: "%.0f%%", pct) }
    /// `2.5×` — the same number as cores-worth, the honest "eating my cores" unit.
    public static func cores(_ cpuPercent: Double) -> String { String(format: "%.1f×", cpuPercent / 100) }
    /// GPU work as a busy percentage: `gpuMsPerSec` of 1000 = a saturated GPU.
    public static func gpuBusy(_ msPerSec: Double) -> String { String(format: "%.0f%%", msPerSec / 10) }
    /// `1.3G` / `842M` — process footprint from a byte count.
    public static func mem(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        if g >= 10 { return String(format: "%.0fG", g) }
        if g >= 1 { return String(format: "%.1fG", g) }
        return String(format: "%.0fM", Double(bytes) / 1_048_576)
    }

    // MARK: frequency

    /// `1284MHz`
    public static func mhz(_ m: Double) -> String { String(format: "%.0fMHz", m) }
    /// `3.87G` — per-core frequency, fixed width so core rows line up.
    public static func ghz(fromMHz m: Double) -> String { String(format: "%4.2fG", m / 1000) }

    // MARK: time

    /// `2:05` from a whole number of minutes.
    public static func duration(minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
    /// `0.42ms`
    public static func ms(_ v: Double) -> String { String(format: "%.2fms", v) }

    // MARK: plain counts

    /// `1204` — IOPS and other whole-number rates.
    public static func count(_ v: Double) -> String { String(format: "%.0f", v) }

    // MARK: optionals

    /// Formats `v` with `f`, or returns `fallback` when `v` is nil.
    public static func opt(_ v: Double?, _ f: (Double) -> String, else fallback: String = none) -> String {
        v.map(f) ?? fallback
    }

    /// `ON` / `OFF`
    public static func onOff(_ b: Bool) -> String { b ? "ON" : "OFF" }
    /// `YES` / `NO`
    public static func yesNo(_ b: Bool) -> String { b ? "YES" : "NO" }
}
