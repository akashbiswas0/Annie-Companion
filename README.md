# Annie

Annie is a macOS menu bar companion for screen-aware, voice-first AI help. It lives in the status bar, listens while you hold `control + option`, captures the current screen context, and responds with spoken guidance plus an on-screen cursor that can point at relevant UI elements.

## What It Does

- lives entirely in the macOS menu bar with a custom floating panel
- records push-to-talk audio and transcribes it on key release
- captures screen context, including multi-monitor setups
- sends transcript and screenshots through a Cloudflare Worker proxy
- streams back assistant text, speaks it aloud, and can point on screen
- supports `gpt-5.4` by default, with `gpt-5` as an option
- uses OpenAI transcription by default, with AssemblyAI and Apple Speech as alternates

## How It Works

`hotkey -> mic capture -> transcription -> screen capture -> OpenAI chat -> TTS -> cursor pointing`

The macOS app never ships raw API keys. Chat, transcription, text-to-speech, and AssemblyAI token requests all go through `worker/src/index.ts`.

## OpenAI Models

- chat and screen-aware responses: `gpt-5.4` by default, `gpt-5` optional
- transcription: `gpt-4o-transcribe`
- text-to-speech: `gpt-4o-mini-tts` with the `nova` voice

## Key Components

- CompanionManager.swift: central app state and interaction pipeline
- MenuBarPanelManager.swift: status bar item and floating panel lifecycle
- BuddyDictationManager.swift: push-to-talk recording flow
- BuddyTranscriptionProvider.swift: transcription provider selection
- CompanionScreenCaptureUtility.swift: screenshot capture and screen context
- OpenAIChatCompletionsClient.swift: streaming chat requests
- StreamingSpeechTextAccumulator.swift: safe TTS chunking from streamed text
- OpenAITextToSpeechClient.swift: speech playback
- OverlayWindow.swift: cursor overlay, waveform, and pointing animation
- WindowPositionManager.swift: permissions and window placement helpers
- worker/src/index.ts: proxy for OpenAI and AssemblyAI routes

## Development

- Open in Xcode: `open leanring-buddy.xcodeproj`
- Run the `leanring-buddy` scheme from Xcode
- Do not run `xcodebuild` from the terminal; it can invalidate TCC permissions like Screen Recording, Accessibility, and Microphone access
