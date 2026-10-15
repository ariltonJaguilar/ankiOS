import Foundation
import AVFoundation

@MainActor
final class MediaStore: ObservableObject {
    private var player: AVAudioPlayer?
    private var recorder: AVAudioRecorder?
    private var ownVoiceURL: URL?
    private var ownVoicePlayer: AVAudioPlayer?

    var mediaDirectory: URL {
        CollectionStore.shared.mediaRoot
    }

    var isPlaying: Bool { player?.isPlaying == true }
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
        guard let url = url(for: filename) else { return }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
        } catch {
            // ignore playback errors
        }
    }

    func pauseOrResume() {
        guard let player else { return }
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
    }

    /// Temporary mic check while studying (Anki “Record Own Voice”) — not saved to the note.
    func startRecordingOwnVoice() {
        stopRecordingOwnVoice()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ankios-own-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.prepareToRecord()
            recorder?.record()
            ownVoiceURL = url
        } catch {
            recorder = nil
        }
    }

    func stopRecordingOwnVoice() {
        recorder?.stop()
        recorder = nil
    }

    func replayOwnVoice() {
        stopRecordingOwnVoice()
        guard let ownVoiceURL, FileManager.default.fileExists(atPath: ownVoiceURL.path) else { return }
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

    nonisolated static func soundFiles(in text: String) -> [String] {
        let patterns = [
            #"\[sound:([^\]]+)\]"#,
            #"data-file="([^"]+)""#
        ]
        var files: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: text) else { return }
                let name = String(text[r])
                if !files.contains(name) { files.append(name) }
            }
        }
        return files
    }

    func copyImportedMedia(from folder: URL, mapping: [String: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        for (index, filename) in mapping {
            let src = folder.appendingPathComponent(index)
            let dest = mediaDirectory.appendingPathComponent(filename)
            if fm.fileExists(atPath: src.path) {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: src, to: dest)
            }
        }
    }

    /// Copy a user-picked file into collection.media; returns stored filename.
    @discardableResult
    func importFile(from url: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        var name = url.lastPathComponent
        let dest = mediaDirectory.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            name = "\(base)-\(Int(Date().timeIntervalSince1970)).\(ext)"
        }
        let finalDest = mediaDirectory.appendingPathComponent(name)
        if fm.fileExists(atPath: finalDest.path) {
            try fm.removeItem(at: finalDest)
        }
        try fm.copyItem(at: url, to: finalDest)
        return name
    }
}
