//
//  CaptureHistoryEntry.swift
//  vcdr
//
//  Created by Claude Code
//

import Foundation

/// Represents a complete capture session in history
struct CaptureHistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let actions: [CaptureAction]
    let modeName: String
    let modeId: UUID
    let providerName: String?
    let providerId: UUID?
    let processedOutput: String
    let destinationType: String

    init(
        actions: [CaptureAction],
        modeName: String,
        modeId: UUID,
        providerName: String?,
        providerId: UUID?,
        processedOutput: String,
        destinationType: String
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.actions = actions
        self.modeName = modeName
        self.modeId = modeId
        self.providerName = providerName
        self.providerId = providerId
        self.processedOutput = processedOutput
        self.destinationType = destinationType
    }

    /// Combined input text from all actions
    var inputText: String {
        actions.map { $0.text }.joined(separator: "\n\n")
    }
}
