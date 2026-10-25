import AnkiBackend
import Foundation
import Security

struct AnkiWebAuth: Codable, Sendable {
    var hkey: String
    var endpoint: String?
    var username: String
}

struct AnkiWebSyncResponse: Decodable, Sendable {
    var required: Int
    var serverMessage: String
    var newEndpoint: String?
    var serverMediaUsn: Int
}

private struct AnkiDatabaseCheckResponse: Decodable {
    var problems: [String]
}

struct AnkiWebMediaProgress: Decodable, Sendable, Equatable {
    var checked: String?
    var added: String?
    var removed: String?

    var checkedCount: Int? {
        Self.integer(in: checked)
    }

    var addedCounts: (uploaded: Int, downloaded: Int)? {
        Self.directionalCounts(in: added)
    }

    var removedCounts: (uploaded: Int, downloaded: Int)? {
        Self.directionalCounts(in: removed)
    }

    private static func directionalCounts(in value: String?) -> (uploaded: Int, downloaded: Int)? {
        guard let value else { return nil }
        let parts = value.split(whereSeparator: { $0 == "↑" || $0 == "↓" })
        guard parts.count >= 2,
              let uploaded = integer(in: String(parts[0])),
              let downloaded = integer(in: String(parts[1])) else {
            return nil
        }
        return (uploaded, downloaded)
    }

    private static func integer(in value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.compactMap { character in
            guard let number = character.wholeNumberValue else { return nil }
            return String(number)
        }.joined()
        return Int(digits)
    }
}

private struct AnkiWebMediaStatus: Decodable {
    var active: Bool
    var progress: AnkiWebMediaProgress?
}

final class AnkiWebSyncControl: @unchecked Sendable {
    private let lock = NSLock()
    private weak var session: AnkiBackendSession?
    private var cancelRequested = false
    private var finished = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    func attach(_ session: AnkiBackendSession) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        self.session = session
        let shouldAbort = cancelRequested
        lock.unlock()
        if shouldAbort { session.abort() }
    }

    func cancel() -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        cancelRequested = true
        let session = self.session
        lock.unlock()
        session?.abort()
        return true
    }

    func finish() {
        lock.lock()
        finished = true
        session = nil
        lock.unlock()
    }
}

struct AnkiWebFullSyncPrompt: Identifiable, Sendable {
    enum Direction: Sendable, Equatable {
        case upload, download, either
    }

    let id = UUID()
    let direction: Direction
    let serverUSN: Int?
    let message: String
}

enum AnkiWebSyncError: LocalizedError {
    case backend(String)
    case credentialsUnavailable
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .backend(let message): message
        case .credentialsUnavailable: "Entre na sua conta AnkiWeb antes de sincronizar."
        case .keychain(let status): "Não foi possível salvar a conta AnkiWeb (\(status))."
        }
    }
}

enum AnkiWebCredentialStore {
    private static var service: String {
        if let session = SharedProfiles.uiTestSession {
            return "com.bigbear.AnkiOS.ankiweb.uitests.\(session)"
        }
        return "com.bigbear.AnkiOS.ankiweb"
    }

    static func load(profile: String) -> AnkiWebAuth? {
        var query = baseQuery(profile: profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AnkiWebAuth.self, from: data)
    }

    static func save(_ auth: AnkiWebAuth, profile: String) throws {
        let data = try JSONEncoder().encode(auth)
        let query = baseQuery(profile: profile)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var addQuery = query
        addQuery.merge(attributes) { _, replacement in replacement }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw AnkiWebSyncError.keychain(updateStatus) }
        } else if status != errSecSuccess {
            throw AnkiWebSyncError.keychain(status)
        }
        SharedProfiles.defaults.set(auth.username, forKey: "ankios.ankiweb.username.\(profile)")
        SharedProfiles.defaults.set(auth.endpoint ?? "", forKey: "ankios.ankiweb.endpoint.\(profile)")
    }

    static func remove(profile: String) {
        SecItemDelete(baseQuery(profile: profile) as CFDictionary)
        SharedProfiles.defaults.removeObject(forKey: "ankios.ankiweb.username.\(profile)")
        SharedProfiles.defaults.removeObject(forKey: "ankios.ankiweb.endpoint.\(profile)")
    }

    static func username(profile: String) -> String? {
        let stored = SharedProfiles.defaults.string(forKey: "ankios.ankiweb.username.\(profile)")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return load(profile: profile)?.username
    }

    static func endpoint(profile: String) -> String {
        SharedProfiles.defaults.string(forKey: "ankios.ankiweb.endpoint.\(profile)") ?? ""
    }

    private static func baseQuery(profile: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile
        ]
    }
}

final class AnkiBackendSession: @unchecked Sendable {
    private let handle: OpaquePointer
    private var isClosed = false

    init(collectionPath: URL, mediaPath: URL, mediaDatabasePath: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        let opened = collectionPath.path.withCString { collection in
            mediaPath.path.withCString { media in
                mediaDatabasePath.path.withCString { mediaDatabase in
                    ankios_anki_backend_open(collection, media, mediaDatabase, &error)
                }
            }
        }
        guard let opened else { throw Self.takeError(&error) }
        handle = opened
    }

