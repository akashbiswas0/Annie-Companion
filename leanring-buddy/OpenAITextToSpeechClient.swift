//
//  OpenAITextToSpeechClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from OpenAI and plays it back
//  through the system audio output.
//

import AVFoundation
import Foundation

@MainActor
final class OpenAITextToSpeechClient: NSObject, AVAudioPlayerDelegate {
    private struct PrefetchedSpeechChunk {
        let text: String
        let audioData: Data
    }

    private final class QueuedSpeechPlaybackCoordinator {
        var pendingChunkTexts: [String] = []
        var prefetchedSpeechChunk: PrefetchedSpeechChunk?
        var currentSynthesisTask: Task<Void, Never>?
        var activeGenerationIdentifier = UUID()
        var hasStartedPlaybackForCurrentStream = false
        var hasLoggedFirstTTSRequestForCurrentStream = false
        var isSpeechStreamFinished = false
        var totalQueuedChunkCount = 0
        var lastChunkPlaybackEndedAt: Date?
        var onFirstPlaybackStarted: (@MainActor () -> Void)?
        var onFatalPlaybackError: (@MainActor (Error) -> Void)?
    }

    private let proxyURL: URL
    private let session: URLSession
    private let speechModelIdentifier = "gpt-4o-mini-tts"
    private let speechVoiceIdentifier = "nova"

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?
    private let queuedSpeechPlaybackCoordinator = QueuedSpeechPlaybackCoordinator()

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)

        super.init()
    }

    /// Sends `text` to OpenAI TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        stopPlaybackAndClearQueue()

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let audioData = try await requestSpeechAudioData(for: trimmedText)
        try Task.checkCancellation()

        try startImmediatePlayback(with: audioData)
    }

    func prepareQueuedSpeechStream(
        onFirstPlaybackStarted: @escaping @MainActor () -> Void,
        onFatalPlaybackError: @escaping @MainActor (Error) -> Void
    ) {
        stopPlaybackAndClearQueue()

        queuedSpeechPlaybackCoordinator.onFirstPlaybackStarted = onFirstPlaybackStarted
        queuedSpeechPlaybackCoordinator.onFatalPlaybackError = onFatalPlaybackError
        queuedSpeechPlaybackCoordinator.isSpeechStreamFinished = false
        queuedSpeechPlaybackCoordinator.activeGenerationIdentifier = UUID()
    }

    func enqueueSpeechChunk(text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        queuedSpeechPlaybackCoordinator.pendingChunkTexts.append(trimmedText)
        queuedSpeechPlaybackCoordinator.totalQueuedChunkCount += 1
        print("🗣️ OpenAI TTS: queued chunk \(queuedSpeechPlaybackCoordinator.totalQueuedChunkCount)")

        startSynthesizingNextQueuedChunkIfNeeded()
        startPlaybackFromPrefetchedChunkIfPossible()
    }

    func markSpeechStreamFinished() {
        queuedSpeechPlaybackCoordinator.isSpeechStreamFinished = true
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        (audioPlayer?.isPlaying ?? false)
            || queuedSpeechPlaybackCoordinator.prefetchedSpeechChunk != nil
            || queuedSpeechPlaybackCoordinator.currentSynthesisTask != nil
            || !queuedSpeechPlaybackCoordinator.pendingChunkTexts.isEmpty
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        stopPlaybackAndClearQueue()
    }

    func stopPlaybackAndClearQueue() {
        queuedSpeechPlaybackCoordinator.activeGenerationIdentifier = UUID()
        queuedSpeechPlaybackCoordinator.currentSynthesisTask?.cancel()
        queuedSpeechPlaybackCoordinator.currentSynthesisTask = nil
        queuedSpeechPlaybackCoordinator.pendingChunkTexts.removeAll(keepingCapacity: false)
        queuedSpeechPlaybackCoordinator.prefetchedSpeechChunk = nil
        queuedSpeechPlaybackCoordinator.hasStartedPlaybackForCurrentStream = false
        queuedSpeechPlaybackCoordinator.hasLoggedFirstTTSRequestForCurrentStream = false
        queuedSpeechPlaybackCoordinator.isSpeechStreamFinished = false
        queuedSpeechPlaybackCoordinator.totalQueuedChunkCount = 0
        queuedSpeechPlaybackCoordinator.lastChunkPlaybackEndedAt = nil
        queuedSpeechPlaybackCoordinator.onFirstPlaybackStarted = nil
        queuedSpeechPlaybackCoordinator.onFatalPlaybackError = nil

        audioPlayer?.stop()
        audioPlayer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.audioPlayer === player else { return }
            self.audioPlayer = nil
            self.queuedSpeechPlaybackCoordinator.lastChunkPlaybackEndedAt = Date()
            self.startPlaybackFromPrefetchedChunkIfPossible()
            self.startSynthesizingNextQueuedChunkIfNeeded()
        }
    }

    private func requestSpeechAudioData(for text: String) async throws -> Data {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": speechModelIdentifier,
            "input": text,
            "voice": speechVoiceIdentifier,
            "response_format": "mp3"
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAITextToSpeech",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenAITextToSpeech",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        return data
    }

    private func startImmediatePlayback(with audioData: Data) throws {
        let player = try AVAudioPlayer(data: audioData)
        player.delegate = self
        self.audioPlayer = player
        player.play()
        print("🔊 OpenAI TTS: playing \(audioData.count / 1024)KB audio")
    }

    private func startSynthesizingNextQueuedChunkIfNeeded() {
        guard queuedSpeechPlaybackCoordinator.currentSynthesisTask == nil else { return }
        guard queuedSpeechPlaybackCoordinator.prefetchedSpeechChunk == nil else { return }
        guard let nextChunkText = queuedSpeechPlaybackCoordinator.pendingChunkTexts.first else { return }

        queuedSpeechPlaybackCoordinator.pendingChunkTexts.removeFirst()
        let generationIdentifier = queuedSpeechPlaybackCoordinator.activeGenerationIdentifier

        if !queuedSpeechPlaybackCoordinator.hasLoggedFirstTTSRequestForCurrentStream {
            queuedSpeechPlaybackCoordinator.hasLoggedFirstTTSRequestForCurrentStream = true
            print("⏱️ OpenAI TTS: first chunk request sent")
        }

        queuedSpeechPlaybackCoordinator.currentSynthesisTask = Task { [weak self] in
            guard let self else { return }

            do {
                let requestStartedAt = Date()
                let audioData = try await self.requestSpeechAudioData(for: nextChunkText)

                await MainActor.run {
                    guard self.queuedSpeechPlaybackCoordinator.activeGenerationIdentifier == generationIdentifier else {
                        return
                    }

                    self.queuedSpeechPlaybackCoordinator.currentSynthesisTask = nil
                    self.queuedSpeechPlaybackCoordinator.prefetchedSpeechChunk = PrefetchedSpeechChunk(
                        text: nextChunkText,
                        audioData: audioData
                    )
                    print(
                        "🔊 OpenAI TTS: synthesized chunk in " +
                        "\(String(format: "%.2f", Date().timeIntervalSince(requestStartedAt)))s"
                    )

                    self.startPlaybackFromPrefetchedChunkIfPossible()
                    self.startSynthesizingNextQueuedChunkIfNeeded()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.queuedSpeechPlaybackCoordinator.activeGenerationIdentifier == generationIdentifier else {
                        return
                    }

                    self.queuedSpeechPlaybackCoordinator.currentSynthesisTask = nil
                }
            } catch {
                await MainActor.run {
                    guard self.queuedSpeechPlaybackCoordinator.activeGenerationIdentifier == generationIdentifier else {
                        return
                    }

                    self.queuedSpeechPlaybackCoordinator.currentSynthesisTask = nil
                    print("⚠️ OpenAI TTS queued chunk error: \(error)")

                    if !self.queuedSpeechPlaybackCoordinator.hasStartedPlaybackForCurrentStream {
                        self.queuedSpeechPlaybackCoordinator.onFatalPlaybackError?(error)
                    } else {
                        self.startSynthesizingNextQueuedChunkIfNeeded()
                    }
                }
            }
        }
    }

    private func startPlaybackFromPrefetchedChunkIfPossible() {
        guard audioPlayer?.isPlaying != true else { return }
        guard let prefetchedSpeechChunk = queuedSpeechPlaybackCoordinator.prefetchedSpeechChunk else { return }

        queuedSpeechPlaybackCoordinator.prefetchedSpeechChunk = nil

        do {
            if let lastChunkPlaybackEndedAt = queuedSpeechPlaybackCoordinator.lastChunkPlaybackEndedAt {
                let playbackGapDuration = Date().timeIntervalSince(lastChunkPlaybackEndedAt)
                print("⏱️ OpenAI TTS playback gap: \(String(format: "%.2f", playbackGapDuration))s")
            }

            try startImmediatePlayback(with: prefetchedSpeechChunk.audioData)

            if !queuedSpeechPlaybackCoordinator.hasStartedPlaybackForCurrentStream {
                queuedSpeechPlaybackCoordinator.hasStartedPlaybackForCurrentStream = true
                print("⏱️ OpenAI TTS: first chunk playback started")
                queuedSpeechPlaybackCoordinator.onFirstPlaybackStarted?()
            }

            queuedSpeechPlaybackCoordinator.lastChunkPlaybackEndedAt = nil
            startSynthesizingNextQueuedChunkIfNeeded()
        } catch {
            print("⚠️ OpenAI TTS playback start error: \(error)")

            if !queuedSpeechPlaybackCoordinator.hasStartedPlaybackForCurrentStream {
                queuedSpeechPlaybackCoordinator.onFatalPlaybackError?(error)
            } else {
                startPlaybackFromPrefetchedChunkIfPossible()
            }
        }
    }
}
