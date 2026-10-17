import Foundation
import AVFoundation

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
    private var player: AVAudioPlayer?
    private var playbackQueue: [URL] = []
    private var speechQueue: [CardHTMLRenderer.SpeechRequest] = []
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var recorder: AVAudioRecorder?
    private var noteAudioRecorder: AVAudioRecorder?
    private var noteAudioRecordingURL: URL?
    private var isStartingNoteAudioRecording = false
    private var ownVoiceURL: URL?
    private var ownVoicePlayer: AVAudioPlayer?

    override init() {
        super.init()
    }

    var mediaDirectory: URL {
        CollectionStore.shared.mediaRoot
    }

    var isPlaying: Bool {
        player?.isPlaying == true || (speechSynthesizer.isSpeaking && !speechSynthesizer.isPaused)
    }
    var isRecordingOwnVoice: Bool { recorder?.isRecording == true }
    var hasOwnVoice: Bool {
        guard let ownVoiceURL else { return false }
        return FileManager.default.fileExists(atPath: ownVoiceURL.path)
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
        player?.stop()
        player = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
        playbackQueue = filenames.compactMap { url(for: $0) }
        speechQueue = requests
        playNextFile()
    }

    private func playNextFile() {
        guard !playbackQueue.isEmpty else {
            speechQueue.forEach(speakQueued)
            speechQueue.removeAll()
            return
        }
        let url = playbackQueue.removeFirst()
        do {
            speechSynthesizer.stopSpeaking(at: .immediate)
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.delegate = self
            player?.play()
        } catch {
            playNextFile()
        }
    }

    func speak(_ request: CardHTMLRenderer.SpeechRequest) {
        stop()
        speakQueued(request)
    }

    func speakQueued(_ request: CardHTMLRenderer.SpeechRequest) {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: request.text)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        utterance.voice = request.voices.lazy.compactMap { preferred in
            voices.first { $0.name == preferred || $0.identifier == preferred }
        }.first ?? AVSpeechSynthesisVoice(language: request.language.replacingOccurrences(of: "_", with: "-"))
        utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * request.speed, 0.1), 1.0)
        speechSynthesizer.speak(utterance)
    }

    func pauseOrResume() {
        guard let player else {
            if speechSynthesizer.isPaused {
                speechSynthesizer.continueSpeaking()
            } else if speechSynthesizer.isSpeaking || speechSynthesizer.isPaused {
                speechSynthesizer.pauseSpeaking(at: .immediate)
            }
            return
        }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func seek(by seconds: TimeInterval) {
        guard let player else { return }
        let next = max(0, min(player.duration, player.currentTime + seconds))
        player.currentTime = next
        if !player.isPlaying { player.play() }
    }

    func stop() {
        player?.stop()
        player = nil
        playbackQueue.removeAll()
        speechQueue.removeAll()
        speechSynthesizer.stopSpeaking(at: .immediate)
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
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
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
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            ownVoicePlayer = try AVAudioPlayer(contentsOf: ownVoiceURL)
            ownVoicePlayer?.prepareToPlay()
            ownVoicePlayer?.play()
        } catch {}
    }

    func clearOwnVoice() {
        stopRecordingOwnVoice()
        ownVoicePlayer?.stop()
        ownVoicePlayer = nil
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
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
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
        let fm = FileManager.default
        try fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        var name = url.lastPathComponent
        guard Self.isValidMediaFilename(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let dest = mediaDirectory.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) {
            if try filesAreEqual(url, dest) { return name }
            name = uniqueImportedFilename(for: name, reserved: [])
        }
        let finalDest = mediaDirectory.appendingPathComponent(name)
        try fm.copyItem(at: url, to: finalDest)
        return name
    }

    @discardableResult
    func importClipboardImage(_ data: Data, format: String) throws -> String {
        let fileExtension = format == "png" ? "png" : "jpg"
        let filename = "paste-\(UUID().uuidString).\(fileExtension)"
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try data.write(to: mediaDirectory.appendingPathComponent(filename), options: .atomic)
        return filename
    }
}

extension MediaStore: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let currentPlayer = self.player,
                  ObjectIdentifier(currentPlayer) == playerID else { return }
            self.player = nil
            self.playNextFile()
        }
    }
}
