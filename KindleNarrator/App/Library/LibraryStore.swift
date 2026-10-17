import Foundation
import NarratorCore
import UIKit

struct LibraryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var author: String?
    var format: Book.SourceFormat
    var addedAt: Date
    var lastOpenedAt: Date?
    var position: BookPosition
    var progress: Double
    var chapterCount: Int
    var characterCount: Int
}

/// The books on this device. Each parsed book is stored as JSON next to a small index,
/// so the library loads instantly and only the open book is held in memory.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var isImporting = false
    @Published var importMessage: String?

    private let root: URL
    private var cachedBook: Book?

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        load()
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var booksDirectory: URL { root.appendingPathComponent("books", isDirectory: true) }
    private var coversDirectory: URL { root.appendingPathComponent("covers", isDirectory: true) }

    var sortedEntries: [LibraryEntry] {
        entries.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
    }

    func entry(id: UUID) -> LibraryEntry? { entries.first { $0.id == id } }

    func book(id: UUID) throws -> Book {
        if let cachedBook, cachedBook.id == id { return cachedBook }
        let data = try Data(contentsOf: booksDirectory.appendingPathComponent("\(id).json"))
        let book = try JSONDecoder().decode(Book.self, from: data)
        cachedBook = book
        return book
    }

    func coverImage(id: UUID) -> UIImage? {
        UIImage(contentsOfFile: coversDirectory.appendingPathComponent("\(id).jpg").path)
    }

    // MARK: - Import

    func importBooks(from urls: [URL]) async {
        for url in urls { await importBook(from: url) }
    }

    func importBook(from url: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try BookImporter.importBook(at: url)
            }.value
            let book = imported.book
            try JSONEncoder().encode(book).write(to: booksDirectory.appendingPathComponent("\(book.id).json"), options: .atomic)
            if let cover = imported.cover {
                try? cover.write(to: coversDirectory.appendingPathComponent("\(book.id).jpg"), options: .atomic)
            }
            entries.append(LibraryEntry(
                id: book.id,
                title: book.title,
                author: book.author,
                format: book.format,
                addedAt: Date(),
                lastOpenedAt: nil,
                position: book.startPosition,
                progress: 0,
                chapterCount: book.chapters.count,
                characterCount: book.characterCount
            ))
            save()
            importMessage = nil
        } catch {
            importMessage = "Couldn't import “\(url.lastPathComponent)”. \(error.localizedDescription)"
        }
        // Files opened from other apps land in Documents/Inbox; the parsed copy is all we need.
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Updates

    func markOpened(id: UUID) {
        update(id) { $0.lastOpenedAt = Date() }
    }

    func updatePosition(id: UUID, position: BookPosition, progress: Double) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].position != position else { return }
        entries[index].position = position
        entries[index].progress = progress
        save()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        if cachedBook?.id == id { cachedBook = nil }
        try? FileManager.default.removeItem(at: booksDirectory.appendingPathComponent("\(id).json"))
        try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent("\(id).jpg"))
        save()
    }

    private func update(_ id: UUID, _ change: (inout LibraryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LibraryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        do {
            try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            importMessage = "Couldn't save your library: \(error.localizedDescription)"
        }
    }
}
