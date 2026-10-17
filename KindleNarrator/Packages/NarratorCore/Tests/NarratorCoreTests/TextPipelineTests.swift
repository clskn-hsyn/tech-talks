import XCTest
@testable import NarratorCore

final class TextNormalizerTests: XCTestCase {
    func testAbbreviations() {
        XCTAssertEqual(TextNormalizer.normalize("Mr. Darcy met Dr. Watson."), "Mister Darcy met Doctor Watson.")
        XCTAssertEqual(TextNormalizer.normalize("Bring fruit, e.g. apples."), "Bring fruit, for example apples.")
        XCTAssertEqual(TextNormalizer.normalize("Pens, paper, etc. Then we left."), "Pens, paper, etcetera. Then we left.")
    }

    func testYearsAndNumbers() {
        XCTAssertEqual(TextNormalizer.normalize("It was 1984."), "It was nineteen eighty-four.")
        XCTAssertEqual(TextNormalizer.normalize("In 2005 and 1905."), "In two thousand five and nineteen oh five.")
        XCTAssertEqual(TextNormalizer.normalize("About 3,000 men."), "About three thousand men.")
        XCTAssertEqual(TextNormalizer.normalize("Pi is 3.14"), "Pi is three point one four")
        XCTAssertEqual(TextNormalizer.normalize("the 1850s"), "the eighteen fifties")
        XCTAssertEqual(TextNormalizer.normalize("He had 42 cats."), "He had forty-two cats.")
    }

    func testOrdinalsTimesCurrencyPercent() {
        XCTAssertEqual(TextNormalizer.normalize("the 21st floor"), "the twenty-first floor")
        XCTAssertEqual(TextNormalizer.normalize("the 3rd time"), "the third time")
        XCTAssertEqual(TextNormalizer.normalize("At 3:05 sharp"), "At three oh five sharp")
        XCTAssertEqual(TextNormalizer.normalize("At 10:00"), "At ten o'clock")
        XCTAssertEqual(TextNormalizer.normalize("It cost $5.50"), "It cost five dollars and fifty cents")
        XCTAssertEqual(TextNormalizer.normalize("Only 50% left"), "Only fifty percent left")
    }

    func testRomanChapterNumbers() {
        XCTAssertEqual(TextNormalizer.normalize("Chapter XIV"), "Chapter fourteen")
        XCTAssertEqual(TextNormalizer.normalize("PART II"), "PART two")
    }

    func testNumberSpeller() {
        XCTAssertEqual(NumberSpeller.cardinal(0), "zero")
        XCTAssertEqual(NumberSpeller.cardinal(115), "one hundred fifteen")
        XCTAssertEqual(NumberSpeller.cardinal(1_200_000), "one million two hundred thousand")
        XCTAssertEqual(NumberSpeller.ordinal(12), "twelfth")
        XCTAssertEqual(NumberSpeller.ordinal(40), "fortieth")
        XCTAssertEqual(NumberSpeller.ordinal(101), "one hundred first")
        XCTAssertEqual(NumberSpeller.year(1900), "nineteen hundred")
        XCTAssertEqual(NumberSpeller.year(2024), "twenty twenty-four")
    }
}

final class SentenceSegmenterTests: XCTestCase {
    func testBasicSplit() {
        XCTAssertEqual(
            SentenceSegmenter.split("It rained. We stayed in! Did you?"),
            ["It rained.", "We stayed in!", "Did you?"]
        )
    }

    func testDialogueClosingQuotes() {
        XCTAssertEqual(
            SentenceSegmenter.split("“Run!” she said. “Now.” He ran."),
            ["“Run!” she said.", "“Now.”", "He ran."]
        )
    }

    func testInitialsAndAbbreviations() {
        XCTAssertEqual(
            SentenceSegmenter.split("J. R. R. Tolkien lived on St. Giles. He wrote."),
            ["J. R. R. Tolkien lived on St. Giles.", "He wrote."]
        )
        XCTAssertEqual(SentenceSegmenter.split("See vol. 2 and No. 5 here."), ["See vol. 2 and No. 5 here."])
    }

    func testEllipsisBeforeLowercaseStaysTogether() {
        XCTAssertEqual(SentenceSegmenter.split("Well… maybe not. Fine."), ["Well… maybe not.", "Fine."])
    }

    func testLongSentenceIsSplitAtClauses() {
        let clause = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let sentence = clause + "; " + clause + "; " + clause + "."
        let pieces = SentenceSegmenter.split(sentence, maxLength: 300)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 300 })
        XCTAssertEqual(pieces.joined(separator: " ").filter { $0 == "w" }.count, 120)
    }

    func testDropsPunctuationOnlyFragments() {
        XCTAssertEqual(SentenceSegmenter.split("* * *"), [])
    }
}

