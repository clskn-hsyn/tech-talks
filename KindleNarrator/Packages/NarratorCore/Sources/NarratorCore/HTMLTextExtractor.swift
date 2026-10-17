import Foundation

/// Pulls readable paragraphs out of an EPUB XHTML document.
///
/// EPUB content is nominally XML, but real books use undeclared entities (`&nbsp;`)
/// and sloppy markup often enough that a strict XMLParser fails. This is a small
/// forgiving scanner instead: it drops non-content elements, footnote markers and
/// page-break anchors, and turns block elements into paragraph boundaries.
public enum HTMLTextExtractor {
    public struct Document: Equatable, Sendable {
        public var firstHeading: String?
        public var paragraphs: [String]
    }

    /// Elements whose whole subtree is never read aloud.
    static let skippedElements: Set<String> = [
        "head", "script", "style", "sup", "svg", "math", "nav", "figure", "table", "noscript", "rt",
    ]

    static let blockElements: Set<String> = [
        "p", "div", "section", "article", "blockquote", "li", "ul", "ol", "dd", "dt", "dl",
        "h1", "h2", "h3", "h4", "h5", "h6", "tr", "header", "footer", "aside", "pre", "hr", "br",
        "figcaption", "caption", "body",
    ]

    static let voidElements: Set<String> = [
        "br", "hr", "img", "meta", "link", "input", "col", "area", "base", "wbr", "source",
    ]

    /// `epub:type` / `role` / `class` markers for things a listener doesn't want to hear.
    static let skippedMarkers = [
        "footnote", "endnote", "rearnote", "noteref", "pagebreak", "page-break", "pagenum", "page-number",
    ]

    public static func extract(_ html: String) -> Document {
        var paragraphs: [String] = []
        var current = ""
        var firstHeading: String?
        var headingBuffer: String?
        var skipStack: [String] = []

        func flush() {
            let text = collapseWhitespace(current)
            if !text.isEmpty { paragraphs.append(text) }
            current = ""
        }

        let scalars = Array(html.unicodeScalars)
        var index = 0
        var textStart = 0

        func appendText(upTo end: Int) {
            guard skipStack.isEmpty, textStart < end else { return }
            var chunk = String.UnicodeScalarView()
            chunk.append(contentsOf: scalars[textStart..<end])
            let text = decodeEntities(String(chunk))
            current += text
            if headingBuffer != nil { headingBuffer! += text }
        }

        while index < scalars.count {
            guard scalars[index] == "<" else { index += 1; continue }
            appendText(upTo: index)

            // Comments, CDATA and doctype/processing instructions.
            if matches(scalars, at: index, "<!--") {
                index = find(scalars, "-->", from: index + 4).map { $0 + 3 } ?? scalars.count
                textStart = index
                continue
            }
            guard let close = find(scalars, ">", from: index + 1) else {
                index = scalars.count
                textStart = index
                break
            }
            var tagScalars = String.UnicodeScalarView()
            tagScalars.append(contentsOf: scalars[(index + 1)..<close])
            let tag = String(tagScalars)
            index = close + 1
            textStart = index

            if tag.hasPrefix("!") || tag.hasPrefix("?") { continue }

            let isClosing = tag.hasPrefix("/")
            let body = isClosing ? String(tag.dropFirst()) : tag
            let name = body.prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }.lowercased()
            guard !name.isEmpty else { continue }
            let localName = name.split(separator: ":").last.map(String.init) ?? name
            let selfClosing = body.hasSuffix("/") || voidElements.contains(localName)

            if isClosing {
                if let last = skipStack.last, last == localName {
                    skipStack.removeLast()
                    continue
                }
                guard skipStack.isEmpty else { continue }
                if isHeading(localName), let heading = headingBuffer {
                    let text = collapseWhitespace(heading)
                    if firstHeading == nil, !text.isEmpty { firstHeading = text }
                    headingBuffer = nil
                }
                if blockElements.contains(localName) { flush() }
                continue
            }

            if !skipStack.isEmpty {
                // Track nesting of the element we're skipping so its own close tag ends the skip.
                if !selfClosing, localName == skipStack.last { skipStack.append(localName) }
                continue
            }

            if !selfClosing, shouldSkip(localName, attributes: body) {
                skipStack.append(localName)
                continue
            }

            if blockElements.contains(localName) { flush() }
            if isHeading(localName), !selfClosing { headingBuffer = "" }
        }
        appendText(upTo: scalars.count)
        flush()

        return Document(firstHeading: firstHeading, paragraphs: paragraphs)
    }

    static func shouldSkip(_ name: String, attributes: String) -> Bool {
        if skippedElements.contains(name) { return true }
        let lowered = attributes.lowercased()
        guard lowered.contains("epub:type") || lowered.contains("role") || lowered.contains("class") else {
            return false
        }
        let values = ["epub:type", "role", "class"].compactMap { attribute($0, in: attributes)?.lowercased() }
        return values.contains { value in
            skippedMarkers.contains { value.contains($0) }
        }
    }

    static func isHeading(_ name: String) -> Bool {
        guard name.count == 2, name.hasPrefix("h"), let level = name.last else { return false }
        return ("1"..."6").contains(level)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for group in [2, 3] {
            if let r = Range(match.range(at: group), in: tag) { return decodeEntities(String(tag[r])) }
        }
        return nil
    }

    // MARK: - Text helpers

    public static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace || character == "\u{00AD}" || character == "\u{200B}" {
                if character == "\u{00AD}" || character == "\u{200B}" { continue }
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "copy": "©", "reg": "®",
        "trade": "™", "deg": "°", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "iacute": "í", "oacute": "ó",
        "uacute": "ú", "ntilde": "ñ", "ouml": "ö", "uuml": "ü", "auml": "ä", "ccedil": "ç",
        "shy": "\u{00AD}", "thinsp": " ", "ensp": " ", "emsp": " ", "zwnj": "", "zwj": "",
        "times": "×", "minus": "−", "middot": "·", "bull": "•", "sect": "§", "para": "¶",
        "pound": "£", "euro": "€", "yen": "¥", "cent": "¢",
    ]

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let name = text[text.index(after: index)..<semicolon]
            if let decoded = decodeEntity(String(name)) {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    static func decodeEntity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            return value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
        }
        return namedEntities[name] ?? namedEntities[name.lowercased()]
    }

    private static func matches(_ scalars: [Unicode.Scalar], at index: Int, _ needle: String) -> Bool {
        let needleScalars = Array(needle.unicodeScalars)
        guard index + needleScalars.count <= scalars.count else { return false }
        return Array(scalars[index..<(index + needleScalars.count)]) == needleScalars
    }

    private static func find(_ scalars: [Unicode.Scalar], _ needle: String, from start: Int) -> Int? {
        let needleScalars = Array(needle.unicodeScalars)
        guard !needleScalars.isEmpty, start < scalars.count else { return nil }
        var i = start
        while i + needleScalars.count <= scalars.count {
            if scalars[i] == needleScalars[0], Array(scalars[i..<(i + needleScalars.count)]) == needleScalars {
                return i
            }
            i += 1
        }
        return nil
    }
}
