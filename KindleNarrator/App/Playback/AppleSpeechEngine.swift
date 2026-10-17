import AVFoundation

/// Apple's built-in voices. Always available and instant, so it is also the fallback
/// whenever the on-device neural voice isn't installed or fails to load.
final class AppleSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private var activeCollector: BufferCollector?

    init(voiceIdentifier: String?) {
        voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? Self.availableVoices().first
            ?? AVSpeechSynthesisVoice(language: "en-US")
        super.init()
        synthesizer.delegate = self
    }

    var displayName: String { voice.map { "\($0.name) (Apple)" } ?? "Apple voice" }

    /// English voices, best quality first. Premium and Enhanced voices are downloaded in
    /// Settings › Accessibility › Spoken Content › Voices.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { lhs, rhs in
                lhs.quality.rawValue != rhs.quality.rawValue
                    ? lhs.quality.rawValue > rhs.quality.rawValue
                    : lhs.name < rhs.name
            }
    }

    func render(_ text: String) async throws -> AVAudioPCMBuffer {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // Playback speed is applied by the player's time-pitch unit, not here.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = false

        let collector = BufferCollector()
        activeCollector = collector
        return try await withCheckedThrowingContinuation { continuation in
            collector.continuation = continuation
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    collector.finish()
                } else {
                    collector.append(pcm)
                }
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        activeCollector?.finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        activeCollector?.finish()
    }
}

/// Gathers the buffers `AVSpeechSynthesizer.write` streams back and resumes exactly once,
/// whichever end signal (empty buffer or delegate callback) arrives first.
private final class BufferCollector {
    var continuation: CheckedContinuation<AVAudioPCMBuffer, Error>?
    private var buffers: [AVAudioPCMBuffer] = []
    private var finished = false
    private let lock = NSLock()

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        buffers.append(buffer)
    }

    func finish() {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        let collected = buffers
        lock.unlock()

        do {
            let converted = try collected.map(NarrationAudio.convert)
            continuation.resume(returning: converted.isEmpty
                ? NarrationAudio.silence(seconds: 0.1)
                : NarrationAudio.concatenate(converted))
        } catch {
            continuation.resume(throwing: error)
        }
    }
}
