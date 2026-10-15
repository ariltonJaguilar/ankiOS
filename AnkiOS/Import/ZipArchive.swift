import Foundation
import Compression

enum ZipArchive {
    static func unzip(_ zipURL: URL, to destination: URL) throws {
        let data = try Data(contentsOf: zipURL)
        var offset = 0
        while offset + 30 <= data.count {
            let sig = u32(data, offset)
            if sig != 0x04034b50 { break }

            let method = Int(u16(data, offset + 8))
            let compSize = Int(u32(data, offset + 18))
            let uncompSize = Int(u32(data, offset + 22))
            let nameLen = Int(u16(data, offset + 26))
            let extraLen = Int(u16(data, offset + 28))
            let nameStart = offset + 30
            guard nameStart + nameLen <= data.count else { throw ImportError.unzipFailed("truncated name") }
            let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) ?? "file"
            let dataStart = nameStart + nameLen + extraLen

            guard dataStart + compSize <= data.count else { throw ImportError.unzipFailed("truncated data for \(name)") }
            let payload = data.subdata(in: dataStart..<(dataStart + compSize))
            let outURL = destination.appendingPathComponent(name)

            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let out: Data
                switch method {
                case 0:
                    out = payload
                case 8:
                    out = try inflate(payload, expectedSize: max(uncompSize, 1))
                default:
                    throw ImportError.unzipFailed("unsupported compression \(method)")
                }
                try out.write(to: outURL)
            }
            offset = dataStart + compSize
        }
    }

    private static func u16(_ data: Data, _ o: Int) -> UInt16 {
        UInt16(data[o]) | (UInt16(data[o + 1]) << 8)
    }

    private static func u32(_ data: Data, _ o: Int) -> UInt32 {
        UInt32(data[o]) | (UInt32(data[o + 1]) << 8) | (UInt32(data[o + 2]) << 16) | (UInt32(data[o + 3]) << 24)
    }

    private static func inflate(_ src: Data, expectedSize: Int) throws -> Data {
        // Try zlib-wrapped then raw via NSData
        do {
            return try (src as NSData).decompressed(using: .zlib) as Data
        } catch {
            // Prefixed zlib header for raw deflate streams
            var wrapped = Data([0x78, 0x9C])
            wrapped.append(src)
            if let out = try? (wrapped as NSData).decompressed(using: .zlib) as Data {
                return out
            }
        }

        let dstCapacity = max(expectedSize, src.count * 16, 4096)
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dstBuffer.deallocate() }

        let decoded = src.withUnsafeBytes { srcPtr -> Int in
            guard let base = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(dstBuffer, dstCapacity, base, src.count, nil, COMPRESSION_ZLIB)
        }
        if decoded > 0 {
            return Data(bytes: dstBuffer, count: decoded)
        }

        var wrapped = Data([0x78, 0x9C])
        wrapped.append(src)
        let decoded2 = wrapped.withUnsafeBytes { srcPtr -> Int in
            guard let base = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(dstBuffer, dstCapacity, base, wrapped.count, nil, COMPRESSION_ZLIB)
        }
        guard decoded2 > 0 else { throw ImportError.unzipFailed("inflate failed") }
        return Data(bytes: dstBuffer, count: decoded2)
    }
}
