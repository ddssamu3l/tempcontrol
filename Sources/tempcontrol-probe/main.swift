import Foundation
import Shared

// Diagnostic tool: run `swift run tempcontrol-probe` to see exactly which
// sensors and fan data your Mac exposes. Attach this output to bug reports.

print("== TempControl probe ==")

let sensors = HIDSensors()
let temps = sensors.read()
print("\n[HID temperature sensors] (\(temps.count) found)")
for s in temps {
    print(String(format: "  %-34s %6.1f °C  %@%@",
                 (s.name as NSString).utf8String!, s.celsius,
                 s.group.rawValue, s.isDie ? "" : " (not die)"))
}
if let hottest = sensors.hottestDie() {
    print(String(format: "  hottest die: %.1f °C", hottest))
} else {
    print("  !! no die sensors found")
}

print("\n[SMC fans]")
if let smc = SMC() {
    if let raw = smc.rawInfo("FNum") {
        print(String(format: "  raw FNum: size=%u type=0x%08x byte0=%u decoded=%@",
                     raw.size, raw.type, raw.byte0, String(describing: smc.double("FNum"))))
    } else {
        print("  raw FNum: read FAILED")
    }
    let n = smc.fanCount
    print("  fan count: \(n)\(n == 0 ? "  (fanless Mac — fan control unavailable)" : "")")
    for fan in smc.allFans() {
        print(String(format: "  fan%d: actual %.0f rpm  range %.0f–%.0f  target %.0f",
                     fan.id, fan.actualRPM, fan.minRPM, fan.maxRPM, fan.targetRPM))
    }
    print("\n[SMC battery-control keys]")
    for (key, label) in [("CH0B", "charge inhibit B"), ("CH0C", "charge inhibit C"),
                         ("CH0I", "adapter disable"), ("CHWA", "80% hw limit"),
                         ("ACLC", "magsafe led")] {
        if let raw = smc.rawInfo(key) {
            print(String(format: "  %@ (%@): size=%u type=0x%08x value=%u", key, label, raw.size, raw.type, raw.byte0))
        } else {
            print("  \(key) (\(label)): not available")
        }
    }

    print("\n[SMC power rails]")
    for (key, label) in [("PSTR", "system total"), ("PDTR", "DC-in/adapter"), ("PPBR", "battery")] {
        if let w = smc.double(key) {
            print(String(format: "  %@ (%@): %.2f W", key, label, w))
        } else {
            print("  \(key) (\(label)): not available")
        }
    }
} else {
    print("  !! could not open SMC")
}
