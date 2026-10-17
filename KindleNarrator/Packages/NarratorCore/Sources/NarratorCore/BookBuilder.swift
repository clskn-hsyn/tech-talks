import Foundation

/// Turns extracted paragraphs into narrated chapters. Shared by the EPUB and PDF importers.
public enum BookBuilder {
    public static func chapter(title: String, paragraphs: [String], isAuxiliary: Bool = false) -> Chapter {
        var sentences: [String] = []
        var paragraphEnds: Set<Int> = []
        for paragraph in paragraphs {
            let pieces = SentenceSegmenter.split(TextNormalizer.normalize(paragraph))
            guard !pieces.isEmpty else { continue }
            sentences.append(contentsOf: pieces)
            paragraphEnds.insert(sentences.count - 1)
        }
        return Chapter(title: title, sentences: sentences, paragraphEnds: paragraphEnds, isAuxiliary: isAuxiliary)
    }

    static let auxiliaryMarkers = [
        "copyright", "dedication", "acknowledg", "table of contents", "contents", "also by",
        "about the author", "about the publisher", "index", "title page", "titlepage", "half title",
        "cover", "praise for", "colophon", "imprint", "newsletter", "toc", "bibliography", "permissions",
    ]

    /// Front and back matter, judged from the chapter title or the content file's name.
    public static func isAuxiliary(title: String, path: String) -> Bool {
        let title = title.lowercased()
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        // File names are matched whole or by suffix only: Calibre names every content file
        // "index_split_NNN.html", so a prefix match on "index" would hide the whole book.
        return auxiliaryMarkers.contains { marker in
            let fileMarker = marker.replacingOccurrences(of: " ", with: "")
            return title == marker || title.hasPrefix(marker + " ") || title.hasPrefix(marker + ":")
                || file == fileMarker || file.hasSuffix("-" + fileMarker) || file.hasSuffix("_" + fileMarker)
        }
    }
}
