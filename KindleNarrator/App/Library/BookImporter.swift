import Foundation
import NarratorCore
import PDFKit
import UIKit

/// Turns an EPUB or PDF file into a `Book` plus an optional cover image.
enum BookImporter {
    struct Imported {
        var book: Book
        var cover: Data?
    }

    enum ImportError: LocalizedError {
        case unsupportedType(String)
        case unreadablePDF
        case lockedPDF
        case scannedPDF
        case kindleFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let ext): return "“.\(ext)” files aren't supported. Use a DRM-free EPUB or PDF."
            case .unreadablePDF: return "This PDF couldn't be opened."
            case .lockedPDF: return "This PDF is password-protected."
            case .scannedPDF: return "This PDF is scanned images with no text layer, so there's nothing to read aloud yet."
            case .kindleFormat: return "Kindle files (AZW, KFX, MOBI) are DRM-protected. On Amazon's Manage Your Content and Devices page, check whether the book offers a DRM-free EPUB or PDF download."
            }
        }
    }

    static func importBook(at url: URL) throws -> Imported {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "epub":
            let parser = try EPUBParser(url: url)
            return Imported(book: try parser.parse(fallbackTitle: fallbackTitle), cover: jpeg(parser.coverImageData()))
        case "pdf":
            return try importPDF(at: url, fallbackTitle: fallbackTitle)
        case "azw", "azw3", "azw4", "kfx", "mobi", "prc":
            throw ImportError.kindleFormat
        case let ext:
            throw ImportError.unsupportedType(ext)
        }
    }

    private static func importPDF(at url: URL, fallbackTitle: String) throws -> Imported {
        guard let document = PDFDocument(url: url) else { throw ImportError.unreadablePDF }
        if document.isLocked { throw ImportError.lockedPDF }

        let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        guard pages.contains(where: { $0.contains { $0.isLetter } }) else { throw ImportError.scannedPDF }
        let pageParagraphs = PDFTextCleaner.paragraphs(fromPages: pages)

        var chapters = chapterRanges(for: document).compactMap { range -> Chapter? in
            let paragraphs = pageParagraphs[range.pages].flatMap { $0 }
            let chapter = BookBuilder.chapter(
                title: range.title,
                paragraphs: paragraphs,
                isAuxiliary: BookBuilder.isAuxiliary(title: range.title, path: "")
            )
            return chapter.sentences.isEmpty ? nil : chapter
        }

        guard !chapters.isEmpty else { throw ImportError.scannedPDF }
        let cast = DialogueAnalyzer.analyze(&chapters)

        let attributes = document.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespaces)
        let author = attributes[PDFDocumentAttribute.authorAttribute] as? String
        let cover = document.page(at: 0)?.thumbnail(of: CGSize(width: 400, height: 600), for: .mediaBox)

        return Imported(
            book: Book(
                title: title?.isEmpty == false ? title! : fallbackTitle,
                author: author,
                format: .pdf,
                chapters: chapters,
                cast: cast
            ),
            cover: cover?.jpegData(compressionQuality: 0.8)
        )
    }

    /// Chapters from the PDF's outline (bookmarks) when it has one, else 10-page sections.
    private static func chapterRanges(for document: PDFDocument) -> [(title: String, pages: Range<Int>)] {
        let count = document.pageCount
        var starts: [(String, Int)] = []
        if let outline = document.outlineRoot {
            for index in 0..<outline.numberOfChildren {
                guard let item = outline.child(at: index),
                      let page = item.destination?.page else { continue }
                let pageIndex = document.index(for: page)
                if starts.last?.1 != pageIndex { starts.append((item.label ?? "Section \(index + 1)", pageIndex)) }
            }
        }
        starts.sort { $0.1 < $1.1 }
        if starts.count < 2 {
            return stride(from: 0, to: count, by: 10).map { start -> (title: String, pages: Range<Int>) in
                let end = min(start + 10, count)
                return (title: "Pages \(start + 1)–\(end)", pages: start..<end)
            }
        }
        if let first = starts.first, first.1 > 0 { starts.insert(("Opening", 0), at: 0) }
        return starts.enumerated().compactMap { (index, start) -> (title: String, pages: Range<Int>)? in
            let end = index + 1 < starts.count ? starts[index + 1].1 : count
            return end > start.1 ? (title: start.0, pages: start.1..<end) : nil
        }
    }

    private static func jpeg(_ data: Data?) -> Data? {
        guard let data, let image = UIImage(data: data) else { return nil }
        let scale = min(1, 600 / max(image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