    static func checkDatabase(collectionPath: URL, mediaPath: URL, mediaDatabasePath: URL) throws -> [String] {
        var error: UnsafeMutablePointer<CChar>?
        let result = collectionPath.path.withCString { collection in
            mediaPath.path.withCString { media in
                mediaDatabasePath.path.withCString { mediaDatabase in
                    ankios_anki_check_database(collection, media, mediaDatabase, &error)
                }
            }
        }
        guard let result else { throw takeError(&error) }
        defer { ankios_anki_backend_free_string(result) }
        let data = Data(String(cString: result).utf8)
        return try JSONDecoder().decode(AnkiDatabaseCheckResponse.self, from: data).problems
    }

    func login(username: String, password: String, endpoint: String?) throws -> AnkiWebAuth {
        let response: LoginResponse = try withError { error in
            username.withCString { user in
                password.withCString { pass in
                    Self.withOptionalCString(endpoint) { endpointPointer in
                        ankios_anki_sync_login(handle, user, pass, endpointPointer, error)
                    }
                }
            }
        }
        return AnkiWebAuth(hkey: response.hkey, endpoint: endpoint ?? response.endpoint, username: username)
    }

    func sync(
        auth: AnkiWebAuth,
        syncMedia: Bool = true,
        progress: @Sendable (AnkiWebMediaProgress?) -> Void
    ) throws -> AnkiWebSyncResponse {
        let response: AnkiWebSyncResponse = try withError { error in
            auth.hkey.withCString { key in
                Self.withOptionalCString(syncEndpoint(for: auth)) { endpointPointer in
                    ankios_anki_sync_collection(handle, key, endpointPointer, syncMedia ? 1 : 0, error)
                }
            }
        }
        if response.required == 0 || response.required == 1 {
            try waitForMedia(progress: progress)
        }
        return response
    }

    func syncMedia(auth: AnkiWebAuth, progress: @Sendable (AnkiWebMediaProgress?) -> Void) throws {
        let _: EmptyResponse = try withError { error in
            auth.hkey.withCString { key in
                Self.withOptionalCString(syncEndpoint(for: auth)) { endpointPointer in
                    ankios_anki_sync_media(handle, key, endpointPointer, error)
                }
            }
        }
        try waitForMedia(progress: progress)
    }

    func fullSync(auth: AnkiWebAuth, upload: Bool, serverUSN: Int?, progress: @Sendable (AnkiWebMediaProgress?) -> Void) throws {
        let _: EmptyResponse = try withError { error in
            auth.hkey.withCString { key in
                Self.withOptionalCString(syncEndpoint(for: auth)) { endpointPointer in
                    ankios_anki_sync_full_upload_or_download(
                        handle,
                        key,
                        endpointPointer,
                        upload ? 1 : 0,
                        serverUSN == nil ? 0 : 1,
                        Int32(serverUSN ?? 0),
                        error
                    )
                }
            }
        }
        try waitForMedia(progress: progress)
    }

    func abort() {
        do {
            let _: EmptyResponse = try withError { error in
                ankios_anki_sync_abort(handle, error)
            }
        } catch {}
    }

    func close() throws {
        guard !isClosed else { return }
        let _: EmptyResponse = try withError { error in
            ankios_anki_backend_close(handle, error)
        }
        isClosed = true
    }

    private func syncEndpoint(for auth: AnkiWebAuth) -> String? {
        #if DEBUG
        if let endpoint = ProcessInfo.processInfo.environment["ANKIOS_UI_SYNC_ENDPOINT"],
           URL(string: endpoint)?.host == "127.0.0.1" {
            return endpoint
        }
        #endif
        return auth.endpoint
    }

    deinit {
        ankios_anki_backend_destroy(handle)
    }

    private func waitForMedia(progress: @Sendable (AnkiWebMediaProgress?) -> Void) throws {
        while true {
            let status: AnkiWebMediaStatus = try withError { error in
                ankios_anki_media_sync_status(handle, error)
            }
            progress(status.progress)
            if !status.active { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func withError<Response: Decodable>(
        _ operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> UnsafeMutablePointer<CChar>?
    ) throws -> Response {
        var error: UnsafeMutablePointer<CChar>?
        guard let value = try operation(&error) else { throw Self.takeError(&error) }
        defer { ankios_anki_backend_free_string(value) }
        let data = Data(String(cString: value).utf8)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func withOptionalCString<T>(_ value: String?, operation: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        guard let value, !value.isEmpty else { return try operation(nil) }
        return try value.withCString(operation)
    }

    private static func takeError(_ error: inout UnsafeMutablePointer<CChar>?) -> Error {
        guard let error else { return AnkiWebSyncError.backend("Erro desconhecido do backend Anki.") }
        defer { ankios_anki_backend_free_string(error) }
        return AnkiWebSyncError.backend(String(cString: error))
    }
}

private struct LoginResponse: Decodable {
    var hkey: String
    var endpoint: String?
}

private struct EmptyResponse: Decodable {}
