import Foundation

enum Zstd {
    static func decompress(_ data: Data) throws -> Data {
        let out = try decompressPayload(data)
        guard isSQLite(out) else {
            throw ImportError.decodeFailed("O arquivo collection.anki21b não contém um banco SQLite válido.")
        }
        return out
    }

    static func decompressPayload(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        var output: UnsafeMutableRawPointer?
        var outputSize = 0
        let status = data.withUnsafeBytes { source in
            ankios_zstd_decompress_data(source.baseAddress, source.count, &output, &outputSize)
        }
        guard status == 0, let output else {
            throw ImportError.decodeFailed("Falha ao descomprimir conteúdo zstd do pacote Anki.")
        }
        defer { ankios_zstd_free(output) }
        if let expectedSize, outputSize != expectedSize {
            throw ImportError.decodeFailed("O conteúdo zstd do pacote Anki tem tamanho inesperado.")
        }
        return Data(bytes: output, count: outputSize)
    }

    static func compress(_ data: Data) throws -> Data {
        var output: UnsafeMutableRawPointer?
        var outputSize = 0
        let status = data.withUnsafeBytes { source in
            ankios_zstd_compress_data(source.baseAddress, source.count, &output, &outputSize)
        }
        guard status == 0, let output else {
            throw ImportError.decodeFailed("Falha ao comprimir conteúdo zstd do pacote Anki.")
        }
        defer { ankios_zstd_free(output) }
        return Data(bytes: output, count: outputSize)
    }

    static func compressFile(_ source: URL, to destination: URL) throws {
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                ankios_zstd_compress_file(sourcePath, destinationPath)
            }
        }
        guard status == 0 else {
            throw ImportError.decodeFailed("Falha ao comprimir arquivo zstd do pacote Anki.")
        }
    }

    private static func isSQLite(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        return String(data: data.prefix(15), encoding: .utf8) == "SQLite format 3"
    }
}
