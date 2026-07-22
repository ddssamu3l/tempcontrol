import Foundation
import XPC
import Shared

/// XPC client for the root helper. If the helper isn't installed, every
/// request cleanly reports failure and the app degrades to dashboard-only.
public final class HelperClient {
    public init() {}

    private let queue = DispatchQueue(label: "tempcontrol.helperclient")
    private var conn: xpc_connection_t?

    private func connection() -> xpc_connection_t {
        if let c = conn { return c }
        let c = xpc_connection_create_mach_service(TC.helperMachName, queue, 0)
        xpc_connection_set_event_handler(c) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                // Drop the cached connection so we retry fresh next time
                // (covers "helper installed after app launch").
                self?.conn = nil
            }
        }
        xpc_connection_activate(c)
        conn = c
        return c
    }

    private func request(_ cmd: String,
                         bools: [String: Bool] = [:],
                         doubles: [String: Double] = [:],
                         json: Data? = nil,
                         completion: @escaping (xpc_object_t?) -> Void) {
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "cmd", cmd)
        for (k, v) in bools { xpc_dictionary_set_bool(msg, k, v) }
        for (k, v) in doubles { xpc_dictionary_set_double(msg, k, v) }
        json?.withUnsafeBytes { raw in
            if let base = raw.baseAddress { xpc_dictionary_set_data(msg, "json", base, raw.count) }
        }
        xpc_connection_send_message_with_reply(connection(), msg, queue) { reply in
            completion(xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? reply : nil)
        }
    }

    private func decodeJSON<T: Decodable>(_ reply: xpc_object_t?, _ type: T.Type) -> T? {
        guard let reply else { return nil }
        var len = 0
        guard let ptr = xpc_dictionary_get_data(reply, "json", &len), len > 0 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(bytes: ptr, count: len))
    }

    // MARK: typed API (completions run on an arbitrary queue)

    public func fetchSample(_ completion: @escaping (HelperSample?) -> Void) {
        request("sample") { completion(self.decodeJSON($0, HelperSample.self)) }
    }

    public func heartbeat(_ completion: @escaping (ControlStatus?) -> Void) {
        request("heartbeat") { completion(self.decodeJSON($0, ControlStatus.self)) }
    }

    public func setControl(enabled: Bool, target: Double, _ completion: @escaping (ControlStatus?) -> Void) {
        request("setControl", bools: ["enabled": enabled], doubles: ["target": target]) {
            completion(self.decodeJSON($0, ControlStatus.self))
        }
    }

    public func setLowPower(_ on: Bool, _ completion: @escaping (Bool) -> Void) {
        request("setLowPower", bools: ["on": on]) { reply in
            completion(reply.map { xpc_dictionary_get_bool($0, "ok") } ?? false)
        }
    }

    public func setBatterySettings(_ s: BatterySettings, _ completion: @escaping (BatteryControlState?) -> Void) {
        request("setBattery", json: try? JSONEncoder().encode(s)) {
            completion(self.decodeJSON($0, BatteryControlState.self))
        }
    }

    public func setTopUp(_ on: Bool, _ completion: @escaping (BatteryControlState?) -> Void) {
        request("topUp", bools: ["on": on]) {
            completion(self.decodeJSON($0, BatteryControlState.self))
        }
    }

    public func setCalibration(_ on: Bool, _ completion: @escaping (BatteryControlState?) -> Void) {
        request("calibrate", bools: ["on": on]) {
            completion(self.decodeJSON($0, BatteryControlState.self))
        }
    }
}
