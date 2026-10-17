import Foundation
import NarratorCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Asks Apple's on-device language model who speaks each line of dialogue.
///
/// The rule-based pass gets tagged lines right ("…," Anna said) but guesses on untagged
/// exchanges and ambiguous pronouns. The model reads the surrounding paragraphs the way a
/// person would. It runs on the iPhone (iOS 26 with Apple Intelligence), costs nothing and
/// sends nothing off the device.
enum SpeakerLabeler {
    struct Result: Sendable {
        var speakers: [Int: String?] = [:]
        var genders: [String: Gender] = [:]
    }

    /// Nil when the model can be used; otherwise a sentence explaining why not.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in Settings for better speaker detection."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading. Speaker detection will improve once it's ready."
            case .unavailable(.deviceNotEligible):
                return "This device doesn't support Apple Intelligence, so basic speaker detection is used."
            case .unavailable:
                return "Apple Intelligence isn't available right now, so basic speaker detection is used."
            }
        }
        #endif
        return "Better speaker detection needs iOS 26 with Apple Intelligence."
    }

    /// About 1,000 tokens of text per request, leaving room in the model's context for the
    /// instructions, the character list and the answer.
    static let charactersPerRequest = 3_500

    static func label(chapter: Chapter, cast: [CastMember]) async -> Result {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await labelWithModel(chapter: chapter, cast: cast)
        }
        #endif
        return Result()
    }

    /// Groups paragraph indices into requests, keeping only groups that contain dialogue.
    static func requests(for paragraphs: [(text: String, hasDialogue: Bool)]) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        var length = 0
        for (index, paragraph) in paragraphs.enumerated() {
            if length + paragraph.text.count > charactersPerRequest, !current.isEmpty {
                groups.append(current)
                current = []
                length = 0
            }
            current.append(index)
            length += paragraph.text.count
        }
        if !current.isEmpty { groups.append(current) }
        return groups.filter { group in group.contains { paragraphs[$0].hasDialogue } }
    }

    static let instructions = """
    You identify who is speaking in passages from a novel. Each paragraph starts with its \
    number in square brackets. For every paragraph that contains words inside quotation marks, \
    give the name of the character who says them. Use speech tags, pronouns and the flow of the \
    conversation; in a back-and-forth exchange without tags, speakers usually alternate. \
    Prefer names from the list of known characters, written the same way. If the story's \
    first-person narrator is speaking, answer narrator. If you can't tell, answer unknown.
    """
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct SpeakerLabel {
    @Guide(description: "The paragraph number shown in square brackets")
    var paragraph: Int
    @Guide(description: "Who says the quoted words: a character's name, narrator, or unknown")
    var speaker: String
    @Guide(description: "The speaker's gender: female, male, or unknown")
    var gender: String
}

@available(iOS 26.0, *)
@Generable
struct SpeakerLabels {
    @Guide(description: "One entry for each paragraph that contains quoted speech")
    var labels: [SpeakerLabel]
}

@available(iOS 26.0, *)
extension SpeakerLabeler {
    static func labelWithModel(chapter: Chapter, cast: [CastMember]) async -> Result {
        let paragraphs = DialogueAnalyzer.paragraphs(of: chapter)
        let known = cast.prefix(25).map { "\($0.name) (\($0.gender.rawValue))" }.joined(separator: ", ")
        var result = Result()

        for group in requests(for: paragraphs) {
            if Task.isCancelled { break }
            let excerpt = group.map { "[\($0)] \(paragraphs[$0].text)" }.joined(separator: "\n")
            let prompt = "Known characters: \(known.isEmpty ? "none yet" : known)\n\nPassage:\n\(excerpt)"
            // A fresh session per request keeps each one inside the context window.
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: SpeakerLabels.self)
                for label in response.content.labels {
                    guard group.contains(label.paragraph), paragraphs[label.paragraph].hasDialogue,
                          let speaker = DialogueAnalyzer.resolve(label.speaker, against: cast) else { continue }
                    result.speakers[label.paragraph] = .some(speaker)
                    if speaker != DialogueAnalyzer.narratorSpeaker,
                       let gender = Gender(rawValue: label.gender.lowercased()), gender != .unknown {
                        result.genders[speaker] = gender
                    }
                }
            } catch {
                // Safety guardrails can refuse violent or mature passages, and very dense
                // passages can overflow the context. The rule-based labels stay for those parts.
                continue
            }
        }
        return result
    }
}
#endif
