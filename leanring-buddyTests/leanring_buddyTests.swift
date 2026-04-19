//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
import Testing
@testable import leanring_buddy

struct leanring_buddyTests {
    private func makeCompanionScreenCapture(
        label: String,
        isCursorScreen: Bool,
        screenIndex: Int,
        capturePriority: CompanionScreenCapturePriority
    ) -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: Data([0x01, 0x02, 0x03]),
            label: label,
            isCursorScreen: isCursorScreen,
            screenIndex: screenIndex,
            capturePriority: capturePriority,
            displayWidthInPoints: 1000,
            displayHeightInPoints: 700,
            displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 700),
            screenshotWidthInPixels: 1200,
            screenshotHeightInPixels: 840
        )
    }

    private func makeScreenUnderstandingContext(
        frontmostWindowTitle: String?,
        cursorFocusedCropImageData: Data?,
        cursorFocusedCropLabel: String?,
        prioritizedScreenCaptures: [CompanionScreenCapture]
    ) -> CompanionScreenUnderstandingContext {
        CompanionScreenUnderstandingContext(
            frontmostApplicationName: "Xcode",
            frontmostWindowTitle: frontmostWindowTitle,
            cursorScreenIndex: 1,
            cursorLocationInScreenPoints: CGPoint(x: 400, y: 500),
            cursorLocationInScreenshotPixels: CGPoint(x: 480, y: 320),
            cursorFocusedCropImageData: cursorFocusedCropImageData,
            cursorFocusedCropLabel: cursorFocusedCropLabel,
            prioritizedScreenCaptures: prioritizedScreenCaptures
        )
    }

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func screenshotCommandTranscriptTriggersLocalScreenshotPath() async throws {
        let shouldHandleAsScreenshotCommand = CompanionManager.shouldHandleTranscriptAsScreenshotCommand(
            "can you take a screenshot please"
        )

        #expect(shouldHandleAsScreenshotCommand)
    }

    @Test func screenshotQuestionDoesNotTriggerLocalScreenshotPath() async throws {
        let shouldHandleAsScreenshotCommand = CompanionManager.shouldHandleTranscriptAsScreenshotCommand(
            "how do i take a screenshot on mac"
        )

        #expect(!shouldHandleAsScreenshotCommand)
    }

    @Test func multiStepGuidanceRequestStartsGuidedTaskMode() async throws {
        let shouldStartGuidedTask = CompanionManager.shouldStartGuidedTask(
            for: "tell me how to open whatsapp and message someone"
        )

        #expect(shouldStartGuidedTask)
    }

    @Test func normalQuestionDoesNotStartGuidedTaskMode() async throws {
        let shouldStartGuidedTask = CompanionManager.shouldStartGuidedTask(
            for: "what is whatsapp"
        )

        #expect(!shouldStartGuidedTask)
    }

    @Test func shortProgressUpdateContinuesGuidedTaskMode() async throws {
        let shouldContinueGuidedTask = CompanionManager.shouldContinueGuidedTask(
            with: "done"
        )

        #expect(shouldContinueGuidedTask)
    }

    @Test func cancellationPhraseStopsGuidedTaskMode() async throws {
        let shouldCancelGuidedTask = CompanionManager.shouldCancelGuidedTask(
            for: "never mind"
        )

        #expect(shouldCancelGuidedTask)
    }

    @Test func legacyChatModelSelectionMigratesToGPTFivePointFour() async throws {
        let normalizedModelIdentifier = CompanionManager.normalizedOpenAIModelIdentifier(
            "gpt-5.2"
        )

        #expect(normalizedModelIdentifier == "gpt-5.4")
    }

    @Test func screenUnderstandingSummaryFallsBackWhenWindowTitleIsUnavailable() async throws {
        let screenUnderstandingContext = makeScreenUnderstandingContext(
            frontmostWindowTitle: nil,
            cursorFocusedCropImageData: nil,
            cursorFocusedCropLabel: nil,
            prioritizedScreenCaptures: [
                makeCompanionScreenCapture(
                    label: "user's screen (cursor is here)",
                    isCursorScreen: true,
                    screenIndex: 1,
                    capturePriority: .cursorScreen
                )
            ]
        )

        let screenUnderstandingSummary = CompanionScreenCaptureUtility.buildScreenUnderstandingSummary(
            from: screenUnderstandingContext
        )

        #expect(screenUnderstandingSummary.contains("frontmost app: Xcode"))
        #expect(screenUnderstandingSummary.contains("focused window title: unavailable"))
        #expect(screenUnderstandingSummary.contains("no cursor-centered crop was available"))
    }

    @Test func orderedModelImagesPrioritizeCursorCropBeforeFullScreens() async throws {
        let cursorScreenCapture = makeCompanionScreenCapture(
            label: "screen 1 of 2 — cursor is on this screen (primary focus)",
            isCursorScreen: true,
            screenIndex: 1,
            capturePriority: .cursorScreen
        )
        let secondaryScreenCapture = makeCompanionScreenCapture(
            label: "screen 2 of 2 — secondary screen",
            isCursorScreen: false,
            screenIndex: 2,
            capturePriority: .secondaryScreen
        )
        let screenUnderstandingContext = makeScreenUnderstandingContext(
            frontmostWindowTitle: "CompanionManager.swift",
            cursorFocusedCropImageData: Data([0x09, 0x09]),
            cursorFocusedCropLabel: "cursor-centered crop from screen 1 (image dimensions: 480x480 pixels)",
            prioritizedScreenCaptures: [cursorScreenCapture, secondaryScreenCapture]
        )

        let orderedModelImages = CompanionScreenCaptureUtility.buildOrderedModelImages(
            from: screenUnderstandingContext
        )

        #expect(orderedModelImages.count == 3)
        #expect(orderedModelImages[0].label == "cursor-centered crop from screen 1 (image dimensions: 480x480 pixels)")
        #expect(orderedModelImages[1].label == cursorScreenCapture.modelLabel)
        #expect(orderedModelImages[2].label == secondaryScreenCapture.modelLabel)
    }

    @Test func orderedModelImagesFallBackToFullScreensWhenCursorCropFails() async throws {
        let cursorScreenCapture = makeCompanionScreenCapture(
            label: "user's screen (cursor is here)",
            isCursorScreen: true,
            screenIndex: 1,
            capturePriority: .cursorScreen
        )
        let screenUnderstandingContext = makeScreenUnderstandingContext(
            frontmostWindowTitle: "Notes",
            cursorFocusedCropImageData: nil,
            cursorFocusedCropLabel: nil,
            prioritizedScreenCaptures: [cursorScreenCapture]
        )

        let orderedModelImages = CompanionScreenCaptureUtility.buildOrderedModelImages(
            from: screenUnderstandingContext
        )

        #expect(orderedModelImages.count == 1)
        #expect(orderedModelImages[0].label == cursorScreenCapture.modelLabel)
    }

    @Test func userTextBlocksIncludeStructuredContextBeforePrompt() async throws {
        let userTextBlocks = OpenAIChatCompletionsClient.buildUserTextBlocks(
            screenUnderstandingSummary: "screen context: frontmost app: Xcode",
            userPrompt: "what am i looking at?"
        )

        #expect(userTextBlocks.count == 2)
        #expect(userTextBlocks[0] == "screen context: frontmost app: Xcode")
        #expect(userTextBlocks[1] == "what am i looking at?")
    }

    @Test func pointingRefinementCropRectStaysInsideScreenshotBounds() async throws {
        let cropRect = CompanionScreenCaptureUtility.makePointingRefinementCropRect(
            centeredOn: CGPoint(x: 25, y: 30),
            screenshotWidthInPixels: 1200,
            screenshotHeightInPixels: 840
        )

        #expect(cropRect.minX >= 0)
        #expect(cropRect.minY >= 0)
        #expect(cropRect.maxX <= 1200)
        #expect(cropRect.maxY <= 840)
    }

    @Test func fullScreenshotCoordinateMapsBackFromRefinementCrop() async throws {
        let cropRect = CGRect(x: 300, y: 200, width: 420, height: 420)

        let fullScreenshotCoordinate = CompanionScreenCaptureUtility.fullScreenshotCoordinate(
            from: CGPoint(x: 40, y: 55),
            cropRect: cropRect
        )

        #expect(fullScreenshotCoordinate == CGPoint(x: 340, y: 255))
    }

    @Test func streamingSpeechAccumulatorEmitsSentenceChunkDuringStreaming() async throws {
        var streamingSpeechTextAccumulator = StreamingSpeechTextAccumulator()

        let speechChunks = streamingSpeechTextAccumulator.ingest(
            "open whatsapp from the dock first. after that you can search for the person"
        )

        #expect(speechChunks == ["open whatsapp from the dock first."])
    }

    @Test func streamingSpeechAccumulatorFallsBackWhenPunctuationIsDelayed() async throws {
        var streamingSpeechTextAccumulator = StreamingSpeechTextAccumulator()

        let speechChunks = streamingSpeechTextAccumulator.ingest(
            "open whatsapp from the dock and wait for it to finish launching before you move to the next part of the task because the app can take a moment"
        )

        #expect(speechChunks.count == 1)
        #expect(!speechChunks[0].isEmpty)
        #expect(!speechChunks[0].contains("[POINT:"))
    }

    @Test func streamingSpeechAccumulatorNeverLeaksPartialPointTag() async throws {
        var streamingSpeechTextAccumulator = StreamingSpeechTextAccumulator()

        let speechChunks = streamingSpeechTextAccumulator.ingest(
            "click the save button in the top bar now. this tail stays protected [POI"
        )

        #expect(speechChunks == ["click the save button in the top bar now."])
    }

    @Test func streamingSpeechAccumulatorFlushesFinalTextWithoutPointTag() async throws {
        var streamingSpeechTextAccumulator = StreamingSpeechTextAccumulator()

        let finalSpeechChunks = streamingSpeechTextAccumulator.finish(
            with: "open whatsapp from the dock first. [POINT:420,210:search field]"
        )

        #expect(finalSpeechChunks == ["open whatsapp from the dock first."])
    }

    @Test func streamingSpeechAccumulatorDoesNotReplaySpeechWhenPointTagStartsStreaming() async throws {
        let fullResponseText =
            "this is a longer response that should stream out once. it has enough text to emit before the point tag starts appearing at the end and then keep going for a bit more. [POINT:none]"

        var streamingSpeechTextAccumulator = StreamingSpeechTextAccumulator()
        var emittedSpeechChunks: [String] = []

        for characterCount in 1..<fullResponseText.count {
            let streamedResponsePrefix = String(fullResponseText.prefix(characterCount))
            emittedSpeechChunks.append(
                contentsOf: streamingSpeechTextAccumulator.ingest(streamedResponsePrefix)
            )
        }

        emittedSpeechChunks.append(
            contentsOf: streamingSpeechTextAccumulator.finish(with: fullResponseText)
        )

        let reconstructedSpokenResponse = emittedSpeechChunks.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReconstructedSpokenResponse = reconstructedSpokenResponse
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let normalizedExpectedSpokenResponse = StreamingSpeechTextAccumulator
            .stripPointTagForSpeech(from: fullResponseText)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)

        #expect(
            normalizedReconstructedSpokenResponse == normalizedExpectedSpokenResponse
        )
    }

}
