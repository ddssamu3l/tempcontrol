import Foundation
import Shared

/// Owns every sampler the dashboard needs and produces `Snapshot`s.
///
/// Two entry points, one body of collection code:
///
///   - `sampleLocal()` — everything readable without root. The app's
///     `MetricsStore` calls this from its 1s/5s timer and then folds in the
///     helper reply asynchronously.
///   - `collect(...)` — a *fully populated* snapshot, synchronously, for the
///     CLI. Takes a throwaway sample first because per-core load and disk
///     throughput are rates and need two readings to exist at all.
///
/// Not thread-safe: the samplers hold previous-reading state. Use one
/// collector per consumer and always drive it from the same queue.
public final class SnapshotCollector {
    private let cpuSampler = CPULoadSampler()
    private let diskSampler = DiskSampler()
    private let sensors = HIDSensors()
    private let smc = SMC()
    private let batteryReader = BatteryReader()

    /// Exposed so the app can issue control commands over the same client.
    public let helper = HelperClient()
    public let sysInfo: SystemInfo

    public init(sysInfo: SystemInfo = .detect()) {
        self.sysInfo = sysInfo
    }

    /// Everything available to an unprivileged process. Rate-based fields
    /// (`coreLoads`, `disk.readBps`…) are zero on the very first call.
    public func sampleLocal() -> Snapshot {
        var s = Snapshot()
        s.date = Date()
        s.coreLoads = cpuSampler.sample()
        s.totalLoad = s.coreLoads.isEmpty ? 0 : s.coreLoads.reduce(0, +) / Double(s.coreLoads.count)
        s.sensors = sensors.read()
        s.hottest = s.sensors.filter(\.isDie).map(\.celsius).max()
        s.mem = sampleMemory(totalB: sysInfo.memTotalB)
        s.disk = diskSampler.sample()
        s.gpu = sampleGPU()
        s.fans = smc?.allFans() ?? []
        s.fanCount = smc?.fanCount ?? 0
        s.systemPowerW = smc?.double("PSTR")
        s.adapterPowerW = smc?.double("PDTR")
        s.battery = batteryReader.read()
        return s
    }

    /// A complete snapshot, blocking. Costs roughly `settleFor` seconds plus
    /// (at worst) `helperTimeout` when the helper is installed but wedged.
    ///
    /// If the helper isn't installed the snapshot still comes back — with
    /// `helperAvailable == false` and the root-only fields (`pm`, `control`,
    /// `batteryControl`) left nil. It never hangs and never traps.
    public func collect(settleFor: TimeInterval = 0.6,
                        helperTimeout: TimeInterval = 1.5) -> Snapshot {
        // Prime the rate counters, wait, then take the reading that counts.
        _ = sampleLocal()
        if settleFor > 0 { Thread.sleep(forTimeInterval: settleFor) }
        var s = sampleLocal()

        if let helperSample = fetchHelperSample(timeout: helperTimeout) {
            s.helperAvailable = true
            s.pm = helperSample.pm
            s.control = helperSample.control
            s.batteryControl = helperSample.battery
        } else {
            s.helperAvailable = false
        }
        return s
    }

    /// Synchronous helper round-trip. XPC replies land on the client's own
    /// queue, so waiting here can't deadlock; a missing helper produces an
    /// error reply (nil) rather than silence, and the timeout covers the rest.
    private func fetchHelperSample(timeout: TimeInterval) -> HelperSample? {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        helper.fetchSample { sample in
            box.value = sample
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    private final class ResultBox {
        var value: HelperSample?
    }
}
