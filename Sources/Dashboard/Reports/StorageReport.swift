import Foundation
import Shared

/// Mirrors the STORAGE tab (`Views/StoragePanel.swift`: CapacityBox,
/// ActivityBox, DriveBox).
public enum StorageReport: PanelReporting {
    public static let panel = Panel.storage

    public static func sections(_ s: Snapshot, _ sys: SystemInfo) -> [ReportSection] {
        [capacity(s), activity(s), drive(s)]
    }

    // MARK: CAPACITY

    private static func capacity(_ s: Snapshot) -> ReportSection {
        let d = s.disk
        let used = max(0, d.totalB - d.freeB)
        var rows: [ReportRow] = [
            ReportRow("INTERNAL SSD", "\(Fmt.bytes(used)) / \(Fmt.bytes(d.totalB)) USED",
                      raw: Double(used), unit: "B"),
            .bytes("TOTAL", d.totalB),
            .bytes("FREE", d.freeB),
            .bytes("PURGEABLE", d.purgeableB),
        ]
        for vol in d.volumes {
            let usedFrac = vol.totalB > 0 ? Double(vol.totalB - vol.freeB) / Double(vol.totalB) : 0
            rows.append(ReportRow(vol.name.uppercased(),
                                  "\(Fmt.percentPadded(usedFrac)) USED   \(Fmt.bytes(vol.totalB - vol.freeB)) / \(Fmt.bytes(vol.totalB))   \(vol.path)",
                                  raw: usedFrac * 100, unit: "%"))
        }
        return ReportSection("CAPACITY", rows,
                             note: "PURGEABLE = SPACE MACOS FREES AUTOMATICALLY (SNAPSHOTS, CACHES)")
    }

    // MARK: I/O ACTIVITY

    private static func activity(_ s: Snapshot) -> ReportSection {
        let d = s.disk
        let rows: [ReportRow] = [
            ReportRow("READ", Fmt.rate(d.readBps), raw: d.readBps, unit: "B/s"),
            ReportRow("WRITE", Fmt.rate(d.writeBps), raw: d.writeBps, unit: "B/s"),
            ReportRow("READ IOPS", Fmt.count(d.readIOPS), raw: d.readIOPS, unit: "IO/s"),
            ReportRow("WRITE IOPS", Fmt.count(d.writeIOPS), raw: d.writeIOPS, unit: "IO/s"),
            latency("READ LAT", d.readLatencyMs),
            latency("WRITE LAT", d.writeLatencyMs),
        ]
        return ReportSection("I/O ACTIVITY", rows,
                             note: "RATES ARE MEASURED ACROSS THE SAMPLE WINDOW, NOT SINCE BOOT")
    }

    /// Zero latency means "no I/O in the window", not "instant" — the app
    /// shows a dash there, so the CLI does too.
    private static func latency(_ label: String, _ ms: Double) -> ReportRow {
        ms > 0 ? ReportRow(label, Fmt.ms(ms), raw: ms, unit: "ms")
               : ReportRow(label, Fmt.none, raw: nil, unit: "ms")
    }

    // MARK: DRIVE

    private static func drive(_ s: Snapshot) -> ReportSection {
        let d = s.disk
        let nand = s.sensors.first { $0.name.lowercased().contains("nand") }?.celsius
        let rows: [ReportRow] = [
            .bytes("READ SINCE BOOT", d.bootReadB),
            .bytes("WRITTEN SINCE BOOT", d.bootWriteB),
            .temp("NAND TEMP", nand),
            .int("VOLUMES", d.volumes.count),
        ]
        return ReportSection("DRIVE", rows,
                             note: "WRITTEN-SINCE-BOOT IS THE NUMBER THAT WEARS SSD CELLS — SUSTAINED HEAVY WRITES MATTER MORE THAN READS")
    }
}
