import AVFoundation
import NarratorCore

/// Plays a book sentence by sentence.
///
/// Sentences are rendered a few ahead of the listener and scheduled back-to-back on one
/// `AVAudioPlayerNode`, so there are no gaps between them. Speed comes from a time-pitch
/// unit, which keeps the voice's pitch natural and needs no re-rendering.
@MainActor
final class NarrationPlayer: ObservableObject {
    @Published private(set) var book: Book?
    @Published private(set) var entryID: UUID?
    @Published private(set) var position = BookPosition(chapter: 0, sentence: 0)
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var voiceName = ""
    @Published var notice: String?
    @Published private(set) var sleepTimer: SleepTimer?
    @Published var rate: Float {
        didSet {
            timePitch.rate = rate
            settings.rate = rate
            nowPlaying?.update()
        }
    }

    enum SleepTimer: Equatable {
        case until(Date)
        case endOfChapter(Int)
    }

    /// About 170 words a minute at 1×; used to estimate times without rendered audio.
    static let charactersPerSecond = 15.0
    /// How many sentences to render ahead of the listener, and how many to queue on the audio node.
    private let renderAhead = 6
    private let queueDepth = 2

    private let library: LibraryStore
    private let settings: VoiceSettings
    private let modelStore: KokoroModelStore
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var nowPlaying: NowPlayingController?

    private var engine: SpeechEngine?
    private var engineVoiceKey: String?
    private var cache: [BookPosition: AVAudioPCMBuffer] = [:]
    /// Sentences handed to the audio node, oldest first; the first one is the one being heard.
    private var scheduled: [BookPosition] = []
    private var nextToSchedule: BookPosition?
    private var renderTask: Task<Void, Never>?
    /// Bumped on every seek so completion callbacks from flushed buffers are ignored.
    private var playbackGeneration = 0
    /// Bumped when the voice changes so in-flight renders in the old voice are discarded.
    private var voiceGeneration = 0
    private var observers: [NSObjectProtocol] = []

    init(library: LibraryStore, settings: VoiceSettings, modelStore: KokoroModelStore) {
        self.library = library
        self.settings = settings
        self.modelStore = modelStore
        rate = settings.rate

        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
        audioEngine.connect(playerNode, to: timePitch, format: NarrationAudio.format)
        audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: NarrationAudio.format)
        timePitch.rate = rate

