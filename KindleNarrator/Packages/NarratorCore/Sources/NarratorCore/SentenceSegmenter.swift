import Foundation

/// Splits a paragraph into sentences, the unit the narrator renders, highlights and resumes from.
///
/// Rule-based on purpose: it behaves the same on every platform and in tests, and it
/// knows about fiction's habits (closing quotes after the period, initials like
/// "J. R. R."). Long sentences are split again at clause punctuation so each piece
/// stays inside a speech model's input limit.
public enum SentenceSegmenter {
    /// Kokoro accepts ~510 phoneme tokens per call; ~300 characters stays well under that.
    public static let defaultMaxLength = 300

    static let terminators: Set<Character> = [".", "!", "?", "…"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
    static let openers: Set<Character> = ["\"", "'", "“", "‘", "(", "[", "«"]

    /// Abbreviations that survive normalization and must not end a sentence.
    static let nonTerminalWords: Set<String> = [
        "St", "No", "no", "Nos", "nos", "Vol", "vol", "Vols", "vols", "pp", "p", "ch", "Ch", "fig", "Fig", "cf", "al", "Inc",
        "Ltd", "Co", "Corp", "Ave", "Rd", "Blvd", "Mme", "Mlle", "Messrs", "Ph", "U.S", "U.K",
    ]

    public static func split(_ paragraph: String, maxLength: Int = defaultMaxLength) -> [String] {
        let characters = Array(paragraph)
        var sentences: [String] = []
        var start = 0
        var i = 0

        while i < characters.count {
            guard terminators.contains(characters[i]) else { i += 1; continue }

            // Consume runs like "?!" or "…" and any closing quotes/brackets.
            var end = i + 1
            while end < characters.count, terminators.contains(characters[end]) { end += 1 }
            while end < characters.count, closers.contains(characters[end]) { end += 1 }

            guard end < characters.count else { break }
            guard characters[end].isWhitespace else { i = end; continue }

            var next = end
            while next < characters.count, characters[next].isWhitespace { next += 1 }
            guard next < characters.count else { break }

            if characters[i] == ".", isAbbreviationOrInitial(characters, periodAt: i) {
                i = next
                continue
            }
            let following = characters[next]
            let startsNewSentence = following.isUppercase || following.isNumber || openers.contains(following)
            // "…" mid-sentence is often a trailing-off followed by lowercase: keep it together.
            guard startsNewSentence else { i = next; continue }

            sentences.append(String(characters[start..<end]))
            start = next
            i = next
        }
        if start < characters.count {
            sentences.append(String(characters[start...]))
        }

        return sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .flatMap { splitLong($0, maxLength: maxLength) }
    }

    static func isAbbreviationOrInitial(_ characters: [Character], periodAt index: Int) -> Bool {
        var wordStart = index
        while wordStart > 0, !characters[wordStart - 1].isWhitespace, !openers.contains(characters[wordStart - 1]) {
            wordStart -= 1
        }
        let word = String(characters[wordStart..<index])
        if word.count == 1, word.first?.isUppercase == true { return true } // "J. Smith"
        if nonTerminalWords.contains(word) { return true }
        // Dotted acronyms such as "U.S." or "a.m." rarely end a sentence in prose.
        return word.contains(".") && word.split(separator: ".").allSatisfy { $0.count == 1 }
    }

    /// Breaks an over-long sentence at the best clause boundary before `maxLength`.
    static func splitLong(_ sentence: String, maxLength: Int) -> [String] {
        guard sentence.count > maxLength else { return [sentence] }
        let characters = Array(sentence)
        let preferred: [Set<Character>] = [[";", ":"], ["—", "–"], [","], [" "]]
        let minimum = maxLength / 3

        for separators in preferred {
            var cut: Int?
            var i = min(maxLength, characters.count - 1)
            while i > minimum {
                if separators.contains(characters[i]) { cut = i; break }
                i -= 1
            }
            if let cut {
                let head = String(characters[...cut]).trimmingCharacters(in: .whitespaces)
                let tail = String(characters[(cut + 1)...]).trimmingCharacters(in: .whitespaces)
                return tail.isEmpty ? [head] : [head] + splitLong(tail, maxLength: maxLength)
            }
        }
        let head = String(characters[..<maxLength])
        return [head] + splitLong(String(characters[maxLength...]), maxLength: maxLength)
    }
}
