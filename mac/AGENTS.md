# AGENTS.md - VCDR Architecture

This document describes the architecture and key components (agents) of the VCDR (Voice Coding Done Right) macOS application.

## Overview

VCDR is a modular voice coding assistant that follows a pipeline architecture:

```
Voice Input → Transcription → Mode Processing → Destination Output
```

The system is designed with extensibility in mind, using protocol-based abstractions for modes, LLM providers, and destinations.

## Core Architecture

### Main Orchestrator

**MenuBarController** (`vcdr/UI/MenuBarController.swift`)
- Central coordinator managing the entire voice-to-text-to-output pipeline
- Handles recording lifecycle, transcription flow, and destination routing
- Manages global hotkey integration and app focus restoration
- Key responsibilities:
  - Recording state management (start/stop/cancel)
  - Whisper service initialization and transcription
  - Selected text capture (for context-aware AI assistance)
  - Mode processing coordination
  - Destination selection and routing
  - UI state updates

### Audio & Transcription Layer

**AudioRecorder** (`vcdr/Audio/AudioRecorder.swift`)
- Handles microphone recording using AVFoundation
- Manages audio permissions
- Records to temporary audio files

**WhisperKitService** (`vcdr/Transcription/WhisperKitService.swift`)
- Native Swift implementation using Apple's WhisperKit
- Converts audio files to text transcriptions
- Handles model downloading and initialization
- Singleton service for app-wide transcription

### Input Management

**GlobalHotkeyManager** (`vcdr/Core/GlobalHotkeyManager.swift`)
- Registers system-wide keyboard shortcuts (default: Cmd+Shift+Space)
- Monitors accessibility permissions and auto-retries registration
- Allows hotkey customization through app settings

**AppSettings** (`vcdr/Core/AppSettings.swift`)
- Persists user preferences (active mode, hotkey configuration, etc.)
- Syncs with ModeManager and other components

## Mode System (Text Processing Agents)

The mode system provides an extensible framework for AI-powered text transformation.

### Mode Protocol

**Location:** `vcdr/Modes/Mode.swift`

```swift
protocol Mode: Identifiable {
    var id: UUID { get }
    var name: String { get }
    var description: String { get }
    func process(text: String, using provider: any LLMProvider) async throws -> String
}
```

### ModeManager

**Location:** `vcdr/Modes/ModeManager.swift`

Singleton manager responsible for:
- Mode registration and lifecycle
- Active mode selection
- LLM provider management
- Text processing coordination

**Key Features:**
- Enable/disable mode processing globally
- Select active mode at runtime
- Switch between LLM providers
- Graceful fallback to raw transcription on errors

### Built-in Modes

#### 1. DisabledMode (`vcdr/Modes/DisabledMode.swift`)
- **Purpose:** Pass-through mode with no text transformation
- **Use Case:** When you want raw Whisper transcription without AI processing
- **Processing:** Returns input text unchanged

#### 2. AssistantMode (`vcdr/Modes/AssistantMode.swift`)
- **Purpose:** General-purpose AI assistant
- **Use Case:** Question answering, text transformation, coding assistance
- **Features:**
  - Supports selected text as context (captured before recording)
  - Concise, direct responses
  - Follows natural conversation flow

**System Prompt Strategy:**
```
You are a helpful AI assistant. The user will provide you with text and possibly some context.
Respond naturally and helpfully to their requests or questions.

If the user provides "Selected text:" followed by their response, use the selected text as
context for your answer.

Be concise, clear, and helpful. Provide direct answers without unnecessary preamble.
```

#### 3. MarketingEmailMode (`vcdr/Modes/MarketingEmailMode.swift`)
- **Purpose:** Transform dictated speech into professional marketing emails
- **Use Case:** Rapid email composition using voice input
- **Features:**
  - Professional structure (greeting, body, closing)
  - Persuasive yet friendly tone
  - Grammar correction from speech-to-text artifacts
  - Proper formatting and paragraph breaks

**System Prompt Strategy:**
```
You are a professional marketing email writer. Your task is to take the user's spoken input
and transform it into a well-structured, professional marketing email.

Guidelines:
- Keep the core message and intent from the user's input
- Add appropriate professional structure (greeting, body, closing)
- Use persuasive but friendly language
- Maintain a professional yet warm tone
- Ensure proper formatting and paragraph breaks
- Keep it concise and focused
- Fix any grammatical issues from speech-to-text

Output ONLY the email text, without any meta-commentary or explanations.
```

### Adding Custom Modes

To create a new mode:

