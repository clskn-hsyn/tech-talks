import Foundation

/// A piece of a sentence read by one voice.
public struct SpeechSegment: Codable, Equatable, Sendable {
    public var text: String
    public var isDialogue: Bool
    /// The character speaking a dialogue piece, `DialogueAnalyzer.narratorSpeaker` when a
    /// first-person narrator speaks, or nil when unknown. Always nil for narration.
    public var speaker: String?

    public init(text: String, isDialogue: Bool, speaker: String?) {
        self.text = text
        self.isDialogue = isDialogue
        self.speaker = speaker
    }
}

public enum Gender: String, Codable, Sendable, CaseIterable {
    case female, male, unknown
}

public struct CastMember: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var lineCount: Int
    public var femaleVotes: Int
    public var maleVotes: Int

    public init(name: String, lineCount: Int, femaleVotes: Int = 0, maleVotes: Int = 0) {
        self.name = name
        self.lineCount = lineCount
        self.femaleVotes = femaleVotes
        self.maleVotes = maleVotes
    }

    public var id: String { name }

    public var gender: Gender {
        if femaleVotes > maleVotes { return .female }
        if maleVotes > femaleVotes { return .male }
        return .unknown
    }
}

/// Finds quoted speech and works out who says it, so each character can get their own voice.
///
/// This is the fast rule-based pass that runs on import, on every device. It handles the
/// common patterns in fiction: `"…," Anna said`, `said Mister Darcy`, `she asked` (resolved
/// against who's in the conversation), action beats like `Anna smiled. "…"`, and untagged
/// back-and-forth where speakers alternate. On iOS 26 the app refines its guesses with the
/// on-device language model; see `applySpeakers(_:to:)`.
public enum DialogueAnalyzer {
    public static let narratorSpeaker = "narrator"

    struct Votes {
        var female = 0
        var male = 0
    }

    enum QuoteStyle {
        case double, single
    }

    // MARK: - Entry points

    /// Fills in `dialogue` on every chapter and returns the book's cast.
    public static func analyze(_ chapters: inout [Chapter]) -> [CastMember] {
        let style = quoteStyle(of: chapters)
        var votes: [String: Votes] = [:]
        var knownNames: Set<String> = []
        for index in chapters.indices {
            analyzeChapter(&chapters[index], style: style, votes: &votes, knownNames: &knownNames)
        }
        mergeAliases(in: &chapters, votes: &votes)
        return buildCast(chapters: chapters, votes: votes)
    }

    /// Paragraph-by-paragraph text for the language-model pass, with whether each has dialogue.
    public static func paragraphs(of chapter: Chapter) -> [(text: String, hasDialogue: Bool)] {
        chapter.paragraphRanges.map { range in
            let text = range.map { chapter.sentences[$0] }.joined(separator: " ")
            return (text, range.contains { chapter.dialogue[$0] != nil })
        }
    }

    /// Replaces the speaker of every dialogue piece in the given paragraphs.
    /// `speakers` maps paragraph index to a name (or nil for unknown).
    public static func applySpeakers(_ speakers: [Int: String?], to chapter: inout Chapter) {
        let ranges = chapter.paragraphRanges
        for (paragraph, speaker) in speakers where ranges.indices.contains(paragraph) {
            for sentence in ranges[paragraph] {
                guard var pieces = chapter.dialogue[sentence] else { continue }
                for i in pieces.indices where pieces[i].isDialogue { pieces[i].speaker = speaker }
                chapter.dialogue[sentence] = pieces
            }
        }
    }

    /// Recounts lines after speakers change, keeping earlier gender evidence and adding `extraVotes`.
    public static func rebuildCast(chapters: [Chapter], previous: [CastMember], extraVotes: [String: Gender] = [:]) -> [CastMember] {
        var votes: [String: Votes] = [:]
        for member in previous {
            votes[member.name] = Votes(female: member.femaleVotes, male: member.maleVotes)
        }
        for (name, gender) in extraVotes {
            // A language-model judgment counts for more than a single pronoun.
            if gender == .female { votes[name, default: Votes()].female += 3 }
            if gender == .male { votes[name, default: Votes()].male += 3 }
        }
        return buildCast(chapters: chapters, votes: votes, includeNameList: false)
    }

