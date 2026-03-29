import Foundation

struct BashScriptPreset: Identifiable {
    let id: String
    let name: String
    let processingCommand: String
    let systemPromptEnabled: Bool
    let systemPrompt: String
    let parameters: [ModeParameter]

    /// Applies the preset to a mode, overwriting processing-related fields only.
    func apply(to mode: inout Mode) {
        mode.processingType = .bashScript
        mode.processingCommand = processingCommand
        mode.systemPromptEnabled = systemPromptEnabled
        mode.systemPrompt = systemPrompt
        mode.parameters = parameters
    }
}

// MARK: - Built-in Presets

extension BashScriptPreset {
    static let all: [BashScriptPreset] = []
}
