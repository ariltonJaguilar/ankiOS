import Foundation

enum ICloudSyncError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "iCloud não está disponível. Entre na mesma conta Apple neste aparelho. O contêiner iCloud.com.bigbear.AnkiOS precisa estar ligado neste app."
        case .failed(let message):
            return message
        }
    }
}

/// Copies the local Profiles folder to the iCloud Drive container and back.
/// The newer collection.anki2 wins. Media files are merged by date.
enum ICloudSync {
    static let containerID = "iCloud.com.bigbear.AnkiOS"

    static func sync(localProfiles: URL) throws -> String {
        let fm = FileManager.default
        guard let container = fm.url(forUbiquityContainerIdentifier: containerID) else {
            throw ICloudSyncError.unavailable
        }
        let cloudProfiles = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
        try fm.createDirectory(at: localProfiles, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloudProfiles, withIntermediateDirectories: true)

        let names = Set(directoryNames(at: localProfiles) + directoryNames(at: cloudProfiles))
        let profiles = names.isEmpty ? ["User 1"] : names.sorted()

        var sent = 0
        var received = 0
        var media = 0
        for name in profiles {
            let result = try syncProfile(
                name,
                localRoot: localProfiles,
                cloudRoot: cloudProfiles
            )
            sent += result.sentCollection ? 1 : 0
            received += result.receivedCollection ? 1 : 0
            media += result.mediaFiles
        }

        if sent == 0, received == 0, media == 0 {
            return "iCloud já estava em dia."
        }
        var parts: [String] = []
        if sent > 0 { parts.append("coleção enviada") }
        if received > 0 { parts.append("coleção recebida") }
        if media > 0 { parts.append("\(media) arquivo(s) de mídia") }
        return "iCloud: " + parts.joined(separator: ", ") + "."
    }

    private struct ProfileResult {
        var sentCollection = false
        var receivedCollection = false
        var mediaFiles = 0
    }

    private static func syncProfile(_ name: String, localRoot: URL, cloudRoot: URL) throws -> ProfileResult {
        let fm = FileManager.default
        let local = localRoot.appendingPathComponent(name, isDirectory: true)
        let cloud = cloudRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)

        let localDB = local.appendingPathComponent("collection.anki2")
        let cloudDB = cloud.appendingPathComponent("collection.anki2")
        try downloadIfNeeded(cloudDB)
        removeSidecars(localDB)
        removeSidecars(cloudDB)

        var result = ProfileResult()
        let localDate = modificationDate(of: localDB)
        let cloudDate = modificationDate(of: cloudDB)
        if localDate == nil, cloudDate != nil {
            try copyReplacing(from: cloudDB, to: localDB)
            result.receivedCollection = true
        } else if cloudDate == nil, localDate != nil {
            try copyReplacing(from: localDB, to: cloudDB)
            result.sentCollection = true
        } else if let localDate, let cloudDate {
            if localDate.timeIntervalSince(cloudDate) > 1 {
                try copyReplacing(from: localDB, to: cloudDB)
                result.sentCollection = true
            } else if cloudDate.timeIntervalSince(localDate) > 1 {
                try copyReplacing(from: cloudDB, to: localDB)
                result.receivedCollection = true
            }
        }
        removeSidecars(localDB)
        result.mediaFiles = try syncMedia(
            local: local.appendingPathComponent("collection.media", isDirectory: true),
            cloud: cloud.appendingPathComponent("collection.media", isDirectory: true)
        )
        return result
    }

    private static func syncMedia(local: URL, cloud: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let names = Set(fileNames(at: local) + fileNames(at: cloud))
        var copied = 0
        for name in names {
            let localFile = local.appendingPathComponent(name)
            let cloudFile = cloud.appendingPathComponent(name)
            try downloadIfNeeded(cloudFile)
            let localDate = modificationDate(of: localFile)
            let cloudDate = modificationDate(of: cloudFile)
            if localDate == nil, cloudDate != nil {
                try copyReplacing(from: cloudFile, to: localFile)
                copied += 1
            } else if cloudDate == nil, localDate != nil {
                try copyReplacing(from: localFile, to: cloudFile)
                copied += 1
            } else if let localDate, let cloudDate {
                if localDate.timeIntervalSince(cloudDate) > 1 {
                    try copyReplacing(from: localFile, to: cloudFile)
                    copied += 1
                } else if cloudDate.timeIntervalSince(localDate) > 1 {
                    try copyReplacing(from: cloudFile, to: localFile)
                    copied += 1
                }
            }
        }
        return copied
    }

    private static func copyReplacing(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(
            readingItemAt: source,
            options: [],
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { readURL, writeURL in
            do {
                if fm.fileExists(atPath: writeURL.path) {
                    try fm.removeItem(at: writeURL)
                }
                try fm.copyItem(at: readURL, to: writeURL)
            } catch {
                copyError = error
            }
        }
        if let coordinationError {
            throw ICloudSyncError.failed(coordinationError.localizedDescription)
        }
        if let copyError {
            throw ICloudSyncError.failed(copyError.localizedDescription)
        }
    }

    private static func downloadIfNeeded(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey
        ])
        let status = values?.ubiquitousItemDownloadingStatus
        let stillDownloading = values?.ubiquitousItemIsDownloading == true
        if !stillDownloading, status == nil || status == .current || status == .downloaded {
            return
        }
        if status == .notDownloaded {
            try fm.startDownloadingUbiquitousItem(at: url)
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let latest = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if latest?.ubiquitousItemDownloadingStatus == .current
                || latest?.ubiquitousItemDownloadingStatus == .downloaded {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ICloudSyncError.failed("O iCloud ainda está baixando \(url.lastPathComponent). Tente de novo em instantes.")
    }

    private static func modificationDate(of url: URL) -> Date? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func directoryNames(at url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            let path = url.appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    private static func fileNames(at url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
    }

    private static func removeSidecars(_ database: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
    }
}
