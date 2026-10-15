import Foundation
import Compression

enum Zstd {
    /// Apple Compression algorithm id for zstd (COMPRESSION_ZSTD = 0x801).
    private static let algorithm = compression_algorithm(0x801)

    /// Decompress zstd payload (Anki collection.anki21b).
    static func decompress(_ data: Data) throws -> Data {
        if let out = try? decompressApple(data), isSQLite(out) || out.count > data.count {
            return out
        }
        #if os(macOS)
        if let out = try? decompressCLI(data), !out.isEmpty {
            return out
        }
        #endif
        throw ImportError.decodeFailed("Falha ao descomprimir zstd (collection.anki21b).")
    }

    private static func isSQLite(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        return String(data: data.prefix(15), encoding: .utf8) == "SQLite format 3"
    }

    private static func decompressApple(_ data: Data) throws -> Data {
        var capacity = max(data.count * 8, 1 << 20)
        let maxCapacity = max(data.count * 64, 256 << 20)
        while capacity <= maxCapacity {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written: Int = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(dst, capacity, base, data.count, nil, algorithm)
            }
            if written > 0 {
                return Data(bytes: dst, count: written)
            }
            capacity *= 2
        }
        throw ImportError.decodeFailed("zstd buffer too small")
    }

    #if os(macOS)
    private static func decompressCLI(_ data: Data) throws -> Data {
        let fm = FileManager.default
        let inURL = fm.temporaryDirectory.appendingPathComponent("anki-zstd-\(UUID().uuidString).zst")
        let outURL = fm.temporaryDirectory.appendingPathComponent("anki-zstd-\(UUID().uuidString).out")
        try data.write(to: inURL)
        defer {
            try? fm.removeItem(at: inURL)
            try? fm.removeItem(at: outURL)
        }
        let zstdPaths = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        guard let bin = zstdPaths.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw ImportError.decodeFailed("zstd CLI not found")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["-d", "-f", "-o", outURL.path, inURL.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ImportError.decodeFailed("zstd CLI failed (\(proc.terminationStatus))")
        }
        return try Data(contentsOf: outURL)
    }
    #endif
}