final class HTMLTextExtractorTests: XCTestCase {
    func testParagraphsHeadingAndEntities() {
        let html = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ignore me</title><style>p{}</style></head>
        <body><h1 class="chapter">Chapter&nbsp;One</h1>
        <p>It was a <em>bright</em> cold day&#8212;and the clocks were striking thirteen.</p>
        <!-- a comment -->
        <p>Winston&rsquo;s chin<br/>was nuzzled.</p></body></html>
        """
        let document = HTMLTextExtractor.extract(html)
        XCTAssertEqual(document.firstHeading, "Chapter One")
        XCTAssertEqual(document.paragraphs, [
            "Chapter One",
            "It was a bright cold day—and the clocks were striking thirteen.",
            "Winston’s chin",
            "was nuzzled.",
        ])
    }

    func testSkipsFootnotesAndPageBreaks() {
        let html = """
        <body><p>Text<a epub:type="noteref" href="#n1"><sup>1</sup></a> continues<span epub:type="pagebreak" id="p5">5</span> here.</p>
        <aside epub:type="footnote" id="n1"><p>The note.</p></aside>
        <p>Next<sup>2</sup>.</p></body>
        """
        XCTAssertEqual(HTMLTextExtractor.extract(html).paragraphs, ["Text continues here.", "Next."])
    }
}

final class PDFTextCleanerTests: XCTestCase {
    func testRemovesRunningHeadersAndPageNumbers() {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
        let pages = words.enumerated().map { index, word in
            """
            THE GREAT NOVEL
            The \(word) passage opens this page with a long line of ordinary prose text.
            Then the \(word) story keeps going for another long line of ordinary prose.
            Short \(word) ending.
            \(index + 1)
            """
        }
        let result = PDFTextCleaner.paragraphs(fromPages: pages)
        XCTAssertEqual(result.count, 6)
        XCTAssertFalse(result[0].joined().contains("GREAT NOVEL"))
        XCTAssertTrue(result[2].joined().contains("charlie passage"))
        XCTAssertTrue(result[2].last?.hasSuffix("Short charlie ending.") ?? false)
    }

    func testRejoinsHyphenatedWords() {
        let paragraphs = PDFTextCleaner.joinLines(["The extra-", "ordinary thing happened in the long line of text.", "End."])
        XCTAssertTrue(paragraphs.joined(separator: " ").contains("extraordinary"))
    }
}

final class BookTests: XCTestCase {
    let book = Book(title: "T", author: nil, format: .epub, chapters: [
        Chapter(title: "Copyright", sentences: ["All rights reserved."], isAuxiliary: true),
        Chapter(title: "Empty", sentences: []),
        Chapter(title: "One", sentences: ["Alpha.", "Beta."]),
        Chapter(title: "Two", sentences: ["Gamma."]),
    ])

    func testStartSkipsAuxiliary() {
        XCTAssertEqual(book.startPosition, BookPosition(chapter: 2, sentence: 0))
    }

    func testNavigationCrossesChaptersAndSkipsEmpty() {
        XCTAssertEqual(book.position(after: BookPosition(chapter: 0, sentence: 0)), BookPosition(chapter: 2, sentence: 0))
        XCTAssertEqual(book.position(after: BookPosition(chapter: 2, sentence: 1)), BookPosition(chapter: 3, sentence: 0))
        XCTAssertNil(book.position(after: BookPosition(chapter: 3, sentence: 0)))
        XCTAssertEqual(book.position(before: BookPosition(chapter: 2, sentence: 0)), BookPosition(chapter: 0, sentence: 0))
    }

    func testCharacterOffsetAndSkip() {
        XCTAssertEqual(book.characterOffset(of: BookPosition(chapter: 2, sentence: 1)), "All rights reserved.".count + "Alpha.".count)
        XCTAssertEqual(book.position(from: BookPosition(chapter: 2, sentence: 0), offsetByCharacters: 7), BookPosition(chapter: 3, sentence: 0))
        XCTAssertEqual(book.progress(at: BookPosition(chapter: 0, sentence: 0)), 0)
    }

    func testAuxiliaryDetection() {
        XCTAssertTrue(BookBuilder.isAuxiliary(title: "Copyright", path: "Text/c.xhtml"))
        XCTAssertTrue(BookBuilder.isAuxiliary(title: "Section 1", path: "OEBPS/titlepage.xhtml"))
        XCTAssertFalse(BookBuilder.isAuxiliary(title: "Chapter 1", path: "index_split_003.html"))
        XCTAssertFalse(BookBuilder.isAuxiliary(title: "The Discovery", path: "ch01.xhtml"))
    }
}
