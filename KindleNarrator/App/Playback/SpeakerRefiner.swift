import Foundation
import NarratorCore

/// Re-checks who speaks each line with the on-device language model, one chapter at a time,
/// starting with the chapter being listened to so the improvement is heard soonest.
/// Results are saved with the book, so each chapter is only analysed once.
@MainActor
final class SpeakerRefiner: ObservableObject {
    enum Status: Equatable {
        case unavailable(String)
        case idle
        case working(done: Int, total: Int)
        case finished
    }

    @Published private(set) var status: Status = .idle

    private let library: LibraryStore
    private weak var player: NarrationPlayer?
    private var task: Task<Void, Never>?
    private var bookID: UUID?

    init(library: LibraryStore, player: NarrationPlayer) {
        self.library = library
        self.player = player
    }

    func start(bookID: UUID) {
        guard bookID != self.bookID || task == nil else { return }
        task?.cancel()
        self.bookID = bookID
        if let reason = SpeakerLabeler.unavailableReason {
            status = .unavailable(reason)
            return
        }
        task = Task { [weak self] in
            await self?.run(bookID: bookID)
        }
    }

    /// Stops work on `id`'s book, such as when it's deleted.
    func stop(bookID id: UUID) {
        guard id == bookID else { return }
        task?.cancel()
        task = nil
        bookID = nil
        status = .idle
    }

    private func run(bookID: UUID) async {
        guard var book = try? library.book(id: bookID) else { return }
        let first = player?.entryID == bookID ? player?.position.chapter ?? 0 : 0
        let order = Array(first..<book.chapters.count) + Array(0..<first)
        let pending = order.filter { !book.chapters[$0].speakersRefined && !book.chapters[$0].dialogue.isEmpty }
        guard !pending.isEmpty else {
            status = .finished
            return
        }

        for (done, index) in pending.enumerated() {
            if Task.isCancelled { return }
            status = .working(done: done, total: pending.count)
            let result = await SpeakerLabeler.label(chapter: book.chapters[index], cast: book.cast)
            if Task.isCancelled { return }

            DialogueAnalyzer.applySpeakers(result.speakers, to: &book.chapters[index])
            book.chapters[index].speakersRefined = true
            book.cast = DialogueAnalyzer.rebuildCast(chapters: book.chapters, previous: book.cast, extraVotes: result.genders)
            library.saveBook(book)
            player?.bookDidUpdate(book)
        }
        status = .finished
        task = nil
    }
}
