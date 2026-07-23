import Foundation
import Shared

/// Runs `powermetrics` (root only) as a streaming subprocess and keeps the
/// latest parsed sample. Only runs while the app is actually asking for data —
/// it stops itself after 15s of no interest so the daemon idles at ~0% CPU.
final class PowerMetricsStreamer {
    private let queue = DispatchQueue(label: "tempcontrol.powermetrics")
    private var process: Process?
    private var buffer = Data()
    private var wantedUntil = Date.distantPast
    /// The `tasks` sampler (per-process CPU/GPU) is heavier and only wanted
    /// while the TASKS panel is open, so it's tracked separately. Flipping it
    /// changes powermetrics' arguments, which forces a stream restart.
    private var tasksWantedUntil = Date.distantPast
    private var tasksActive = false

    private let lock = NSLock()
    private var _latest: PMSample?
    /// pid → per-process GPU ms/s and energy impact, newest sample only.
    private var _latestTasks: [Int32: (gpu: Double?, energy: Double?)] = [:]
    /// Set once we've actually seen a GPU number — proves this hardware
    /// reports per-process GPU (the man page says not all do).
    private var _gpuAccounting = false

    var latest: PMSample? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    var latestTasks: [Int32: (gpu: Double?, energy: Double?)] {
        lock.lock(); defer { lock.unlock() }
        return _latestTasks
    }

    var gpuAccounting: Bool {
        lock.lock(); defer { lock.unlock() }
        return _gpuAccounting
    }

    /// Called whenever the app requests a sample; keeps the stream alive 15s.
    func markWanted() {
        queue.async {
            self.wantedUntil = Date().addingTimeInterval(15)
            self.startLocked()
        }
    }

    /// Called when the TASKS panel is open — adds the per-process sampler.
    /// Restarts the stream if it wasn't already running with tasks.
    func markTasksWanted() {
        queue.async {
            self.wantedUntil = Date().addingTimeInterval(15)
            self.tasksWantedUntil = Date().addingTimeInterval(15)
            let shouldRun = Date() < self.tasksWantedUntil
            if shouldRun != self.tasksActive {
                self.tasksActive = shouldRun
                self.restartLocked()
            } else {
                self.startLocked()
            }
        }
    }

    /// Called from the maintenance timer.
    func reapIfIdle() {
        queue.async {
            // Drop the (heavier) tasks sampler as soon as the panel closes,
            // even while the lean stream keeps running for fan control.
            if self.tasksActive, Date() > self.tasksWantedUntil {
                self.tasksActive = false
                self.lock.lock(); self._latestTasks.removeAll(); self.lock.unlock()
                if Date() <= self.wantedUntil { self.restartLocked() }
            }
            if Date() > self.wantedUntil { self.stopLocked() }
        }
    }

    func shutdown() {
        queue.sync { self.stopLocked() }
    }

    /// Stop and immediately restart so new arguments (tasks on/off) take hold.
    private func restartLocked() {
        stopLocked()
        startLocked()
    }

