import NarratorCore
import SwiftUI

/// The book's narrator and characters, each with the voice they read in.
struct CastView: View {
    @EnvironmentObject private var player: NarrationPlayer
    @EnvironmentObject private var settings: VoiceSettings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var refiner: SpeakerRefiner
    @EnvironmentObject private var modelStore: KokoroModelStore
    @Environment(\.dismiss) private var dismiss

    let entryID: UUID

    private var cast: [CastMember] {
        (player.book?.cast ?? []).filter { $0.lineCount >= VoiceCasting.minimumLines }
    }

    private var overrides: [String: String] {
        library.entry(id: entryID)?.voiceOverrides ?? [:]
    }

    var body: some View {
        NavigationStack {
            Form {
                if settings.engine != .kokoro || modelStore.state != .ready {
                    Section {
                        Text("Character voices use the natural voice. Choose it and download it in Voice settings.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Give characters their own voices", isOn: $settings.characterVoices)
                    VoiceRow(
                        title: "Narrator",
                        detail: "Reads everything that isn't a character's line",
                        selection: $settings.kokoroVoice,
                        isAutomatic: false,
                        reset: nil,
                        preview: { player.previewVoice(settings.kokoroVoice, saying: "Chapter one. It was a quiet morning in the village.") }
                    )
                } footer: {
                    refinementFooter
                }

                if settings.characterVoices {
                    Section("Characters") {
                        if cast.isEmpty {
                            Text("No recurring speakers found in this book yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(cast) { member in
                            VoiceRow(
                                title: member.name,
                                detail: detail(for: member),
                                selection: binding(for: member),
                                isAutomatic: overrides[member.name] == nil,
                                reset: {
                                    library.setVoice(nil, for: member.name, in: entryID)
                                    player.castChanged()
                                },
                                preview: {
                                    let voice = player.castVoices[member.name] ?? settings.kokoroVoice
                                    player.previewVoice(voice, saying: "I'm \(member.name). Shall we begin?")
                                }
                            )
                        }
                    }
                }
            }
            .navigationTitle("Characters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: settings.voiceKey) { _, _ in player.voiceSettingsChanged() }
        }
    }

    @ViewBuilder
    private var refinementFooter: some View {
        switch refiner.status {
        case .working(let done, let total):
            Label("Checking who's speaking with Apple Intelligence: \(done) of \(total) chapters", systemImage: "sparkles")
        case .finished:
            Label("Speakers checked with Apple Intelligence", systemImage: "checkmark.seal")
        case .unavailable(let reason):
            Text(reason)
        case .idle:
            EmptyView()
        }
    }

    private func detail(for member: CastMember) -> String {
        let gender: String
        switch member.gender {
        case .female: gender = "female"
        case .male: gender = "male"
        case .unknown: gender = "gender unclear"
        }
        return "\(member.lineCount) lines · \(gender)"
    }

    /// Shows the automatic choice until the listener picks one.
    private func binding(for member: CastMember) -> Binding<String> {
        Binding(
            get: { overrides[member.name] ?? player.castVoices[member.name] ?? settings.kokoroVoice },
            set: { voice in
                library.setVoice(voice, for: member.name, in: entryID)
                player.castChanged()
            }
        )
    }
}

private struct VoiceRow: View {
    let title: String
    let detail: String
    @Binding var selection: String
    let isAutomatic: Bool
    let reset: (() -> Void)?
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                if let reset, !isAutomatic {
                    Button("Automatic", action: reset)
                }
                Picker("Voice", selection: $selection) {
                    ForEach(KokoroSpeechEngine.voiceNames, id: \.self) { name in
                        Text(KokoroSpeechEngine.displayName(forVoice: name)).tag(name)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(KokoroSpeechEngine.displayName(forVoice: selection).components(separatedBy: " · ").first ?? selection)
                    if isAutomatic {
                        Text("auto").font(.caption2).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            Button(action: preview) {
                Image(systemName: "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Preview \(title)'s voice")
        }
    }
}
