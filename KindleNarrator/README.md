# Narrator (Kindle Narrator)

An iPhone app that reads your DRM-free ebooks aloud in a natural voice that runs entirely on the device.

- **Natural voice, on-device:** [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) through [KokoroSwift](https://github.com/mlalma/kokoro-ios) and MLX. It's free, private, and works offline once downloaded. Apple's built-in voices are the fallback.
- **EPUB and PDF import:** from Files, iCloud Drive, AirDrop or "Open in Narrator".
- **Read-along view** that highlights the sentence being spoken. Tap any sentence to jump there.
- **Gapless playback:** speed from 0.75× to 2.5× without chipmunk pitch, a sleep timer (minutes or end of chapter), and resume where you left off.
- **System controls:** lock screen, Control Center, AirPods and the CarPlay Now Playing screen. Skip ±15 s, and next/previous track moves by chapter.
- **Cleanup before reading:** front and back matter (copyright, contents, acknowledgements…) is skipped, and footnote markers and page numbers are dropped. Numbers, years, times, money and abbreviations are spelled out so they're read naturally.

## Getting your Kindle books in

Amazon offers no API for Kindle book content, and most Kindle books are DRM-locked. Since January 2026, though, Amazon lets buyers download a **DRM-free EPUB or PDF** of books whose publisher allows it:

1. On a computer, open amazon.com › **Manage Your Content and Devices**.
2. Open a book's menu. If the publisher allows it, you'll see an EPUB/PDF download.
3. Save it to iCloud Drive, then tap **+** in Narrator.

DRM-free books from anywhere else work the same way, such as Standard Ebooks, Project Gutenberg, Humble Bundle and publisher stores. Narrator detects DRM-protected EPUBs and Kindle formats (AZW/KFX/MOBI) and explains why it can't read them. It doesn't try to break DRM.

## Requirements

- **Xcode 26** or newer. KokoroSwift's package manifest needs Swift tools 6.2.
- **An iPhone or iPad on iOS 18+.** MLX doesn't run in the Simulator, so there the app automatically falls back to Apple voices.
- About 350 MB free on the device for the voice model.

## Build and run

```bash
brew install xcodegen
cd KindleNarrator
xcodegen            # generates KindleNarrator.xcodeproj from project.yml
open KindleNarrator.xcodeproj
```

In Xcode:

1. Select the **KindleNarrator** target › Signing & Capabilities. Choose your team and change the bundle identifier from `com.example.narrator` to something of your own.
2. Pick your iPhone as the run destination and press Run. The first build resolves the Swift packages (MLX is large, so give it a few minutes).
3. In the app, tap the waveform button › **Download natural voice**. This is a one-time download of about 340 MB. Until it finishes, an Apple voice reads.

You can also copy `kokoro-v1_0.safetensors` and `voices.npz` into the app's folder via Finder (iPhone › Files › Narrator) instead of downloading them in the app.

If the app is killed for memory while the natural voice loads on an older iPhone, add the **Increased Memory Limit** capability in Signing & Capabilities.

## Tests

The text pipeline lives in a plain Swift package with no UIKit dependency:

```bash
cd KindleNarrator/Packages/NarratorCore
swift test
```

The tests cover EPUB parsing (nav and NCX titles, DRM detection, paths), HTML-to-text extraction, number and abbreviation normalization, sentence splitting, PDF header/footer cleanup and book navigation. In Xcode, the KindleNarrator scheme's Test action runs the same suite.

## How it works

```
Files / Share ─▶ BookImporter ─▶ NarratorCore ─────────────────────────────▶ Book (JSON)
                 (EPUB, PDFKit)   EPUBParser · HTMLTextExtractor ·
                                  TextNormalizer · SentenceSegmenter

NarrationPlayer ─▶ SpeechEngine.render(sentence) ─▶ AVAudioPCMBuffer (24 kHz mono)
   │                 ├─ KokoroSpeechEngine (MLX, actor-isolated)
   │                 └─ AppleSpeechEngine (AVSpeechSynthesizer.write)
   └─▶ AVAudioPlayerNode ─▶ AVAudioUnitTimePitch (speed) ─▶ output
         renders 6 sentences ahead, keeps 2 queued, saves position every sentence
```

| Path | What's there |
|---|---|
| `Packages/NarratorCore` | Book model, EPUB parser, text cleanup and sentence splitting. Pure Swift, unit tested. |
| `App/Library` | Importing books and storing the library (JSON in Application Support) |
| `App/Playback` | Voice engines, model download, gapless player, lock-screen controls |
| `App/Views` | Library, read-along player and voice settings screens |
| `project.yml` | XcodeGen project definition, including the Info.plist keys for background audio and "Open in" |

## Status and next steps

This is the first working cut of phases 1–2 of the plan. It was written without access to a Mac, so **it has not been compiled yet**. Expect a few compiler fixes on the first build in Xcode. Every Swift file passes a syntax check, and the Kokoro, MLX and ZIPFoundation calls were checked against those libraries' sources at the pinned versions.

Next up:

- [ ] First on-device build: measure Kokoro's real-time factor, battery use and memory on your iPhone
- [ ] Cache rendered chapters to disk (AAC) so re-listening and scrubbing cost nothing
- [ ] Render ahead while charging (`BGProcessingTask`)
- [ ] Per-book pronunciation fixes (long-press a word)
- [ ] iCloud sync of positions, Shortcuts ("Continue my book"), widgets
- [ ] Optional cloud "studio" voices behind a cost estimate

## Licenses

Kokoro weights and KokoroSwift are Apache-2.0. MLX is MIT. ZIPFoundation is MIT. The model files are downloaded from the KokoroSwift author's sample app repository on first use.
