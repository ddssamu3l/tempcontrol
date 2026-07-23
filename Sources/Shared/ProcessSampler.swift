import Foundation

/// One process's resource use, as shown in the TASKS panel. This is the wire
/// type (helper → app) and the display type, so it's `Codable`.
///
/// `cpuPercent` is **top-style**: the sum across cores, so a process pinning
/// four cores reads 400%. That's deliberate — the question is "what's eating my
/// cores", and cores-worth is the honest unit. `gpuMsPerSec` is nil when GPU
/// accounting isn't available (needs the root helper + supporting hardware).
public struct ProcInfo: Codable, Identifiable, Equatable {
    public var pid: Int32
    public var name: String
    /// 0…(100 × core count). 100 = one core fully busy.
    public var cpuPercent: Double
    public var memBytes: UInt64
    /// GPU milliseconds of work per wall-clock second (so 1000 = a fully
    /// saturated GPU timeline). nil = not measured on this machine.
    public var gpuMsPerSec: Double?
    public var diskReadBytesPerSec: Double
    public var diskWriteBytesPerSec: Double
    /// powermetrics' relative "energy impact" rate. nil without the helper.
    public var energyImpact: Double?

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, memBytes: UInt64,
                gpuMsPerSec: Double? = nil, diskReadBytesPerSec: Double = 0,
                diskWriteBytesPerSec: Double = 0, energyImpact: Double? = nil) {
        self.pid = pid; self.name = name; self.cpuPercent = cpuPercent
        self.memBytes = memBytes; self.gpuMsPerSec = gpuMsPerSec
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.energyImpact = energyImpact
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "?"
        cpuPercent = try c.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? 0
        memBytes = try c.decodeIfPresent(UInt64.self, forKey: .memBytes) ?? 0
        gpuMsPerSec = try c.decodeIfPresent(Double.self, forKey: .gpuMsPerSec)
        diskReadBytesPerSec = try c.decodeIfPresent(Double.self, forKey: .diskReadBytesPerSec) ?? 0
        diskWriteBytesPerSec = try c.decodeIfPresent(Double.self, forKey: .diskWriteBytesPerSec) ?? 0
        energyImpact = try c.decodeIfPresent(Double.self, forKey: .energyImpact)
    }
}

// libproc — not surfaced through Swift's Darwin module map, so bind the C
// symbols directly. proc_pid_rusage takes a `rusage_info_t *` (an opaque
// `void **`); it writes the WHOLE struct into the buffer we point at, so the
// buffer must be a real `rusage_info_v6`, not a pointer-sized slot. Getting
// that wrong is a silent heap smash (learned the hard way).
@_silgen_name("proc_listpids")
private func c_proc_listpids(_ type: UInt32, _ typeinfo: UInt32,
                             _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
@_silgen_name("proc_pid_rusage")
private func c_proc_pid_rusage(_ pid: Int32, _ flavor: Int32,
                               _ buffer: UnsafeMutableRawPointer) -> Int32
@_silgen_name("proc_name")
private func c_proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32
@_silgen_name("proc_pidpath")
private func c_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

private let PROC_ALL_PIDS: UInt32 = 1
private let RUSAGE_INFO_V6: Int32 = 6

/// Stateful per-process sampler. CPU/disk/energy are cumulative counters, so
/// rates come from the delta between two `sample()` calls — the sampler holds
/// the previous reading. First call returns memory-only (no rates yet).
///
/// Reach depends on privilege: unprivileged, `proc_pid_rusage` only answers for
/// same-uid processes, so the app sees ~its own; run as root (the helper) it
/// sees everything. Either way it never traps on a process it can't read — it
/// just skips it.
public final class ProcessSampler {
    private struct Prev { var cpuTicks: UInt64; var diskR: UInt64; var diskW: UInt64; var energyNj: UInt64 }
    private var prev: [Int32: Prev] = [:]
    private var lastWall = Date.distantPast
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    /// ns per CPU-time tick. `ri_user_time`/`ri_system_time` come back in mach
    /// time units, NOT nanoseconds, on Apple Silicon (numer/denom = 125/3, so
    /// ~41.7 ns/tick). Treating them as ns under-reports CPU by ~40× — a busy
    /// process reads 2%. Verified against `ps`. Query the timebase, never
    /// hardcode it: it differs across chip families.
    private let nsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom > 0 ? Double(tb.numer) / Double(tb.denom) : 1
    }()

    public init() {}

    private struct Raw { var cpuTicks: UInt64; var mem: UInt64; var diskR: UInt64; var diskW: UInt64; var energyNj: UInt64 }

    private func rusage(_ pid: Int32) -> Raw? {
        var v = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &v) {
            c_proc_pid_rusage(pid, RUSAGE_INFO_V6, UnsafeMutableRawPointer($0)) == 0
        }
        guard ok else { return nil }
        return Raw(cpuTicks: v.ri_user_time &+ v.ri_system_time, mem: v.ri_phys_footprint,
                   diskR: v.ri_diskio_bytesread, diskW: v.ri_diskio_byteswritten,
                   energyNj: v.ri_energy_nj)
    }

    private func name(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        if c_proc_name(pid, &buf, 4096) > 0 {
            let n = String(cString: buf)
            if !n.isEmpty { return n }
        }
        // Fall back to the executable's last path component — proc_name reads
        // the (truncated) accounting name and is occasionally empty.
        if c_proc_pidpath(pid, &buf, 4096) > 0 {
            let path = String(cString: buf)
            if let last = path.split(separator: "/").last { return String(last) }
        }
        return "pid \(pid)"
    }

    private func livePids() -> [Int32] {
        let bytes = c_proc_listpids(PROC_ALL_PIDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size)
        let n = c_proc_listpids(PROC_ALL_PIDS, 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n) / MemoryLayout<Int32>.size)).filter { $0 > 0 }
    }

    /// Sample every reachable process. Rates are over the wall interval since
    /// the previous call; `nil`/zero for processes seen for the first time.
    public func sample() -> [ProcInfo] {
        let now = Date()
        let dt = now.timeIntervalSince(lastWall)
        let haveBaseline = dt > 0 && dt < 60 && !prev.isEmpty
        var next: [Int32: Prev] = [:]
        var out: [ProcInfo] = []
        out.reserveCapacity(prev.count)

        for pid in livePids() {
            guard let r = rusage(pid) else { continue }
            next[pid] = Prev(cpuTicks: r.cpuTicks, diskR: r.diskR, diskW: r.diskW, energyNj: r.energyNj)
            var cpu = 0.0, dR = 0.0, dW = 0.0
            if haveBaseline, let p = prev[pid] {
                // ticks → ns via the mach timebase, then a fraction of the
                // wall interval; ×100 so one core busy reads 100%.
                let cpuNs = Double(r.cpuTicks &- p.cpuTicks) * nsPerTick
                cpu = cpuNs / (dt * 1e9) * 100
                dR = Double(r.diskR &- p.diskR) / dt
                dW = Double(r.diskW &- p.diskW) / dt
            }
            out.append(ProcInfo(pid: pid, name: name(pid),
                                cpuPercent: max(0, cpu), memBytes: r.mem,
                                diskReadBytesPerSec: max(0, dR),
                                diskWriteBytesPerSec: max(0, dW)))
        }
        prev = next
        lastWall = now
        return out
    }

    /// Logical core count — the ceiling `cpuPercent` can reach (× 100).
    public var coreCount: Double { cores }
}
