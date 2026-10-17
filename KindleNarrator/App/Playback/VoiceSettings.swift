import Foundation

/// The listener's voice choices, persisted in UserDefaults.
@MainActor
final class VoiceSettings: ObservableObject {
    enum EngineKind: String, CaseIterable, Identifiable {
        case kokoro
        case apple

        var id: String { rawValue }
        var title: String {
            switch self {
            case .kokoro: return "Natural (on-device)"
            case .apple: return "Apple voices"
            }
        }
    }

    private let defaults: UserDefaults

    @Published var engine: EngineKind { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    /// The narrator's Kokoro voice.
    @Published var kokoroVoice: String { didSet { defaults.set(kokoroVoice, forKey: "kokoroVoice") } }
    @Published var appleVoiceIdentifier: String? { didSet { defaults.set(appleVoiceIdentifier, forKey: "appleVoice") } }
    @Published var rate: Float { didSet { defaults.set(rate, forKey: "rate") } }
    /// Give recurring characters their own voices; the narrator voice reads everything else.
    @Published var characterVoices: Bool { didSet { defaults.set(characterVoices, forKey: "characterVoices") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = EngineKind(rawValue: defaults.string(forKey: "engine") ?? "") ?? .kokoro
        kokoroVoice = defaults.string(forKey: "kokoroVoice") ?? "af_heart"
        appleVoiceIdentifier = defaults.string(forKey: "appleVoice")
        let storedRate = defaults.float(forKey: "rate")
        rate = storedRate > 0 ? storedRate : 1.0
        characterVoices = defaults.object(forKey: "characterVoices") as? Bool ?? true
    }

    /// Changes whenever a different voice would be heard, so the player knows to re-render.
    var voiceKey: String {
        switch engine {
        case .kokoro: return "kokoro:\(kokoroVoice):\(characterVoices ? "cast" : "solo")"
        case .apple: return "apple:\(appleVoiceIdentifier ?? "default")"
        }
    }
}
