import Foundation
import IOKit
import CoreGraphics

/// External display detection.
///
/// This exists for one reason: **forced discharge cuts the adapter off**, and
/// a monitor hanging off the Mac's USB-C/Thunderbolt path can lose its link or
/// its power when that happens. With the lid also shut, losing AC ends
/// clamshell operation and sleeps the whole machine (see `Lid`). So the
/// battery controller refuses to force-discharge while a monitor is attached.
///
/// Detection is **IOKit-based on purpose**. CoreGraphics is the obvious API but
/// it needs a window-server session, and the helper is a root LaunchDaemon that
/// doesn't have one — it would report "no displays" and cheerfully do the
/// dangerous thing. `IOMobileFramebufferShim` is readable from any context.
///
/// The distinction that matters: every external *port* publishes a shim with
/// `external = Yes` whether or not anything is plugged into it. Only a port
/// with a display actually connected carries `DisplayAttributes` (the EDID).
/// Requiring both is what separates "you have Thunderbolt ports" from "you
/// have a monitor".
public enum ExternalDisplay {
    public struct State {
        /// nil when this machine publishes no framebuffer services at all and
        /// CoreGraphics is unavailable — genuinely unknown, not "none".
        public var attached: Bool?
        /// EDID product names, for messages a person can act on.
        public var names: [String] = []
        public init() {}

        public var isAttached: Bool { attached == true }
        /// "LEN G34w-10" / "2 EXTERNAL DISPLAYS" / "AN EXTERNAL DISPLAY"
        public var describedName: String {
            if names.count == 1 { return names[0].uppercased() }
            if names.count > 1 { return "\(names.count) EXTERNAL DISPLAYS" }
            return "AN EXTERNAL DISPLAY"
        }
    }

    public static func read() -> State {
        var state = State()
        var sawFramebuffer = false

        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault,
                                        IOServiceMatching("IOMobileFramebufferShim"),
                                        &iter) == KERN_SUCCESS {
            defer { IOObjectRelease(iter) }
            while case let entry = IOIteratorNext(iter), entry != 0 {
                defer { IOObjectRelease(entry) }
                sawFramebuffer = true
                guard let ext = prop(entry, "external") as? NSNumber, ext.boolValue,
                      let attrs = prop(entry, "DisplayAttributes") as? [String: Any]
                else { continue }
                state.attached = true
                if let product = attrs["ProductAttributes"] as? [String: Any],
                   let name = product["ProductName"] as? String, !name.isEmpty {
                    state.names.append(name)
                }
            }
        }
        if sawFramebuffer, state.attached == nil { state.attached = false }

        // Cross-check with CoreGraphics. In the app this corroborates; in the
        // helper it returns nothing and contributes nothing. Never used to
        // *clear* an IOKit detection — only to add one.
        if let cg = coreGraphicsExternalCount() {
            if cg > 0 { state.attached = true }
            else if state.attached == nil { state.attached = false }
        }
        return state
    }

    private static func prop(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    /// nil when CoreGraphics can't answer (no window-server session).
    private static func coreGraphicsExternalCount() -> Int? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }
}
