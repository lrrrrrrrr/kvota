import Foundation
import libzstd

/// Streams the lines of a zstd-compressed file (Codex compresses rollouts older than a week).
enum ZstdLineScanner {
    static func scan(url: URL, _ body: (UnsafeRawBufferPointer) -> Void) throws {
        guard let stream = ZSTD_createDStream() else { throw KvotaError("Could not start zstd decoder") }
        defer { _ = ZSTD_freeDStream(stream) }
        _ = ZSTD_initDStream(stream)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let outCapacity = ZSTD_DStreamOutSize()
        var output = [UInt8](repeating: 0, count: outCapacity)
        var pending = Data()

        while let chunk = try handle.read(upToCount: ZSTD_DStreamInSize()), !chunk.isEmpty {
            try chunk.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                var inBuffer = ZSTD_inBuffer(src: input.baseAddress, size: input.count, pos: 0)
                var outputWasFull = false
                repeat {
                    let produced: Int = try output.withUnsafeMutableBytes { out in
                        var outBuffer = ZSTD_outBuffer(dst: out.baseAddress, size: out.count, pos: 0)
                        let result = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                        if ZSTD_isError(result) != 0 {
                            throw KvotaError("Corrupt zstd data in \(url.lastPathComponent)")
                        }
                        return outBuffer.pos
                    }
                    if produced > 0 {
                        output.withUnsafeBufferPointer { decoded in
                            if let base = decoded.baseAddress {
                                pending.append(base, count: produced)
                            }
                        }
                        let used = pending.withUnsafeBytes { LineScanner.forEachCompleteLine($0, body) }
                        if used > 0 {
                            pending = used == pending.count ? Data() : pending.subdata(in: used..<pending.count)
                        }
                    }
                    outputWasFull = produced == outCapacity
                } while inBuffer.pos < inBuffer.size || outputWasFull
            }
        }
        // A final line without a trailing newline.
        if !pending.isEmpty {
            pending.withUnsafeBytes { body($0) }
        }
    }
}
