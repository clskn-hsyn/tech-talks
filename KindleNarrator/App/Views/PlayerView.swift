import NarratorCore
import SwiftUI

/// Read-along player: the current chapter's text with the spoken sentence highlighted.
struct PlayerView: View {
    @EnvironmentObject private var player: NarrationPlayer
    let entry: LibraryEntry

    @State private var showingChapters = false
    @State private var showingSettings = false
    @State private var followsAudio = true

    var body: some View {
        VStack(spacing: 0) {
            if let book = player.book, player.entryID == entry.id {
                ReadAlongText(
                    chapter: book.chapters[player.position.chapter],
                    chapterIndex: player.position.chapter,
                    current: player.position.sentence,
                    followsAudio: $followsAudio
                ) { sentence in
                    followsAudio = true
                    player.seek(to: BookPosition(chapter: player.position.chapter, sentence: sentence))
                }
                Divider()
                PlayerControls(book: book, showingChapters: $showingChapters)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: {
                    Label("Voice", systemImage: "waveform")
                }
            }
        }
        .onAppear { player.open(entry) }
        .sheet(isPresented: $showingChapters) {
            if let book = player.book {
                ChapterList(book: book, current: player.position.chapter) { index in
                    player.goToChapter(index)
                    showingChapters = false
                }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .alert("Heads up", isPresented: Binding(
            get: { player.notice != nil },
            set: { if !$0 { player.notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.notice ?? "")
        }
    }
}

private struct ReadAlongText: View {
    let chapter: Chapter
    let chapterIndex: Int
    let current: Int
    @Binding var followsAudio: Bool
    let onTap: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(chapter.title)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .padding(.bottom, 16)
                    ForEach(Array(chapter.sentences.enumerated()), id: \.offset) { index, sentence in
                        Text(sentence)
                            .font(.system(.title3, design: .serif))
                            .lineSpacing(5)
                            .foregroundStyle(index < current ? .secondary : .primary)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(index == current ? Color.narratorHighlight : .clear)
                            )
                            .padding(.bottom, chapter.paragraphEnds.contains(index) ? 14 : 0)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(index) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Starts reading from this sentence")
                            .id(index)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(DragGesture().onChanged { _ in followsAudio = false })
            .onChange(of: current) { _, newValue in
                guard followsAudio else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(newValue, anchor: UnitPoint(x: 0, y: 0.35)) }
            }
            .onChange(of: chapterIndex) { _, _ in
                proxy.scrollTo(current, anchor: .top)
            }
            .onAppear { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.35)) }
            .overlay(alignment: .bottomTrailing) {
                if !followsAudio {
                    Button {
                        followsAudio = true
                        withAnimation { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.35)) }
                    } label: {
                        Label("Back to reading", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct PlayerControls: View {
    @EnvironmentObject private var player: NarrationPlayer
    let book: Book
    @Binding var showingChapters: Bool

    static let speeds: [Float] = [0.75, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5]

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                ProgressView(value: book.progress(at: player.position))
                HStack {
                    Button { showingChapters = true } label: {
                        Label("Chapter \(player.position.chapter + 1) of \(book.chapters.count)", systemImage: "list.bullet")
                            .labelStyle(.titleAndIcon)
                    }
                    .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(formatted(player.chapterTimeRemaining)) left in chapter")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                ControlButton("Back 15 seconds", systemImage: "gobackward.15") { player.skip(seconds: -15) }
                Spacer()
                ControlButton("Previous sentence", systemImage: "backward.end.fill") { player.previousSentence() }
                Spacer()
                Button(action: player.togglePlayback) {
                    ZStack {
                        Circle().fill(Color.narratorAccent).frame(width: 68, height: 68)
                        if player.isBuffering {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                        }
                    }
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Spacer()
                ControlButton("Next sentence", systemImage: "forward.end.fill") { player.nextSentence() }
                Spacer()
                ControlButton("Forward 15 seconds", systemImage: "goforward.15") { player.skip(seconds: 15) }
            }

            HStack {
                Menu {
                    Picker("Speed", selection: $player.rate) {
                        ForEach(Self.speeds, id: \.self) { speed in
                            Text(speedLabel(speed)).tag(speed)
                        }
                    }
                } label: {
                    Label(speedLabel(player.rate), systemImage: "speedometer")
                }
                Spacer()
                Text(player.voiceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("15 minutes") { player.setSleepTimer(minutes: 15) }
                    Button("30 minutes") { player.setSleepTimer(minutes: 30) }
                    Button("1 hour") { player.setSleepTimer(minutes: 60) }
                    Button("End of chapter") { player.sleepAtEndOfChapter() }
                    if player.sleepTimer != nil {
                        Button("Turn off", role: .destructive) { player.setSleepTimer(minutes: nil) }
                    }
                } label: {
                    Label(sleepLabel, systemImage: player.sleepTimer == nil ? "moon" : "moon.fill")
                }
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var sleepLabel: String {
        switch player.sleepTimer {
        case nil: return "Sleep"
        case .some(.endOfChapter): return "End of chapter"
        case .some(.until(let date)): return "Until \(date.formatted(date: .omitted, time: .shortened))"
        }
    }

    private func speedLabel(_ speed: Float) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

private struct ControlButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(title)
    }
}

private struct ChapterList: View {
    let book: Book
    let current: Int
    let select: (Int) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button { select(index) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title)
                                    .foregroundStyle(chapter.isAuxiliary ? .secondary : .primary)
                                Text(Duration.seconds(Double(chapter.characterCount) / NarrationPlayer.charactersPerSecond)
                                    .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if index == current {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                    .id(index)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
