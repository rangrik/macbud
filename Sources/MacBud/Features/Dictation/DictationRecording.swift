import AVFoundation
import Speech

/// The tap and the main actor share this object. The lock owns every access to the
/// file and its counters; closing it waits for any in-flight write to finish.
nonisolated final class DictationRecording: @unchecked Sendable {
    static let silencePeak: Float = 300 / 32_767

    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frameCount: AVAudioFramePosition = 0
    private var peak: Float = 0
    private let sampleRate: Double

    init(format: AVAudioFormat, directory: URL = FileManager.default.temporaryDirectory) throws {
        url = directory.appendingPathComponent("macbud-dictation-\(UUID().uuidString).caf")
        sampleRate = format.sampleRate
        file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            file = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    var hasAudio: Bool { lock.withLock { frameCount > 0 && FileManager.default.fileExists(atPath: url.path) } }
    var hasAudibleAudio: Bool { lock.withLock { frameCount > 0 && peak >= Self.silencePeak } }
    var duration: TimeInterval { lock.withLock { Double(frameCount) / sampleRate } }

    /// Returns false once capture has closed, including a tap already queued at stop time.
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) throws -> Bool {
        try lock.withLock {
            guard let file, buffer.frameLength > 0 else { return false }
            try file.write(from: buffer)
            frameCount += AVAudioFramePosition(buffer.frameLength)
            peak = max(peak, Self.levels(of: buffer).peak)
            return true
        }
    }

    func close() { lock.withLock { file = nil } }

    func discard() {
        lock.withLock {
            file = nil
            frameCount = 0
            peak = 0
            try? FileManager.default.removeItem(at: url)
        }
    }

    deinit {
        file = nil
        try? FileManager.default.removeItem(at: url)
    }

    static func levels(of buffer: AVAudioPCMBuffer) -> (peak: Float, meter: Float) {
        guard buffer.frameLength > 0 else { return (0, 0) }
        var peak: Float = 0
        var sum: Float = 0
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.format.isInterleaved ? channels : 1
        for channel in 0..<channels {
            for frame in 0..<frames {
                let index = frame * stride + (buffer.format.isInterleaved ? channel : 0)
                let channelIndex = buffer.format.isInterleaved ? 0 : channel
                let sample: Float
                if let data = buffer.floatChannelData {
                    sample = data[channelIndex][index]
                } else if let data = buffer.int16ChannelData {
                    sample = Float(data[channelIndex][index]) / 32_768
                } else if let data = buffer.int32ChannelData {
                    sample = Float(data[channelIndex][index]) / 2_147_483_648
                } else {
                    continue
                }
                peak = max(peak, abs(sample))
                sum += sample * sample
            }
        }
        return (peak, min(1, sqrt(sum / Float(max(1, frames * channels))) * 4))
    }

}

/// AVAudioConverter is confined to this lock. Input buffers are only read within
/// the synchronous tap callback; the analyzer receives newly allocated buffers.
nonisolated final class DictationAudioCapture: @unchecked Sendable {
    struct Output: Sendable {
        let input: AnalyzerInput
        let volume: Float
    }

    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let recording: DictationRecording
    private let ratio: Double
    private var finished = false
    private var paused = false

    init(inputFormat: AVAudioFormat, targetFormat: AVAudioFormat, recording: DictationRecording) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.conversionFailed
        }
        self.converter = converter
        self.targetFormat = targetFormat
        self.recording = recording
        ratio = targetFormat.sampleRate / inputFormat.sampleRate
    }

    /// Dropped audio is never recorded and never analyzed, so typing a correction
    /// leaves no trace in either.
    func setPaused(_ paused: Bool) {
        lock.withLock { self.paused = paused }
    }

    func process(_ buffer: AVAudioPCMBuffer) throws -> Output? {
        try lock.withLock {
            guard !finished, !paused else { return nil }
            // Save the source first: even a conversion failure leaves replayable audio.
            guard try recording.append(buffer) else { return nil }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw CaptureError.conversionFailed
            }
            let input = ConverterInput(buffer: buffer)
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                input.take(status: outStatus)
            }
            if let error { throw error }
            guard status != .error else { throw CaptureError.conversionFailed }
            guard converted.frameLength > 0 else { return nil }
            return Output(input: AnalyzerInput(buffer: converted), volume: DictationRecording.levels(of: buffer).meter)
        }
    }

    /// Drain resampler latency after removing the tap, so instant confirmation
    /// includes the final converted samples before the analyzer sees end-of-input.
    func finish() throws -> [AnalyzerInput] {
        try lock.withLock {
            guard !finished else { return [] }
            finished = true
            var inputs: [AnalyzerInput] = []
            while true {
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else {
                    throw CaptureError.conversionFailed
                }
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if let error { throw error }
                guard status != .error else { throw CaptureError.conversionFailed }
                if converted.frameLength > 0 { inputs.append(AnalyzerInput(buffer: converted)) }
                if status == .endOfStream || converted.frameLength == 0 { return inputs }
            }
        }
    }

    enum CaptureError: LocalizedError {
        case conversionFailed
        var errorDescription: String? { "The microphone audio could not be converted. Retry the saved recording or choose another microphone." }
    }

    /// The converter requests this source synchronously and may request it more than once.
    /// Locking the one-use state also satisfies its @Sendable input-block contract.
    private final class ConverterInput: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private let lock = NSLock()
        private var consumed = false

        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func take(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.withLock {
                guard !consumed else { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
        }
    }
}
