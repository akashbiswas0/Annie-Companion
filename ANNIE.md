# Annie

Annie is the tutor companion . She is designed to help users while they are already in the middle of real work on macOS, without forcing them into a separate chat app or a full-screen assistant workflow.

## Real-World Problem Statement

People often need help at the exact moment they are stuck on their computer.

That might mean:

- trying to find a setting in an unfamiliar app
- figuring out what button to press next
- asking a quick coding question 
- understanding something visible on screen without typing a long explanation
- taking an action while their hands and attention are already on the current task

In the real world, most AI tools are still separate from the work itself. The user has to stop what they are doing, switch to a chat window, explain the context manually, upload a screenshot, and then translate a text response back onto the screen.

That creates a few practical problems:

- context switching breaks focus
- users waste time describing what the assistant could have seen directly
- text-only answers are hard to map back to the UI
- help feels detached from the actual moment of work

The real-world problem Annie is solving is:

How do you give someone fast, natural, screen-aware help while they are already working, without making them leave the app, type a full prompt, or interpret everything on their own?

## Real-World Solution

Annie turns the assistant into something that feels present on the desktop instead of separate from it.

The solution is built around a few real-world behaviors:

1. Stay out of the way until needed

Annie lives in the macOS menu bar and can appear as a lightweight on-screen companion. She does not require a main window or a full chat layout.

2. Let the user speak naturally

Instead of typing, the user can hold `control + option`, ask for help, and release. That makes Annie usable in the middle of real flow, especially when the user is already looking at the answer on screen.

3. Understand the user’s current screen context

When the user asks something, Annie captures what is on screen, identifies the active context around the cursor, and sends that along with the transcript so the model can answer based on the real task in front of the user.

4. Respond in the same medium the user is already using

Annie responds with voice and, when helpful, points directly at the relevant UI element on screen. This reduces the cognitive step of converting a text explanation into a physical click path.

5. Keep the experience fast and ambient

The goal is not to feel like “open app, ask chatbot, read answer.” The goal is to feel like a companion that is already there, already aware, and able to help with minimal friction.

## Application Architecture

Annie is implemented as a macOS menu bar app with a voice pipeline, screen-capture pipeline, model-response pipeline, and overlay-rendering pipeline.

### 1. App Shell

The app is launched from [`leanring_buddyApp.swift`](/Users/akash/clicky-1/leanring-buddy/leanring_buddyApp.swift).

This layer:

- starts the menu bar app
- creates the app delegate
- initializes `CompanionManager`
- avoids creating a normal dock-based main window

The app runs as an `LSUIElement` menu bar utility, so it stays lightweight and always available.

### 2. Menu Bar and Panel Layer

The menu bar icon and floating control panel are managed by [`MenuBarPanelManager.swift`](/Users/akash/clicky-1/leanring-buddy/MenuBarPanelManager.swift) and rendered through [`CompanionPanelView.swift`](/Users/akash/clicky-1/leanring-buddy/CompanionPanelView.swift).

This layer is responsible for:

- the status bar icon
- showing and hiding the floating panel
- permissions UI
- model selection
- onboarding and basic controls

### 3. Orchestration Layer

The core app logic lives in [`CompanionManager.swift`](/Users/akash/clicky-1/leanring-buddy/CompanionManager.swift).

This is Annie’s main state machine. It coordinates:

- voice state
- global shortcut events
- dictation start and stop
- screen capture
- OpenAI chat requests
- text-to-speech playback
- overlay visibility
- point-tag parsing and cursor navigation
- short conversational memory

If Annie has a “brainstem” inside the app, this file is it.

### 4. Voice Input Pipeline

Voice input starts with [`GlobalPushToTalkShortcutMonitor.swift`](/Users/akash/clicky-1/leanring-buddy/GlobalPushToTalkShortcutMonitor.swift), which listens for the global `control + option` shortcut.

When the shortcut is pressed, [`BuddyDictationManager.swift`](/Users/akash/clicky-1/leanring-buddy/BuddyDictationManager.swift) starts microphone capture using `AVAudioEngine`.

Transcription is abstracted through [`BuddyTranscriptionProvider.swift`](/Users/akash/clicky-1/leanring-buddy/BuddyTranscriptionProvider.swift), which allows different providers:

