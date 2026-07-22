import Foundation
import XPC
import Shared

/// TempControl privileged helper. Installed as a LaunchDaemon (root) with a
/// MachServices endpoint. Responsibilities:
///   - stream `powermetrics` (per-core freq/power — root only) on demand
///   - run the fan boost control loop
///   - watchdog: if the app stops heartbeating, fans revert to automatic
///   - toggle low power mode via pmset
final class HelperCore {
    private let smc = SMC()
    private let sensors = HIDSensors()
    private lazy var fans = FanController(smc: smc, sensors: sensors)
    private lazy var battery = BatteryController(smc: smc)
    private let pm = PowerMetricsStreamer()
    private let queue = DispatchQueue(label: "tempcontrol.helper")
    private var lastHeartbeat = Date()
    private var listener: xpc_connection_t?
    private var timer: DispatchSourceTimer?
    private var tickCount = 0

    func run() {
        setupSignals()
        setupTimer()
        setupListener()
        dispatchMain()
    }

    // MARK: control loop + watchdog, every 2s

    private func setupTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.fans.enabled, Date().timeIntervalSince(self.lastHeartbeat) > TC.heartbeatTimeout {
                // App is gone — never keep forcing fans unattended.
                self.fans.disableAndRelease()
            }
            self.fans.tick()
            self.pm.reapIfIdle()
            // Battery moves slowly — every 5th tick (10s) is plenty.
            self.tickCount += 1
            if self.tickCount % 5 == 0 { self.battery.tick() }
        }
        t.resume()
        timer = t
    }

    // MARK: graceful shutdown — always hand fans back to macOS

    private func setupSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { [weak self] in
                self?.fans.disableAndRelease()
                self?.pm.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: XPC listener

    private func setupListener() {
        let l = xpc_connection_create_mach_service(
            TC.helperMachName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        xpc_connection_set_event_handler(l) { [weak self] peer in
            guard let self, xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            xpc_connection_set_event_handler(peer) { [weak self] msg in
                self?.handle(msg, from: peer)
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(l)
        listener = l
    }

    private func handle(_ msg: xpc_object_t, from peer: xpc_connection_t) {
        guard xpc_get_type(msg) == XPC_TYPE_DICTIONARY,
              let cmdC = xpc_dictionary_get_string(msg, "cmd"),
              let reply = xpc_dictionary_create_reply(msg)
        else { return }
        let cmd = String(cString: cmdC)

        switch cmd {
        case "sample":
            lastHeartbeat = Date()
            pm.markWanted()
            var status = fans.status()
            status.lowPowerMode = readLowPowerMode()
            encode(HelperSample(pm: pm.latest, control: status, battery: battery.state()),
                   into: reply)

        case "setBattery":
            var len = 0
            if let ptr = xpc_dictionary_get_data(msg, "json", &len), len > 0,
               let s = try? JSONDecoder().decode(BatterySettings.self,
                                                 from: Data(bytes: ptr, count: len)) {
                battery.apply(s)
            }
            encode(battery.state(), into: reply)

        case "topUp":
            battery.setTopUp(xpc_dictionary_get_bool(msg, "on"))
            encode(battery.state(), into: reply)

        case "calibrate":
            battery.setCalibration(xpc_dictionary_get_bool(msg, "on"))
            encode(battery.state(), into: reply)

        case "heartbeat", "status":
            lastHeartbeat = Date()
            encode(fans.status(), into: reply)

        case "setControl":
            lastHeartbeat = Date()
            let enabled = xpc_dictionary_get_bool(msg, "enabled")
            let target = xpc_dictionary_get_double(msg, "target")
            let ok = fans.setControl(enabled: enabled, target: target)
            xpc_dictionary_set_bool(reply, "ok", ok)
            encode(fans.status(), into: reply)

        case "setLowPower":
            let on = xpc_dictionary_get_bool(msg, "on")
            let ok = setLowPowerMode(on)
            xpc_dictionary_set_bool(reply, "ok", ok)

        default:
            xpc_dictionary_set_bool(reply, "ok", false)
        }
        xpc_connection_send_message(peer, reply)
    }

    private func encode<T: Encodable>(_ value: T, into reply: xpc_object_t) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                xpc_dictionary_set_data(reply, "json", base, raw.count)
            }
        }
    }

    // MARK: low power mode (bonus performance control)

    private func readLowPowerMode() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("lowpowermode") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return nil
    }

    private func setLowPowerMode(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-a", "lowpowermode", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// CLI mode used by uninstall.sh (run as root): put every battery-control SMC
// key back to macOS defaults, then exit.
if CommandLine.arguments.contains("--reset-battery") {
    BatteryController.resetStandalone()
    print("battery control keys reset to macOS defaults")
    exit(0)
}

let core = HelperCore()
core.run()
