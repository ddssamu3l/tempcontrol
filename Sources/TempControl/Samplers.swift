import Foundation
import IOKit
import Shared

// MARK: - Static hardware info

struct SystemInfo {
    let chipName: String
    let isAppleSilicon: Bool
    let pCores: Int
    let eCores: Int
    let totalCores: Int
    let memTotalB: Int64

    static func detect() -> SystemInfo {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        // perflevel0 = performance cores, perflevel1 = efficiency cores.
        let p = sysctlInt("hw.perflevel0.physicalcpu") ?? 0
        let e = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        let total = sysctlInt("hw.ncpu") ?? (p + e)
        return SystemInfo(
            chipName: chip,
            isAppleSilicon: chip.contains("Apple"),
            pCores: p,
            eCores: max(0, e),
            totalCores: total,
            memTotalB: Int64(sysctlInt("hw.memsize") ?? 0)
        )
    }

    /// Core IDs are cluster-ordered on Apple Silicon: efficiency cores first.
    func isPCore(_ id: Int) -> Bool { id >= eCores }
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

// MARK: - Per-core CPU load (no root needed)

final class CPULoadSampler {
    private var prev: [[UInt32]] = []

    /// Returns per-core load 0...1, in core-ID order.
    func sample() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for cpu in 0..<Int(cpuCount) {
            var t = [UInt32](repeating: 0, count: states)
            for s in 0..<states {
                t[s] = UInt32(bitPattern: info[cpu * states + s])
            }
            ticks.append(t)
        }

        defer { prev = ticks }
        guard prev.count == ticks.count else { return ticks.map { _ in 0 } }

        return ticks.enumerated().map { i, t in
            let d = (0..<states).map { s in Double(t[s] &- prev[i][s]) }
            let busy = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
            let total = busy + d[Int(CPU_STATE_IDLE)]
            return total > 0 ? busy / total : 0
        }
    }
}

// MARK: - Memory (unified — shared by CPU and GPU on Apple Silicon)

struct MemStats {
    var totalB: Int64 = 0
    var usedB: Int64 = 0
    var appB: Int64 = 0
    var wiredB: Int64 = 0
    var compressedB: Int64 = 0
    var swapUsedB: Int64 = 0
    /// 1 = normal, 2 = warning, 4 = critical (kernel levels)
    var pressureLevel: Int = 1
}

func sampleMemory(totalB: Int64) -> MemStats {
    var stats = MemStats()
    stats.totalB = totalB

    var vm = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return stats }

    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    let page = Int64(pageSize)

    // Same accounting Activity Monitor uses.
    let app = (Int64(vm.internal_page_count) - Int64(vm.purgeable_count)) * page
    let wired = Int64(vm.wire_count) * page
    let compressed = Int64(vm.compressor_page_count) * page
    stats.appB = max(0, app)
    stats.wiredB = wired
    stats.compressedB = compressed
    stats.usedB = max(0, app) + wired + compressed

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
        stats.swapUsedB = Int64(swap.xsu_used)
    }
    stats.pressureLevel = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
    return stats
}

// MARK: - Storage: capacity, volumes, and detailed I/O

struct VolumeInfo: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let totalB: Int64
    let freeB: Int64
}

struct DiskStats {
    var totalB: Int64 = 0
    /// Finder-style free space (includes purgeable).
    var freeB: Int64 = 0
    var purgeableB: Int64 = 0
    var readBps: Double = 0
    var writeBps: Double = 0
    var readIOPS: Double = 0
    var writeIOPS: Double = 0
    /// Average time per I/O over the last sample window.
    var readLatencyMs: Double = 0
    var writeLatencyMs: Double = 0
    /// Cumulative since boot (the raw driver counters).
    var bootReadB: Int64 = 0
    var bootWriteB: Int64 = 0
    var volumes: [VolumeInfo] = []
}

final class DiskSampler {
    private struct Counters {
        var readB: Int64 = 0, writeB: Int64 = 0
        var readOps: Int64 = 0, writeOps: Int64 = 0
        var readNs: Int64 = 0, writeNs: Int64 = 0
    }
    private var prev: Counters?
    private var prevTime: Date?