    /// Maps a name from the language model or user onto an existing cast name where possible.
    public static func resolve(_ rawName: String, against cast: [CastMember]) -> String? {
        // The model may write "Mr. Darcy"; the book text was normalized to "Mister Darcy".
        let trimmed = TextNormalizer.expandAbbreviations(rawName)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lowered = trimmed.lowercased()
        if lowered.isEmpty || lowered == "unknown" || lowered == "none" { return nil }
        if ["narrator", "i", "me", "the narrator"].contains(lowered) { return narratorSpeaker }
        let canonical = canonicalName(trimmed).name
        if let exact = cast.first(where: { $0.name.caseInsensitiveCompare(canonical) == .orderedSame }) {
            return exact.name
        }
        let words = Set(canonical.lowercased().split(separator: " ").map(String.init))
        let partial = cast.filter { member in
            !words.isDisjoint(with: member.name.lowercased().split(separator: " ").map(String.init))
        }
        return partial.count == 1 ? partial[0].name : canonical
    }

    // MARK: - Chapter pass

    static func analyzeChapter(_ chapter: inout Chapter, style: QuoteStyle, votes: inout [String: Votes], knownNames: inout Set<String>) {
        chapter.dialogue = [:]
        var conversation: [String] = [] // recent speakers, most recent last
        var recentNames: [String] = []   // known characters mentioned in narration, most recent last

        for range in chapter.paragraphRanges {
            var inQuote = false
            var pieces: [Int: [SpeechSegment]] = [:]
            var narrationParts: [String] = []
            for index in range {
                let segments = splitQuotes(chapter.sentences[index], style: style, inQuote: &inQuote)
                if segments.contains(where: \.isDialogue) { pieces[index] = segments }
                narrationParts += segments.filter { !$0.isDialogue }.map(\.text)
            }
            let narration = narrationParts.joined(separator: " ")

            guard !pieces.isEmpty else {
                // A long stretch of pure narration ends the conversation.
                if narration.count > 300 { conversation.removeAll() }
                for name in knownNames where narration.contains(name) {
                    recentNames.removeAll { $0 == name }
                    recentNames.append(name)
                }
                continue
            }

            var speaker: String?
            switch attribution(in: narration, knownNames: knownNames) {
            case .named(let raw):
                let (name, honorificGender) = canonicalName(raw)
                if let honorificGender { addVote(honorificGender, for: name, to: &votes) }
                knownNames.insert(name)
                speaker = name
            case .firstPerson:
                speaker = narratorSpeaker
            case .pronoun(let gender):
                speaker = resolvePronoun(gender, conversation: conversation, recentNames: recentNames, votes: votes)
                if let speaker, speaker != narratorSpeaker { addVote(gender, for: speaker, to: &votes) }
            case .none:
                // Untagged lines in a two-person exchange alternate between the speakers.
                speaker = conversation.count >= 2 ? conversation[conversation.count - 2] : nil
            }

            for (index, segments) in pieces {
                chapter.dialogue[index] = segments.map { segment in
                    var segment = segment
                    if segment.isDialogue { segment.speaker = speaker }
                    return segment
                }
            }
            if let speaker {
                conversation.removeAll { $0 == speaker }
                conversation.append(speaker)
                if conversation.count > 4 { conversation.removeFirst() }
            }
        }
    }

    static func resolvePronoun(_ gender: Gender, conversation: [String], recentNames: [String], votes: [String: Votes]) -> String? {
        func genderOf(_ name: String) -> Gender {
            let v = votes[name] ?? Votes()
            let list = NameGenders.gender(ofFirstName: name)
            let female = v.female + (list == .female ? 2 : 0)
            let male = v.male + (list == .male ? 2 : 0)
            return female > male ? .female : male > female ? .male : .unknown
        }
        let participants = conversation.reversed().filter { $0 != narratorSpeaker }
        let matching = participants.filter { genderOf($0) == gender }
        // In a two-person exchange the next line usually belongs to the other person.
        if matching.count >= 2 { return matching[1] }
        if let only = matching.first { return only }
        if conversation.count >= 2 {
            let alternate = conversation[conversation.count - 2]
            if alternate != narratorSpeaker, genderOf(alternate) != opposite(gender) { return alternate }
        }
        return recentNames.reversed().first { genderOf($0) == gender }
    }

    static func opposite(_ gender: Gender) -> Gender {
        switch gender {
        case .female: return .male
        case .male: return .female
        case .unknown: return .unknown
        }
    }

    static func addVote(_ gender: Gender, for name: String, to votes: inout [String: Votes]) {
        switch gender {
        case .female: votes[name, default: Votes()].female += 1
        case .male: votes[name, default: Votes()].male += 1
        case .unknown: break
        }
    }

