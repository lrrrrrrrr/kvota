import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Streams newline-delimited files without loading them whole, so large session logs
/// stay cheap to read. Lines are handed out as raw bytes; callers decode only the
/// lines that pass a quick substring filter.
enum LineScanner {
    static let chunkSize = 1 << 20

    /// Calls `body` for every complete line from `offset` on and returns the offset just
    /// after the last newline. A line still being written is left for the next call.
    static func scan(url: URL, from offset: UInt64, _ body: (UnsafeRawBufferPointer) -> Void) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var consumed = offset
        var pending = Data()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            pending.append(chunk)
            let used = pending.withUnsafeBytes { forEachCompleteLine($0, body) }
            if used > 0 {
                consumed += UInt64(used)
                pending = used == pending.count ? Data() : pending.subdata(in: used..<pending.count)
            }
        }
        return consumed
    }

    /// Splits `buffer` on newlines. Returns the number of bytes consumed (through the last newline).
    @discardableResult
    static func forEachCompleteLine(_ buffer: UnsafeRawBufferPointer, _ body: (UnsafeRawBufferPointer) -> Void) -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        let count = buffer.count
        var start = 0
        while start < count {
            guard let found = memchr(base + start, 0x0A, count - start) else { break }
            let end = base.distance(to: UnsafeRawPointer(found))
            if end > start {
                body(UnsafeRawBufferPointer(start: base + start, count: end - start))
            }
            start = end + 1
        }
        return start
    }

    /// Byte-level substring check, much cheaper than decoding the line.
    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBytes { n in
            guard let h = haystack.baseAddress, let nb = n.baseAddress else { return false }
            let hc = haystack.count
            let nc = n.count
            if nc == 0 { return true }
            if hc < nc { return false }
            let first = Int32(n[0])
            let last = hc - nc
            var i = 0
            while i <= last {
                guard let p = memchr(h + i, first, last - i + 1) else { return false }
                let index = h.distance(to: UnsafeRawPointer(p))
                if memcmp(h + index, nb, nc) == 0 { return true }
                i = index + 1
            }
            return false
        }
    }

    static func containsAny(_ haystack: UnsafeRawBufferPointer, _ needles: [[UInt8]]) -> Bool {
        for needle in needles where contains(haystack, needle) {
            return true
        }
        return false
    }
}

extension Array where Element == UInt8 {
    init(literal: StaticString) {
        self = literal.withUTF8Buffer { Array($0) }
    }
}
