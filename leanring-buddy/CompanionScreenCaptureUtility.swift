//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit

enum CompanionScreenCapturePriority: Int {
    case cursorScreen
    case secondaryScreen
}

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let screenIndex: Int
    let capturePriority: CompanionScreenCapturePriority
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int

    var modelLabel: String {
        "\(label) (image dimensions: \(screenshotWidthInPixels)x\(screenshotHeightInPixels) pixels)"
    }
}

struct CompanionScreenUnderstandingContext {
    let frontmostApplicationName: String
    let frontmostWindowTitle: String?
    let cursorScreenIndex: Int
    let cursorLocationInScreenPoints: CGPoint
    let cursorLocationInScreenshotPixels: CGPoint
    let cursorFocusedCropImageData: Data?
    let cursorFocusedCropLabel: String?
    let prioritizedScreenCaptures: [CompanionScreenCapture]
}

@MainActor
enum CompanionScreenCaptureUtility {
    private static let defaultMaxDimension = 1280
    private static let secondaryScreenMaxDimension = 900
    nonisolated private static let cropMinimumSideLengthPixels: CGFloat = 360
    nonisolated private static let cropMaximumSideLengthPixels: CGFloat = 640
    nonisolated private static let pointingRefinementCropSideLengthPixels: CGFloat = 420

    static func captureCurrentScreenAsJPEG() async throws -> CompanionScreenCapture {
        let screenCaptures = try await captureAllScreensAsJPEG()

        if let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) {
            return cursorScreenCapture
        }