    private func startLocked() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        // plist samples separated by NUL bytes, once per second.
        var samplers = "cpu_power,gpu_power,thermal"
        var args = ["-i", "1000", "-f", "plist"]
        if tasksActive {
            samplers += ",tasks"
            // Per-process GPU is the whole point of the panel; IO + energy are
            // cheap to add and fill the other columns.
            args += ["--show-process-gpu", "--show-process-io", "--show-process-energy"]
        }
        args += ["-s", samplers]
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.process = nil
                self.buffer.removeAll()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            process = nil
        }
    }

    private func stopLocked() {
        guard let p = process else { return }
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminate()
        process = nil
        buffer.removeAll()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        // Each powermetrics sample is a complete XML plist terminated by \0.
        while let nul = buffer.firstIndex(of: 0) {
            let chunk = buffer.subdata(in: buffer.startIndex..<nul)
            buffer.removeSubrange(buffer.startIndex...nul)
            guard !chunk.isEmpty,
                  let obj = try? PropertyListSerialization.propertyList(from: chunk, format: nil),
                  let dict = obj as? [String: Any]
            else { continue }
            let sample = Self.parse(dict)
            let tasks = Self.parseTasks(dict)
            lock.lock()
            _latest = sample
            if let tasks {
                _latestTasks = tasks.byPid
                if tasks.sawGPU { _gpuAccounting = true }
            }
            lock.unlock()
        }
        // Guard against runaway garbage if parsing desyncs.
        if buffer.count > 4_000_000 { buffer.removeAll() }
    }

    /// Field names vary a little across chip generations and macOS versions,
    /// so everything is optional and parsed defensively.
    static func parse(_ dict: [String: Any]) -> PMSample {
        var s = PMSample()
        s.timestamp = Date().timeIntervalSince1970
        let elapsedNs = dict["elapsed_ns"] as? Double

        func watts(fromMilliwatts key: String, in d: [String: Any]) -> Double? {
            (d[key] as? Double).map { $0 / 1000.0 }
        }
        // Energy counters are mJ over the sample window.
        func watts(fromEnergy key: String, in d: [String: Any]) -> Double? {
            guard let e = d[key] as? Double, let ns = elapsedNs, ns > 0 else { return nil }
            return (e / 1000.0) / (ns / 1e9)
        }

        if let proc = dict["processor"] as? [String: Any] {
            for c in proc["clusters"] as? [[String: Any]] ?? [] {
                let cores: [PMCore] = (c["cpus"] as? [[String: Any]] ?? []).map { cpu in
                    PMCore(
                        id: cpu["cpu"] as? Int ?? -1,
                        freqMHz: (cpu["freq_hz"] as? Double ?? 0) / 1e6,
                        activeRatio: 1.0 - (cpu["idle_ratio"] as? Double ?? 1.0)
                    )
                }
                s.clusters.append(PMCluster(
                    name: c["name"] as? String ?? "?",
                    freqMHz: (c["freq_hz"] as? Double ?? 0) / 1e6,
                    activeRatio: 1.0 - (c["idle_ratio"] as? Double ?? 1.0),
                    cores: cores
                ))
            }
            s.cpuPowerW = watts(fromMilliwatts: "cpu_power", in: proc) ?? watts(fromEnergy: "cpu_energy", in: proc)
            s.gpuPowerW = watts(fromMilliwatts: "gpu_power", in: proc)
            s.anePowerW = watts(fromMilliwatts: "ane_power", in: proc) ?? watts(fromEnergy: "ane_energy", in: proc)
            s.combinedPowerW = watts(fromMilliwatts: "combined_power", in: proc)
        }

        if let gpu = dict["gpu"] as? [String: Any] {
            s.gpuFreqMHz = (gpu["freq_hz"] as? Double).map { $0 / 1e6 }
            s.gpuActiveRatio = (gpu["idle_ratio"] as? Double).map { 1.0 - $0 }
            if s.gpuPowerW == nil {
                s.gpuPowerW = watts(fromMilliwatts: "gpu_power", in: gpu) ?? watts(fromEnergy: "gpu_energy", in: gpu)
            }
        }

        s.thermalPressure = dict["thermal_pressure"] as? String
        return s
    }

    /// Parse the `tasks` sampler array into per-pid GPU ms/s and energy impact.
    /// nil when the sample carried no tasks (tasks sampler not enabled).
    ///
    /// Key names are read defensively across a few spellings powermetrics has
    /// used. GPU is the field the panel exists for — `sawGPU` records whether
    /// any process reported a real (non-nil) GPU number, which is how we learn
    /// this hardware supports per-process GPU accounting at all.
    static func parseTasks(_ dict: [String: Any]) -> (byPid: [Int32: (gpu: Double?, energy: Double?)], sawGPU: Bool)? {
        guard let tasks = dict["tasks"] as? [[String: Any]] else { return nil }
        func num(_ d: [String: Any], _ keys: [String]) -> Double? {
            for k in keys { if let v = d[k] as? Double { return v }
                            if let v = d[k] as? NSNumber { return v.doubleValue } }
            return nil
        }
        var byPid: [Int32: (gpu: Double?, energy: Double?)] = [:]
        var sawGPU = false
        for t in tasks {
            guard let pidD = num(t, ["pid"]) else { continue }
            let gpu = num(t, ["gputime_ms_per_s", "gpu_ms_per_s", "gputime_ms_per_sec"])
            let energy = num(t, ["energy_impact_per_s", "energy_impact_per_sec", "energy_impact"])
            if gpu != nil { sawGPU = true }
            byPid[Int32(pidD)] = (gpu, energy)
        }
        return (byPid, sawGPU)
    }
}
