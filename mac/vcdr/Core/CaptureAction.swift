//
//  CaptureAction.swift
//  vcdr
//
//  Created by Claude Code
//

import Foundation

/// Represents a single action within a capture session
/// Each action can be from recording, clipboard, or selected text
struct CaptureAction: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let source: CaptureSource
    let text: String
    let audioFileURL: URL?

    enum CaptureSource: String, Codable {
        case clipboard
        case recording
        case selectedText
        case keyboardInput
        case appContext
    }

    init(source: CaptureSource, text: String, audioFileURL: URL? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.source = source
        self.text = text
        self.audioFileURL = audioFileURL
    }
}

extension CaptureAction {
    /// Human-readable description of the action source
    var sourceDescription: String {
        switch source {
        case .clipboard:
            return "Clipboard"
        case .recording:
            return "Recording"
        case .selectedText:
            return "Selected Text"
        case .keyboardInput:
            return "Keyboard Input"
        case .appContext:
            return "App Context"
        }
    }

    /// Icon name for the action source
    var sourceIcon: String {
        switch source {
        case .clipboard:
            return "doc.on.clipboard"
        case .recording:
            return "waveform"
        case .selectedText:
            return "selection.pin.in.out"
        case .keyboardInput:
            return "keyboard"
        case .appContext:
            return "macwindow"
        }
    }
}
