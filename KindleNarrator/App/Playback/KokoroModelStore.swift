import Foundation

/// Downloads and locates the Kokoro model files (≈ 330 MB weights + 15 MB voice pack).
///
/// They're too large to ship inside the app, so they're fetched once on first use. You can
/// also copy `kokoro-v1_0.safetensors` and `voices.npz` into the app's folder from Finder
/// (iPhone › Files › Narrator) and they'll be picked up from there.
@MainActor
final class KokoroModelStore: ObservableObject {
    enum State: Equatable {
        case missing
        case downloading(progress: Double)
        case ready
        case failed(String)
    }

    // Apache-2.0 weights, mirrored by the KokoroSwift author's sample app.
    static let modelRemoteURL = URL(string: "https://media.githubusercontent.com/media/mlalma/KokoroTestApp/main/Resources/kokoro-v1_0.safetensors")!
    static let voicesRemoteURL = URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz")!
    nonisolated static let modelFileName = "kokoro-v1_0.safetensors"
    nonisolated static let voicesFileName = "voices.npz"
    /// The real file is ~327 MB; anything far smaller is a failed download or a Git LFS pointer.
    nonisolated static let minimumModelBytes: Int64 = 200_000_000

    @Published private(set) var state: State = .missing

    private var observation: NSKeyValueObservation?

    init() {
        refresh()
    }

    var installedFiles: (model: URL, voices: URL)? {
        for directory in [Self.storageDirectory, Self.documentsDirectory] {
            let model = directory.appendingPathComponent(Self.modelFileName)
            let voices = directory.appendingPathComponent(Self.voicesFileName)
            if Self.isValidModel(at: model), FileManager.default.fileExists(atPath: voices.path) {
                return (model, voices)
            }
        }
        return nil
    }

    func refresh() {
        if case .downloading = state { return }
        state = installedFiles == nil ? .missing : .ready
    }

    func download() async {
        if case .downloading = state { return }
        state = .downloading(progress: 0)
        do {
            try FileManager.default.createDirectory(at: Self.storageDirectory, withIntermediateDirectories: true)
            let voices = Self.storageDirectory.appendingPathComponent(Self.voicesFileName)
            let model = Self.storageDirectory.appendingPathComponent(Self.modelFileName)
            try await fetch(Self.voicesRemoteURL, to: voices) { [weak self] fraction in
                self?.state = .downloading(progress: fraction * 0.04)
            }
            try await fetch(Self.modelRemoteURL, to: model) { [weak self] fraction in
                self?.state = .downloading(progress: 0.04 + fraction * 0.96)
            }
            guard Self.isValidModel(at: model) else {
                try? FileManager.default.removeItem(at: model)
                throw URLError(.cannotDecodeContentData)
            }
            // The model can always be downloaded again, so keep it out of iCloud backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var storage = Self.storageDirectory
            try? storage.setResourceValues(values)
            state = .ready
        } catch {
            state = .failed("Download failed: \(error.localizedDescription) Check your connection and try again.")
        }
    }

    func deleteDownloadedModel() {
        try? FileManager.default.removeItem(at: Self.storageDirectory)
        refresh()
    }

    private func fetch(_ remote: URL, to destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: remote) { temporaryURL, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let temporaryURL, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporaryURL, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { taskProgress, _ in
                let fraction = taskProgress.fractionCompleted
                Task { @MainActor in progress(fraction) }
            }
            task.resume()
        }
        observation = nil
    }

    nonisolated static func isValidModel(at url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return size >= minimumModelBytes
    }

    nonisolated static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kokoro", isDirectory: true)
    }

    nonisolated static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
