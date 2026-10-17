import XCTest
@testable import NarratorCore

final class QuoteSplittingTests: XCTestCase {
    func split(_ sentence: String, style: DialogueAnalyzer.QuoteStyle = .double) -> [SpeechSegment] {
        var inQuote = false
        return DialogueAnalyzer.splitQuotes(sentence, style: style, inQuote: &inQuote)
    }

    func testQuoteThenTag() {
        XCTAssertEqual(split("“Run!” she said."), [
            SpeechSegment(text: "“Run!”", isDialogue: true, speaker: nil),
            SpeechSegment(text: "she said.", isDialogue: false, speaker: nil),
        ])
    }

    func testTagInTheMiddle() {
        XCTAssertEqual(split("“I know,” Anna said, “but not yet.”").map(\.isDialogue), [true, false, true])
    }

    func testQuoteSpanningSentences() {
        var inQuote = false
        let first = DialogueAnalyzer.splitQuotes("“Run.", style: .double, inQuote: &inQuote)
        XCTAssertTrue(inQuote)
        let second = DialogueAnalyzer.splitQuotes("Now,” she said.", style: .double, inQuote: &inQuote)
        XCTAssertFalse(inQuote)
        XCTAssertEqual(first.map(\.isDialogue), [true])
        XCTAssertEqual(second.map(\.text), ["Now,”", "she said."])
        XCTAssertEqual(second.map(\.isDialogue), [true, false])
    }

    func testBritishSingleQuotesKeepApostrophes() {
        let pieces = split("‘Don’t go,’ she said.", style: .single)
        XCTAssertEqual(pieces.map(\.text), ["‘Don’t go,’", "she said."])
    }

    func testDetectsSingleQuoteBooks() {
        let chapters = [Chapter(title: "1", sentences: ["‘Run!’ she said.", "It’s late."])]
        XCTAssertEqual(DialogueAnalyzer.quoteStyle(of: chapters), .single)
    }
}

final class SpeakerAttributionTests: XCTestCase {
    /// One sentence per paragraph, the way most dialogue is laid out.
    func analyze(_ sentences: [String]) -> (Chapter, [CastMember]) {
        var chapters = [Chapter(title: "One", sentences: sentences, paragraphEnds: Set(sentences.indices))]
        let cast = DialogueAnalyzer.analyze(&chapters)
        return (chapters[0], cast)
    }

    func speakers(_ chapter: Chapter) -> [String?] {
        chapter.sentences.indices.map { index in
            chapter.dialogue[index]?.first(where: \.isDialogue)?.speaker ?? "—"
        }
    }

    func testConversationWithTagsPronounsAndAlternation() {
        let (chapter, cast) = analyze([
            "Anna looked at Bob.",
            "“Where are you going?” Anna asked.",
            "“Out,” said Bob.",
            "“Why?”",
            "“Because.”",
            "“Fine,” she said.",
            "“I’m going too,” I said.",
        ])
        XCTAssertEqual(speakers(chapter), ["—", "Anna", "Bob", "Anna", "Bob", "Anna", DialogueAnalyzer.narratorSpeaker])
        XCTAssertEqual(cast.map(\.name), ["Anna", "Bob"])
        XCTAssertEqual(cast.map(\.lineCount), [3, 2])
        XCTAssertEqual(cast.map(\.gender), [.female, .male])
    }

    func testEarliestTagWinsOverTheListener() {
        let (chapter, _) = analyze([
            "“Hi,” said Bob.",
            "“Hello,” said Anna.",
            "“Go home,” he told Anna.",
        ])
        XCTAssertEqual(speakers(chapter), ["Bob", "Anna", "Bob"])
    }

    func testActionBeatForKnownCharacter() {
        let (chapter, _) = analyze([
            "“Hi,” said Tom.",
            "Tom grinned. “Hello again.”",
        ])
        XCTAssertEqual(speakers(chapter), ["Tom", "Tom"])
    }

    func testHonorificGivesGenderAndIsDropped() {
        let (_, cast) = analyze([
            "“Indeed,” said Mister Darcy.",
            "“Yes,” Darcy said.",
        ])
        XCTAssertEqual(cast.first?.name, "Darcy")
        XCTAssertEqual(cast.first?.lineCount, 2)
        XCTAssertEqual(cast.first?.gender, .male)
    }

