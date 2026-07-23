import Foundation
import Dashboard
import Shared

// tempcontrol-cli — the terminal face of the dashboard.
//
// There is deliberately NO hardcoded list of subcommands anywhere in this
// file: every command, the usage text and the error message all iterate
// `Panel.allCases`. Adding a panel to the app adds it here for free, and the
// exhaustive switch in `PanelReports.reporter(for:)` refuses to compile until
// that panel has a reporter. Output can't drift from the app either — both
// render the same `ReportSection`s through the same `Fmt`.

// MARK: - argument parsing

let args = Array(CommandLine.arguments.dropFirst())
var wantJSON = false
var positional: [String] = []

for arg in args {
    switch arg {
    case "--json": wantJSON = true
    case "-h", "--help", "help": positional.append("--help")
    default: positional.append(arg)
    }
}

func stderrLine(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func usage() -> String {
    var out = """
    tempcontrol-cli — probe this Mac's sensors, one subcommand per dashboard panel.

    USAGE
      tempcontrol-cli <command> [--json]

    COMMANDS

    """
    let width = max(Panel.cliNames.map(\.count).max() ?? 0, "all".count) + 2
    for panel in Panel.allCases {
        out += "  \(panel.cliName.padding(toLength: width, withPad: " ", startingAt: 0))"
        out += "the \(panel.rawValue) panel\n"
    }
    out += "  \("all".padding(toLength: width, withPad: " ", startingAt: 0))every panel\n"
    out += """

    OPTIONS
      --json      emit the report as JSON on stdout (nothing else is printed)
      -h, --help  this message

    NOTES
      Root-only data (per-core frequency, fan control state, battery control)
      comes from the tempcontrol helper daemon. Without it the report still
      prints, with those rows marked accordingly.
    """
    return out
}

guard let command = positional.first, command != "--help" else {
    print(usage())
    exit(0)
}

if positional.count > 1 {
    stderrLine("tempcontrol-cli: unexpected argument '\(positional[1])'")
    stderrLine("valid commands: \((Panel.cliNames + ["all"]).joined(separator: ", "))")
    exit(1)
}

/// `all` is the only command that isn't a panel; everything else must resolve
/// through `Panel.named`, so an unknown name can never silently do nothing.
let panels: [Panel]
if command.lowercased() == "all" {
    panels = Panel.allCases
} else if let panel = Panel.named(command) {
    panels = [panel]
} else {
    stderrLine("tempcontrol-cli: unknown panel '\(command)'")
    stderrLine("valid panels: \(Panel.cliNames.joined(separator: ", ")) (or 'all')")
    exit(1)
}

// MARK: - collect

let collector = SnapshotCollector()
let sysInfo = collector.sysInfo
// Two samples with a settle gap: per-core load and disk throughput are rates
// and simply don't exist from a single reading. The TASKS panel needs a
// longer gap still — per-process CPU% and GPU ms/s are rates too, and the
// helper's powermetrics sampler has to warm up.
collector.wantTasks = panels.contains(.tasks)
let snap = collector.wantTasks
    ? collector.collect(settleFor: 1.4, helperTimeout: 2.5)
    : collector.collect()
let reports = panels.map { PanelReports.report($0, snap, sysInfo) }

// MARK: - JSON output (the agent-facing path)

if wantJSON {
    let encoder = JSONEncoder()
    // sortedKeys keeps the output byte-stable across runs, so agents can
    // diff two reports without spurious churn.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        // One panel -> the object; `all` -> an array of those objects.
        let data = reports.count == 1
            ? try encoder.encode(reports[0])
            : try encoder.encode(reports)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    } catch {
        stderrLine("tempcontrol-cli: failed to encode JSON: \(error)")
        exit(1)
    }
}

// MARK: - text output

/// Right-hand bar for any row that carries a 0–100 percentage, drawn purely
/// from `raw` so it can never disagree with the printed value.
func bar(_ pct: Double, width: Int = 10) -> String {
    let filled = Int((min(max(pct, 0), 100) / 100 * Double(width)).rounded())
    return "[" + String(repeating: "#", count: filled)
         + String(repeating: " ", count: width - filled) + "]"
}

func wrap(_ text: String, width: Int, indent: String) -> String {
    var lines: [String] = []
    var line = ""
    for word in text.split(separator: " ") {
        if line.isEmpty {
            line = String(word)
        } else if line.count + 1 + word.count <= width {
            line += " " + word
        } else {
            lines.append(line)
            line = String(word)
        }
    }
    if !line.isEmpty { lines.append(line) }
    return lines.map { indent + $0 }.joined(separator: "\n")
}

func render(_ report: PanelReport) -> String {
    var out = "\u{2550}\u{2550} \(report.panel.rawValue) "
    out += String(repeating: "\u{2550}", count: max(0, 60 - report.panel.rawValue.count - 4))
    out += "\n"

    for section in report.sections {
        out += "\n\(section.title)\n"
        let labelWidth = max(section.rows.map(\.label.count).max() ?? 0, 12)
        // Reserve the bar column for the whole section (blank on rows without
        // one) so values stay in a single column.
        func barFor(_ row: ReportRow) -> Double? {
            row.unit == "%" ? row.raw : nil
        }
        let barWidth = section.rows.contains(where: { barFor($0) != nil }) ? 14 : 0

        for row in section.rows {
            let label = row.label.padding(toLength: max(labelWidth, row.label.count),
                                          withPad: " ", startingAt: 0)
            let barCell = barWidth == 0 ? ""
                : (barFor(row).map { bar($0) } ?? "").padding(toLength: barWidth,
                                                              withPad: " ", startingAt: 0)
            let line = "  \(label)  \(barCell)\(row.value)"
            out += line.replacingOccurrences(of: "\\s+$", with: "",
                                             options: .regularExpression) + "\n"
        }
        if let note = section.note {
            out += wrap(note, width: 66, indent: "  · ") + "\n"
        }
    }
    return out
}

print(reports.map(render).joined(separator: "\n"), terminator: "")
exit(0)