    // MARK: - Quotes

    static func quoteStyle(of chapters: [Chapter]) -> QuoteStyle {
        var double = 0
        var singleOpen = 0
        for chapter in chapters.prefix(20) {
            for sentence in chapter.sentences {
                let characters = Array(sentence)
                for (i, character) in characters.enumerated() {
                    if character == "“" || character == "\"" { double += 1 }
                    if character == "‘", i == 0 || characters[i - 1].isWhitespace { singleOpen += 1 }
                }
            }
        }
        return double == 0 && singleOpen > 0 ? .single : .double
    }

    /// Splits one sentence into narration and dialogue pieces. `inQuote` carries an open quote
    /// into the next sentence, since quotes often span several sentences.
    static func splitQuotes(_ sentence: String, style: QuoteStyle, inQuote: inout Bool) -> [SpeechSegment] {
        let characters = Array(sentence)
        var segments: [SpeechSegment] = []
        var buffer = ""
        var pendingPunctuation = ""

        func flush(asDialogue: Bool) {
            let text = buffer.trimmingCharacters(in: .whitespaces)
            buffer = ""
            guard !text.isEmpty else { return }
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
                // Stray punctuation such as the ", " between quote and tag rides with its neighbour.
                if segments.isEmpty { pendingPunctuation += text } else { segments[segments.count - 1].text += text }
                return
            }
            segments.append(SpeechSegment(text: pendingPunctuation + text, isDialogue: asDialogue, speaker: nil))
            pendingPunctuation = ""
        }