    func testAliasesMergeIntoMostUsedForm() {
        let (_, cast) = analyze([
            "“A,” said Harry Potter.",
            "“B,” said Harry.",
            "“C,” said Harry.",
        ])
        XCTAssertEqual(cast.map(\.name), ["Harry"])
        XCTAssertEqual(cast.first?.lineCount, 3)
    }

    func testCapitalizedNonNamesAreIgnored() {
        XCTAssertNil(DialogueAnalyzer.cleanName("The"))
        XCTAssertEqual(DialogueAnalyzer.cleanName("Then Anna"), "Anna")
        XCTAssertEqual(DialogueAnalyzer.cleanName("Mother"), "Mother")
        XCTAssertNil(DialogueAnalyzer.cleanName("Mister"))
    }

    func testApplySpeakersAndRebuildCast() {
        var (chapter, cast) = analyze([
            "“Hi,” said Bob.",
            "“Who’s there?”",
        ])
        DialogueAnalyzer.applySpeakers([1: "Zed"], to: &chapter)
        XCTAssertEqual(speakers(chapter), ["Bob", "Zed"])
        cast = DialogueAnalyzer.rebuildCast(chapters: [chapter], previous: cast, extraVotes: ["Zed": .male])
        XCTAssertEqual(Set(cast.map(\.name)), ["Bob", "Zed"])
        XCTAssertEqual(cast.first { $0.name == "Zed" }?.gender, .male)
    }

    func testResolveModelNames() {
        let cast = [CastMember(name: "Darcy", lineCount: 4), CastMember(name: "Harry Potter", lineCount: 2)]
        XCTAssertEqual(DialogueAnalyzer.resolve("Mr. Darcy", against: cast), "Darcy")
        XCTAssertEqual(DialogueAnalyzer.resolve("Harry", against: cast), "Harry Potter")
        XCTAssertEqual(DialogueAnalyzer.resolve("I", against: cast), DialogueAnalyzer.narratorSpeaker)
        XCTAssertNil(DialogueAnalyzer.resolve("unknown", against: cast))
        XCTAssertEqual(DialogueAnalyzer.resolve("Elizabeth", against: cast), "Elizabeth")
    }

    func testSegmentsFallBackToWholeSentence() {
        let chapter = Chapter(title: "1", sentences: ["Plain narration."])
        XCTAssertEqual(chapter.segments(forSentence: 0), [SpeechSegment(text: "Plain narration.", isDialogue: false, speaker: nil)])
    }

    func testParagraphRanges() {
        let chapter = Chapter(title: "1", sentences: ["a", "b", "c", "d", "e"], paragraphEnds: [1, 3])
        XCTAssertEqual(chapter.paragraphRanges, [0..<2, 2..<4, 4..<5])
    }
}

final class VoiceCastingTests: XCTestCase {
    let cast = [
        CastMember(name: "Anna", lineCount: 5, femaleVotes: 3),
        CastMember(name: "Bob", lineCount: 3, maleVotes: 2),
        CastMember(name: "Kim", lineCount: 2),
        CastMember(name: "Extra", lineCount: 1, femaleVotes: 1),
    ]

    func testCastsDistinctVoicesAwayFromNarrator() {
        let voices = VoiceCasting.assign(cast: cast, narrator: "af_heart")
        XCTAssertEqual(voices[DialogueAnalyzer.narratorSpeaker], "af_heart")
        XCTAssertEqual(voices["Anna"], "af_bella")
        XCTAssertEqual(voices["Bob"], "am_michael")
        XCTAssertEqual(voices["Kim"], "am_fenrir") // unknown gender contrasts with a female narrator first
        XCTAssertNil(voices["Extra"])              // one line: stays with the narrator
    }

    func testPrefersNarratorsAccent() {
        let voices = VoiceCasting.assign(cast: cast, narrator: "bm_george")
        XCTAssertEqual(voices["Anna"], "bf_emma")
        XCTAssertEqual(voices["Bob"], "bm_fable")
    }

    func testOverridesWinAndAreNotReused() {
        let voices = VoiceCasting.assign(cast: cast, narrator: "af_heart", overrides: ["Bob": "af_bella"])
        XCTAssertEqual(voices["Bob"], "af_bella")
        XCTAssertEqual(voices["Anna"], "af_nicole")
    }
}
