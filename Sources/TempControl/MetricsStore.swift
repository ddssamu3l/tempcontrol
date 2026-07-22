import Foundation
import Combine
import Shared

struct Snapshot {
    var date = Date()
    var coreLoads: [Double] = []
    var totalLoad: Double = 0
    var sensors: [TempSensor] = []
    var hottest: Double?
    var mem = MemStats()
    var disk = DiskStats()
    var gpu = GPUStats()
    var fans: [FanState] = []
    var fanCount: Int = 0
    /// Whole-machine draw from the SMC (PSTR) — includes display, SSD, fans;
    /// works without the helper.
    var systemPowerW: Double?
    /// Actual adapter input right now (SMC PDTR), not the adapter's rating.
    var adapterPowerW: Double?
    var battery: BatteryInfo?
    var batteryControl: BatteryControlState?
    var pm: PMSample?
    var control: ControlStatus?
    var helperAvailable = false
}

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

    let sysInfo = SystemInfo.detect()

    private let cpuSampler = CPULoadSampler()
    private let diskSampler = DiskSampler()
    private let sensors = HIDSensors()
    private let smc = SMC()
    private let helper = HelperClient()
    private let batteryReader = BatteryReader()
    private let queue = DispatchQueue(label: "tempcontrol.metrics", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var syncedControlFromHelper = false
    private var syncedBatteryFromHelper = false

    /// 1s refresh while the dashboard is visible; 5s in the background
    /// (keeps the menu bar temp fresh and the helper heartbeat alive).
    var popoverOpen = false {
        didSet { if popoverOpen != oldValue { restartTimer() } }
    }

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

        let wantFullSample = popoverOpen
        let needHeartbeat = desiredEnabled

        if wantFullSample {
            helper.fetchSample { [weak self] helperSample in
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
            self.history.push(\.power, s.pm?.combinedPowerW ?? 0)
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
