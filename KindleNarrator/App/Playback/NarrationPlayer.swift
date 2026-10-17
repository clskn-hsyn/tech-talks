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
    /// Which Kokoro voice each speaker gets in the open book (empty when everyone uses the narrator).
    @Published private(set) var castVoices: [String: String] = [:]
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
    private let previewNode = AVAudioPlayerNode()
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
        audioEngine.attach(previewNode)
        audioEngine.connect(previewNode, to: audioEngine.mainMixerNode, format: NarrationAudio.format)
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
            recast()
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
        guard book != nil, startAudio() else { return }
        previewNode.stop()
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

    private func startAudio() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            if !audioEngine.isRunning { try audioEngine.start() }
            return true
        } catch {
            notice = "Audio couldn't start: \(error.localizedDescription)"
            return false
        }
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
        // Also re-run when the natural voice has just been downloaded while an Apple voice stood in.
        let kokoroNowAvailable = settings.engine == .kokoro && !(engine is KokoroSpeechEngine)
            && modelStore.installedFiles != nil
        guard settings.voiceKey != engineVoiceKey || engine == nil || kokoroNowAvailable else { return }
        // Keep the loaded Kokoro model when only the narrator voice or casting changed.
        let reuseKokoro = settings.engine == .kokoro && engine is KokoroSpeechEngine
            && engineVoiceKey?.hasPrefix("kokoro:") == true
        if reuseKokoro, let kokoro = engine as? KokoroSpeechEngine {
            kokoro.voiceName = settings.kokoroVoice
            engineVoiceKey = settings.voiceKey
            voiceName = kokoro.displayName
        } else {
            engine = nil
            prepareEngineIfNeeded()
        }
        recast()
        rerenderUpcoming()
    }

    /// Call after the listener picks a different voice for a character.
    func castChanged() {
        recast()
        rerenderUpcoming()
    }

    /// Takes a newer copy of the open book, such as one with re-labelled speakers.
    func bookDidUpdate(_ updated: Book) {
        guard updated.id == book?.id else { return }
        book = updated
        recast()
        // Sentences already queued keep their voices; everything after is rendered again.
        voiceGeneration += 1
        cache.removeAll()
        pump()
    }

    /// Plays a short sample in a character voice without moving the reading position.
    func previewVoice(_ voice: String, saying sample: String) {
        guard let kokoro = engine as? KokoroSpeechEngine ?? makeKokoroEngine() else {
            notice = "Voice previews need the natural voice. Download it in Settings."
            return
        }
        pause()
        guard startAudio() else { return }
        Task { [weak self] in
            do {
                let buffer = try await kokoro.render(sample, voice: voice)
                guard let self else { return }
                self.previewNode.stop()
                self.previewNode.scheduleBuffer(buffer, completionHandler: nil)
                self.previewNode.play()
            } catch {
                self?.notice = "Couldn't play the preview: \(error.localizedDescription)"
            }
        }
    }

    private func recast() {
        guard let book, let entryID, settings.engine == .kokoro, settings.characterVoices,
              engine?.supportsCharacterVoices ?? true else {
            castVoices = [:]
            return
        }
        let overrides = library.entry(id: entryID)?.voiceOverrides ?? [:]
        castVoices = VoiceCasting.assign(cast: book.cast, narrator: settings.kokoroVoice, overrides: overrides)
    }

    private func rerenderUpcoming() {
        voiceGeneration += 1
        cache.removeAll()
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
            if let kokoro = makeKokoroEngine() {
                engine = kokoro
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
        recast()
    }

    private func makeKokoroEngine() -> KokoroSpeechEngine? {
        guard let files = modelStore.installedFiles, KokoroSpeechEngine.isSupportedOnThisDevice else { return nil }
        return KokoroSpeechEngine(modelURL: files.model, voicesURL: files.voices, voiceName: settings.kokoroVoice)
    }

    private func fallBackToAppleVoice(because error: Error) {
        engine = AppleSpeechEngine(voiceIdentifier: settings.appleVoiceIdentifier)
        voiceName = engine?.displayName ?? ""
        recast()
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
              book.sentence(at: target) != nil else { return }
        let parts = voicedParts(of: target, in: book)

        let generation = voiceGeneration
        let pause = book.chapters[target.chapter].paragraphEnds.contains(target.sentence) ? 0.45 : 0.12
        let isChapterEnd = target.sentence == book.chapters[target.chapter].sentences.count - 1

        renderTask = Task { [weak self] in
            var rendered: AVAudioPCMBuffer?
            var failure: Error?
            do {
                var buffers: [AVAudioPCMBuffer] = []
                for (index, part) in parts.enumerated() {
                    // A short breath where the voice changes, like a reader turning to a character.
                    if index > 0 { buffers.append(NarrationAudio.silence(seconds: 0.12)) }
                    buffers.append(try await engine.render(part.text, voice: part.voice))
                }
                rendered = NarrationAudio.concatenate(buffers)
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

    /// The sentence split into runs of text that share a voice. Narration and unattributed
    /// dialogue stay with the narrator, so most sentences are still a single render.
    private func voicedParts(of target: BookPosition, in book: Book) -> [(text: String, voice: String?)] {
        let segments = book.chapters[target.chapter].segments(forSentence: target.sentence)
        var parts: [(text: String, voice: String?)] = []
        for segment in segments {
            let voice = castVoices.isEmpty ? nil : segment.speaker.flatMap { castVoices[$0] }
            let narratorVoice = castVoices[DialogueAnalyzer.narratorSpeaker]
            // The narrator's own voice and "no voice" are the same thing.
            let normalized = voice == narratorVoice ? nil : voice
            if let last = parts.last, last.voice == normalized {
                parts[parts.count - 1].text += " " + segment.text
            } else {
                parts.append((segment.text, normalized))
            }
        }
        return parts
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
