import SwiftUI

@main
struct NarratorApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var settings: VoiceSettings
    @StateObject private var modelStore: KokoroModelStore
    @StateObject private var player: NarrationPlayer
    @StateObject private var refiner: SpeakerRefiner

    init() {
        let library = LibraryStore()
        let settings = VoiceSettings()
        let modelStore = KokoroModelStore()
        _library = StateObject(wrappedValue: library)
        _settings = StateObject(wrappedValue: settings)
        _modelStore = StateObject(wrappedValue: modelStore)
        let player = NarrationPlayer(library: library, settings: settings, modelStore: modelStore)
        _player = StateObject(wrappedValue: player)
        _refiner = StateObject(wrappedValue: SpeakerRefiner(library: library, player: player))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(modelStore)
                .environmentObject(player)
                .environmentObject(refiner)
                .tint(.narratorAccent)
                // "Open in Narrator" from Files, Mail, Safari or the share sheet.
                .onOpenURL { url in
                    Task { await library.importBook(from: url) }
                }
        }
    }
}

extension Color {
    /// Ink blue, chosen to read well on both the light and dark reading backgrounds.
    static let narratorAccent = Color(red: 0.24, green: 0.36, blue: 0.80)
    /// The marker-yellow wash behind the sentence being read.
    static let narratorHighlight = Color(red: 1.0, green: 0.85, blue: 0.30).opacity(0.38)
}
