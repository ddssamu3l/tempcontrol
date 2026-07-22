import Foundation
import CShims

/// Thin Swift wrapper over the C SMC user client.
/// Reads (fan RPM etc.) work as a normal user; writes need root (the helper).
public final class SMC {
    private var conn: io_connect_t = 0
    private let lock = NSLock()

    public init?() {
        var c: io_connect_t = 0
        guard smc_open(&c) == 0 else { return nil }
        conn = c
    }

    deinit { smc_close(conn) }

    private static func fourcc(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for ch in s.utf8.prefix(4) { v = (v << 8) | UInt32(ch) }
        return v
    }

    private func read(_ key: String) -> SMCVal_t? {
        lock.lock(); defer { lock.unlock() }
        var val = SMCVal_t()
        guard smc_read_key(conn, key, &val) == 0 else { return nil }
        return val
    }

    /// Decode a numeric SMC value regardless of its declared type.
    public func double(_ key: String) -> Double? {
        guard let val = read(key) else { return nil }
        var bytes = val.bytes
        return withUnsafeBytes(of: &bytes) { raw -> Double? in
            switch val.dataType {
            case Self.fourcc("flt "):
                // Little-endian IEEE float (the Apple Silicon fan/temp format).
                return Double(Float(bitPattern: raw.loadUnaligned(as: UInt32.self)))
            case Self.fourcc("ui8 "):
                return Double(raw.load(as: UInt8.self))
            case Self.fourcc("ui16"):
                return Double(UInt16(bigEndian: raw.loadUnaligned(as: UInt16.self)))
            case Self.fourcc("ui32"):
                return Double(UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self)))
            case Self.fourcc("sp78"):
                let raw16 = Int16(bitPattern: UInt16(bigEndian: raw.loadUnaligned(as: UInt16.self)))
                return Double(raw16) / 256.0
            default:
                return nil
            }
        }
    }

    public func int(_ key: String) -> Int? {
        double(key).map { Int($0) }
    }

    // MARK: Fans

    /// Number of fans. 0 on fanless Macs (MacBook Air) — fan control must be refused then.
    public var fanCount: Int { int("FNum") ?? 0 }

    public func fanState(_ i: Int) -> FanState? {
        guard let actual = double("F\(i)Ac") else { return nil }
        return FanState(
            id: i,
            actualRPM: actual,
            minRPM: double("F\(i)Mn") ?? 0,
            maxRPM: double("F\(i)Mx") ?? 0,
            targetRPM: double("F\(i)Tg") ?? 0
        )
    }

    public func allFans() -> [FanState] {
        (0..<fanCount).compactMap { fanState($0) }
    }

    // MARK: Fan writes (root only — called from the helper)

    @discardableResult
    private func write(_ key: String, _ val: SMCVal_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var v = val
        return smc_write_key(conn, key, &v) == 0
    }

    /// F{i}Md: 0 = macOS automatic control, 1 = forced (obey F{i}Tg).
    @discardableResult
    public func setFanMode(_ i: Int, forced: Bool) -> Bool {
        var val = SMCVal_t()
        val.dataSize = 1
        val.dataType = Self.fourcc("ui8 ")
        val.bytes.0 = forced ? 1 : 0
        return write("F\(i)Md", val)
    }

    @discardableResult
    public func setFanTarget(_ i: Int, rpm: Double) -> Bool {
        var val = SMCVal_t()
        val.dataSize = 4
        val.dataType = Self.fourcc("flt ")
        let bits = Float(rpm).bitPattern
        val.bytes.0 = UInt8(bits & 0xff)
        val.bytes.1 = UInt8((bits >> 8) & 0xff)
        val.bytes.2 = UInt8((bits >> 16) & 0xff)
        val.bytes.3 = UInt8((bits >> 24) & 0xff)
        return write("F\(i)Tg", val)
    }
}