        guard let firstAvailableScreenCapture = screenCaptures.first else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to find a screen to copy."]
            )
        }

        return firstAvailableScreenCapture
    }

    static func captureScreenUnderstandingContext() async throws -> CompanionScreenUnderstandingContext {
        let prioritizedScreenCaptures = try await captureScreensAsJPEG(
            cursorScreenMaxDimension: defaultMaxDimension,
            secondaryScreenMaxDimension: secondaryScreenMaxDimension
        )

        guard let cursorScreenCapture = prioritizedScreenCaptures.first(where: { $0.isCursorScreen })
            ?? prioritizedScreenCaptures.first else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to determine the cursor screen."]
            )
        }

        let cursorLocationInScreenPoints = NSEvent.mouseLocation
        let cursorLocationInScreenshotPixels = screenshotPixelLocation(
            cursorLocationInScreenPoints: cursorLocationInScreenPoints,
            displayFrame: cursorScreenCapture.displayFrame,
            screenshotWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
        )

        let cursorFocusedCropRect = makeCursorFocusedCropRect(
            centeredOn: cursorLocationInScreenshotPixels,
            screenshotWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
        )

        let cursorFocusedCropImageData = makeCursorFocusedCropImageData(
            from: cursorScreenCapture,
            cropRect: cursorFocusedCropRect
        )

        let cursorFocusedCropLabel: String? = {
            guard cursorFocusedCropImageData != nil else { return nil }
            let cropWidth = Int(cursorFocusedCropRect.width.rounded())
            let cropHeight = Int(cursorFocusedCropRect.height.rounded())
            return "cursor-centered crop from screen \(cursorScreenCapture.screenIndex) (image dimensions: \(cropWidth)x\(cropHeight) pixels)"
        }()

        let frontmostAppContext = frontmostApplicationContext()

        return CompanionScreenUnderstandingContext(
            frontmostApplicationName: frontmostAppContext.applicationName,
            frontmostWindowTitle: focusedWindowTitleIfAvailable(
                frontmostApplicationProcessIdentifier: frontmostAppContext.processIdentifier
            ),
            cursorScreenIndex: cursorScreenCapture.screenIndex,
            cursorLocationInScreenPoints: cursorLocationInScreenPoints,
            cursorLocationInScreenshotPixels: cursorLocationInScreenshotPixels,
            cursorFocusedCropImageData: cursorFocusedCropImageData,
            cursorFocusedCropLabel: cursorFocusedCropLabel,
            prioritizedScreenCaptures: prioritizedScreenCaptures
        )
    }

    nonisolated static func buildScreenUnderstandingSummary(
        from screenUnderstandingContext: CompanionScreenUnderstandingContext
    ) -> String {
        let cursorScreenPointX = Int(screenUnderstandingContext.cursorLocationInScreenPoints.x.rounded())
        let cursorScreenPointY = Int(screenUnderstandingContext.cursorLocationInScreenPoints.y.rounded())
        let cursorScreenshotPixelX = Int(screenUnderstandingContext.cursorLocationInScreenshotPixels.x.rounded())
        let cursorScreenshotPixelY = Int(screenUnderstandingContext.cursorLocationInScreenshotPixels.y.rounded())

        let focusedWindowLine: String
        if let frontmostWindowTitle = screenUnderstandingContext.frontmostWindowTitle {
            focusedWindowLine = "- focused window title: \(frontmostWindowTitle)"
        } else {
            focusedWindowLine = "- focused window title: unavailable"
        }

        let cursorCropLine: String
        if let cursorFocusedCropLabel = screenUnderstandingContext.cursorFocusedCropLabel {
            cursorCropLine = "- the first attached image is \(cursorFocusedCropLabel)"
        } else {
            cursorCropLine = "- no cursor-centered crop was available; rely on the full-screen images"
        }

        return """
        screen context:
        - frontmost app: \(screenUnderstandingContext.frontmostApplicationName)
        \(focusedWindowLine)
        - cursor is on screen \(screenUnderstandingContext.cursorScreenIndex)
        - cursor location in screen points: (\(cursorScreenPointX), \(cursorScreenPointY))
        - cursor location in screenshot pixels for screen \(screenUnderstandingContext.cursorScreenIndex): (\(cursorScreenshotPixelX), \(cursorScreenshotPixelY))
        \(cursorCropLine)
        - after the cursor crop, the remaining attached images are full-screen captures ordered by relevance
        - when using [POINT:...:screenN], refer to the numbered full-screen screen labels, not the cursor crop
        """
    }

    nonisolated static func buildOrderedModelImages(
        from screenUnderstandingContext: CompanionScreenUnderstandingContext
    ) -> [(data: Data, label: String)] {
        var orderedModelImages: [(data: Data, label: String)] = []

        if let cursorFocusedCropImageData = screenUnderstandingContext.cursorFocusedCropImageData,
           let cursorFocusedCropLabel = screenUnderstandingContext.cursorFocusedCropLabel {
            orderedModelImages.append((data: cursorFocusedCropImageData, label: cursorFocusedCropLabel))
        }

        orderedModelImages.append(
            contentsOf: screenUnderstandingContext.prioritizedScreenCaptures.map { screenCapture in
                (data: screenCapture.imageData, label: screenCapture.modelLabel)
            }
        )

        return orderedModelImages
    }

    nonisolated static func screenshotPixelLocation(
        cursorLocationInScreenPoints: CGPoint,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> CGPoint {
        let horizontalRatio = max(
            CGFloat.zero,
            min((cursorLocationInScreenPoints.x - displayFrame.origin.x) / max(displayFrame.width, 1.0), 1.0)
        )
        let verticalRatioFromBottom = max(
            CGFloat.zero,
            min((cursorLocationInScreenPoints.y - displayFrame.origin.y) / max(displayFrame.height, 1.0), 1.0)
        )
        let verticalRatioFromTop = 1.0 - verticalRatioFromBottom

        return CGPoint(
            x: horizontalRatio * CGFloat(screenshotWidthInPixels),
            y: verticalRatioFromTop * CGFloat(screenshotHeightInPixels)
        )
    }

    nonisolated static func makePointingRefinementCropRect(
        centeredOn screenshotCoordinate: CGPoint,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> CGRect {
        let cropSideLength = min(
            pointingRefinementCropSideLengthPixels,
            CGFloat(min(screenshotWidthInPixels, screenshotHeightInPixels))
        )

        let originX = max(
            CGFloat.zero,
            min(
                screenshotCoordinate.x - cropSideLength / 2,
                CGFloat(screenshotWidthInPixels) - cropSideLength
            )
        )
        let originY = max(
            CGFloat.zero,
            min(
                screenshotCoordinate.y - cropSideLength / 2,
                CGFloat(screenshotHeightInPixels) - cropSideLength
            )
        )

        return CGRect(
            x: originX.rounded(.down),
            y: originY.rounded(.down),
            width: cropSideLength.rounded(.down),
            height: cropSideLength.rounded(.down)
        )
    }

    nonisolated static func fullScreenshotCoordinate(
        from refinementCropCoordinate: CGPoint,
        cropRect: CGRect
    ) -> CGPoint {
        CGPoint(
            x: cropRect.origin.x + refinementCropCoordinate.x,
            y: cropRect.origin.y + refinementCropCoordinate.y
        )
    }

    static func croppedJPEGImageData(
        from screenshotImageData: Data,
        cropRect: CGRect,
        compressionFactor: CGFloat = 0.9
    ) -> Data? {
        guard let bitmapImageRepresentation = NSBitmapImageRep(data: screenshotImageData),
              let fullScreenCGImage = bitmapImageRepresentation.cgImage,
              let croppedCGImage = fullScreenCGImage.cropping(to: cropRect) else {
            return nil
        }

        return NSBitmapImageRep(cgImage: croppedCGImage)
            .representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        try await captureScreensAsJPEG(
            cursorScreenMaxDimension: defaultMaxDimension,
            secondaryScreenMaxDimension: defaultMaxDimension
        )
    }

    private static func captureScreensAsJPEG(
        cursorScreenMaxDimension: Int,
        secondaryScreenMaxDimension: Int
    ) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No display available for capture"]
            )
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(
                    x: display.frame.origin.x,
                    y: display.frame.origin.y,
                    width: CGFloat(display.width),
                    height: CGFloat(display.height)
                )
            let isCursorScreen = displayFrame.contains(mouseLocation)
            let capturePriority: CompanionScreenCapturePriority = isCursorScreen ? .cursorScreen : .secondaryScreen

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = isCursorScreen ? cursorScreenMaxDimension : secondaryScreenMaxDimension
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                screenIndex: displayIndex + 1,
                capturePriority: capturePriority,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"]
            )
        }

        return capturedScreens
    }

    nonisolated private static func makeCursorFocusedCropRect(
        centeredOn cursorLocationInScreenshotPixels: CGPoint,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> CGRect {
        let shortestScreenshotDimension = min(screenshotWidthInPixels, screenshotHeightInPixels)
        let preferredCropSideLength = CGFloat(shortestScreenshotDimension) * 0.45
        let cropSideLength = min(
            max(preferredCropSideLength, cropMinimumSideLengthPixels),
            min(cropMaximumSideLengthPixels, CGFloat(shortestScreenshotDimension))
        )

        let originX = max(
            CGFloat.zero,
            min(cursorLocationInScreenshotPixels.x - cropSideLength / 2, CGFloat(screenshotWidthInPixels) - cropSideLength)
        )
        let originY = max(
            CGFloat.zero,
            min(cursorLocationInScreenshotPixels.y - cropSideLength / 2, CGFloat(screenshotHeightInPixels) - cropSideLength)
        )

        return CGRect(
            x: originX.rounded(.down),
            y: originY.rounded(.down),
            width: cropSideLength.rounded(.down),
            height: cropSideLength.rounded(.down)
        )
    }

    private static func makeCursorFocusedCropImageData(
        from cursorScreenCapture: CompanionScreenCapture,
        cropRect: CGRect
    ) -> Data? {
        croppedJPEGImageData(
            from: cursorScreenCapture.imageData,
            cropRect: cropRect,
            compressionFactor: 0.9
        )
    }

    private static func frontmostApplicationContext() -> (applicationName: String, processIdentifier: pid_t?) {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return ("unknown", nil)
        }

        let localizedName = frontmostApplication.localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let frontmostApplicationName = (localizedName?.isEmpty == false) ? localizedName! : "unknown"
        return (frontmostApplicationName, frontmostApplication.processIdentifier)
    }

    private static func focusedWindowTitleIfAvailable(
        frontmostApplicationProcessIdentifier: pid_t?
    ) -> String? {
        guard WindowPositionManager.hasAccessibilityPermission(),
              let frontmostApplicationProcessIdentifier else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(frontmostApplicationProcessIdentifier)

        var focusedWindowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
        let focusedWindowValue else {
            return nil
        }

        var windowTitleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedWindowValue as! AXUIElement,
            kAXTitleAttribute as CFString,
            &windowTitleValue
        ) == .success,
        let windowTitle = windowTitleValue as? String else {
            return nil
        }

        let trimmedWindowTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedWindowTitle.isEmpty ? nil : trimmedWindowTitle
    }
}