1. **Create a new Swift file** implementing the `Mode` protocol:
   ```swift
   class CustomMode: Mode {
       let id = UUID()
       let name = "Your Mode Name"
       let description = "What your mode does"

       private let systemPrompt = """
       Your custom system instructions...
       """

       func process(text: String, using provider: any LLMProvider) async throws -> String {
           return try await provider.generate(prompt: text, systemPrompt: systemPrompt)
       }
   }
   ```

2. **Register in ModeManager** (`vcdr/Modes/ModeManager.swift:27`):
   ```swift
   availableModes = [
       DisabledMode(),
       AssistantMode(),
       MarketingEmailMode(),
       CustomMode() // Add your mode here
   ]
   ```

## LLM Provider System

The LLM provider system abstracts the AI model backend, allowing easy integration of different LLM services.

### LLMProvider Protocol

**Location:** `vcdr/Services/LLMProvider.swift`

```swift
protocol LLMProvider: Identifiable {
    var id: UUID { get }
    var name: String { get }
    var requiresAPIKey: Bool { get }
    var isAvailable: Bool { get async }
    func generate(prompt: String, systemPrompt: String?) async throws -> String
}
```

### Built-in Providers

#### FoundationModelsProvider (`vcdr/Services/FoundationModelsProvider.swift`)
- **Backend:** Apple's on-device Foundation Models (Apple Intelligence)
- **Requirements:**
  - Apple Silicon Mac
  - macOS 15.1+ with Apple Intelligence enabled
  - Supported system language
- **Features:**
  - No API key required
  - Completely on-device processing (privacy-preserving)
  - Session management with prewarming
  - Detailed availability error messages
- **Limitations:**
  - Device and language restrictions
  - Smaller context window than cloud models

### Adding Custom Providers

To integrate a new LLM provider (e.g., Ollama, Anthropic, OpenAI):

1. **Create provider implementation:**
   ```swift
   class OllamaProvider: LLMProvider {
       let id = UUID()
       let name = "Ollama"
       let requiresAPIKey = false

       var isAvailable: Bool {
           get async {
               // Check if Ollama is running locally
           }
       }

       func generate(prompt: String, systemPrompt: String?) async throws -> String {
           // Call Ollama API
       }
   }
   ```

2. **Register in ModeManager** (`vcdr/Modes/ModeManager.swift:34`):
   ```swift
   availableProviders = [
       foundationModelsProvider,
       OllamaProvider()
   ]
   ```

## Destination System (Output Agents)

The destination system defines where processed text is sent after transcription and mode processing.

### TextDestination Protocol

**Location:** `vcdr/Destinations/DestinationProtocol.swift`

```swift
protocol TextDestination {
    var name: String { get }
    func send(text: String, onPrepareSend: (() async -> Void)?) async throws
    func isAvailable() async -> Bool
}
```

The `onPrepareSend` callback allows destinations to restore app focus before sending text, enabling seamless workflow integration.

### Built-in Destinations

#### 1. TmuxDestination (`vcdr/Destinations/TmuxDestination.swift`)
- **Purpose:** Send text directly to Claude Code running in tmux
- **Use Case:** Voice-powered Claude Code interactions
- **Features:**
  - Finds tmux sessions and panes automatically
  - Detects Claude Code panes by title
  - Fallback strategies for pane selection
  - Handles multi-line text properly
- **Requirements:** tmux installed at `/usr/local/bin/tmux`

#### 2. PasteDestination (`vcdr/Destinations/PasteDestination.swift`)
- **Purpose:** Copy text to clipboard and auto-paste into active application
- **Use Case:** Voice input into any application
- **Features:**
  - Automatic clipboard management
  - Simulates Cmd+V keystroke
  - App focus restoration before paste
- **Requirements:** Accessibility permissions

#### 3. CopyDestination (`vcdr/Destinations/CopyDestination.swift`)
- **Purpose:** Copy text to clipboard without auto-pasting
- **Use Case:** Manual paste workflows
- **Features:**
  - Simple clipboard population
  - User controls when/where to paste

### Adding Custom Destinations

To create a new destination (e.g., Slack, Discord):

1. **Implement TextDestination protocol:**
   ```swift
   class SlackDestination: TextDestination {
       let name = "Slack"

       func send(text: String, onPrepareSend: (() async -> Void)?) async throws {
           // Call onPrepareSend to restore focus before sending
           await onPrepareSend?()

           // Send to Slack via API
       }

       func isAvailable() async -> Bool {
           // Check if Slack is configured/running
       }
   }
   ```

2. **Add to MenuBarController** (`vcdr/UI/MenuBarController.swift`):
   ```swift
   private let slackDestination = SlackDestination()

   // Add destination type to enum
   enum DestinationType {
       case paste
       case copy
       case tmux
       case slack
   }

   // Add routing logic in stopRecordingAndSendTo
   ```

## Data Flow

