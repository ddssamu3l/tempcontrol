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

    private let lock = NSLock()
    private var _latest: PMSample?

    var latest: PMSample? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    /// Called whenever the app requests a sample; keeps the stream alive 15s.
    func markWanted() {
        queue.async {
            self.wantedUntil = Date().addingTimeInterval(15)
            self.startLocked()
        }
    }

    /// Called from the maintenance timer.
    func reapIfIdle() {
        queue.async {
            if Date() > self.wantedUntil { self.stopLocked() }
        }
    }

    func shutdown() {
        queue.sync { self.stopLocked() }
    }

    private func startLocked() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        // plist samples separated by NUL bytes, once per second.
        p.arguments = ["-i", "1000", "-f", "plist", "-s", "cpu_power,gpu_power,thermal"]
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
            lock.lock()
            _latest = sample
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
}
