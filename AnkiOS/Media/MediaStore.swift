import Foundation
import AVFoundation
import CryptoKit
import UIKit

enum NoteAudioRecordingError: LocalizedError {
    case permissionDenied
    case couldNotStart
    case emptyRecording
    case recordingInProgress

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "O acesso ao microfone foi negado. Ative-o nos Ajustes do sistema."
        case .couldNotStart: "Não foi possível iniciar a gravação."
        case .emptyRecording: "A gravação ficou vazia. Tente gravar por mais tempo."
        case .recordingInProgress: "Finalize a gravação atual antes de iniciar outra."
        }
    }
}

@MainActor
final class MediaStore: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    private var playbackQueue: [CardHTMLRenderer.PlaybackItem] = []
    private var isWaitingForSequencedSpeech = false
    private var sequencedUtterance: AVSpeechUtterance?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var recorder: AVAudioRecorder?
    private var noteAudioRecorder: AVAudioRecorder?
    private var noteAudioRecordingURL: URL?
    private var isStartingNoteAudioRecording = false
    private var ownVoiceURL: URL?
    private var ownVoicePlayer: AVAudioPlayer?

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    var mediaDirectory: URL {
        CollectionStore.shared.mediaRoot
    }

    var hasUnfinishedPlayback: Bool {
        player != nil
            || ownVoicePlayer != nil
            || !playbackQueue.isEmpty
            || isWaitingForSequencedSpeech
            || speechSynthesizer.isSpeaking
    }
    var isRecordingOwnVoice: Bool { recorder?.isRecording == true }
    var hasOwnVoice: Bool {
        guard let ownVoiceURL else { return false }
        return FileManager.default.fileExists(atPath: ownVoiceURL.path)
    }

    private func refreshPlaybackState() {
        let playing = player?.isPlaying == true
            || ownVoicePlayer?.isPlaying == true
            || (speechSynthesizer.isSpeaking && !speechSynthesizer.isPaused)
        if isPlaying != playing { isPlaying = playing }
    }

    private func configurePlaybackAudioSession(mode: AVAudioSession.Mode) {
        let session = AVAudioSession.sharedInstance()
        let duckAndIgnoreMute = CollectionStore.shared.conf["alwaysDuckAndIgnoreMute"] as? Bool ?? false
        let category: AVAudioSession.Category = duckAndIgnoreMute ? .playback : .ambient
        let options: AVAudioSession.CategoryOptions = duckAndIgnoreMute ? [.duckOthers] : []
        try? session.setCategory(category, mode: mode, options: options)
        try? session.setActive(true)
    }

    func url(for filename: String) -> URL? {
        let url = mediaDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func play(_ filename: String) {
        play([filename])
    }

    func play(_ filenames: [String]) {
        play(filenames, then: [])
    }

    func play(_ filenames: [String], then requests: [CardHTMLRenderer.SpeechRequest]) {
        let items = filenames.map(CardHTMLRenderer.PlaybackItem.file)
            + requests.map(CardHTMLRenderer.PlaybackItem.speech)
        play(items)
    }

    func play(_ items: [CardHTMLRenderer.PlaybackItem]) {
        stop()
        playbackQueue = items
        playNextItem()
    }

    private func playNextItem() {
        guard !playbackQueue.isEmpty else { return }
        let item = playbackQueue.removeFirst()
        switch item {
        case .file(let filename):
            guard let url = url(for: filename) else {
                playNextItem()
                return
            }
            do {
                configurePlaybackAudioSession(mode: .default)
                player = try AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
                player?.delegate = self
                if player?.play() != true {
                    player = nil
                    refreshPlaybackState()
                    playNextItem()
                } else {
                    refreshPlaybackState()
                }
            } catch {
                player = nil
                refreshPlaybackState()
                playNextItem()
            }
        case .speech(let request):
            isWaitingForSequencedSpeech = true
            speakQueued(request, sequenced: true)
        }
    }

    func speak(_ request: CardHTMLRenderer.SpeechRequest) {
        stop()
        speakQueued(request)
    }

    func speakQueued(_ request: CardHTMLRenderer.SpeechRequest) {
        speakQueued(request, sequenced: false)
    }

    private func speakQueued(_ request: CardHTMLRenderer.SpeechRequest, sequenced: Bool) {
        configurePlaybackAudioSession(mode: .spokenAudio)
        let utterance = AVSpeechUtterance(string: request.text)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        utterance.voice = request.voices.lazy.compactMap { preferred in
            voices.first { $0.name == preferred || $0.identifier == preferred }
        }.first ?? AVSpeechSynthesisVoice(language: request.language.replacingOccurrences(of: "_", with: "-"))
        utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * request.speed, 0.1), 1.0)
        if sequenced {
            sequencedUtterance = utterance
        }
        speechSynthesizer.speak(utterance)
        refreshPlaybackState()
    }

    private func finishSequencedSpeech(_ utteranceID: ObjectIdentifier) {
        guard isWaitingForSequencedSpeech,
              let activeUtterance = sequencedUtterance,
              ObjectIdentifier(activeUtterance) == utteranceID else { return }
        isWaitingForSequencedSpeech = false
        sequencedUtterance = nil
        playNextItem()
    }

    func pauseOrResume() {
        if let player {
            if player.isPlaying {
                player.pause()
            } else {
                player.play()
            }
            refreshPlaybackState()
            return
        }
        if let ownVoicePlayer {
            if ownVoicePlayer.isPlaying {
                ownVoicePlayer.pause()
            } else {
                ownVoicePlayer.play()
            }
            refreshPlaybackState()
            return
        }
        if speechSynthesizer.isPaused {
            speechSynthesizer.continueSpeaking()
        } else if speechSynthesizer.isSpeaking {
            speechSynthesizer.pauseSpeaking(at: .immediate)
        }
        refreshPlaybackState()
    }

    func seek(by seconds: TimeInterval) {
        let audioPlayer = player ?? ownVoicePlayer
        guard let audioPlayer else { return }
        let next = max(0, min(audioPlayer.duration, audioPlayer.currentTime + seconds))
        audioPlayer.currentTime = next
        if !audioPlayer.isPlaying { audioPlayer.play() }
        refreshPlaybackState()
    }

    func stop() {
        player?.stop()
        player = nil
        ownVoicePlayer?.stop()
        ownVoicePlayer = nil
        playbackQueue.removeAll()
        isWaitingForSequencedSpeech = false
        sequencedUtterance = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
        refreshPlaybackState()
    }

    /// Temporary mic check while studying (Anki “Record Own Voice”) — not saved to the note.
    func startRecordingOwnVoice() async throws {
        stopRecordingOwnVoice()
        guard noteAudioRecorder == nil, !isStartingNoteAudioRecording else {
            throw NoteAudioRecordingError.recordingInProgress
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw NoteAudioRecordingError.permissionDenied
        }
        guard !Task.isCancelled else { throw CancellationError() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ankios-own-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            stop()
            ownVoicePlayer?.stop()
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            let audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            guard audioRecorder.prepareToRecord(), audioRecorder.record() else {
                try? FileManager.default.removeItem(at: url)
                throw NoteAudioRecordingError.couldNotStart
            }
            recorder = audioRecorder
            ownVoiceURL = url
        } catch {
            recorder = nil
            ownVoiceURL = nil
            throw error
        }
    }

    func stopRecordingOwnVoice() {
        recorder?.stop()
        recorder = nil
    }

    func replayOwnVoice() {
        stopRecordingOwnVoice()
        guard let ownVoiceURL, FileManager.default.fileExists(atPath: ownVoiceURL.path) else { return }
        stop()
        ownVoicePlayer?.stop()
        do {
            configurePlaybackAudioSession(mode: .default)
            ownVoicePlayer = try AVAudioPlayer(contentsOf: ownVoiceURL)
            ownVoicePlayer?.prepareToPlay()
            ownVoicePlayer?.delegate = self
            if ownVoicePlayer?.play() != true {
                ownVoicePlayer = nil
            }
            refreshPlaybackState()
        } catch {
            refreshPlaybackState()
        }
    }

    func clearOwnVoice() {
        stopRecordingOwnVoice()
        ownVoicePlayer?.stop()
        ownVoicePlayer = nil
        refreshPlaybackState()
        if let ownVoiceURL {
            try? FileManager.default.removeItem(at: ownVoiceURL)
        }
        ownVoiceURL = nil
    }

    func startNoteAudioRecording() async throws {
        guard noteAudioRecorder == nil, !isStartingNoteAudioRecording else {
            throw NoteAudioRecordingError.recordingInProgress
        }
        isStartingNoteAudioRecording = true
        defer { isStartingNoteAudioRecording = false }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw NoteAudioRecordingError.permissionDenied }
        guard !Task.isCancelled else { throw CancellationError() }
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let filename = "ankios-recording-\(UUID().uuidString).m4a"
        let url = mediaDirectory.appendingPathComponent(filename)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try AVAudioSession.sharedInstance().setActive(true)
        let audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        guard audioRecorder.prepareToRecord(), audioRecorder.record() else {
            try? FileManager.default.removeItem(at: url)
            throw NoteAudioRecordingError.couldNotStart
        }
        noteAudioRecorder = audioRecorder
        noteAudioRecordingURL = url
    }

    func stopNoteAudioRecording() throws -> String {
        guard let audioRecorder = noteAudioRecorder, let url = noteAudioRecordingURL else {
            throw NoteAudioRecordingError.couldNotStart
        }
        audioRecorder.stop()
        noteAudioRecorder = nil
        noteAudioRecordingURL = nil
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
                throw NoteAudioRecordingError.emptyRecording
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url.lastPathComponent
    }

    func cancelNoteAudioRecording() {
        noteAudioRecorder?.stop()
        noteAudioRecorder = nil
        if let noteAudioRecordingURL {
            try? FileManager.default.removeItem(at: noteAudioRecordingURL)
        }
        noteAudioRecordingURL = nil
    }

    nonisolated static func soundFiles(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[sound:([^\]]+)\]|data-file="([^"]+)""#,
            options: [.caseInsensitive]
        ) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let capture = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let range = Range(capture, in: text) else { return nil }
            let filename = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filename.isEmpty,
                  !filename.hasPrefix("data:"),
                  !filename.contains("://"),
                  !filename.hasPrefix("#") else { return nil }
            return filename
        }
    }

    nonisolated static func mediaFiles(in text: String) -> [String] {
        matches(in: text, patterns: [
            #"\[sound:([^\]]+)\]"#,
            #"data-file="([^"]+)""#,
            #"(?:src|href|poster)\s*=\s*["']([^"']+)["']"#,
            #"url\(\s*["']?([^\)'"\s]+)["']?\s*\)"#
        ])
    }

    private nonisolated static func matches(in text: String, patterns: [String]) -> [String] {
        var files: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let range = Range(match.range(at: 1), in: text) else { return }
                let reference = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reference.isEmpty,
                      !reference.hasPrefix("data:"),
                      !reference.contains("://"),
                      !reference.hasPrefix("#"),
                      !files.contains(reference) else { return }
                files.append(reference)
            }
        }
        return files
    }

    func copyImportedMedia(from folder: URL, mapping: [String: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        for (index, filename) in mapping {
            guard Int(index) != nil, Self.isValidMediaFilename(filename) else { continue }
            let src = folder.appendingPathComponent(index)
            let dest = mediaDirectory.appendingPathComponent(filename)
            if fm.fileExists(atPath: src.path) {
                if fm.fileExists(atPath: dest.path) {
                    guard try filesAreEqual(src, dest) else {
                        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dest.path])
                    }
                    continue
                }
                try fm.copyItem(at: src, to: dest)
            }
        }
    }

    func resolvingImportedMedia(in folder: URL, mapping: [String: String]) throws -> [String: String] {
        let fm = FileManager.default
        var resolved: [String: String] = [:]
        var reserved = Set<String>()
        for (index, filename) in mapping.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            guard Int(index) != nil, Self.isValidMediaFilename(filename) else { continue }
            let source = folder.appendingPathComponent(index)
            guard fm.fileExists(atPath: source.path) else { continue }
            let original = mediaDirectory.appendingPathComponent(filename)
            let originalExists = fm.fileExists(atPath: original.path)
            let matchesExisting = originalExists ? try filesAreEqual(source, original) : true
            if !reserved.contains(filename), matchesExisting {
                resolved[index] = filename
                reserved.insert(filename)
                continue
            }
            let renamed = uniqueImportedFilename(for: filename, reserved: reserved)
            resolved[index] = renamed
            reserved.insert(renamed)
        }
        return resolved
    }

    static func isValidMediaFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && !filename.contains("\\")
            && !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func uniqueImportedFilename(for filename: String, reserved: Set<String>) -> String {
        let url = URL(fileURLWithPath: filename)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var suffix = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            if !reserved.contains(candidate) && !FileManager.default.fileExists(atPath: mediaDirectory.appendingPathComponent(candidate).path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func filesAreEqual(_ first: URL, _ second: URL) throws -> Bool {
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: first.path)
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: second.path)
        guard (firstAttributes[.size] as? NSNumber)?.int64Value == (secondAttributes[.size] as? NSNumber)?.int64Value else { return false }
        let firstHandle = try FileHandle(forReadingFrom: first)
        let secondHandle = try FileHandle(forReadingFrom: second)
        defer {
            try? firstHandle.close()
            try? secondHandle.close()
        }
        while true {
            let firstChunk = try firstHandle.read(upToCount: 65_536) ?? Data()
            let secondChunk = try secondHandle.read(upToCount: 65_536) ?? Data()
            if firstChunk != secondChunk { return false }
            if firstChunk.isEmpty { return true }
        }
    }

    /// Copy a user-picked file into collection.media; returns stored filename.
    @discardableResult
    func importFile(from url: URL) throws -> String {
        try addFile(data: Data(contentsOf: url), desiredName: url.lastPathComponent)
    }

    @discardableResult
    func importRemoteFile(_ data: Data, suggestedName: String) throws -> String {
        try addFile(data: data, desiredName: suggestedName)
    }

    @discardableResult
    func importClipboardImage(_ data: Data, format: String) throws -> String {
        let fileExtension = format == "png" ? "png" : "jpg"
        let conf = CollectionStore.shared.conf
        if conf["resizePastedImages"] as? Bool == true,
           let maxDimension = conf["imageMaxDimension"] as? Int,
           maxDimension > 0,
           let resized = Self.resizedImageData(data, maxDimension: maxDimension, format: fileExtension) {
            let filename = "paste-\(UUID().uuidString).\(fileExtension)"
            return try addFile(data: resized, desiredName: filename)
        }
        let filename = "paste-\(UUID().uuidString).\(fileExtension)"
        return try addFile(data: data, desiredName: filename)
    }

    @discardableResult
    func importPhotoImage(_ data: Data, maxDimension: Int) throws -> String {
        guard let image = UIImage(data: data),
              let jpeg = Self.resizedImageData(data, maxDimension: maxDimension, format: "jpg") ?? image.jpegData(compressionQuality: 0.92) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try addFile(data: jpeg, desiredName: "photo-\(UUID().uuidString).jpg")
    }

    @discardableResult
    func importDrawingImage(_ data: Data) throws -> String {
        try addFile(data: data, desiredName: "drawing-\(UUID().uuidString).png")
    }

    private static func resizedImageData(_ data: Data, maxDimension: Int, format: String) -> Data? {
        guard maxDimension > 0,
              let image = UIImage(data: data),
              image.size.width > 0,
              image.size.height > 0 else { return nil }
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, CGFloat(maxDimension) / longestSide)
        let size = CGSize(width: (image.size.width * scale).rounded(.down), height: (image.size.height * scale).rounded(.down))
        guard scale < 1 else {
            return format == "png" ? image.pngData() : image.jpegData(compressionQuality: 0.92)
        }
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: rendererFormat)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return format == "png" ? resized.pngData() : resized.jpegData(compressionQuality: 0.92)
    }

    private func addFile(data: Data, desiredName: String) throws -> String {
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let normalizedName = Self.normalizedFilename(desiredName)
        guard !normalizedName.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let existingURL = existingMediaURL(for: normalizedName)
        let sourceHash = Insecure.SHA1.hash(data: data)
        if let existingURL,
           let existingData = try? Data(contentsOf: existingURL),
           Insecure.SHA1.hash(data: existingData) == sourceHash {
            return existingURL.lastPathComponent.precomposedStringWithCanonicalMapping
        }
        if normalizedName != normalizedName.lowercased() {
            return try addFile(data: data, desiredName: normalizedName.lowercased())
        }
        guard existingURL != nil else {
            try data.write(to: mediaDirectory.appendingPathComponent(normalizedName), options: .atomic)
            return normalizedName
        }
        let hash = sourceHash.map { String(format: "%02x", $0) }.joined()
        let hashedName = Self.hashedFilename(normalizedName, hash: hash)
        try data.write(to: mediaDirectory.appendingPathComponent(hashedName), options: .atomic)
        return hashedName
    }

    private func existingMediaURL(for filename: String) -> URL? {
        let directURL = mediaDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: directURL.path) {
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: mediaDirectory,
                includingPropertiesForKeys: nil
            ), let actualURL = entries.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame
            }) {
                return actualURL
            }
            return directURL
        }
        return nil
    }

    private static func normalizedFilename(_ filename: String) -> String {
        let disallowed = Set("[]<>:\"/?*^\\|".unicodeScalars)
        var normalized = String(filename.precomposedStringWithCanonicalMapping.unicodeScalars.filter { scalar in
            !disallowed.contains(scalar)
                && !(scalar.isASCII && (scalar.value < 0x20 || scalar.value == 0x7f))
                && scalar.properties.generalCategory != .unassigned
        })
        normalized = normalized.replacingOccurrences(of: "\u{00a0}", with: " ")
        let uppercased = normalized.uppercased()
        let deviceNames = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        if let deviceName = deviceNames.first(where: { name in
            guard uppercased.hasPrefix(name) else { return false }
            let suffix = uppercased.dropFirst(name.count)
            return suffix.isEmpty || suffix.hasPrefix(".")
        }), let insertionPoint = normalized.index(normalized.startIndex, offsetBy: deviceName.count, limitedBy: normalized.endIndex) {
            normalized.insert("_", at: insertionPoint)
        }
        if normalized.last == " " || normalized.last == "." {
            normalized.append("_")
        }
        return truncatedFilename(normalized, maxBytes: 120)
    }

    private static func hashedFilename(_ filename: String, hash: String) -> String {
        let (stem, ext) = splitFilename(filename, maxBytes: 79)
        return ext.isEmpty ? "\(stem)-\(hash)" : "\(stem)-\(hash).\(ext)"
    }

    private static func truncatedFilename(_ filename: String, maxBytes: Int) -> String {
        guard filename.utf8.count > maxBytes else { return filename }
        let (stem, ext) = splitFilename(filename, maxBytes: maxBytes)
        let truncated = ext.isEmpty ? stem : "\(stem).\(ext)"
        return truncated.last == " " || truncated.last == "." ? truncated + "_" : truncated
    }

    private static func splitFilename(_ filename: String, maxBytes: Int) -> (String, String) {
        let stem: String
        var ext: String
        if let dot = filename.lastIndex(of: ".") {
            stem = String(filename[..<dot])
            ext = String(filename[filename.index(after: dot)...])
        } else {
            stem = filename
            ext = ""
        }
        ext = utf8Prefix(ext, maxBytes: 10)
        let stemLimit = max(maxBytes - ext.utf8.count - 2, 0)
        return (utf8Prefix(stem, maxBytes: stemLimit), ext)
    }

    private static func utf8Prefix(_ value: String, maxBytes: Int) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let next = String(scalar)
            guard result.utf8.count + next.utf8.count <= maxBytes else { break }
            result.append(contentsOf: next)
        }
        return result
    }
}

extension MediaStore: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let currentPlayer = self.player, ObjectIdentifier(currentPlayer) == playerID {
                self.player = nil
                self.refreshPlaybackState()
                self.playNextItem()
            } else if let ownVoicePlayer = self.ownVoicePlayer,
                      ObjectIdentifier(ownVoicePlayer) == playerID {
                self.ownVoicePlayer = nil
                self.refreshPlaybackState()
            }
        }
    }
}

extension MediaStore: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finishSequencedSpeech(utteranceID)
            self.refreshPlaybackState()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finishSequencedSpeech(utteranceID)
            self.refreshPlaybackState()
        }
    }
}