        nowPlaying = NowPlayingController(player: self)
        observeAudioSession()
    }

    // MARK: - Opening books

    func open(_ entry: LibraryEntry) {
        guard entry.id != entryID else { return }
        do {
            let loaded = try library.book(id: entry.id)
            pause()
            book = loaded
            entryID = entry.id
            cache.removeAll()
            let saved = entry.position
            position = loaded.sentence(at: saved) == nil ? loaded.startPosition : saved
            resetQueue(at: position)
            library.markOpened(id: entry.id)
            nowPlaying?.update()
        } catch {
            notice = "Couldn't open this book: \(error.localizedDescription)"
        }
    }

    func close(_ id: UUID) {
        guard id == entryID else { return }
        pause()
        book = nil
        entryID = nil
        cache.removeAll()
        resetQueue(at: BookPosition(chapter: 0, sentence: 0))
        nowPlaying?.update()
    }

    // MARK: - Transport

    func play() {
        guard book != nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            if !audioEngine.isRunning { try audioEngine.start() }
        } catch {
            notice = "Audio couldn't start: \(error.localizedDescription)"
            return
        }
        prepareEngineIfNeeded()
        if scheduled.isEmpty && nextToSchedule == nil { nextToSchedule = position }
        isPlaying = true
        playerNode.play()
        pump()
        nowPlaying?.update()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        isBuffering = false
        playerNode.pause()
        savePosition()
        nowPlaying?.update()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func seek(to target: BookPosition) {
        guard let book, book.sentence(at: target) != nil else { return }
        let wasPlaying = isPlaying
        position = target
        resetQueue(at: target)
        let window = Set(positions(from: target, count: renderAhead))
        cache = cache.filter { window.contains($0.key) }
        if wasPlaying {
            playerNode.play()
            pump()
        }
        savePosition()
        nowPlaying?.update()
    }

    func nextSentence() {
        guard let book, let next = book.position(after: position) else { return }
        seek(to: next)
    }

    func previousSentence() {
        guard let book, let previous = book.position(before: position) else { return }
        seek(to: previous)
    }

    /// Skips by approximately `seconds` of listening, measured in text.
    func skip(seconds: Double) {
        guard let book else { return }
        let characters = Int(seconds * Self.charactersPerSecond)
        seek(to: book.position(from: position, offsetByCharacters: characters))
    }

    func goToChapter(_ index: Int) {
        guard let book, book.chapters.indices.contains(index) else { return }
        if book.chapters[index].sentences.isEmpty, let next = book.position(after: BookPosition(chapter: index, sentence: -1)) {
            seek(to: next)
        } else {
            seek(to: BookPosition(chapter: index, sentence: 0))
        }
    }

    func nextChapter() { goToChapter(position.chapter + 1) }

    func previousChapter() {
        // Like a music player: first go back to the start of this chapter.
        goToChapter(position.sentence > 2 ? position.chapter : position.chapter - 1)
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimer = minutes.map { .until(Date().addingTimeInterval(TimeInterval($0 * 60))) }
    }

    func sleepAtEndOfChapter() {
        sleepTimer = .endOfChapter(position.chapter)
    }

    /// Call after the voice settings change; upcoming audio is re-rendered in the new voice.
    func voiceSettingsChanged() {
        guard settings.voiceKey != engineVoiceKey || engine == nil else { return }
        engine = nil
        voiceGeneration += 1
        cache.removeAll()
        prepareEngineIfNeeded()
        seek(to: position)
    }

    // MARK: - Estimates for the UI

    func estimatedSeconds(characters: Int) -> TimeInterval {
        Double(characters) / Self.charactersPerSecond / Double(max(rate, 0.1))
    }

    var chapterTimeRemaining: TimeInterval {
        guard let book else { return 0 }
        let chapter = book.chapters[position.chapter]
        return estimatedSeconds(characters: chapter.sentences.dropFirst(position.sentence).reduce(0) { $0 + $1.count })
    }

    var chapterTimeElapsed: TimeInterval {
        guard let book else { return 0 }
        let chapter = book.chapters[position.chapter]
        return estimatedSeconds(characters: chapter.sentences.prefix(position.sentence).reduce(0) { $0 + $1.count })
    }

    var bookTimeRemaining: TimeInterval {
        guard let book else { return 0 }
        return estimatedSeconds(characters: book.characterCount - book.characterOffset(of: position))
    }

    // MARK: - Engine

    private func prepareEngineIfNeeded() {
        guard engine == nil || engineVoiceKey != settings.voiceKey else { return }
        switch settings.engine {
        case .kokoro:
            if let files = modelStore.installedFiles, KokoroSpeechEngine.isSupportedOnThisDevice {
                engine = KokoroSpeechEngine(modelURL: files.model, voicesURL: files.voices, voiceName: settings.kokoroVoice)
            } else {
                engine = AppleSpeechEngine(voiceIdentifier: settings.appleVoiceIdentifier)
                notice = KokoroSpeechEngine.isSupportedOnThisDevice
                    ? "The natural voice isn't downloaded yet, so an Apple voice is reading. Download it in Settings."
                    : "The Simulator can't run the natural voice, so an Apple voice is reading."
            }
        case .apple:
            engine = AppleSpeechEngine(voiceIdentifier: settings.appleVoiceIdentifier)
        }
        engineVoiceKey = settings.voiceKey
        voiceName = engine?.displayName ?? ""
    }

    private func fallBackToAppleVoice(because error: Error) {
        engine = AppleSpeechEngine(voiceIdentifier: settings.appleVoiceIdentifier)
        voiceName = engine?.displayName ?? ""
        voiceGeneration += 1
        cache.removeAll()
        notice = "The natural voice couldn't load (\(error.localizedDescription)), so an Apple voice is reading."
        seek(to: position)
    }

    // MARK: - Scheduling

    private func resetQueue(at target: BookPosition) {
        playbackGeneration += 1
        playerNode.stop() // fires completion handlers for flushed buffers; the generation check ignores them
        scheduled.removeAll()
        nextToSchedule = target
    }

    /// Moves rendered sentences onto the audio node and keeps the renderer busy.
    private func pump() {
        guard isPlaying, let book else { return }
        while scheduled.count < queueDepth, let next = nextToSchedule, let buffer = cache[next] {
            schedule(buffer, at: next)
            nextToSchedule = book.position(after: next)
        }
        isBuffering = scheduled.isEmpty && nextToSchedule != nil
        renderAheadIfNeeded()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, at target: BookPosition) {
        let generation = playbackGeneration
        scheduled.append(target)
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.didFinishPlaying(target, generation: generation) }
        }
    }

    private func didFinishPlaying(_ finished: BookPosition, generation: Int) {
        guard generation == playbackGeneration, scheduled.first == finished, let book else { return }
        scheduled.removeFirst()
        cache[finished] = nil

        guard let upcoming = scheduled.first ?? nextToSchedule else {
            // End of the book.
            isPlaying = false
            isBuffering = false
            playerNode.pause()
            savePosition()
            nowPlaying?.update()
            return
        }
        position = upcoming
        savePosition()

        switch sleepTimer {
        case .until(let date) where date <= Date():
            sleepTimer = nil
            pauseAndRewind(to: upcoming)
            return
        case .endOfChapter(let chapter) where upcoming.chapter != chapter:
            sleepTimer = nil
            pauseAndRewind(to: upcoming)
            return
        default:
            break
        }

        if book.sentence(at: upcoming) != nil { nowPlaying?.update() }
        pump()
    }

    /// Stops at a sentence boundary so resuming starts cleanly at `target`.
    private func pauseAndRewind(to target: BookPosition) {
        pause()
        resetQueue(at: target)
    }

    // MARK: - Rendering

    private func positions(from start: BookPosition?, count: Int) -> [BookPosition] {
        guard let book, var current = start else { return [] }
        var result = [current]
        while result.count < count, let next = book.position(after: current) {
            result.append(next)
            current = next
        }
        return result
    }

    private func renderAheadIfNeeded() {
        guard renderTask == nil, let book else { return }
        prepareEngineIfNeeded()
        guard let engine,
              let target = positions(from: nextToSchedule, count: renderAhead).first(where: { cache[$0] == nil }),
              let text = book.sentence(at: target) else { return }

        let generation = voiceGeneration
        let pause = book.chapters[target.chapter].paragraphEnds.contains(target.sentence) ? 0.45 : 0.12
        let isChapterEnd = target.sentence == book.chapters[target.chapter].sentences.count - 1

        renderTask = Task { [weak self] in
            var rendered: AVAudioPCMBuffer?
            var failure: Error?
            do {
                rendered = try await engine.render(text)
            } catch {
                failure = error
            }
            guard let self else { return }
            self.renderTask = nil
            guard generation == self.voiceGeneration else {
                self.pump()
                return
            }
            if let failure {
                if let kokoro = engine as? KokoroSpeechEngine, !(await kokoro.isLoaded) {
                    self.fallBackToAppleVoice(because: failure)
                    return
                }
                // One bad sentence shouldn't stop the book: leave a short silence and move on.
                rendered = NarrationAudio.silence(seconds: 0.2)
            }
            if let rendered {
                let trailing = isChapterEnd ? 1.2 : pause
                self.cache[target] = NarrationAudio.concatenate([rendered], trailingSilence: trailing)
            }
            self.pump()
        }
    }

    // MARK: - Persistence and system events

    private func savePosition() {
        guard let entryID, let book else { return }
        library.updatePosition(id: entryID, position: position, progress: book.progress(at: position))
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                switch type {
                case .began:
                    self.pause()
                case .ended:
                    if AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) { self.play() }
                @unknown default:
                    break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                // Headphones unplugged or AirPods taken out: pause instead of playing out loud.
                if reasonValue == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                // The engine stops itself on a route or format change; restart from the current sentence.
                try? self.audioEngine.start()
                self.seek(to: self.position)
            }
        })
    }
}
