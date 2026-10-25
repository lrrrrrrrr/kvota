import Foundation

/// Small helpers for reading loosely typed JSON from `JSONSerialization`.
enum JSON {
    static func object(_ bytes: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = bytes.baseAddress, bytes.count > 1 else { return nil }
        let data = Data(bytes: base, count: bytes.count)
        return object(data)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    static func int(_ value: Any?) -> Int64 {
        optionalInt(value) ?? 0
    }

    static func optionalInt(_ value: Any?) -> Int64? {
        switch value {
        case let n as Int: return Int64(n)
        case let n as Int64: return n
        case let n as Double: return n.isFinite ? Int64(n) : nil
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s) ?? Double(s).map { Int64($0) }
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n.isFinite ? n : nil
        case let n as Int: return Double(n)
        case let n as Int64: return Double(n)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased())
        default: return nil
        }
    }

    /// Dates arrive as ISO strings, epoch seconds or epoch milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            if let d = Timestamp.parse(s) { return d }
            if let n = Double(s) { return epoch(n) }
            return nil
        }
        if let n = double(value) { return epoch(n) }
        return nil
    }

    private static func epoch(_ n: Double) -> Date? {
        guard n > 0 else { return nil }
        // Anything past the year 5000 in seconds is really milliseconds.
        return Date(timeIntervalSince1970: n > 95_000_000_000 ? n / 1000 : n)
    }
}
