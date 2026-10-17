import Foundation
import Compression

enum ZipArchive {
    static func unzip(_ zipURL: URL, to destination: URL) throws {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        guard let centralDirectory = locateCentralDirectory(in: data) else {
            throw ImportError.unzipFailed("missing central directory")
        }
        let (directoryOffset, directorySize, entryCount) = centralDirectory
        var offset = directoryOffset
        for _ in 0..<entryCount {
            guard offset + 46 <= directoryOffset + directorySize, u32(data, offset) == 0x02014b50 else {
                throw ImportError.unzipFailed("invalid central directory")
            }
            let flags = u16(data, offset + 8)
            let method = Int(u16(data, offset + 10))
            let expectedCRC = u32(data, offset + 16)
            var compSize = UInt64(u32(data, offset + 20))
            var uncompSize = UInt64(u32(data, offset + 24))
            let nameLen = Int(u16(data, offset + 28))
            let extraLen = Int(u16(data, offset + 30))
            let commentLen = Int(u16(data, offset + 32))
            var localOffset = UInt64(u32(data, offset + 42))
            let nameStart = offset + 46
            let extraStart = nameStart + nameLen
            let nextOffset = extraStart + extraLen + commentLen
            guard nextOffset <= directoryOffset + directorySize,
                  nameStart + nameLen <= data.count else {
                throw ImportError.unzipFailed("truncated entry")
            }
            if compSize == UInt64(UInt32.max) || uncompSize == UInt64(UInt32.max) || localOffset == UInt64(UInt32.max) {
                let extra = data.subdata(in: extraStart..<(extraStart + extraLen))
                guard let sizes = zip64Values(in: extra, compressed: compSize == UInt64(UInt32.max), uncompressed: uncompSize == UInt64(UInt32.max), localOffset: localOffset == UInt64(UInt32.max)) else {
                    throw ImportError.unzipFailed("invalid ZIP64 entry")
                }
                if compSize == UInt64(UInt32.max) { compSize = sizes.compressed }
                if uncompSize == UInt64(UInt32.max) { uncompSize = sizes.uncompressed }
                if localOffset == UInt64(UInt32.max) { localOffset = sizes.localOffset }
            }
            guard let compressedSize = Int(exactly: compSize),
                  let uncompressedSize = Int(exactly: uncompSize),
                  let localHeaderOffset = Int(exactly: localOffset) else {
                throw ImportError.unzipFailed("ZIP entry is too large for this device")
            }
            guard let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) else {
                throw ImportError.unzipFailed("invalid archive filename")
            }
            guard !name.hasPrefix("/"),
                  !name.contains("\\"),
                  !name.split(separator: "/").contains("..") else {
                throw ImportError.unzipFailed("invalid archive path")
            }
            guard flags & 1 == 0 else { throw ImportError.unzipFailed("encrypted ZIP entries are unsupported") }
            guard localHeaderOffset <= data.count - 30, u32(data, localHeaderOffset) == 0x04034b50 else {
                throw ImportError.unzipFailed("invalid local file header for \(name)")
            }
            let localNameLen = Int(u16(data, localHeaderOffset + 26))
            let localExtraLen = Int(u16(data, localHeaderOffset + 28))
            let localNameStart = localHeaderOffset + 30
            let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            guard localNameLen == nameLen,
                  localNameStart + localNameLen <= data.count,
                  data.subdata(in: localNameStart..<(localNameStart + localNameLen)) == data.subdata(in: nameStart..<(nameStart + nameLen)),
                  u16(data, localHeaderOffset + 6) == flags,
                  u16(data, localHeaderOffset + 8) == method,
                  dataStart <= data.count,
                  compressedSize <= data.count - dataStart else {
                throw ImportError.unzipFailed("truncated data for \(name)")
            }
            let payload = data.subdata(in: dataStart..<(dataStart + compressedSize))
            let outURL = destination.appendingPathComponent(name)

            if name.hasSuffix("/") {
                guard compressedSize == 0, uncompressedSize == 0, expectedCRC == 0 else {
                    throw ImportError.unzipFailed("invalid directory entry for \(name)")
                }
                try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let out: Data
                switch method {
                case 0:
                    out = payload
                case 8:
                    out = try inflate(payload, expectedSize: max(uncompressedSize, 1))
                default:
                    throw ImportError.unzipFailed("unsupported compression \(method)")
                }
                guard out.count == uncompressedSize, crc32(out) == expectedCRC else {
                    throw ImportError.unzipFailed("corrupt entry \(name)")
                }
                try out.write(to: outURL)
            }
            offset = nextOffset
        }
    }

    private static func locateCentralDirectory(in data: Data) -> (offset: Int, size: Int, count: Int)? {
        guard data.count >= 22 else { return nil }
        let firstCandidate = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: firstCandidate, by: -1) where u32(data, offset) == 0x06054b50 {
            let commentLength = Int(u16(data, offset + 20))
            guard offset + 22 + commentLength <= data.count,
                  u16(data, offset + 4) == 0,
                  u16(data, offset + 6) == 0,
                  u16(data, offset + 8) == u16(data, offset + 10) else { continue }
            let count = Int(u16(data, offset + 10))
            let size32 = u32(data, offset + 12)
            let directoryOffset32 = u32(data, offset + 16)
            if size32 == UInt32.max || directoryOffset32 == UInt32.max || count == Int(UInt16.max) {
                guard offset >= 20, u32(data, offset - 20) == 0x07064b50,
                      u32(data, offset - 16) == 0,
                      u32(data, offset - 4) == 1 else { continue }
                let zip64OffsetRaw = u64(data, offset - 12)
                guard let zip64Offset = Int(exactly: zip64OffsetRaw),
                      zip64Offset <= data.count - 56,
                      u32(data, zip64Offset) == 0x06064b50,
                      u64(data, zip64Offset + 4) >= 44,
                      u32(data, zip64Offset + 16) == 0,
                      u32(data, zip64Offset + 20) == 0 else { continue }
                let zip64Count = u64(data, zip64Offset + 32)
                let zip64Size = u64(data, zip64Offset + 40)
                let zip64DirectoryOffset = u64(data, zip64Offset + 48)
                guard u64(data, zip64Offset + 24) == zip64Count,
                      let entryCount = Int(exactly: zip64Count),
                      let directorySize = Int(exactly: zip64Size),
                      let directoryOffset = Int(exactly: zip64DirectoryOffset),
                      directoryOffset <= zip64Offset,
                      directorySize <= zip64Offset - directoryOffset else { continue }
                return (directoryOffset, directorySize, entryCount)
            }
            let size = Int(size32)
            let directoryOffset = Int(directoryOffset32)
            guard directoryOffset <= offset, size <= offset - directoryOffset else { continue }
            return (directoryOffset, size, count)
        }
        return nil
    }

    private static func zip64Values(
        in extra: Data,
        compressed: Bool,
        uncompressed: Bool,
        localOffset: Bool
    ) -> (compressed: UInt64, uncompressed: UInt64, localOffset: UInt64)? {
        var offset = 0
        while offset + 4 <= extra.count {
            let identifier = u16(extra, offset)
            let length = Int(u16(extra, offset + 2))
            let start = offset + 4
            guard start + length <= extra.count else { return nil }
            if identifier == 0x0001 {
                var cursor = start
                let end = start + length
                var uncompressedValue: UInt64 = 0
                var compressedValue: UInt64 = 0
                var localOffsetValue: UInt64 = 0
                if uncompressed {
                    guard cursor + 8 <= end else { return nil }
                    uncompressedValue = u64(extra, cursor)
                    cursor += 8
                }
                if compressed {
                    guard cursor + 8 <= end else { return nil }
                    compressedValue = u64(extra, cursor)
                    cursor += 8
                }
                if localOffset {
                    guard cursor + 8 <= end else { return nil }
                    localOffsetValue = u64(extra, cursor)
                }
                return (compressedValue, uncompressedValue, localOffsetValue)
            }
            offset = start + length
        }
        return nil
    }

    private static func u16(_ data: Data, _ o: Int) -> UInt16 {
        UInt16(data[o]) | (UInt16(data[o + 1]) << 8)
    }

    private static func u32(_ data: Data, _ o: Int) -> UInt32 {
        UInt32(data[o]) | (UInt32(data[o + 1]) << 8) | (UInt32(data[o + 2]) << 16) | (UInt32(data[o + 3]) << 24)
    }

    private static func u64(_ data: Data, _ o: Int) -> UInt64 {
        UInt64(u32(data, o)) | (UInt64(u32(data, o + 4)) << 32)
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1
        }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return ~crc
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
