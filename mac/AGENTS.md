# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Cursor, GitHub Copilot, etc.) when working with code in this repository.

## Project Overview

VCDR (Voice Coding Done Right) is a macOS menu bar application that records voice, transcribes it using WhisperKit (Apple's native Swift implementation of Whisper), processes it through configurable modes with LLMs, and sends the result to various destinations (tmux/Claude Code, clipboard with auto-paste).

## Build and Development Commands

### Building the Application

```bash
# Open in Xcode
open vcdr.xcodeproj

# Build from command line
xcodebuild -project vcdr.xcodeproj -scheme vcdr build

# Run in Xcode
# Press Cmd+R in Xcode
```

### Testing

```bash
# Run tests from command line
xcodebuild test -project vcdr.xcodeproj -scheme vcdr

# Or use Cmd+U in Xcode
```

## Architecture

### Core Flow: Capture → Record → Transcribe → Process → Send

1. **Capture Session**: User triggers global hotkey (default: Cmd+Option+/) to start a capture session
2. **Multi-Source Input**: Within a session, user can:
   - Record voice (transcribed via WhisperKit)
   - Add selected text from other apps
   - Add clipboard content
   - Add keyboard input (direct text entry via overlay)
3. **Mode Processing**: Combined text is processed through the active Mode (Disabled, Assistant, or custom)
4. **Destination**: Processed text is sent to chosen destination (tmux, paste, or clipboard)

### Key Architectural Components

#### MenuBarController (UI/MenuBarController.swift)
- Central coordinator managing the entire capture/process/send flow
- Owns and coordinates: AudioRecorder, TranscriptionProvider, ModeManager, Destinations, and HUDNotificationManager
- Manages state machine: idle → capturing → recording → processing → sending
- Handles global hotkeys and window positioning
- **Important**: Captures the previously active app (`previousActiveApp`) before showing overlay, then restores focus before LLM processing to ensure paste works in the correct app

#### Mode System (Modes/)
- **Mode Protocol**: Defines interface for processing transcribed text with an LLM
- **ModeManager**: Singleton that manages mode lifecycle, switching, and text processing
- **Built-in Modes**:
  - `DisabledMode`: Pass-through, no LLM processing
  - `AssistantMode`: Processes text with helpful context
- **CustomMode**: User-created modes with custom system prompts, stored via CustomModesStorage
- **Mode Selection**: Users can switch modes during capture with keyboard shortcuts (x=Disabled, a=Assistant, c=cycle custom)

#### LLM Provider System (LLMProviders/)
- **LLMProvider Protocol**: Abstraction over different LLM backends
  - Defines: `name`, `requiresAPIKey`, `isAvailable`, `generate(prompt:systemPrompt:)`
- **ProviderConfiguration**: Stores per-provider settings (model names, URLs, etc.)
  - Auto-generates display names from configuration parameters
  - Stored persistently via ProvidersStorage
- **Available Providers**:
  - **FoundationModelsProvider**: Uses Apple's on-device Foundation Models (requires macOS 15.1+, no configuration needed)
  - **OllamaProvider**: Uses local Ollama server with configurable models and base URLs
    - Default base URL: `http://localhost:11434`
    - Supports custom URLs per model for multiple Ollama instances
  - **AnthropicProvider**: Uses Anthropic's Claude API with configurable models
    - Default model: `claude-sonnet-4-5-20250929`
    - Requires API key (stored in GlobalProviderSettingsStorage)
    - API key format: `sk-ant-...`
- **Provider Management**:
  - User configures and selects default provider in Settings > Providers tab
  - Multiple instances of same provider type can be configured (e.g., different Ollama models)
  - Provider availability checked asynchronously, displayed as status indicator in UI
- **Global Provider Settings**: Type-specific settings stored separately
  - Ollama: Default base URL for new models
  - Anthropic: API key (shared across all Anthropic models)
  - Apple Foundation Models: No configuration needed

#### Transcription Provider System (Transcription/)
- **TranscriptionProvider Protocol**: Abstraction over different speech-to-text backends
- **WhisperKitService**: Uses WhisperKit (Apple's native Swift implementation of Whisper)
- Models download automatically on first run and are cached locally
- Supports both "transcribe" and "translate" tasks (configurable in settings)
- Easy to swap in other providers (Deepgram, AssemblyAI, etc.) by implementing the protocol

#### Destination System (Destinations/)
- **TextDestination Protocol**: Abstraction for where processed text goes
- **TmuxDestination**: Finds Claude Code session in tmux and sends text directly
- **PasteDestination**: Uses clipboard + CGEvent to paste into the previously active app
- **CopyDestination**: Simply copies to clipboard
- All destinations implement `send(text:onPrepareSend:)` for async handling

#### Capture Actions (Core/CaptureAction.swift)
- Represents a single piece of captured content within a session
- Sources: `.recording` (voice), `.selectedText`, `.clipboard`, `.keyboardInput`
- Multiple actions accumulate during a capture session
- Combined text = all action texts joined with newlines

#### Window Management (vcdrApp.swift)
- **MenuBar**: Main menu dropdown
- **MiniOverlay**: Shows recording status during capture (bottom-center, always visible)
- **KeyboardInputOverlay**: Text input overlay for adding keyboard input during capture (center screen, dismissable)
- **ResultsOverlay**: Shows after capture for action selection (floating, keyboard-driven)
- **HUD**: Transient notifications for mode switches, events (center screen, auto-dismiss)
- **CapturePreview**: Preview window for viewing accumulated capture content
- All windows are styled with custom frames, transparency, and positioning

### State Management

The app uses @Published properties in MenuBarController for reactive UI updates:
- `isCapturing`: Whether a capture session is active (shows minimized overlay)
- `isRecording`: Whether currently recording audio
- `isProcessing`: Whether transcribing or processing with LLM
- `showResultsOverlay`: Whether to show the results overlay
- `captureActions`: Array of accumulated captures in the current session
- `statusMessage`: Current status shown to user

### Global Hotkeys (Core/GlobalHotkeyManager.swift)

Implemented using Carbon Event Manager with Accessibility permissions:
- **Capture Toggle** (Cmd+Option+/): Start/finish capture session
- **Toggle Recording** (Cmd+Option+R): Start/stop voice recording (only during capture)
- **Add Clipboard** (Cmd+Option+C): Add clipboard content (only during capture)
- **Add Keyboard Input** (Cmd+Option+I): Open keyboard input overlay to type text (only during capture)
- **Preview** (Cmd+Option+P): Show capture preview window (only during capture)

Settings stored in AppSettings, reconfigurable via SettingsView.

### Permissions Required

1. **Microphone**: For audio recording (NSMicrophoneUsageDescription in Info.plist)
2. **Accessibility**: For global hotkeys and auto-paste functionality
3. **No App Sandbox**: Disabled to allow Python execution for WhisperKit

## Important Implementation Details

### Focus Management
When finishing a capture and sending to paste destination:
1. `previousActiveApp` is captured at the START of the capture session (before overlay shows)
2. Results overlay shows, user selects action
3. **CRITICAL**: Focus is restored to `previousActiveApp` BEFORE LLM processing starts
4. This ensures paste happens in the correct app, even if LLM takes time

### Audio File Cleanup
Recording actions store temporary audio files (`audioFileURL`). These are cleaned up:
- When capture session is closed/cancelled
- When transcription fails
- Files are NOT cleaned up while in `captureActions` until session ends

### Mode Processing Error Handling
If mode processing fails (e.g., Ollama unavailable):
- Error is caught and displayed to user
- Falls back to raw transcribed text
- Still sends to destination (degraded experience, not total failure)

### HUD Notifications (Core/HUDNotificationManager.swift)
Non-intrusive, center-screen notifications for:
- Capture session started (shows active mode)
- Recording started/stopped
- Mode switched
- Clipboard added
- Processing complete

## Common Development Scenarios

### Adding a New Destination
1. Create class conforming to `TextDestination` protocol
2. Implement `name`, `send(text:onPrepareSend:)`, and `isAvailable()`
3. Add instance to MenuBarController
4. Add button in ResultsOverlay for the new destination
5. Add corresponding method in MenuBarController (e.g., `stopAndSendToNewDestination()`)

### Adding a New LLM Provider
1. Add new case to `ProviderType` enum in `ProviderConfiguration.swift`
2. Create class conforming to `LLMProvider` protocol in `LLMProviders/`
   - Implement `name`, `requiresAPIKey`, `isAvailable`, and `generate(prompt:systemPrompt:)`
3. (Optional) Create global settings struct in `ProviderGlobalSettings.swift` if provider needs shared config (like API keys)
4. Update `ProviderConfiguration` to support provider-specific settings (e.g., model names, endpoints)
   - Add static factory method like `.yourProvider(modelName:...)`
   - Update `displayName` computed property to generate readable names
5. Update `ModeManager.createProviderInstance(from:)` to handle the new provider type
6. Add UI in `SettingsView`:
   - Add global settings section in `ProviderGlobalSettingsSection` if needed
   - Update `AddProviderSheet` and `EditProviderSheet` to support the new provider type
   - Update `ProviderRow` icon mapping in `providerIcon` computed property

### Adding a New Transcription Provider
1. Create class conforming to `TranscriptionProvider` protocol in `Transcription/`
2. Implement `name`, `isAvailable`, `initialize()`, and `transcribe(audioFileURL:)`
3. Update MenuBarController to conditionally use the new provider (e.g., based on AppSettings)
4. Add UI in SettingsView to select between transcription providers

### Adding a New Built-in Mode
1. Create class conforming to `Mode` protocol
2. Implement `name`, `description`, and `process(text:using:)`
3. Add to `builtInModes` in ModeManager
4. Add keyboard shortcut if desired (in vcdrApp.swift commands)

### Modifying Global Shortcuts
1. Update AppSettings to add new shortcut properties
2. Add shortcut registration in MenuBarController.setupGlobalHotkey()
3. Add callback handler method in MenuBarController
4. Add UI in SettingsView for configuring the shortcut
5. Ensure callbacks check appropriate state (e.g., `isCapturing` for in-capture shortcuts)

## File Organization

```
vcdr/
├── vcdrApp.swift              # App entry point, window definitions
├── UI/                        # All user interface components
│   ├── MenuBarController.swift    # Main coordinator/controller
│   ├── MenuBarView.swift          # Menu bar dropdown UI
│   ├── ResultsOverlay.swift       # Post-capture action selector
│   ├── MiniOverlay.swift          # In-capture status indicator
│   ├── KeyboardInputOverlay.swift # Keyboard input text entry overlay
│   ├── SettingsView.swift         # App settings UI
│   └── ...
├── Audio/
│   └── AudioRecorder.swift    # AVFoundation recording
├── Transcription/             # Speech-to-text providers
│   ├── TranscriptionProvider.swift # Protocol
│   └── WhisperKitService.swift # WhisperKit implementation
├── Modes/                     # Mode system
│   ├── Mode.swift             # Protocol
│   ├── ModeManager.swift      # Coordinator
│   ├── DisabledMode.swift     # Built-in
│   ├── AssistantMode.swift    # Built-in
│   ├── CustomMode.swift       # User-defined
│   └── CustomModesStorage.swift # Persistence
├── LLMProviders/              # LLM providers
│   ├── LLMProvider.swift      # Protocol
│   ├── ProviderConfiguration.swift # Provider config & storage
│   ├── ProviderGlobalSettings.swift # Global provider settings
│   ├── FoundationModelsProvider.swift
│   ├── OllamaProvider.swift
│   └── AnthropicProvider.swift
├── Destinations/              # Output destinations
│   ├── DestinationProtocol.swift
│   ├── TmuxDestination.swift
│   ├── PasteDestination.swift
│   └── CopyDestination.swift
└── Core/                      # Core utilities
    ├── GlobalHotkeyManager.swift
    ├── HUDNotificationManager.swift
    ├── CaptureAction.swift
    └── AppSettings.swift
```

## tmux Integration Details

TmuxDestination finds Claude Code by:
1. Listing all tmux sessions
2. Finding panes with "Claude" in the title
3. Sending text via `tmux send-keys` (bracketed paste mode)

Requires tmux at `/usr/local/bin/tmux` or in PATH.
