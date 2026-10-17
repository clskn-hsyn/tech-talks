import MediaPlayer
import UIKit

/// Lock screen, Control Center, CarPlay, AirPods and headphone-button controls.
@MainActor
final class NowPlayingController {
    private weak var player: NarrationPlayer?
    private var cachedArtwork: (id: UUID, artwork: MPMediaItemArtwork?)?

    init(player: NarrationPlayer) {
        self.player = player
        configureCommands()
    }

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]

        handle(center.playCommand) { $0.play() }
        handle(center.pauseCommand) { $0.pause() }
        handle(center.togglePlayPauseCommand) { $0.togglePlayback() }
        handle(center.skipForwardCommand) { $0.skip(seconds: 15) }
        handle(center.skipBackwardCommand) { $0.skip(seconds: -15) }
        handle(center.nextTrackCommand) { $0.nextChapter() }
        handle(center.previousTrackCommand) { $0.previousChapter() }
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5].map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            Task { @MainActor in self?.player?.rate = rate }
            return .success
        }
    }

    private func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (NarrationPlayer) -> Void) {
        command.isEnabled = true
        command.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let player = self?.player else { return }
                action(player)
            }
            return .success
        }
    }

    func update() {
        let info = MPNowPlayingInfoCenter.default()
        guard let player, let book = player.book, let entryID = player.entryID else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        let chapter = book.chapters[player.position.chapter]
        var values: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author ?? "",
            MPMediaItemPropertyPlaybackDuration: player.chapterTimeElapsed + player.chapterTimeRemaining,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.chapterTimeElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyChapterNumber: player.position.chapter,
            MPNowPlayingInfoPropertyChapterCount: book.chapters.count,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork = artwork(for: entryID) {
            values[MPMediaItemPropertyArtwork] = artwork
        }
        info.nowPlayingInfo = values
        info.playbackState = player.isPlaying ? .playing : .paused
    }

    private func artwork(for id: UUID) -> MPMediaItemArtwork? {
        if let cachedArtwork, cachedArtwork.id == id { return cachedArtwork.artwork }
        let made = LibraryCovers.image(for: id).map(Self.makeArtwork)
        cachedArtwork = (id, made)
        return made
    }

    /// Built outside the main actor: MediaPlayer calls the image handler on a background queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

/// Cover lookup that doesn't need the library object, for places like the lock screen.
enum LibraryCovers {
    static func image(for id: UUID) -> UIImage? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library/covers/\(id).jpg")
        return UIImage(contentsOfFile: url.path)
    }
}
