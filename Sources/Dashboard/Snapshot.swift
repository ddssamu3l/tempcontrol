import Foundation
import Shared

/// One complete reading of the machine. Produced by `SnapshotCollector`
/// (synchronously for the CLI, on a timer for the app) and consumed by both
/// the SwiftUI views and the `PanelReporting` reporters, so neither surface
/// can see data the other cannot.
public struct Snapshot {
    public var date = Date()
    public var coreLoads: [Double] = []
    public var totalLoad: Double = 0
    public var sensors: [TempSensor] = []
    public var hottest: Double?
    public var mem = MemStats()
    public var disk = DiskStats()
    public var gpu = GPUStats()
    public var fans: [FanState] = []
    public var fanCount: Int = 0
    /// Whole-machine draw from the SMC (PSTR) — includes display, SSD, fans;
    /// works without the helper.
    public var systemPowerW: Double?
    /// Actual adapter input right now (SMC PDTR), not the adapter's rating.
    public var adapterPowerW: Double?
    public var battery: BatteryInfo?
    public var batteryControl: BatteryControlState?
    public var pm: PMSample?
    public var control: ControlStatus?
    public var helperAvailable = false

    public init() {}
}
