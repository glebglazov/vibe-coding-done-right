# VCDR - Voice Coding Done Right (Mac)

A macOS menu bar application that records voice, transcribes it using OpenAI Whisper, and sends the text to your Claude Code session via tmux.

## Features

- 🍏 **Menu Bar App**: Runs discretely in your macOS menu bar
- 🎤 **Voice Recording**: Click to start/stop recording
- ⌨️ **Global Shortcut**: Record with Cmd+Shift+Space from anywhere
- 🤖 **Native Whisper Transcription**: Uses WhisperKit (Apple's native Swift implementation)
- 📤 **Multiple Destinations**: Choose between tmux/Claude or clipboard with auto-paste
- 🔌 **Extensible Architecture**: Easy to add more destinations
- 📦 **Self-Contained**: No external dependencies - models download automatically

## Prerequisites

### Required Software

1. **tmux** (for Claude Code integration):
   ```bash
   brew install tmux
   ```

2. **Xcode 15+** (for building the app)

### tmux Setup

Make sure your Claude Code session is running in tmux with "Claude" in the pane title for optimal detection.

## Installation & Building

1. **Clone the repository**:
   ```bash
   cd /path/to/vibe-coding-done-right/mac
   ```

2. **Open in Xcode**:
   ```bash
   open vcdr.xcodeproj
   ```

3. **Build and Run**:
   - Press `Cmd+R` in Xcode, or
   - From command line: `xcodebuild -project vcdr.xcodeproj -scheme vcdr build`

## Usage

1. **Launch the app** - A microphone icon will appear in your menu bar
2. **Choose your destination** - Select between "Tmux (Claude)" or "Clipboard (Auto-paste)"
3. **Start recording** either by:
   - Clicking the menu bar icon and pressing "Start Recording"
   - Using the global shortcut **Cmd+Shift+Space** from anywhere
4. **Speak your message**
5. **Stop recording** by clicking "Stop Recording" or pressing **Cmd+Shift+Space** again
6. The app will automatically:
   - Transcribe your speech using WhisperKit
   - Send to your chosen destination (tmux/Claude or clipboard with auto-paste)

### Global Shortcut

**Cmd+Shift+Space** - Start/stop recording from anywhere on your system

### Destinations

- **Tmux (Claude)** - Finds your Claude Code session and sends text directly
- **Clipboard (Auto-paste)** - Copies text to clipboard and automatically pastes it to the active app

**Note:** Clipboard auto-paste requires Accessibility permissions (the app will prompt you)

## Architecture

### Core Components

- **`MenuBarController`**: Main app logic and state management
- **`AudioRecorder`**: Handles microphone recording using AVFoundation
- **`WhisperKitService`**: Manages native Swift/WhisperKit transcription
- **`DestinationProtocol`**: Abstracted interface for sending transcribed text
- **`TmuxDestination`**: Implementation for sending text to tmux/Claude Code

### Destination System

The app uses an abstracted destination system, making it easy to add support for other targets:

```swift
protocol TextDestination {
    var name: String { get }
    func send(text: String) async throws
    func isAvailable() async -> Bool
}
```

You can easily add new destinations (Slack, Discord, etc.) by implementing this protocol.

## Project Structure

```
mac/
├── vcdr/
│   ├── vcdrApp.swift           # Main app entry point
│   ├── UI/                     # User Interface
│   │   ├── MenuBarController.swift # Core application logic
│   │   ├── MenuBarView.swift   # SwiftUI menu bar interface
│   │   └── ContentView.swift   # Fallback window view
│   ├── Audio/                  # Audio Recording
│   │   └── AudioRecorder.swift # Voice recording functionality
│   ├── Transcription/          # Speech-to-Text
│   │   └── WhisperKitService.swift # Native WhisperKit transcription
│   ├── Destinations/           # Output Destinations
│   │   ├── DestinationProtocol.swift # Abstracted destination interface
│   │   ├── TmuxDestination.swift # tmux/Claude Code integration
│   │   └── ClipboardDestination.swift # Clipboard with auto-paste
│   └── Core/                   # Core Functionality
│       └── GlobalHotkeyManager.swift # System-wide shortcuts
├── vcdr.xcodeproj/            # Xcode project
└── README.md                  # This file
```

## Troubleshooting

### Common Issues

1. **"WhisperKit initialization failed"**:
   - Ensure you have internet connection for model download on first run
   - Models are cached locally after first download

2. **"Microphone permission denied"**:
   - The app will automatically request microphone permission on first use
   - If denied, go to System Settings → Privacy & Security → Microphone
   - Add and enable your app
   - Note: The app includes the required `NSMicrophoneUsageDescription` in Info.plist

3. **"Claude session not found"**:
   - Ensure tmux is running: `tmux list-sessions`
   - Make sure your Claude Code pane has "Claude" in the title
   - Check that tmux is installed in `/usr/local/bin/tmux`

4. **"Transcription failed: xcrun: error: cannot be used within an App Sandbox"**:
   - This has been fixed by disabling App Sandbox in the project
   - The app now runs without sandbox restrictions to allow Python execution

5. **"Failed to transcribe"**:
   - Ensure microphone is working and app has permission
   - Try speaking louder and clearer
   - Check internet connection if models aren't downloaded yet

### Debug Information

The app logs debug information to the console. To view logs:
1. Open Console.app
2. Search for "vcdr" or view device logs
3. Look for transcription and tmux integration messages

## Development

### Adding New Destinations

To add support for a new destination (e.g., Slack):

1. Create a new file implementing `TextDestination`:
   ```swift
   class SlackDestination: TextDestination {
       let name = "Slack"

       func send(text: String) async throws {
           // Implementation here
       }

       func isAvailable() async -> Bool {
           // Check if Slack is available
       }
   }
   ```

2. Add it to `MenuBarController`:
   ```swift
   private let destinations: [TextDestination] = [
       TmuxDestination(),
       SlackDestination()
   ]
   ```

### Building for Distribution

To create a distributable app:

1. **Archive the project**:
   - Product → Archive in Xcode

2. **Export for distribution**:
   - Choose "Developer ID" for distribution outside App Store

3. **Notarize** (if distributing outside App Store):
   - Follow Apple's notarization process

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

This project is open source. Add your preferred license here.

## Acknowledgments

- OpenAI Whisper for speech recognition
- tmux for session management
- SwiftUI for the native macOS interface