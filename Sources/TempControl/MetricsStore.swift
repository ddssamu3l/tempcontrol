import Foundation
import Combine
import Shared
import Dashboard

/// Fixed-length rolling history for the sparklines.
struct History {
    var cpu: [Double] = []
    var gpu: [Double] = []
    var temp: [Double] = []
    var power: [Double] = []
    var diskRead: [Double] = []
    var diskWrite: [Double] = []
    var fanRPM: [Double] = []
    var batteryPct: [Double] = []
    var batteryW: [Double] = []
    /// Controller output 0...1 (0 when not engaged).
    var fanLevel: [Double] = []
    var batteryTemp: [Double] = []

    static let capacity = 120
    mutating func push(_ keyPath: WritableKeyPath<History, [Double]>, _ v: Double) {
        self[keyPath: keyPath].append(v)
        if self[keyPath: keyPath].count > Self.capacity {
            self[keyPath: keyPath].removeFirst(self[keyPath: keyPath].count - Self.capacity)
        }
    }
}

final class MetricsStore: ObservableObject {
    @Published var snap = Snapshot()
    @Published var history = History()
    @Published var desiredTarget: Double = 80
    @Published var desiredEnabled = false
    @Published var batterySettings = BatterySettings()

    /// Same collector the CLI uses — one definition of "a sample".
    private let collector = SnapshotCollector()
    var sysInfo: SystemInfo { collector.sysInfo }
    private var helper: HelperClient { collector.helper }

    private let queue = DispatchQueue(label: "tempcontrol.metrics", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var syncedControlFromHelper = false
    private var syncedBatteryFromHelper = false

    /// 1s refresh while the dashboard is visible; 5s in the background
    /// (keeps the menu bar temp fresh and the helper heartbeat alive).
    var popoverOpen = false {
        didSet { if popoverOpen != oldValue { restartTimer() } }
    }

    /// True only while the TASKS panel is on screen. Gates the per-process
    /// sample (libproc locally, powermetrics GPU in the helper) so the cost is
    /// paid only when someone's looking. Set by `TasksView`.
    @Published var showingTasks = false

    init() {
        restartTimer()
    }

    private func restartTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval: Double = popoverOpen ? 1.0 : 5.0
        t.schedule(deadline: .now() + 0.05, repeating: interval)
        t.setEventHandler { [weak self] in self?.sampleOnce() }
        t.resume()
        timer = t
    }

    private func sampleOnce() {
        // Local (unprivileged) half of the snapshot; the helper reply is
        // folded in below, exactly as before.
        let wantTasks = showingTasks
        collector.wantTasks = wantTasks           // adds the libproc fallback list
        let s = collector.sampleLocal()

        let wantFullSample = popoverOpen
        let needHeartbeat = desiredEnabled

        if wantFullSample {
            helper.fetchSample(wantTasks: wantTasks) { [weak self] helperSample in
                self?.publish(s, helper: helperSample, helperTried: true)
            }
        } else if needHeartbeat {
            helper.heartbeat { [weak self] status in
                var hs: HelperSample?
                if let status { hs = HelperSample(pm: nil, control: status) }
                self?.publish(s, helper: hs, helperTried: true)
            }
        } else {
            publish(s, helper: nil, helperTried: false)
        }
    }

    private func publish(_ base: Snapshot, helper helperSample: HelperSample?, helperTried: Bool) {
        var s = base
        if let helperSample {
            s.helperAvailable = true
            s.pm = helperSample.pm
            s.control = helperSample.control
            s.batteryControl = helperSample.battery
            s.gpuAccounting = helperSample.gpuAccounting
            // Root-gathered list wins over the local fallback: complete + GPU.
            if let tasks = helperSample.tasks {
                s.tasks = tasks
                s.tasksComplete = true
            }
        } else if helperTried {
            s.helperAvailable = false
        } else {
            s.helperAvailable = snapHelperWasAvailable
        }

        DispatchQueue.main.async {
            self.snapHelperWasAvailable = s.helperAvailable
            // Adopt the helper's persisted control state once at startup,
            // so reopening the app doesn't clobber a running boost.
            if let c = s.control, !self.syncedControlFromHelper {
                self.syncedControlFromHelper = true
                self.desiredTarget = c.targetTemp
                self.desiredEnabled = c.enabled
            }
            // Same one-time adoption for battery settings (helper persists them).
            if let b = s.batteryControl, !self.syncedBatteryFromHelper {
                self.syncedBatteryFromHelper = true
                self.batterySettings = b.settings
            }
            self.snap = s
            self.history.push(\.cpu, s.totalLoad)
            self.history.push(\.gpu, s.gpu.deviceUtil ?? 0)
            self.history.push(\.temp, s.hottest ?? 0)
            // socPowerW, not combinedPowerW — combined_power isn't reported on
            // every chip/OS, and the sparkline must match the PACKAGE readout.
            self.history.push(\.power, s.pm?.socPowerW ?? 0)
            self.history.push(\.diskRead, s.disk.readBps)
            self.history.push(\.diskWrite, s.disk.writeBps)
            self.history.push(\.fanRPM, s.fans.map(\.actualRPM).max() ?? 0)
            self.history.push(\.batteryPct, s.battery?.hwPercent ?? 0)
            self.history.push(\.batteryW, s.battery?.batteryPowerW ?? 0)
            self.history.push(\.fanLevel, s.control?.fanLevel ?? 0)
            self.history.push(\.batteryTemp, s.battery?.temperatureC ?? 0)
        }
    }
    private var snapHelperWasAvailable = false

    // MARK: control actions

    func pushControl() {
        let target = desiredTarget
        let enabled = desiredEnabled
        helper.setControl(enabled: enabled, target: target) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                if let status {
                    self.snap.control = status
                    // Helper refuses on fanless Macs.
                    if enabled && !status.enabled { self.desiredEnabled = false }
                } else {
                    self.desiredEnabled = false
                }
            }
        }
    }

    func setLowPower(_ on: Bool) {
        helper.setLowPower(on) { _ in }
    }

    // MARK: battery actions

    func pushBatterySettings() {
        helper.setBatterySettings(batterySettings) { [weak self] state in
            DispatchQueue.main.async {
                if let state {
                    self?.snap.batteryControl = state
                    self?.batterySettings = state.settings
                }
            }
        }
    }

    func setTopUp(_ on: Bool) {
        helper.setTopUp(on) { [weak self] state in
            DispatchQueue.main.async { if let state { self?.snap.batteryControl = state } }
        }
    }

    func setCalibration(_ on: Bool) {
        helper.setCalibration(on) { [weak self] state in
            DispatchQueue.main.async { if let state { self?.snap.batteryControl = state } }
        }
    }
}
