import AVFoundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

/// The natural on-device voice: Kokoro-82M running through MLX on the iPhone's GPU.
/// Nothing leaves the device and it works offline once the model is downloaded.
final class KokoroSpeechEngine: SpeechEngine {
    enum KokoroError: LocalizedError {
        case unsupportedDevice
        case modelMissing
        case unknownVoice(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedDevice: return "The natural voice needs a real iPhone or iPad; the Simulator can't run it."
            case .modelMissing: return "The natural voice isn't downloaded yet. Download it in Settings."
            case .unknownVoice(let name): return "The voice “\(name)” isn't in the voice pack."
            }
        }
    }

    /// The 28 English voices in Kokoro v1.0's pack. "a" = American, "b" = British; "f"/"m" = female/male.
    static let voiceNames = [
        "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "af_nova", "af_river", "af_jessica",
        "af_alloy", "af_aoede", "af_kore", "am_michael", "am_adam", "am_eric", "am_liam", "am_onyx",
        "am_echo", "am_fenrir", "am_puck", "am_santa", "bf_emma", "bf_isabella", "bf_alice", "bf_lily",
        "bm_george", "bm_fable", "bm_daniel", "bm_lewis",
    ]

    static func displayName(forVoice name: String) -> String {
        let parts = name.split(separator: "_")
        guard parts.count == 2, let code = parts.first, code.count == 2 else { return name }
        let accent = code.first == "b" ? "British" : "American"
        return "\(parts[1].capitalized) · \(accent)"
    }

    static var isSupportedOnThisDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// The narrator voice; character voices are passed per call.
    var voiceName: String
    private let worker: KokoroWorker

    init(modelURL: URL, voicesURL: URL, voiceName: String) {
        self.voiceName = voiceName
        worker = KokoroWorker(modelURL: modelURL, voicesURL: voicesURL)
    }

    var displayName: String { Self.displayName(forVoice: voiceName) }

    /// True once the model weights are in memory, so the player can tell a load failure
    /// (fall back to Apple voices) from a one-sentence failure (skip it).
    var isLoaded: Bool {
        get async { await worker.isLoaded }
    }

    var supportsCharacterVoices: Bool { true }

    func render(_ text: String, voice: String?) async throws -> AVAudioPCMBuffer {
        guard Self.isSupportedOnThisDevice else { throw KokoroError.unsupportedDevice }
        // Pronunciation follows the narrator's accent for every voice, so the phonemizer
        // isn't switched back and forth between American and British mid-conversation.
        let language: Language = voiceName.hasPrefix("b") ? .enGB : .enUS
        let samples = try await worker.synthesize(text, voiceName: voice ?? voiceName, language: language)
        return NarrationAudio.buffer(fromSamples: samples)
    }
}

/// Owns the MLX model off the main thread. MLX arrays aren't thread-safe, so every call goes
/// through this actor, one sentence at a time.
private actor KokoroWorker {
    private let modelURL: URL
    private let voicesURL: URL
    private var tts: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    init(modelURL: URL, voicesURL: URL) {
        self.modelURL = modelURL
        self.voicesURL = voicesURL
    }

    var isLoaded: Bool { tts != nil }

    func synthesize(_ text: String, voiceName: String, language: Language) throws -> [Float] {
        let tts = try loadIfNeeded()
        guard let voice = voices[voiceName + ".npy"] ?? voices[voiceName] else {
            throw KokoroSpeechEngine.KokoroError.unknownVoice(voiceName)
        }
        let (audio, _) = try tts.generateAudio(voice: voice, language: language, text: text)
        return audio
    }

    private func loadIfNeeded() throws -> KokoroTTS {
        if let tts { return tts }
        // KokoroTTS force-unwraps its weights, so check the files before handing them over.
        guard KokoroModelStore.isValidModel(at: modelURL), FileManager.default.fileExists(atPath: voicesURL.path),
              let loadedVoices = NpyzReader.read(fileFromPath: voicesURL), !loadedVoices.isEmpty else {
            throw KokoroSpeechEngine.KokoroError.modelMissing
        }
        // Keep MLX's buffer cache small; the model itself stays resident.
        MLX.Memory.cacheLimit = 64 * 1024 * 1024
        let engine = KokoroTTS(modelPath: modelURL)
        voices = loadedVoices
        tts = engine
        return engine
    }
}
