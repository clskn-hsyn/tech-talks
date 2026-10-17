import Foundation

/// Rewrites written-only conventions into the words a narrator would say.
///
/// Speech models mispronounce "Dr.", "1984", "3:15" or "21st" often enough to break
/// immersion over a whole book, so these are spelled out before synthesis. Running this
/// before sentence segmentation also removes most abbreviation periods that would
/// otherwise look like sentence ends.
public enum TextNormalizer {
    public static func normalize(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "...", with: "…")
        s = s.replacingOccurrences(of: ". . .", with: "…")
        s = expandAbbreviations(s)
        s = replace(#"\b(Chapter|CHAPTER|Part|PART|Book|BOOK)\s+([IVXLCDM]+)\b"#, in: s) { groups in
            guard let value = romanValue(groups[2]) else { return groups[0] }
            return "\(groups[1]) \(NumberSpeller.cardinal(value))"
        }
        s = replace(#"([$£€])(\d[\d,]*)(?:\.(\d{2}))?\b"#, in: s) { groups in
            spokenCurrency(symbol: groups[1], whole: groups[2], cents: groups[3])
        }
        s = replace(#"\b(\d{1,2}):(\d{2})\b"#, in: s) { groups in
            spokenTime(hours: groups[1], minutes: groups[2]) ?? groups[0]
        }
        s = replace(#"\b(\d+)(st|nd|rd|th)\b"#, in: s) { groups in
            guard let value = Int(groups[1]), value < 1_000_000 else { return groups[0] }
            return NumberSpeller.ordinal(value)
        }
        s = replace(#"\b(1[1-9]|20)(\d0)s\b"#, in: s) { groups in
            // Decades: "the 1850s" → "the eighteen fifties", "1900s" → "nineteen hundreds".
            guard let value = Int(groups[1] + groups[2]) else { return groups[0] }
            let words = NumberSpeller.year(value)
            return words.hasSuffix("y") ? String(words.dropLast()) + "ies" : words + "s"
        }
        s = replace(#"(\d+(?:\.\d+)?)\s?%"#, in: s) { groups in
            "\(spokenNumber(groups[1]) ?? groups[1]) percent"
        }
        s = replace(#"(?<![\d.,])(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?(?![\d,]*\d)"#, in: s) { groups in
            spokenNumber(groups[0]) ?? groups[0]
        }
        s = s.replacingOccurrences(of: "&", with: " and ")
        return HTMLTextExtractor.collapseWhitespace(s)
    }

    // MARK: - Abbreviations

    /// Case-sensitive, matched at word boundaries. Only unambiguous ones: "St." could be
    /// Saint or Street and "No." could be a word, so those are left for the segmenter.
    static let abbreviations: [(String, String)] = [
        ("Mr.", "Mister"), ("Mrs.", "Missus"), ("Ms.", "Miz"), ("Dr.", "Doctor"),
        ("Prof.", "Professor"), ("Capt.", "Captain"), ("Gen.", "General"), ("Lt.", "Lieutenant"),
        ("Sgt.", "Sergeant"), ("Col.", "Colonel"), ("Rev.", "Reverend"), ("Gov.", "Governor"),
        ("Sen.", "Senator"), ("Rep.", "Representative"), ("Jr.", "Junior"), ("Sr.", "Senior"),
        ("e.g.", "for example"), ("i.e.", "that is"), ("etc.", "etcetera"), ("vs.", "versus"),
        ("approx.", "approximately"), ("Mt.", "Mount"), ("Ft.", "Fort"),
    ]

    static func expandAbbreviations(_ text: String) -> String {
        var s = text
        for (short, long) in abbreviations where s.contains(short) {
            let pattern = "(?<![\\p{L}.])" + NSRegularExpression.escapedPattern(for: short)
            // "etc." ending a sentence keeps its period as the sentence end.
            s = replace(pattern + "(?=\\s+\\p{Lu})", in: s) { _ in
                short == "etc." ? long + "." : long
            }
            s = replace(pattern, in: s) { _ in long }
        }
        return s
    }

    // MARK: - Numbers

    static func spokenNumber(_ raw: String) -> String? {
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        let wholeDigits = parts[0].replacingOccurrences(of: ",", with: "")
        guard let whole = Int(wholeDigits), wholeDigits.count <= 12 else { return nil }
        if parts.count == 2 {
            let decimals = parts[1].compactMap { $0.wholeNumberValue }.map { NumberSpeller.cardinal($0) }
            return NumberSpeller.cardinal(whole) + " point " + decimals.joined(separator: " ")
        }
        // A bare four-digit number in prose is usually a year: "in 1984", "the 1850s".
        if !parts[0].contains(","), wholeDigits.count == 4, (1100...2099).contains(whole) {
            return NumberSpeller.year(whole)
        }
        return NumberSpeller.cardinal(whole)
    }

    static func spokenTime(hours: String, minutes: String) -> String? {
        guard let h = Int(hours), let m = Int(minutes), h <= 24, m < 60 else { return nil }
        if m == 0 { return "\(NumberSpeller.cardinal(h)) o'clock" }
        let minuteWords = m < 10 ? "oh \(NumberSpeller.cardinal(m))" : NumberSpeller.cardinal(m)
        return "\(NumberSpeller.cardinal(h)) \(minuteWords)"
    }

    static func spokenCurrency(symbol: String, whole: String, cents: String) -> String {
        let names: [String: (String, String)] = ["$": ("dollar", "dollars"), "£": ("pound", "pounds"), "€": ("euro", "euros")]
        let (singular, plural) = names[symbol] ?? ("", "")
        let value = Int(whole.replacingOccurrences(of: ",", with: "")) ?? 0
        var spoken = "\(NumberSpeller.cardinal(value)) \(value == 1 ? singular : plural)"
        if let c = Int(cents), c > 0 {
            spoken += " and \(NumberSpeller.cardinal(c)) \(c == 1 ? "cent" : "cents")"
        }
        return spoken
    }

    static func romanValue(_ numeral: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0
        var previous = 0
        for character in numeral.reversed() {
            guard let value = values[character] else { return nil }
            if value < previous { total -= value } else { total += value; previous = value }
        }
        return total > 0 && total < 400 ? total : nil
    }

    // MARK: - Regex helper

    /// Replaces each match using `transform`, which receives the full match and its
    /// capture groups (empty string for groups that didn't participate).
    static func replace(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

public enum NumberSpeller {
    static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                       "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                       "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    static let scales: [(Int, String)] = [(1_000_000_000, "billion"), (1_000_000, "million"), (1_000, "thousand")]

    public static func cardinal(_ number: Int) -> String {
        if number < 0 { return "minus " + cardinal(-number) }
        if number < 20 { return ones[number] }
        if number < 100 {
            let rest = number % 10
            return tens[number / 10] + (rest == 0 ? "" : "-" + ones[rest])
        }
        if number < 1000 {
            let rest = number % 100
            return ones[number / 100] + " hundred" + (rest == 0 ? "" : " " + cardinal(rest))
        }
        for (scale, name) in scales where number >= scale {
            let rest = number % scale
            return cardinal(number / scale) + " " + name + (rest == 0 ? "" : " " + cardinal(rest))
        }
        return String(number)
    }

    public static func year(_ year: Int) -> String {
        let century = year / 100
        let rest = year % 100
        if year % 1000 < 10 && year >= 2000 {
            // 2000–2009 read as "two thousand (and) five".
            return cardinal(year)
        }
        if rest == 0 { return cardinal(century) + " hundred" }
        let restWords = rest < 10 ? "oh " + cardinal(rest) : cardinal(rest)
        return cardinal(century) + " " + restWords
    }

    public static func ordinal(_ number: Int) -> String {
        let words = cardinal(number)
        let irregular: [String: String] = [
            "one": "first", "two": "second", "three": "third", "five": "fifth",
            "eight": "eighth", "nine": "ninth", "twelve": "twelfth",
        ]
        // Only the last word (after a space or hyphen) changes: "twenty-one" → "twenty-first".
        let separators: Set<Character> = [" ", "-"]
        let splitIndex = words.lastIndex { separators.contains($0) }.map { words.index(after: $0) } ?? words.startIndex
        let head = String(words[..<splitIndex])
        let last = String(words[splitIndex...])
        if let replacement = irregular[last] { return head + replacement }
        if last.hasSuffix("y") { return head + String(last.dropLast()) + "ieth" }
        return head + last + "th"
    }
}
