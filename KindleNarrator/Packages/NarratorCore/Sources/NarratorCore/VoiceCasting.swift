import Foundation

/// Gives each recurring character a voice of their own, distinct from the narrator's.
public enum VoiceCasting {
    /// Kokoro voices by gender, best-rated first. Accent is the first letter: a = American, b = British.
    public static let femaleVoices = [
        "af_heart", "af_bella", "bf_emma", "af_nicole", "af_aoede", "af_kore", "af_sarah", "bf_isabella",
        "af_nova", "af_sky", "af_alloy", "af_jessica", "af_river", "bf_alice", "bf_lily",
    ]
    public static let maleVoices = [
        "am_michael", "am_fenrir", "am_puck", "bm_george", "bm_fable", "am_echo", "am_eric", "am_liam",
        "am_onyx", "bm_lewis", "bm_daniel", "am_adam",
    ]
    /// Characters with fewer lines than this keep the narrator's voice; a voice for a one-line
    /// stranger mostly risks getting their gender wrong.
    public static let minimumLines = 2

    /// Returns the voice for each speaker. `overrides` (from the listener) always win.
    /// Voices with the narrator's accent are used first, then the other accent.
    public static func assign(cast: [CastMember], narrator: String, overrides: [String: String] = [:]) -> [String: String] {
        var result: [String: String] = [DialogueAnalyzer.narratorSpeaker: narrator]
        let accent = narrator.first
        // Voices the listener picked by hand aren't handed out again automatically.
        let taken = Set(overrides.values).union([narrator])
        func ordered(_ voices: [String]) -> [String] {
            let available = voices.filter { !taken.contains($0) }
            return available.filter { $0.first == accent } + available.filter { $0.first != accent }
        }
        let pools: [Gender: [String]] = [.female: ordered(femaleVoices), .male: ordered(maleVoices)]
        var next: [Gender: Int] = [.female: 0, .male: 0]
        var unknownTurn: Gender = isFemale(narrator) ? .male : .female

        for member in cast {
            if let override = overrides[member.name] {
                result[member.name] = override
                continue
            }
            guard member.lineCount >= minimumLines else { continue }
            var gender = member.gender
            if gender == .unknown {
                // Alternate, starting with the gender that contrasts most with the narrator.
                gender = unknownTurn
                unknownTurn = unknownTurn == .female ? .male : .female
            }
            guard let pool = pools[gender], !pool.isEmpty else { continue }
            let index = next[gender, default: 0]
            result[member.name] = pool[index % pool.count]
            next[gender] = index + 1
        }
        return result
    }

    public static func isFemale(_ voice: String) -> Bool {
        voice.dropFirst().first == "f"
    }
}