    func sample() -> DiskStats {
        var stats = DiskStats()
        sampleCapacity(&stats)
        sampleIO(&stats)
        return stats
    }

    private func sampleCapacity(_ stats: inout DiskStats) {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.volumeIsBrowsable == true,
                  let total = v.volumeTotalCapacity, total > 1_000_000_000
            else { continue }
            let plainFree = Int64(v.volumeAvailableCapacity ?? 0)
            let importantFree = v.volumeAvailableCapacityForImportantUsage ?? Int64(plainFree)
            stats.volumes.append(VolumeInfo(
                path: url.path,
                name: v.volumeName ?? url.lastPathComponent,
                totalB: Int64(total),
                freeB: max(plainFree, importantFree)))
            if url.path == "/" {
                stats.totalB = Int64(total)
                stats.freeB = max(plainFree, importantFree)
                stats.purgeableB = max(0, importantFree - plainFree)
            }
        }
    }

    private func sampleIO(_ stats: inout DiskStats) {
        var c = Counters()
        var iter = io_iterator_t()
        if IOServiceGetMatchingServices(kIOMainPortDefault,
                                        IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS {
            while case let entry = IOIteratorNext(iter), entry != 0 {
                defer { IOObjectRelease(entry) }
                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dict = props?.takeRetainedValue() as? [String: Any],
                      let s = dict["Statistics"] as? [String: Any]
                else { continue }
                c.readB += (s["Bytes (Read)"] as? Int64) ?? 0
                c.writeB += (s["Bytes (Write)"] as? Int64) ?? 0
                c.readOps += (s["Operations (Read)"] as? Int64) ?? 0
                c.writeOps += (s["Operations (Write)"] as? Int64) ?? 0
                c.readNs += (s["Total Time (Read)"] as? Int64) ?? 0
                c.writeNs += (s["Total Time (Write)"] as? Int64) ?? 0
            }
            IOObjectRelease(iter)
        }

        stats.bootReadB = c.readB
        stats.bootWriteB = c.writeB

        let now = Date()
        if let prev, let prevTime {
            let dt = now.timeIntervalSince(prevTime)
            if dt > 0 {
                stats.readBps = Double(max(0, c.readB - prev.readB)) / dt
                stats.writeBps = Double(max(0, c.writeB - prev.writeB)) / dt
                let dReadOps = max(0, c.readOps - prev.readOps)
                let dWriteOps = max(0, c.writeOps - prev.writeOps)
                stats.readIOPS = Double(dReadOps) / dt
                stats.writeIOPS = Double(dWriteOps) / dt
                if dReadOps > 0 {
                    stats.readLatencyMs = Double(max(0, c.readNs - prev.readNs)) / Double(dReadOps) / 1e6
                }
                if dWriteOps > 0 {
                    stats.writeLatencyMs = Double(max(0, c.writeNs - prev.writeNs)) / Double(dWriteOps) / 1e6
                }
            }
        }
        prev = c
        prevTime = now
    }
}

// MARK: - GPU utilization (whole-GPU: Apple exposes no per-GPU-core stats)

struct GPUStats {
    var deviceUtil: Double?
    var rendererUtil: Double?
    var tilerUtil: Double?
    var inUseMemB: Int64?
    var allocMemB: Int64?
    var coreCount: Int?
}

func sampleGPU() -> GPUStats {
    var stats = GPUStats()
    var iter = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
    else { return stats }
    while case let entry = IOIteratorNext(iter), entry != 0 {
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let perf = dict["PerformanceStatistics"] as? [String: Any]
        else { continue }
        if let v = perf["Device Utilization %"] as? Int { stats.deviceUtil = Double(v) / 100.0 }
        if let v = perf["Renderer Utilization %"] as? Int { stats.rendererUtil = Double(v) / 100.0 }
        if let v = perf["Tiler Utilization %"] as? Int { stats.tilerUtil = Double(v) / 100.0 }
        if let v = perf["In use system memory"] as? Int64 { stats.inUseMemB = v }
        if let v = perf["Alloc system memory"] as? Int64 { stats.allocMemB = v }
        if let v = dict["gpu-core-count"] as? Int { stats.coreCount = v }
        if stats.deviceUtil != nil { break }
    }
    IOObjectRelease(iter)
    return stats
}
