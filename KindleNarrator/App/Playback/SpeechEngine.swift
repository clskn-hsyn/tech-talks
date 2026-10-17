import AVFoundation

/// Something that turns one sentence into audio.
///
/// The player never speaks live: it asks an engine for a PCM buffer per sentence, a few
/// sentences ahead, and schedules those buffers gaplessly. That keeps seeking and speed
/// changes instant and lets on-device and Apple voices share one playback path.
protocol SpeechEngine: AnyObject {
    var displayName: String { get }
    /// Renders `text` as mono PCM in `NarrationAudio.format`. `voice` names a character's voice;
    /// nil means the narrator. Engines without per-character voices ignore it.
    func render(_ text: String, voice: String?) async throws -> AVAudioPCMBuffer
    /// Whether `voice` is honoured, so the player knows character casting will be heard.
    var supportsCharacterVoices: Bool { get }
}

enum NarrationAudio {
    /// Kokoro's native rate. Apple voices are converted to it so one player graph serves both.
    static let sampleRate: Double = 24_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    enum ConversionError: LocalizedError {
        case unsupportedFormat
        case conversionFailed(Error?)

        var errorDescription: String? { "The voice produced audio the app couldn't play." }
    }

    static func buffer(fromSamples samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                buffer.floatChannelData![0].update(from: base, count: samples.count)
            }
        }
        return buffer
    }

    static func silence(seconds: Double) -> AVAudioPCMBuffer {
        buffer(fromSamples: [Float](repeating: 0, count: Int(seconds * sampleRate)))
    }

    /// Joins buffers already in `format`, optionally adding trailing silence.
    static func concatenate(_ buffers: [AVAudioPCMBuffer], trailingSilence: Double = 0) -> AVAudioPCMBuffer {
        let silenceFrames = Int(trailingSilence * sampleRate)
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) } + silenceFrames
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(total, 1)))!
        var offset = 0
        let destination = output.floatChannelData![0]
        for buffer in buffers {
            let count = Int(buffer.frameLength)
            destination.advanced(by: offset).update(from: buffer.floatChannelData![0], count: count)
            offset += count
        }
        destination.advanced(by: offset).initialize(repeating: 0, count: silenceFrames)
        output.frameLength = AVAudioFrameCount(total)
        return output
    }

    /// Converts any PCM buffer (Apple voices emit 16-bit or float at 22.05 kHz and others) to `format`.
    static func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw ConversionError.unsupportedFormat
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ConversionError.unsupportedFormat
        }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw ConversionError.conversionFailed(error) }
        return output
    }
}
