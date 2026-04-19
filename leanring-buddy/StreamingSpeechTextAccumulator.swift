//
//  StreamingSpeechTextAccumulator.swift
//  leanring-buddy
//
//  Converts progressively streamed assistant text into speakable chunks
//  while holding back point-tag fragments so they never leak into TTS.
//

import Foundation

struct StreamingSpeechTextAccumulator {
    private static let firstChunkMinimumCharacterCount = 24
    private static let laterChunkMinimumCharacterCount = 40
    private static let firstChunkFallbackCharacterCount = 64
    private static let laterChunkFallbackCharacterCount = 120
    private static let protectedTrailingCharacterCount = 24

    private var lastSeenAccumulatedText = ""
    private var lastPreparedSpeakableText = ""
    private var pendingChunkBuffer = ""

    private(set) var emittedChunkCount = 0

    mutating func ingest(_ accumulatedResponseText: String) -> [String] {
        synchronizePendingBuffer(with: accumulatedResponseText, isFinal: false)
        return drainSpeakableChunks(isFinal: false)
    }

    mutating func finish(with fullResponseText: String) -> [String] {
        synchronizePendingBuffer(with: fullResponseText, isFinal: true)
        return drainSpeakableChunks(isFinal: true)
    }

    static func stripPointTagForSpeech(from responseText: String) -> String {
        guard let pointTagRange = responseText.range(
            of: #"\s*\[POINT:[^\]]*\]\s*$"#,
            options: .regularExpression
        ) else {
            return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(responseText[..<pointTagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func synchronizePendingBuffer(with accumulatedResponseText: String, isFinal: Bool) {
        if !accumulatedResponseText.hasPrefix(lastSeenAccumulatedText) {
            lastPreparedSpeakableText = ""
            pendingChunkBuffer = ""
        }

        lastSeenAccumulatedText = accumulatedResponseText

        let preparedSpeakableText = preparedSpeakableText(
            from: accumulatedResponseText,
            isFinal: isFinal
        )

        if preparedSpeakableText.hasPrefix(lastPreparedSpeakableText) {
            pendingChunkBuffer += String(
                preparedSpeakableText.dropFirst(lastPreparedSpeakableText.count)
            )
            lastPreparedSpeakableText = preparedSpeakableText
            return
        }

        if lastPreparedSpeakableText.hasPrefix(preparedSpeakableText) {
            // A partial trailing [POINT:...] tag can temporarily shorten the
            // speakable text near the end of the stream. Keep the previous
            // high-water mark so already queued speech is not appended again
            // when the final point-free response arrives.
            return
        }

        pendingChunkBuffer = preparedSpeakableText
        lastPreparedSpeakableText = preparedSpeakableText
    }

    private func preparedSpeakableText(from accumulatedResponseText: String, isFinal: Bool) -> String {
        let pointTagStrippedText = Self.stripPointTagForSpeech(from: accumulatedResponseText)
        guard !isFinal else {
            return pointTagStrippedText
        }

        let textWithoutPartialPointTag = stripPartialPointTagPrefixIfPresent(
            from: pointTagStrippedText
        )

        guard textWithoutPartialPointTag.count > Self.protectedTrailingCharacterCount else {
            return ""
        }

        return String(
            textWithoutPartialPointTag.dropLast(Self.protectedTrailingCharacterCount)
        )
    }

    private func stripPartialPointTagPrefixIfPresent(from text: String) -> String {
        guard let lastBracketIndex = text.lastIndex(of: "[") else {
            return text
        }

        let trailingBracketText = String(text[lastBracketIndex...]).uppercased()
        if "[POINT:".hasPrefix(trailingBracketText) {
            return String(text[..<lastBracketIndex])
        }

        return text
    }

    private mutating func drainSpeakableChunks(isFinal: Bool) -> [String] {
        var emittedChunks: [String] = []

        while let nextChunk = nextSpeakableChunk(isFinal: isFinal) {
            emittedChunks.append(nextChunk)
            emittedChunkCount += 1
        }

        return emittedChunks
    }

    private mutating func nextSpeakableChunk(isFinal: Bool) -> String? {
        let trimmedPendingChunkBuffer = pendingChunkBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPendingChunkBuffer.isEmpty else {
            pendingChunkBuffer = ""
            return nil
        }

        if isFinal {
            pendingChunkBuffer = ""
            return trimmedPendingChunkBuffer
        }

        let isFirstChunk = emittedChunkCount == 0
        let minimumCharacterCount = isFirstChunk
            ? Self.firstChunkMinimumCharacterCount
            : Self.laterChunkMinimumCharacterCount
        let fallbackCharacterCount = isFirstChunk
            ? Self.firstChunkFallbackCharacterCount
            : Self.laterChunkFallbackCharacterCount

        if let sentenceBoundaryIndex = sentenceBoundaryIndex(
            in: trimmedPendingChunkBuffer,
            minimumCharacterCount: minimumCharacterCount
        ) {
            let nextChunk = String(trimmedPendingChunkBuffer[...sentenceBoundaryIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingChunkBuffer = String(trimmedPendingChunkBuffer[trimmedPendingChunkBuffer.index(after: sentenceBoundaryIndex)...])
            return nextChunk.isEmpty ? nil : nextChunk
        }

        guard trimmedPendingChunkBuffer.count >= fallbackCharacterCount else {
            pendingChunkBuffer = trimmedPendingChunkBuffer
            return nil
        }

        let fallbackSplitIndex = preferredFallbackSplitIndex(
            in: trimmedPendingChunkBuffer,
            fallbackCharacterCount: fallbackCharacterCount
        )
        let nextChunk = String(trimmedPendingChunkBuffer[..<fallbackSplitIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pendingChunkBuffer = String(trimmedPendingChunkBuffer[fallbackSplitIndex...])
        return nextChunk.isEmpty ? nil : nextChunk
    }

    private func sentenceBoundaryIndex(
        in text: String,
        minimumCharacterCount: Int
    ) -> String.Index? {
        var currentOffset = 0

        for currentIndex in text.indices {
            defer { currentOffset += 1 }

            let currentCharacter = text[currentIndex]
            guard currentCharacter == "." || currentCharacter == "!" || currentCharacter == "?" else {
                continue
            }

            guard currentOffset + 1 >= minimumCharacterCount else {
                continue
            }

            let nextIndex = text.index(after: currentIndex)
            if nextIndex == text.endIndex {
                return currentIndex
            }

            let nextCharacter = text[nextIndex]
            if nextCharacter.isWhitespace || nextCharacter == "\"" || nextCharacter == "'" {
                return currentIndex
            }
        }

        return nil
    }

    private func preferredFallbackSplitIndex(
        in text: String,
        fallbackCharacterCount: Int
    ) -> String.Index {
        let fallbackLimitedEndIndex = text.index(
            text.startIndex,
            offsetBy: min(fallbackCharacterCount, text.count)
        )
        let fallbackLimitedPrefix = text[..<fallbackLimitedEndIndex]

        if let lastWhitespaceIndex = fallbackLimitedPrefix.lastIndex(where: { $0.isWhitespace }) {
            return lastWhitespaceIndex
        }

        return text.index(text.startIndex, offsetBy: fallbackCharacterCount)
    }
}
