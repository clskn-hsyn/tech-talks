import Foundation

/// A book reduced to what the narrator needs: chapters of speakable sentences.
public struct Book: Codable, Identifiable, Sendable, Equatable {
    public enum SourceFormat: String, Codable, Sendable {
        case epub, pdf
    }

    public var id: UUID
    public var title: String
    public var author: String?
    public var format: SourceFormat
    public var chapters: [Chapter]

    public init(id: UUID = UUID(), title: String, author: String?, format: SourceFormat, chapters: [Chapter]) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.chapters = chapters
    }

    public var sentenceCount: Int { chapters.reduce(0) { $0 + $1.sentences.count } }
    public var characterCount: Int { chapters.reduce(0) { $0 + $1.characterCount } }

    /// Where listening should start for a fresh book: the first chapter that isn't front matter.
    public var startPosition: BookPosition {
        let index = chapters.firstIndex { !$0.isAuxiliary && !$0.sentences.isEmpty }
            ?? chapters.firstIndex { !$0.sentences.isEmpty }
            ?? 0
        return BookPosition(chapter: index, sentence: 0)
    }

    public func sentence(at position: BookPosition) -> String? {
        guard chapters.indices.contains(position.chapter) else { return nil }
        let sentences = chapters[position.chapter].sentences
        guard sentences.indices.contains(position.sentence) else { return nil }
        return sentences[position.sentence]
    }

    /// The position after `position`, crossing chapter boundaries and skipping empty chapters.
    public func position(after position: BookPosition) -> BookPosition? {
        var chapter = position.chapter
        var sentence = position.sentence + 1
        while chapters.indices.contains(chapter) {
            if sentence < chapters[chapter].sentences.count {
                return BookPosition(chapter: chapter, sentence: sentence)
            }
            chapter += 1
            sentence = 0
        }
        return nil
    }

    public func position(before position: BookPosition) -> BookPosition? {
        if position.sentence > 0 {
            return BookPosition(chapter: position.chapter, sentence: position.sentence - 1)
        }
        var chapter = position.chapter - 1
        while chapter >= 0 {
            let count = chapters[chapter].sentences.count
            if count > 0 { return BookPosition(chapter: chapter, sentence: count - 1) }
            chapter -= 1
        }
        return nil
    }

    /// Moves forward or backward by roughly `characters` characters of text.
    /// Used to turn "skip 15 seconds" into a sentence jump without rendered audio.
    public func position(from start: BookPosition, offsetByCharacters characters: Int) -> BookPosition {
        var current = start
        var remaining = abs(characters)
        while remaining > 0 {
            let next = characters > 0 ? position(after: current) : position(before: current)
            guard let next else { break }
            remaining -= sentence(at: next)?.count ?? 0
            current = next
        }
        return current
    }

    /// Characters before `position`, for progress and elapsed-time estimates.
    public func characterOffset(of position: BookPosition) -> Int {
        var total = 0
        for (index, chapter) in chapters.enumerated() {
            if index < position.chapter {
                total += chapter.characterCount
            } else if index == position.chapter {
                total += chapter.sentences.prefix(position.sentence).reduce(0) { $0 + $1.count }
                break
            }
        }
        return total
    }

    public func progress(at position: BookPosition) -> Double {
        let total = characterCount
        guard total > 0 else { return 0 }
        return Double(characterOffset(of: position)) / Double(total)
    }
}

public struct Chapter: Codable, Sendable, Equatable {
    public var title: String
    public var sentences: [String]
    /// Indices of sentences that end a paragraph, so the player can pause a little longer there.
    public var paragraphEnds: Set<Int>
    /// Front or back matter (copyright, contents, acknowledgements…) that playback skips by default.
    public var isAuxiliary: Bool

    public init(title: String, sentences: [String], paragraphEnds: Set<Int> = [], isAuxiliary: Bool = false) {
        self.title = title
        self.sentences = sentences
        self.paragraphEnds = paragraphEnds
        self.isAuxiliary = isAuxiliary
    }

    public var characterCount: Int { sentences.reduce(0) { $0 + $1.count } }
}

public struct BookPosition: Codable, Hashable, Sendable, Comparable {
    public var chapter: Int
    public var sentence: Int

    public init(chapter: Int, sentence: Int) {
        self.chapter = chapter
        self.sentence = sentence
    }

    public static func < (lhs: BookPosition, rhs: BookPosition) -> Bool {
        (lhs.chapter, lhs.sentence) < (rhs.chapter, rhs.sentence)
    }
}
