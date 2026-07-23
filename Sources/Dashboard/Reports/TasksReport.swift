import Foundation
import Shared

/// Mirrors the TASKS tab (`Views/TasksView.swift`): a summary of how much of
/// the machine is spoken for, then the heaviest processes ranked by CPU, by
/// GPU, and by memory.
///
/// A process is one row: the label is its name, the value packs the columns
/// (`CPU  GPU  MEM  ENERGY`), and `raw`/`unit` carry that section's sort metric
/// so `--json` consumers get a real number to sort or threshold on.
public enum TasksReport: PanelReporting {
    public static let panel = Panel.tasks

    public static func sections(_ s: Snapshot, _ sys: SystemInfo) -> [ReportSection] {
        let sum = Tasks.summary(s)
        var out = [activity(s, sum, sys)]
        // CPU is always meaningful; GPU only when the hardware accounts for it;
        // memory always. Keep sections short — this is a glance, not htop.
        out.append(ranked(s, .cpu, "TOP BY CPU"))
        if sum.gpuAccounting { out.append(ranked(s, .gpu, "TOP BY GPU")) }
        out.append(ranked(s, .mem, "TOP BY MEMORY"))
        return out
    }

    private static func activity(_ s: Snapshot, _ sum: TaskSummary, _ sys: SystemInfo) -> ReportSection {
        var rows: [ReportRow] = []
        if !s.helperAvailable && s.tasks.isEmpty {
            return ReportSection("ACTIVITY", [.text("STATUS", "NO PROCESS DATA")],
                                 note: "RUN THE APP OR INSTALL THE HELPER (./scripts/install.sh) TO SAMPLE PROCESSES.")
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        rows.append(ReportRow("CORES IN USE",
                              String(format: "%.1f / %d", sum.coresInUse, cores),
                              raw: sum.coresInUse, unit: "cores"))
        if let g = sum.gpuBusyPct {
            rows.append(ReportRow("GPU BUSY", Fmt.percentOf100Whole(g), raw: g, unit: "%"))
        } else {
            rows.append(.text("GPU BUSY", "N/A ON THIS MAC"))
        }
        rows.append(.int("PROCESSES SHOWN", sum.processCount))
        rows.append(.text("SOURCE", sum.complete
                          ? "COMPLETE (ROOT HELPER)"
                          : "LOCAL (SAME-USER ONLY, NO GPU)"))
        let note = sum.complete
            ? "CPU IS TOP-STYLE: 100% = ONE CORE. GPU BUSY IS PER-PROCESS GPU TIME AS A SHARE OF A SATURATED GPU."
            : "THE HELPER ISN'T ANSWERING, SO THIS IS THIS USER'S PROCESSES ONLY AND GPU IS UNAVAILABLE. INSTALL/START IT FOR THE FULL PICTURE."
        return ReportSection("ACTIVITY", rows, note: note)
    }

    private static func ranked(_ s: Snapshot, _ sort: TaskSort, _ title: String) -> ReportSection {
        let top = Tasks.ranked(s.tasks, by: sort, limit: 12)
        guard !top.isEmpty else {
            return ReportSection(title, [.text("—", "NOTHING ACTIVE")])
        }
        let rows = top.map { p -> ReportRow in
            ReportRow(label(p), columns(p, gpu: s.gpuAccounting),
                      raw: sort.key(p), unit: sort == .mem ? "B" : (sort == .cpu ? "%" : nil))
        }
        return ReportSection(title, rows)
    }

    /// `1234 Google Chrome He…` — pid then name, trimmed so the value column
    /// starts in a predictable place.
    private static func label(_ p: ProcInfo) -> String {
        let name = p.name.count > 22 ? String(p.name.prefix(21)) + "…" : p.name
        let pid = String(p.pid)
        return String(repeating: " ", count: max(0, 5 - pid.count)) + pid + " " + name
    }

    /// The shared column block: CPU, GPU (or `·`), MEM, and energy when known.
    /// Values are right-aligned by hand — `String(format:)` width specifiers
    /// don't pad `%@`, so columns would otherwise wander.
    private static func columns(_ p: ProcInfo, gpu gpuAvail: Bool) -> String {
        func pad(_ s: String, _ w: Int) -> String {
            String(repeating: " ", count: max(0, w - s.count)) + s
        }
        var parts = ["cpu \(pad(Fmt.cpuPercent(p.cpuPercent), 5))"]
        if gpuAvail { parts.append("gpu \(pad(p.gpuMsPerSec.map(Fmt.gpuBusy) ?? "·", 4))") }
        parts.append("mem \(pad(Fmt.mem(p.memBytes), 5))")
        if let e = p.energyImpact { parts.append("E \(pad(String(format: "%.0f", e), 3))") }
        return parts.joined(separator: "  ")
    }
}
