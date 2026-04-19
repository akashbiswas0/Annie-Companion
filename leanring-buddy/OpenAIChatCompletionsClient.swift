//
//  OpenAIChatCompletionsClient.swift
//  leanring-buddy
//
//  OpenAI chat completions implementation with streaming support.
//

import Foundation

/// OpenAI chat completions helper with streaming for progressive text display.
final class OpenAIChatCompletionsClient {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "gpt-5.4") {
        self.apiURL = URL(string: proxyURL)!
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. OpenAI image inputs need the correct data URL MIME type.
    private static func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/chat` avoids extra endpoint-specific noise.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    static func buildUserTextBlocks(
        screenUnderstandingSummary: String?,
        userPrompt: String
    ) -> [String] {
        var userTextBlocks: [String] = []

        if let screenUnderstandingSummary {
            let trimmedScreenUnderstandingSummary = screenUnderstandingSummary
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedScreenUnderstandingSummary.isEmpty {
                userTextBlocks.append(trimmedScreenUnderstandingSummary)
            }
        }

        userTextBlocks.append(userPrompt)
        return userTextBlocks
    }

    private func makeImageContentBlock(imageData: Data, label: String) -> [[String: Any]] {
        let imageMediaType = Self.detectImageMediaType(for: imageData)
        return [
            [
                "type": "text",
                "text": label
            ],
            [
                "type": "image_url",
                "image_url": [
                    "url": "data:\(imageMediaType);base64,\(imageData.base64EncodedString())"
                ]
            ]
        ]
    }

    /// Send a vision request to OpenAI with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        screenUnderstandingSummary: String? = nil,
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        // Build messages array
        var messages: [[String: Any]] = []

        messages.append([
            "role": "developer",
            "content": systemPrompt
        ])

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for userTextBlock in Self.buildUserTextBlocks(
            screenUnderstandingSummary: screenUnderstandingSummary,
            userPrompt: userPrompt
        ) {
            contentBlocks.append([
                "type": "text",
                "text": userTextBlock
            ])
        }
        for image in images {
            contentBlocks.append(contentsOf: makeImageContentBlock(imageData: image.data, label: image.label))
        }
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 1024,
            "stream": true,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        let requestBuildDuration = Date().timeIntervalSince(startTime)
        print("🌐 OpenAI streaming request built in \(String(format: "%.2f", requestBuildDuration))s: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAIChatAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "OpenAIChatAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse SSE stream — each event is "data: {json}\n\n"
        var accumulatedResponseText = ""
        var hasLoggedFirstStreamTextChunk = false

        for try await line in byteStream.lines {
            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // End of stream marker
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if let choices = eventPayload["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let delta = firstChoice["delta"] as? [String: Any],
               let textChunk = delta["content"] as? String {
                if !hasLoggedFirstStreamTextChunk {
                    hasLoggedFirstStreamTextChunk = true
                    let firstTokenLatency = Date().timeIntervalSince(startTime)
                    print("⏱️ OpenAI streaming first token: \(String(format: "%.2f", firstTokenLatency))s")
                }
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        print("⏱️ OpenAI streaming completed in \(String(format: "%.2f", duration))s")
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        screenUnderstandingSummary: String? = nil,
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        var messages: [[String: Any]] = []
        messages.append([
            "role": "developer",
            "content": systemPrompt
        ])

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for userTextBlock in Self.buildUserTextBlocks(
            screenUnderstandingSummary: screenUnderstandingSummary,
            userPrompt: userPrompt
        ) {
            contentBlocks.append([
                "type": "text",
                "text": userTextBlock
            ])
        }
        for image in images {
            contentBlocks.append(contentsOf: makeImageContentBlock(imageData: image.data, label: image.label))
        }
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 256,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        let requestBuildDuration = Date().timeIntervalSince(startTime)
        print("🌐 OpenAI request built in \(String(format: "%.2f", requestBuildDuration))s: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenAIChatAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(
                domain: "OpenAIChatAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        print("⏱️ OpenAI request completed in \(String(format: "%.2f", duration))s")
        return (text: text, duration: duration)
    }
}
