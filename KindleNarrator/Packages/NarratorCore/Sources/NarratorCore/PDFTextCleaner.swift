import Foundation

/// Cleans text pulled from PDF pages: drops running headers, footers and page numbers,
/// and re-joins lines into paragraphs. PDFKit itself lives in the app; this part is pure
/// text so it can be tested anywhere.
public enum PDFTextCleaner {
    /// Removes lines that repeat on many pages (running headers/footers) and bare page numbers,
    /// then returns each page's paragraphs.
    public static func paragraphs(fromPages pages: [String]) -> [[String]] {
        let pageLines = pages.map { page in
            page.components(separatedBy: .newlines).map { $0.trimmed }.filter { !$0.isEmpty }
        }

        // A line is "running" if, ignoring digits, it appears at the top or bottom of many pages.
        var counts: [String: Int] = [:]
        for lines in pageLines {
            let edges = Set((lines.prefix(2) + lines.suffix(2)).map(signature))
            for edge in edges { counts[edge, default: 0] += 1 }
        }
        let threshold = max(3, pages.count / 4)
        let running = Set(counts.filter { $0.value >= threshold }.keys)

        return pageLines.map { lines in
            let isEdge: (Int) -> Bool = { $0 < 2 || $0 >= lines.count - 2 }
            let kept = lines.enumerated().filter { index, line in
                if isPageNumber(line) { return false }
                if isEdge(index), running.contains(signature(line)) { return false }
                return true
            }.map(\.element)
            return joinLines(kept)
        }
    }

    static func signature(_ line: String) -> String {
        String(line.lowercased().filter { !$0.isNumber && !$0.isWhitespace })
    }

    static func isPageNumber(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "-–— ."))
        if !stripped.isEmpty, stripped.allSatisfy(\.isNumber) { return true }
        let lowered = stripped.lowercased()
        if lowered.hasPrefix("page "), lowered.dropFirst(5).allSatisfy({ $0.isNumber || $0 == " " || $0 == "o" || $0 == "f" }) {
            return true
        }
        return TextNormalizer.romanValue(stripped.uppercased()) != nil && stripped.count <= 5 && stripped == stripped.lowercased()
    }

    /// PDF text arrives as visual lines. A line ending in sentence punctuation followed by a
    /// short line, or a line that ends well short of the typical width, closes a paragraph.
    static func joinLines(_ lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }
        let typicalWidth = lines.map(\.count).sorted()[lines.count * 3 / 4]
        var paragraphs: [String] = []
        var current = ""
        for line in lines {
            if current.hasSuffix("-"), let first = line.first, first.isLowercase {
                current.removeLast() // re-join hyphenated words
                current += line
            } else {
                current += current.isEmpty ? line : " " + line
            }
            let endsSentence = line.last.map { ".!?”\"’:".contains($0) } ?? false
            if endsSentence && line.count < typicalWidth * 4 / 5 {
                paragraphs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }
}
