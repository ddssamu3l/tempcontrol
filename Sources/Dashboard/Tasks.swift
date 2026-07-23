import Foundation
import Shared

/// Shared task-panel logic, so the SwiftUI view and the CLI report rank and
/// summarise processes identically — the same anti-drift rule the rest of the
/// dashboard follows.
public enum TaskSort: String, CaseIterable, Sendable {
    case cpu, gpu, mem, energy

    public var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .mem: return "MEM"
        case .energy: return "ENERGY"
        }
    }

    /// The scalar processes are ranked by. GPU/energy are nil-safe (0).
    public func key(_ p: ProcInfo) -> Double {
        switch self {
        case .cpu: return p.cpuPercent
        case .gpu: return p.gpuMsPerSec ?? 0
        case .mem: return Double(p.memBytes)
        case .energy: return p.energyImpact ?? 0
        }
    }
}

public struct TaskSummary {
    /// Sum of every shown process's cores-worth (cpuPercent / 100).
    public var coresInUse: Double
    /// Sum of per-process GPU busy%, capped at 100. nil when GPU isn't measured.
    public var gpuBusyPct: Double?
    public var processCount: Int
    /// True = complete root-gathered list (all users, with GPU). False = the
    /// app's own libproc fallback: same-user processes, no GPU.
    public var complete: Bool
    /// This machine's powermetrics reports per-process GPU at all.
    public var gpuAccounting: Bool
}

public enum Tasks {
    /// Processes sorted by `sort`, descending, capped to `limit`. Idle
    /// processes (all metrics ~0) are dropped so the list is signal, not noise.
    public static func ranked(_ list: [ProcInfo], by sort: TaskSort, limit: Int = 60) -> [ProcInfo] {
        list.filter { $0.cpuPercent > 0.05 || (($0.gpuMsPerSec ?? 0) > 0) || $0.memBytes > 0 }
            .sorted { sort.key($0) > sort.key($1) }
            .prefix(limit)
            .map { $0 }
    }

    public static func summary(_ s: Snapshot) -> TaskSummary {
        let cores = s.tasks.reduce(0.0) { $0 + $1.cpuPercent } / 100
        let gpu = s.tasks.compactMap(\.gpuMsPerSec).reduce(0.0, +) / 10   // ms/s → %
        return TaskSummary(
            coresInUse: cores,
            gpuBusyPct: s.gpuAccounting ? min(100, gpu) : nil,
            processCount: s.tasks.count,
            complete: s.tasksComplete,
            gpuAccounting: s.gpuAccounting)
    }
}
