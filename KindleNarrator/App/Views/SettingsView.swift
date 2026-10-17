import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: VoiceSettings
    @EnvironmentObject private var modelStore: KokoroModelStore
    @EnvironmentObject private var player: NarrationPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var appleVoices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Voice type", selection: $settings.engine) {
                        ForEach(VoiceSettings.EngineKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(settings.engine == .kokoro
                         ? "A neural voice that runs entirely on your iPhone. Free, private and works offline."
                         : "Apple's built-in voices. Instant, but they sound more synthetic over long listening.")
                }

                if settings.engine == .kokoro {
                    kokoroSection
                } else {
                    appleSection
                }

                Section("Getting books") {
                    Text("Narrator reads DRM-free EPUB and PDF files. For Kindle purchases, check Amazon's Manage Your Content and Devices page for an EPUB or PDF download. Only some publishers offer one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                appleVoices = AppleSpeechEngine.availableVoices()
                modelStore.refresh()
            }
            .onChange(of: settings.voiceKey) { _, _ in player.voiceSettingsChanged() }
            .onChange(of: modelStore.state) { _, state in
                if state == .ready { player.voiceSettingsChanged() }
            }
        }
    }

    @ViewBuilder
    private var kokoroSection: some View {
        Section {
            switch modelStore.state {
            case .ready:
                Picker("Narrator", selection: $settings.kokoroVoice) {
                    ForEach(KokoroSpeechEngine.voiceNames, id: \.self) { name in
                        Text(KokoroSpeechEngine.displayName(forVoice: name)).tag(name)
                    }
                }
                .pickerStyle(.navigationLink)
            case .missing:
                downloadButton(title: "Download natural voice (≈ 340 MB)")
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloading natural voice…")
                    ProgressView(value: progress)
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                downloadButton(title: "Try again")
            }
        } header: {
            Text("Natural voice")
        } footer: {
            if case .ready = modelStore.state {
                Text("Heart, Bella and Michael are good places to start. Switching voices re-reads from the current sentence.")
            } else if !KokoroSpeechEngine.isSupportedOnThisDevice {
                Text("The natural voice runs only on a real iPhone or iPad, not in the Simulator.")
            } else {
                Text("Downloads once over Wi-Fi and is stored on this iPhone. Until then, an Apple voice reads.")
            }
        }

        if case .ready = modelStore.state {
            Section {
                Button("Remove downloaded voice", role: .destructive) { modelStore.deleteDownloadedModel() }
            }
        }
    }

    private func downloadButton(title: String) -> some View {
        Button {
            Task { await modelStore.download() }
        } label: {
            Label(title, systemImage: "arrow.down.circle")
        }
    }

    @ViewBuilder
    private var appleSection: some View {
        Section {
            Picker("Voice", selection: $settings.appleVoiceIdentifier) {
                Text("Best available").tag(String?.none)
                ForEach(appleVoices, id: \.identifier) { voice in
                    Text("\(voice.name) · \(qualityLabel(voice.quality)) · \(voice.language)").tag(Optional(voice.identifier))
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Apple voice")
        } footer: {
            Text("For better Apple voices, download Premium or Enhanced voices in Settings › Accessibility › Spoken Content › Voices › English.")
        }
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }
}