### Complete Pipeline

```
1. User activates recording (hotkey or menu)
   ↓
2. MenuBarController captures:
   - Previous active app (for focus restoration)
   - Selected text (for context-aware AI)
   ↓
3. AudioRecorder captures voice input
   ↓
4. WhisperKitService transcribes audio → text
   ↓
5. ModeManager processes text:
   - Selected text prepended if available
   - Active Mode transforms text using LLM Provider
   ↓
6. MenuBarController routes to destination:
   - Restores previous app focus
   - Sends processed text via TextDestination
   ↓
7. User sees result in target application
```

### Context-Aware Assistant Flow

The app supports capturing selected text before recording, enabling context-aware AI assistance:

```
1. User selects text in any app
   ↓
2. User triggers recording (Cmd+Shift+Space)
   ↓
3. App captures selected text via Cmd+C simulation
   ↓
4. User dictates question/request
   ↓
5. App prepends selected text to dictation
   ↓
6. Mode processes combined input
   ↓
7. Result sent to destination
```

**Example Usage:**
- Select code snippet → Ask "explain this code"
- Select email → Say "make this more formal"
- Select error message → Request "how do I fix this"

## UI Components

### MenuBarView (`vcdr/UI/MenuBarView.swift`)
- Main menu bar dropdown interface
- Destination selection
- Mode selection and status
- Settings access

### RecordingOverlay (`vcdr/UI/RecordingOverlay.swift`)
- Floating window displayed during recording
- Positioned on screen with active app
- Visual feedback for recording state
- Quick action buttons (cancel, destination shortcuts)

### SettingsView (`vcdr/UI/SettingsView.swift`)
- Mode configuration
- Hotkey customization
- Provider selection
- App preferences

## Extension Points Summary

The VCDR architecture is designed for extensibility. You can easily add:

1. **New Modes** - Custom text transformation agents (Code Refactor Mode, Documentation Mode, etc.)
2. **New LLM Providers** - Additional AI backends (Ollama, Anthropic Claude, OpenAI, etc.)
3. **New Destinations** - Output targets (Slack, Discord, VS Code, etc.)
4. **New UI** - Additional interfaces or overlays

Each extension point uses Swift protocols for clean abstraction and easy testing.

## Configuration Files

- **Info.plist** - Contains required permissions (`NSMicrophoneUsageDescription`)
- **App Sandbox** - Disabled to allow Python/Whisper execution
- **Entitlements** - Accessibility and audio input permissions

## Error Handling

The app includes comprehensive error handling at each layer:

- **ModeError** - Mode processing failures
- **FoundationModelsError** - Apple Intelligence availability issues
- **DestinationError** - Output delivery failures
- **WhisperKitError** - Transcription problems

All errors surface to the user via `MenuBarController.statusMessage` with actionable guidance.

## Performance Considerations

- **WhisperKit Prewarming** - Models loaded on app startup
- **Session Prewarm** - Foundation Models sessions prewarmed before generation
- **Early Focus Restoration** - App focus restored before LLM processing (non-blocking UX)
- **Async/Await** - All I/O operations use Swift concurrency
- **Background Processing** - Transcription and AI processing happen off main thread

## Security & Privacy

- **On-device Processing** - FoundationModelsProvider runs entirely on-device
- **No Cloud Dependencies** - Default configuration doesn't send data externally
- **Microphone Permission** - Explicit user consent required
- **Accessibility Permission** - Only for paste functionality
- **Clipboard Restoration** - Original clipboard content preserved when capturing selected text

## Development Guidelines

### Adding a New Component

1. Define protocol interface (if creating new category)
2. Implement concrete class
3. Register with appropriate manager
4. Update UI if needed
5. Test availability checks and error paths

### Testing Strategy

- Unit test each protocol implementation
- Integration test the full pipeline
- Test permission edge cases
- Test multi-display scenarios
- Verify clipboard restoration

## Future Extension Ideas

- **Code Review Mode** - Analyze and suggest improvements for code
- **Meeting Notes Mode** - Structure dictation into meeting minutes
- **Translation Mode** - Translate to different languages
- **Ollama Provider** - Local LLM alternative to Apple Intelligence
- **VS Code Destination** - Direct integration with VS Code
- **Custom Hotkeys per Mode** - Different shortcuts for different modes
- **Voice Commands** - "Send to Slack", "Copy only", etc.
- **History/Replay** - Review and resend previous transcriptions

## References

- **WhisperKit Documentation**: https://github.com/argmaxinc/WhisperKit
- **Apple Foundation Models**: https://developer.apple.com/documentation/FoundationModels
- **tmux Documentation**: https://github.com/tmux/tmux/wiki
- **Claude Code**: https://claude.com/claude-code