        for (i, character) in characters.enumerated() {
            if !inQuote, isOpeningQuote(character, at: i, in: characters, style: style) {
                flush(asDialogue: false)
                buffer.append(character)
                inQuote = true
            } else if inQuote, isClosingQuote(character, at: i, in: characters, style: style) {
                buffer.append(character)
                flush(asDialogue: true)
                inQuote = false
            } else if !inQuote, style == .double, character == "”", segments.isEmpty, buffer.contains(where: \.isLetter) {
                // A closing quote with no opener: the text so far continues a quote from before.
                buffer.append(character)
                flush(asDialogue: true)
            } else {
                buffer.append(character)
            }
        }
        flush(asDialogue: inQuote)
        if !pendingPunctuation.isEmpty {
            if segments.isEmpty {
                segments.append(SpeechSegment(text: pendingPunctuation, isDialogue: false, speaker: nil))
            } else {
                segments[segments.count - 1].text += pendingPunctuation
            }
        }
        return segments
    }

    static func isOpeningQuote(_ c: Character, at i: Int, in characters: [Character], style: QuoteStyle) -> Bool {
        switch style {
        case .double:
            return c == "“" || c == "\""
        case .single:
            guard c == "‘" else { return false }
            return i == 0 || characters[i - 1].isWhitespace || "(—–“[".contains(characters[i - 1])
        }
    }

    static func isClosingQuote(_ c: Character, at i: Int, in characters: [Character], style: QuoteStyle) -> Bool {
        switch style {
        case .double:
            return c == "”" || c == "\""
        case .single:
            guard c == "’" else { return false }
            // "don’t" keeps its apostrophe: a closing quote isn't followed by a letter.
            return i + 1 >= characters.count || !characters[i + 1].isLetter
        }
    }

    // MARK: - Attribution

    enum Attribution: Equatable {
        case named(String)
        case firstPerson
        case pronoun(Gender)
        case none
    }

    static let speechVerbs = [
        "said", "says", "asked", "asks", "replied", "replies", "answered", "whispered", "whispers",
        "shouted", "shouts", "cried", "called", "muttered", "mutters", "murmured", "murmurs", "added",
        "continued", "exclaimed", "snapped", "yelled", "screamed", "sighed", "laughed", "told", "began",
        "insisted", "demanded", "explained", "admitted", "agreed", "repeated", "protested", "growled",
        "hissed", "breathed", "pleaded", "announced", "declared", "offered", "suggested", "warned",
        "wondered", "mumbled", "stammered", "retorted", "interrupted", "observed", "remarked", "responded",
        "groaned", "gasped", "sobbed", "roared", "bellowed", "chuckled", "teased", "urged", "begged",
    ]

    static let namePattern = #"((?:[A-Z][\p{L}’'\-]+)(?:\s+[A-Z][\p{L}’'\-]+){0,2})"#

    static let attributionRegexes: [(NSRegularExpression, Bool)] = {
        let verbs = "(?:" + speechVerbs.joined(separator: "|") + ")"
        let adverb = #"(?:\p{Ll}+ly\s+)?"#
        let patterns: [(String, NSRegularExpression.Options, Bool)] = [
            (namePattern + #"\s+"# + adverb + verbs + #"\b"#, [], true),     // Anna said / Anna quietly said
            (#"\b"# + verbs + #"\s+"# + namePattern, [], true),             // said Anna
            (#"\b(he|she|i)\s+"# + adverb + verbs + #"\b"#, [.caseInsensitive], false), // she said
            (#"\b"# + verbs + #"\s+(he|she)\b"#, [.caseInsensitive], false),             // said he
        ]
        return patterns.compactMap { pattern, options, isName in
            (try? NSRegularExpression(pattern: pattern, options: options)).map { ($0, isName) }
        }
    }()

    static let actionBeatRegex = try? NSRegularExpression(pattern: #"^\s*"# + namePattern + #"\s+\p{Ll}"#)

    /// The earliest speech tag in the paragraph's narration wins: in "he told Anna" the
    /// speaker is "he", not the person being spoken to.
    static func attribution(in narration: String, knownNames: Set<String>) -> Attribution {
        let ns = narration as NSString
        let range = NSRange(location: 0, length: ns.length)
        var best: (location: Int, result: Attribution)?

        for (regex, isName) in attributionRegexes {
            for match in regex.matches(in: narration, range: range) {
                let captured = ns.substring(with: match.range(at: 1))
                let result: Attribution
                if isName {
                    guard let name = cleanName(captured) else { continue }
                    result = .named(name)
                } else {
                    switch captured.lowercased() {
                    case "i": result = .firstPerson
                    case "he": result = .pronoun(.male)
                    default: result = .pronoun(.female)
                    }
                }
                if best == nil || match.range.location < best!.location {
                    best = (match.range.location, result)
                }
                break
            }
        }
        if let best { return best.result }

        // An action beat names a known character as the subject: `Anna smiled. "Hello."`
        if let regex = actionBeatRegex,
           let match = regex.firstMatch(in: narration, range: range),
           let name = cleanName(ns.substring(with: match.range(at: 1))),
           knownNames.contains(canonicalName(name).name) {
            return .named(name)
        }
        return .none
    }

    /// Drops capitalized words that aren't names ("Then Anna" → "Anna", "The" → nil).
    static func cleanName(_ raw: String) -> String? {
        var words = raw.split(separator: " ").map(String.init)
        while let first = words.first, stopwords.contains(first) { words.removeFirst() }
        while let last = words.last, stopwords.contains(last) || (honorifics[last] != nil && words.count > 1) {
            words.removeLast()
        }
        guard !words.isEmpty else { return nil }
        if words.count == 1, honorifics[words[0]] != nil, !standaloneHonorifics.contains(words[0]) { return nil }
        return words.joined(separator: " ")
    }

    /// "Mister Darcy" → ("Darcy", male). The honorific tells us the gender, then is dropped
    /// so "Darcy" and "Mister Darcy" are one character.
    public static func canonicalName(_ raw: String) -> (name: String, gender: Gender?) {
        var words = raw.split(separator: " ").map(String.init)
        var gender: Gender?
        if words.count > 1, let honorific = honorifics[words[0]] {
            gender = honorific == .unknown ? nil : honorific
            words.removeFirst()
        } else if words.count == 1, let honorific = honorifics[words[0]], honorific != .unknown {
            gender = honorific
        }
        return (words.joined(separator: " "), gender)
    }

    static let honorifics: [String: Gender] = [
        "Mister": .male, "Sir": .male, "Lord": .male, "King": .male, "Prince": .male, "Father": .male,
        "Uncle": .male, "Brother": .male, "Master": .male, "Duke": .male, "Count": .male, "Baron": .male,
        "Monsieur": .male, "Señor": .male, "Herr": .male, "Grandpa": .male, "Dad": .male,
        "Missus": .female, "Miz": .female, "Miss": .female, "Lady": .female, "Queen": .female,
        "Princess": .female, "Mother": .female, "Aunt": .female, "Sister": .female, "Madam": .female,
        "Madame": .female, "Mistress": .female, "Duchess": .female, "Countess": .female,
        "Baroness": .female, "Señora": .female, "Frau": .female, "Dame": .female, "Grandma": .female, "Mom": .female, "Mum": .female,
        "Doctor": .unknown, "Professor": .unknown, "Captain": .unknown, "General": .unknown,
        "Lieutenant": .unknown, "Sergeant": .unknown, "Colonel": .unknown, "Reverend": .unknown,
        "Governor": .unknown, "Senator": .unknown, "Detective": .unknown, "Inspector": .unknown,
        "Officer": .unknown, "Agent": .unknown, "Commander": .unknown,
    ]

    /// Honorifics that are used alone as a character's name ("Mother said").
    static let standaloneHonorifics: Set<String> = [
        "Mother", "Father", "Grandma", "Grandpa", "Mom", "Mum", "Dad", "Uncle", "Aunt", "Doctor",
        "Professor", "Captain", "General", "Inspector", "Detective", "Sergeant", "King", "Queen",
    ]

    static let stopwords: Set<String> = [
        "The", "A", "An", "He", "She", "It", "They", "We", "You", "I", "But", "And", "Then", "When",
        "What", "Why", "How", "Where", "Who", "Yes", "No", "Oh", "Ah", "Well", "This", "That", "There",
        "Here", "His", "Her", "Their", "My", "Our", "Your", "If", "As", "At", "In", "On", "So", "Now",
        "Not", "All", "One", "Just", "Still", "After", "Before", "Even", "Maybe", "Perhaps", "Please",
        "Thank", "Thanks", "Sorry", "Good", "Okay", "OK", "Hello", "Hi", "Hey", "Come", "Look", "Listen",
        "Someone", "Somebody", "Everyone", "Nobody", "Something", "Nothing", "Again", "Finally",
        "Suddenly", "Meanwhile", "Later", "Once", "Instead", "Together", "Both", "Each", "Another",
        "For", "With", "From", "To", "Of", "By", "Or", "Nor", "Yet", "Too", "Very", "Its", "These",
        "Those", "Mine", "Ours", "Them", "Him", "Me", "Us", "Do", "Don’t", "Don't", "Can", "Could",
        "Would", "Should", "Will", "Shall", "May", "Might", "Must", "Is", "Are", "Was", "Were", "Be",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "God",
    ]

    // MARK: - Aliases and cast

    /// Merges "Harry" and "Harry Potter" into whichever form speaks more often.
    static func mergeAliases(in chapters: inout [Chapter], votes: inout [String: Votes]) {
        let counts = lineCounts(chapters)
        var renames: [String: String] = [:]
        let multiWord = counts.keys.filter { $0.contains(" ") }
        for name in counts.keys where !name.contains(" ") {
            let containing = multiWord.filter { $0.split(separator: " ").contains(Substring(name)) }
            guard containing.count == 1, let full = containing.first else { continue }
            let keep = (counts[full] ?? 0) >= (counts[name] ?? 0) ? full : name
            let drop = keep == full ? name : full
            renames[drop] = keep
        }
        guard !renames.isEmpty else { return }
        for (drop, keep) in renames {
            if let v = votes.removeValue(forKey: drop) {
                votes[keep, default: Votes()].female += v.female
                votes[keep, default: Votes()].male += v.male
            }
        }
        for c in chapters.indices {
            for (sentence, pieces) in chapters[c].dialogue {
                chapters[c].dialogue[sentence] = pieces.map { piece in
                    var piece = piece
                    if let speaker = piece.speaker, let renamed = renames[speaker] { piece.speaker = renamed }
                    return piece
                }
            }
        }
    }

    static func lineCounts(_ chapters: [Chapter]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for chapter in chapters {
            for pieces in chapter.dialogue.values {
                for piece in pieces where piece.isDialogue {
                    if let speaker = piece.speaker, speaker != narratorSpeaker { counts[speaker, default: 0] += 1 }
                }
            }
        }
        return counts
    }

    static func buildCast(chapters: [Chapter], votes: [String: Votes], includeNameList: Bool = true) -> [CastMember] {
        lineCounts(chapters)
            .map { name, count in
                var v = votes[name] ?? Votes()
                if includeNameList {
                    switch NameGenders.gender(ofFirstName: name) {
                    case .female: v.female += 2
                    case .male: v.male += 2
                    case .unknown: break
                    }
                }
                return CastMember(name: name, lineCount: count, femaleVotes: v.female, maleVotes: v.male)
            }
            .sorted { $0.lineCount != $1.lineCount ? $0.lineCount > $1.lineCount : $0.name < $1.name }
    }
}
