import AVFoundation
import Foundation
import Testing
@testable import MacBud

@Suite @MainActor struct DictationRecordingTests {
    private func makeBuffer(sample: Float, frames: AVAudioFrameCount = 1024) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) { channel[frame] = sample }
        return buffer
    }

    @Test func closePreservesReplayableSamplesAndRejectsLateTapWrites() throws {
        let buffer = try makeBuffer(sample: 0.25)
        let recording = try DictationRecording(format: buffer.format)
        defer { recording.discard() }
        try recording.append(buffer)
        recording.close()

        #expect(recording.hasAudio)
        #expect(recording.hasAudibleAudio)
        #expect(abs(recording.duration - 1024 / 48_000.0) < 0.000_001)
        #expect(try recording.append(buffer) == false)
        let replay = try AVAudioFile(forReading: recording.url)
        #expect(replay.length == 1024)
        let copy = try #require(AVAudioPCMBuffer(pcmFormat: replay.processingFormat, frameCapacity: 1024))
        try replay.read(into: copy)
        #expect(copy.floatChannelData?[0][1023] == 0.25)
    }

    @Test func discardDeletesTheFileAndIsIdempotent() throws {
        let buffer = try makeBuffer(sample: 0.25)
        let recording = try DictationRecording(format: buffer.format)
        try recording.append(buffer)
        recording.discard()
        recording.discard()
        #expect(!FileManager.default.fileExists(atPath: recording.url.path))
        #expect(!recording.hasAudio)
        #expect(try recording.append(buffer) == false)
    }

    @Test func releasingARecordingRemovesItsTemporaryFile() throws {
        let buffer = try makeBuffer(sample: 0)
        var recording: DictationRecording? = try DictationRecording(format: buffer.format)
        let url = try #require(recording?.url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        recording = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func silenceAndQuietBackgroundDoNotBecomeSpeech() throws {
        let silent = try makeBuffer(sample: 0)
        let recording = try DictationRecording(format: silent.format)
        defer { recording.discard() }
        try recording.append(silent)
        try recording.append(makeBuffer(sample: DictationRecording.silencePeak * 0.5))
        #expect(recording.hasAudio)
        #expect(!recording.hasAudibleAudio)
        try recording.append(makeBuffer(sample: DictationRecording.silencePeak * 2))
        #expect(recording.hasAudibleAudio)
    }

    @Test func converterCopiesInputAndRetainsTheOriginalForRetry() throws {
        let input = try makeBuffer(sample: 0.25, frames: 4096)
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let recording = try DictationRecording(format: input.format)
        defer { recording.discard() }
        let capture = try DictationAudioCapture(inputFormat: input.format, targetFormat: target, recording: recording)
        let output = try #require(try capture.process(input))
        let firstOutput = try #require(output.input.buffer.floatChannelData?[0][100])
        input.floatChannelData?[0][100] = 0
        #expect(output.input.buffer.floatChannelData?[0][100] == firstOutput)
        let tail = try capture.finish()
        #expect(output.input.buffer.frameLength > 0)
        #expect(output.input.buffer.format.sampleRate == 16_000)
        #expect(tail.allSatisfy { $0.buffer.format.sampleRate == 16_000 })
        #expect(try capture.process(input) == nil)
        #expect(try capture.finish().isEmpty)
        recording.close()
        let replay = try AVAudioFile(forReading: recording.url)
        #expect(replay.processingFormat.sampleRate == 48_000)
        #expect(replay.length == 4096)
    }

    @Test func silentFileRetryKeepsTheSameAudioUntilExplicitDiscard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macbud-engine-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try DictationRecording(format: makeBuffer(sample: 0).format)
        defer { source.discard() }
        try source.append(makeBuffer(sample: 0))
        source.close()
        let engine = DictationEngine(recordingDirectory: directory)
        #expect(try await engine.transcribe(file: source.url, locale: Locale(identifier: "en-US")).isEmpty)
        #expect(engine.canRetry)
        let retainedFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(retainedFiles.count == 1)
        await engine.suspend()
        #expect(engine.canRetry)
        #expect(try await engine.retry().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) == retainedFiles)
        engine.discardRecording()
        #expect(!engine.canRetry)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.url.path))
    }

    @Test func cancelDeletesSavedAudioWithoutDeletingTheImportedSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macbud-cancel-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try DictationRecording(format: makeBuffer(sample: 0).format)
        defer { source.discard() }
        try source.append(makeBuffer(sample: 0))
        source.close()
        let engine = DictationEngine(recordingDirectory: directory)
        _ = try await engine.transcribe(file: source.url, locale: Locale(identifier: "en-US"))
        await engine.cancel()
        #expect(!engine.canRetry)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.url.path))
        await #expect(throws: DictationEngine.EngineError.self) { try await engine.retry() }
    }

    @Test func cancelDuringImportRejectsLateCompletionAndRemovesPartialAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macbud-import-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = try makeBuffer(sample: 0, frames: 65_536)
        let source = try DictationRecording(format: buffer.format)
        defer { source.discard() }
        try source.append(buffer)
        source.close()
        let engine = DictationEngine(recordingDirectory: directory)
        var delivered: [String] = []
        engine.onTranscript = { delivered.append($0.text) }
        let importTask = Task { try await engine.transcribe(file: source.url, locale: Locale(identifier: "en-US")) }
        // Import publishes its saved frames before yielding between chunks.
        while !engine.canRetry { await Task.yield() }
        await engine.cancel()
        await #expect(throws: CancellationError.self) { try await importTask.value }
        #expect(delivered.isEmpty)
        #expect(!engine.canRetry)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }
}

@Suite @MainActor struct DictationDeadlineTests {
    @Test func completedOperationReturnsNormally() async throws {
        var finished = false
        try await DictationDeadline.run(timeout: .seconds(1)) { finished = true }
        #expect(finished)
    }

    @Test func timeoutReturnsWithoutWaitingForAnUncooperativeOperation() async throws {
        var releaseOperation: CheckedContinuation<Void, Never>?
        var timedOut = false
        do {
            try await DictationDeadline.run(timeout: .milliseconds(30)) {
                await withCheckedContinuation { releaseOperation = $0 }
            }
        } catch DictationEngine.EngineError.finalizationTimedOut {
            timedOut = true
        }
        #expect(timedOut)
        let release = try #require(releaseOperation)
        release.resume()
        await Task.yield()
    }

    @Test func callerCancellationReturnsBeforeTheOperationCompletes() async throws {
        var releaseOperation: CheckedContinuation<Void, Never>?
        let task = Task {
            try await DictationDeadline.run(timeout: .seconds(60)) {
                await withCheckedContinuation { releaseOperation = $0 }
            }
        }
        while releaseOperation == nil { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        releaseOperation?.resume()
    }
}
