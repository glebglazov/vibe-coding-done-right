import Foundation

/// A user-created mode with custom system prompt
class CustomMode: Mode, Codable {
    let id: UUID
    var name: String
    var description: String
    var systemPrompt: String

    init(id: UUID = UUID(), name: String, description: String, systemPrompt: String) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
    }

    func process(text: String, using provider: any LLMProvider) async throws -> String {
        // Combine base input structure prompt with user's custom system prompt
        let combinedSystemPrompt = """
        \(baseInputStructurePrompt)

        === USER SYSTEM PROMPT ===
        \(systemPrompt)
        """
        return try await provider.generate(prompt: text, systemPrompt: combinedSystemPrompt)
    }

    // Codable conformance
    enum CodingKeys: String, CodingKey {
        case id, name, description, systemPrompt
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(systemPrompt, forKey: .systemPrompt)
    }
}