- [`OpenAIAudioTranscriptionProvider.swift`](/Users/akash/clicky-1/leanring-buddy/OpenAIAudioTranscriptionProvider.swift)
- [`AssemblyAIStreamingTranscriptionProvider.swift`](/Users/akash/clicky-1/leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift)
- [`AppleSpeechTranscriptionProvider.swift`](/Users/akash/clicky-1/leanring-buddy/AppleSpeechTranscriptionProvider.swift)

Audio conversion helpers live in [`BuddyAudioConversionSupport.swift`](/Users/akash/clicky-1/leanring-buddy/BuddyAudioConversionSupport.swift).

### 5. Screen Understanding Pipeline

When the user finishes speaking, Annie gathers screen context through [`CompanionScreenCaptureUtility.swift`](/Users/akash/clicky-1/leanring-buddy/CompanionScreenCaptureUtility.swift).

This layer:

- captures all connected displays using ScreenCaptureKit
- identifies which screen currently contains the cursor
- prioritizes the cursor’s screen over secondary screens
- builds a cursor-centered crop for higher-signal visual context
- includes frontmost app and focused window metadata when available
- prepares the image payloads that will be sent to the model

This is what allows Annie to respond to what the user is actually looking at rather than treating every request like a pure text question.

### 6. Model Request Pipeline

Chat requests are assembled in [`OpenAIChatCompletionsClient.swift`](/Users/akash/clicky-1/leanring-buddy/OpenAIChatCompletionsClient.swift).

The request typically includes:

- the user transcript
- a structured screen-understanding summary
- prioritized images
- recent conversation history
- Annie’s behavior and pointing instructions

Responses stream back over SSE so the app can measure timing and stay responsive.

### 7. Pointing and Visual Guidance

If the model decides pointing will help, it appends a tag like:

`[POINT:x,y:label]`

or

`[POINT:x,y:label:screenN]`

`CompanionManager` parses this tag and converts it into the correct screen-space location. If needed, Annie can run a second-pass zoomed crop refinement to improve the coordinate before moving.

The visual overlay is handled by [`OverlayWindow.swift`](/Users/akash/clicky-1/leanring-buddy/OverlayWindow.swift).

This layer:

- renders Annie as the purple cursor companion
- shows listening, processing, and response states
- animates navigation arcs
- supports multi-monitor pointing
- shows onboarding and greeting moments

### 8. Voice Output Pipeline

Once the spoken text is finalized, [`OpenAITextToSpeechClient.swift`](/Users/akash/clicky-1/leanring-buddy/OpenAITextToSpeechClient.swift) requests synthesized audio and plays it back locally.

This gives Annie a spoken response path, not just a visual one.

### 9. Worker Proxy Layer

The macOS app does not call OpenAI directly. All sensitive API access is routed through the Cloudflare Worker in [`worker/src/index.ts`](/Users/akash/clicky-1/worker/src/index.ts).

The worker handles:

- `/chat`
- `/transcribe`
- `/tts`
- `/transcribe-token`

This keeps API keys off the client and creates a single server-side boundary for external AI services.

### 10. Analytics and Operational Support

Usage and product events are tracked through [`ClickyAnalytics.swift`](/Users/akash/clicky-1/leanring-buddy/ClickyAnalytics.swift).

Permission and placement logic is supported by [`WindowPositionManager.swift`](/Users/akash/clicky-1/leanring-buddy/WindowPositionManager.swift).

## End-to-End Request Flow

The full Annie interaction flow looks like this:

1. The user presses `control + option`
2. The app starts recording microphone input
3. The user releases the shortcut
4. The transcript is finalized
5. Annie captures screen context
6. The app sends transcript + context + images to the worker
7. The worker forwards the request to OpenAI
8. The response streams back
9. Annie parses any point tag
10. Annie speaks the answer aloud
11. Annie points at the target on screen when helpful

In shorthand:

`hotkey -> audio -> transcript -> screenshots -> model -> spoken answer -> optional pointing`

## Why This Architecture Matters

This architecture is not only about “using AI in an app.” It is specifically designed to solve the real-world friction of getting help while already busy on the desktop.

Each major part serves that goal:

- menu bar form factor keeps the app ambient
- push-to-talk keeps input fast
- screen capture keeps context grounded
- voice output keeps responses lightweight
- cursor pointing makes UI guidance concrete
- worker proxy keeps secrets off-device

Together, those pieces make Annie feel less like a chatbot you open and more like a companion that can help inside the moment of work.
