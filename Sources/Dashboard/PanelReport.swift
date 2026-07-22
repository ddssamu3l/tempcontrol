import Foundation

// MARK: - The report data model

/// One labelled reading. `value` is what a human reads (already run through
/// `Fmt`, so it is byte-identical to what the app shows); `raw` + `unit` are
/// what a machine reads. Both are always emitted for numeric rows.
public struct ReportRow: Encodable, Sendable {
    public let label: String
    public let value: String
    public let raw: Double?
    public let unit: String?

    public init(_ label: String, _ value: String, raw: Double? = nil, unit: String? = nil) {
        self.label = label
        // Some formatters pad to fixed widths for column alignment; trailing
        // padding is noise once the string lands in JSON.
        self.value = value.replacingOccurrences(of: "\\s+$", with: "",
                                                options: .regularExpression)
        // JSON has no NaN/Inf. Drop non-finite values rather than throwing
        // mid-encode and losing the whole report.
        self.raw = (raw?.isFinite == true) ? raw : nil
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey { case label, value, raw, unit }

    /// Keys are always present — `null` rather than absent — so consumers can
    /// index the shape without existence checks.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(value, forKey: .value)
        if let raw { try c.encode(raw, forKey: .raw) } else { try c.encodeNil(forKey: .raw) }
        if let unit { try c.encode(unit, forKey: .unit) } else { try c.encodeNil(forKey: .unit) }
    }
}

public struct ReportSection: Encodable, Sendable {
    public let title: String
    public let rows: [ReportRow]
    public let note: String?

    public init(_ title: String, _ rows: [ReportRow], note: String? = nil) {
        self.title = title
        self.rows = rows
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case title, rows, note }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(rows, forKey: .rows)
        if let note { try c.encode(note, forKey: .note) } else { try c.encodeNil(forKey: .note) }
    }
}

public struct PanelReport: Encodable, Sendable {
    public let panel: Panel
    public let sections: [ReportSection]

    public init(panel: Panel, sections: [ReportSection]) {
        self.panel = panel
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey { case panel, sections }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(panel.cliName, forKey: .panel)
        try c.encode(sections, forKey: .sections)
    }
}

// MARK: - The contract

/// One conforming type per `Panel` case, mirroring what that panel's SwiftUI
/// view puts on screen.
public protocol PanelReporting {
    static var panel: Panel { get }
    static func sections(_ s: Snapshot, _ sys: SystemInfo) -> [ReportSection]
}

/// The registry. `reporter(for:)` is an **exhaustive switch with no
/// `default:`** — the compiler refuses to build the package until every
/// `Panel` case has a reporter, which is what makes it structurally
/// impossible for a dashboard panel to be missing from the CLI.
public enum PanelReports {
    public static func reporter(for panel: Panel) -> any PanelReporting.Type {
        switch panel {
        case .temp: return TempReport.self
        case .soc: return SoCReport.self
        case .storage: return StorageReport.self
        case .battery: return BatteryReport.self
        }
    }

    public static func report(_ panel: Panel, _ s: Snapshot, _ sys: SystemInfo) -> PanelReport {
        PanelReport(panel: panel, sections: reporter(for: panel).sections(s, sys))
    }

    /// Every panel, in `Panel.allCases` order.
    public static func all(_ s: Snapshot, _ sys: SystemInfo) -> [PanelReport] {
        Panel.allCases.map { report($0, s, sys) }
    }
}

// MARK: - Shared row helpers

extension ReportRow {
    /// A row whose value may be missing. Emits `Fmt.none` with a null `raw`
    /// when it is, so the shape stays stable.
    public static func optional(_ label: String, _ v: Double?,
                                _ f: (Double) -> String, unit: String) -> ReportRow {
        ReportRow(label, v.map(f) ?? Fmt.none, raw: v, unit: unit)
    }

    public static func temp(_ label: String, _ c: Double?) -> ReportRow {
        .optional(label, c, Fmt.temp, unit: "C")
    }

    public static func watts(_ label: String, _ w: Double?) -> ReportRow {
        .optional(label, w, Fmt.watts, unit: "W")
    }

    /// Percentage row from a 0...1 fraction; `raw` is reported as a percent.
    /// Padded like the app's bar rows so columns line up in the terminal too.
    public static func fraction(_ label: String, _ f: Double?) -> ReportRow {
        ReportRow(label, f.map(Fmt.percentPadded) ?? Fmt.none, raw: f.map { $0 * 100 }, unit: "%")
    }

    public static func bytes(_ label: String, _ b: Int64?) -> ReportRow {
        ReportRow(label, b.map(Fmt.bytes) ?? Fmt.none, raw: b.map(Double.init), unit: "B")
    }

    public static func text(_ label: String, _ v: String) -> ReportRow {
        ReportRow(label, v)
    }

    /// When a `unit` is given it is also appended to the printed value
    /// (`8579mAh`), so the text surface never shows a bare number.
    public static func int(_ label: String, _ v: Int?, unit: String? = nil) -> ReportRow {
        let text = v.map { n in unit.map { u in "\(n)\(u)" } ?? "\(n)" } ?? Fmt.none
        return ReportRow(label, text, raw: v.map(Double.init), unit: unit)
    }
}
