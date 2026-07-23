import SwiftUI
import Shared
import Dashboard

/// The TASKS tab — a task manager focused on the question "what is eating my
/// CPU and GPU cores". Ranking and the summary come from `Dashboard.Tasks`, the
/// same code the `tempcontrol-cli tasks` report uses, so the two never drift.
///
/// The panel only samples processes while it's visible (`store.showingTasks`),
/// because per-process GPU means keeping powermetrics' tasks sampler alive in
/// the helper — not something to pay for on every background heartbeat.
struct TasksView: View {
    @EnvironmentObject var store: MetricsStore
    @State private var sort: TaskSort = .cpu

    var body: some View {
        VStack(spacing: 8) {
            TasksActivityBox()
            processTable
        }
        .onAppear { store.showingTasks = true }
        .onDisappear { store.showingTasks = false }
    }

    private var rows: [ProcInfo] { Tasks.ranked(store.snap.tasks, by: sort, limit: 16) }
    private var gpuAvail: Bool { store.snap.gpuAccounting }

    private var processTable: some View {
        BoxSection(title: "PROCESSES", accent: TUI.cpu) {
            VStack(alignment: .leading, spacing: 6) {
                sortBar
                headerRow
                if rows.isEmpty {
                    Text(store.snap.tasks.isEmpty
                         ? "SAMPLING…  (per-process data needs a second reading)"
                         : "NOTHING ACTIVE")
                        .font(TUI.mono(9)).foregroundStyle(TUI.dim)
                        .padding(.vertical, 8)
                } else {
                    let top = max(rows.first.map { sort.key($0) } ?? 1, 0.0001)
                    ForEach(rows) { p in
                        ProcessRow(p: p, sort: sort, barFraction: sort.key(p) / top,
                                   gpuAvail: gpuAvail)
                    }
                }
                if !gpuAvail {
                    Text("GPU PER-PROCESS: N/A — needs the root helper" +
                         (store.snap.helperAvailable ? " (this Mac's powermetrics doesn't report it)" : "; run ./scripts/install.sh"))
                        .font(TUI.mono(8)).foregroundStyle(TUI.faint)
                }
            }
        }
    }

    private var sortBar: some View {
        HStack(spacing: 6) {
            Text("SORT").font(TUI.mono(9)).foregroundStyle(TUI.dim)
            ForEach(TaskSort.allCases, id: \.self) { s in
                let disabled = s == .gpu && !gpuAvail || s == .energy && !store.snap.tasksComplete
                TUIButton(label: "[ \(s.label) ]", active: sort == s,
                          activeColor: sortColor(s)) {
                    guard !disabled else { return }
                    sort = s
                }
                .opacity(disabled ? 0.35 : 1)
            }
            Spacer()
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("PROCESS").font(TUI.mono(8)).foregroundStyle(TUI.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").font(TUI.mono(8)).foregroundStyle(TUI.faint).frame(width: 52, alignment: .trailing)
            Text("GPU").font(TUI.mono(8)).foregroundStyle(TUI.faint).frame(width: 46, alignment: .trailing)
            Text("MEM").font(TUI.mono(8)).foregroundStyle(TUI.faint).frame(width: 50, alignment: .trailing)
        }
    }

    private func sortColor(_ s: TaskSort) -> Color {
        switch s {
        case .cpu: return TUI.cpu
        case .gpu: return TUI.gpu
        case .mem: return TUI.mem
        case .energy: return TUI.amber
        }
    }
}

/// One process line: a relative bar in the sort metric's color behind the name,
/// then the three numbers, always shown so switching sort doesn't hide columns.
private struct ProcessRow: View {
    let p: ProcInfo
    let sort: TaskSort
    let barFraction: Double
    let gpuAvail: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(barColor.opacity(0.16))
                .frame(width: nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(alignment: .leading) {
                    GeometryReader { g in
                        Rectangle().frame(width: max(0, min(1, barFraction)) * g.size.width)
                    }
                }
            HStack(spacing: 0) {
                Text(p.name)
                    .font(TUI.mono(10)).foregroundStyle(TUI.fg)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Fmt.cpuPercent(p.cpuPercent))
                    .font(TUI.mono(10, sort == .cpu ? .bold : .regular))
                    .foregroundStyle(cpuColor).frame(width: 52, alignment: .trailing)
                Text(gpuAvail ? (p.gpuMsPerSec.map(Fmt.gpuBusy) ?? "0%") : "·")
                    .font(TUI.mono(10, sort == .gpu ? .bold : .regular))
                    .foregroundStyle(gpuAvail ? TUI.gpu : TUI.faint).frame(width: 46, alignment: .trailing)
                Text(Fmt.mem(p.memBytes))
                    .font(TUI.mono(10, sort == .mem ? .bold : .regular))
                    .foregroundStyle(TUI.mem).frame(width: 50, alignment: .trailing)
            }
            .padding(.horizontal, 3)
        }
        .frame(height: 17)
    }

    private var barColor: Color {
        switch sort {
        case .cpu: return TUI.cpu
        case .gpu: return TUI.gpu
        case .mem: return TUI.mem
        case .energy: return TUI.amber
        }
    }
    // A process pinning multiple cores earns a warmer color.
    private var cpuColor: Color {
        if p.cpuPercent >= 150 { return TUI.red }
        if p.cpuPercent >= 60 { return TUI.amber }
        return TUI.cpu
    }
}

/// Top-of-panel summary: how much of the machine is actually spoken for.
private struct TasksActivityBox: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        let sum = Tasks.summary(store.snap)
        let cores = Double(store.sysInfo.totalCores)
        return BoxSection(title: "ACTIVITY", accent: TUI.amber) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    StatCell(label: "CORES IN USE",
                             value: String(format: "%.1f / %.0f", sum.coresInUse, cores),
                             color: TUI.cpu)
                    StatCell(label: "GPU BUSY",
                             value: sum.gpuBusyPct.map(Fmt.percentOf100Whole) ?? "N/A",
                             color: sum.gpuBusyPct != nil ? TUI.gpu : TUI.dim)
                    StatCell(label: "PROCESSES", value: "\(sum.processCount)", color: TUI.fg)
                    StatCell(label: "SOURCE",
                             value: sum.complete ? "ALL (ROOT)" : "SAME-USER",
                             color: sum.complete ? TUI.mem : TUI.amber)
                    Spacer()
                }
                // CPU-cores-in-use bar, scaled to the whole machine.
                HBar(fraction: cores > 0 ? sum.coresInUse / cores : 0, color: TUI.cpu)
                if !sum.complete {
                    Text("Helper not answering — showing this user's processes only, no GPU.\nInstall/start it for every process and per-process GPU.")
                        .font(TUI.mono(8)).foregroundStyle(TUI.amber.opacity(0.8))
                }
            }
        }
    }
}
