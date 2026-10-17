import NarratorCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: NarrationPlayer
    @EnvironmentObject private var refiner: SpeakerRefiner
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.entries.isEmpty {
                    EmptyLibraryView { showingImporter = true }
                } else {
                    List {
                        ForEach(library.sortedEntries) { entry in
                            NavigationLink(value: entry.id) {
                                BookRow(entry: entry, isCurrent: entry.id == player.entryID)
                            }
                        }
                        .onDelete { offsets in
                            let entries = library.sortedEntries
                            for index in offsets {
                                player.close(entries[index].id)
                                refiner.stop(bookID: entries[index].id)
                                library.delete(id: entries[index].id)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: UUID.self) { id in
                if let entry = library.entry(id: id) {
                    PlayerView(entry: entry)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Label("Voice settings", systemImage: "waveform")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImporter = true } label: {
                        Label("Add books", systemImage: "plus")
                    }
                }
            }
            .overlay {
                if library.isImporting {
                    ProgressView("Preparing book…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let id = player.entryID, path.last != id, let entry = library.entry(id: id) {
                    MiniPlayer(entry: entry) { path.append(id) }
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.epub, .pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await library.importBooks(from: urls) }
            case .failure(let error):
                library.importMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .alert("Import problem", isPresented: Binding(
            get: { library.importMessage != nil },
            set: { if !$0 { library.importMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.importMessage ?? "")
        }
    }
}

private struct BookRow: View {
    let entry: LibraryEntry
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 14) {
            BookCover(id: entry.id, title: entry.title)
                .frame(width: 52, height: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(2)
                if let author = entry.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    ProgressView(value: entry.progress)
                        .frame(maxWidth: 120)
                    Text(progressLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Now playing")
            }
        }
        .padding(.vertical, 4)
    }

    private var progressLabel: String {
        let remaining = Double(entry.characterCount) * (1 - entry.progress) / NarrationPlayer.charactersPerSecond
        let percent = Int((entry.progress * 100).rounded())
        return "\(percent)% · \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes], width: .narrow))) left"
    }
}

struct BookCover: View {
    @EnvironmentObject private var library: LibraryStore
    let id: UUID
    let title: String

    var body: some View {
        if let image = library.coverImage(id: id) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.narratorAccent.opacity(0.15))
                .overlay {
                    Text(title.prefix(1))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .accessibilityHidden(true)
        }
    }
}

private struct MiniPlayer: View {
    @EnvironmentObject private var player: NarrationPlayer
    let entry: LibraryEntry
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    BookCover(id: entry.id, title: entry.title)
                        .frame(width: 34, height: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let book = player.book {
                            Text(book.chapters[player.position.chapter].title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: player.togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct EmptyLibraryView: View {
    let addBooks: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Add a book to start listening")
                    .font(.title2.weight(.semibold))
                Text("Narrator reads DRM-free EPUB and PDF books aloud with a natural voice that runs on your iPhone.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Getting your Kindle books").font(.headline)
                    Step(number: 1, text: "On a computer, open amazon.com › Manage Your Content and Devices.")
                    Step(number: 2, text: "Open a book's menu. If the publisher allows it, choose the EPUB or PDF download.")
                    Step(number: 3, text: "Save it to iCloud Drive, then tap + here to add it. Most Kindle books are DRM-locked and won't offer this download.")
                }
                .padding(16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Text("Other DRM-free sources also work, such as Standard Ebooks, Project Gutenberg, Humble Bundle and many publishers' own stores.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(action: addBooks) {
                    Label("Add books", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
        }
    }

    private struct Step: View {
        let number: Int
        let text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.narratorAccent.opacity(0.2)))
                Text(text).font(.subheadline)
            }
        }
    }
}
