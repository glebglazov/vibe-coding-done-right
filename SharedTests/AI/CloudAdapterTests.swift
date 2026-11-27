import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Asserts each shared cloud adapter's constructed request (endpoint, auth,
/// headers, body) for a fixed input, plus success and error decode — all against
/// `StubURLProtocol` so no live network is touched. Request shapes mirror the
/// platform adapter prior art byte-for-byte. Serialized because `StubURLProtocol`
/// holds the captured request / canned response in static state.

private func jsonBody(_ data: Data?) -> [String: Any] {
    guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return obj
}

// MARK: - Anthropic

@Suite("AnthropicAdapter request + decode", .serialized)
final class AnthropicAdapterTests {
    init() { URLProtocol.registerClass(StubURLProtocol.self) }
    deinit { URLProtocol.unregisterClass(StubURLProtocol.self) }

    @Test("constructed request matches the prior art for a fixed input")
    func requestShape() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 200,
            data: Data(#"{"content":[{"text":"ok"}]}"#.utf8)
        )

        _ = try await AnthropicAdapter(apiKey: "secret-key")
            .process(text: "hello", systemPrompt: "be brief")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let body = jsonBody(StubURLProtocol.lastBody)
        #expect(body["model"] as? String == "claude-haiku-4-5-20251001")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect(body["system"] as? String == "be brief")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "hello")
    }

    @Test("decodes a representative success response")
    func successDecode() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 200,
            data: Data(#"{"content":[{"type":"text","text":"processed text"}]}"#.utf8)
        )

        let result = try await AnthropicAdapter(apiKey: "k").process(text: "x", systemPrompt: "y")
        #expect(result == "processed text")
    }

    @Test("maps an error response to apiError with the API message")
    func errorDecode() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 401,
            data: Data(#"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        )

        await #expect {
            _ = try await AnthropicAdapter(apiKey: "k").process(text: "x", systemPrompt: "y")
        } throws: { error in
            guard case let .apiError(provider, statusCode, message) = error as? CloudAIClientError else { return false }
            return provider == .anthropic && statusCode == 401 && message == "invalid x-api-key"
        }
    }
}

// MARK: - OpenAI

@Suite("OpenAIAdapter request + decode", .serialized)
final class OpenAIAdapterTests {
    init() { URLProtocol.registerClass(StubURLProtocol.self) }
    deinit { URLProtocol.unregisterClass(StubURLProtocol.self) }

    @Test("constructed request matches the prior art for a fixed input")
    func requestShape() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 200,
            data: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        )

        _ = try await OpenAIAdapter(apiKey: "secret-key")
            .process(text: "hello", systemPrompt: "be brief")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")

        let body = jsonBody(StubURLProtocol.lastBody)
        #expect(body["model"] as? String == "gpt-4o-mini")
        #expect(body["max_tokens"] as? Int == 1024)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == "be brief")
        #expect(messages.last?["role"] as? String == "user")
        #expect(messages.last?["content"] as? String == "hello")
    }

    @Test("decodes a representative success response")
    func successDecode() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 200,
            data: Data(#"{"choices":[{"message":{"role":"assistant","content":"processed text"}}]}"#.utf8)
        )

        let result = try await OpenAIAdapter(apiKey: "k").process(text: "x", systemPrompt: "y")
        #expect(result == "processed text")
    }

    @Test("maps an error response to apiError with the API message")
    func errorDecode() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 429,
            data: Data(#"{"error":{"message":"rate limit exceeded","type":"rate_limit_error"}}"#.utf8)
        )

        await #expect {
            _ = try await OpenAIAdapter(apiKey: "k").process(text: "x", systemPrompt: "y")
        } throws: { error in
            guard case let .apiError(provider, statusCode, message) = error as? CloudAIClientError else { return false }
            return provider == .openai && statusCode == 429 && message == "rate limit exceeded"
        }
    }
}

// MARK: - Gemini

@Suite("GeminiAdapter request + decode", .serialized)
final class GeminiAdapterTests {
    init() { URLProtocol.registerClass(StubURLProtocol.self) }
    deinit { URLProtocol.unregisterClass(StubURLProtocol.self) }

    @Test("constructed request matches the prior art for a fixed input")
    func requestShape() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 200,
            data: Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)
        )

        _ = try await GeminiAdapter(apiKey: "secret-key")
            .process(text: "hello", systemPrompt: "be brief")

        let request = try #require(StubURLProtocol.lastRequest)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "generativelanguage.googleapis.com")
        #expect(components.path == "/v1beta/models/gemini-3.1-flash-lite:generateContent")
        #expect(components.queryItems?.first(where: { $0.name == "key" })?.value == "secret-key")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = jsonBody(StubURLProtocol.lastBody)
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.first?["role"] as? String == "user")
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "hello")
        let genConfig = try #require(body["generationConfig"] as? [String: Any])
        #expect(genConfig["maxOutputTokens"] as? Int == 1024)
        let systemInstruction = try #require(body["systemInstruction"] as? [String: Any])
        let sysParts = try #require(systemInstruction["parts"] as? [[String: Any]])
        #expect(sysParts.first?["text"] as? String == "be brief")
    }

    @Test("omits systemInstruction when the system prompt is empty")
    func emptySystemPromptOmitsInstruction() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 200,
            data: Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)
        )

        _ = try await GeminiAdapter(apiKey: "k").process(text: "hello", systemPrompt: "")

        let body = jsonBody(StubURLProtocol.lastBody)
        #expect(body["systemInstruction"] == nil)
    }

    @Test("decodes a representative success response")
    func successDecode() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 200,
            data: Data(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"processed text"}]}}]}"#.utf8)
        )

        let result = try await GeminiAdapter(apiKey: "k").process(text: "x", systemPrompt: "y")
        #expect(result == "processed text")
    }

    @Test("maps an error response to apiError with the API message")
    func errorDecode() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 400,
            data: Data(#"{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}"#.utf8)
        )

        await #expect {
            _ = try await GeminiAdapter(apiKey: "k").process(text: "x", systemPrompt: "y")
        } throws: { error in
            guard case let .apiError(provider, statusCode, message) = error as? CloudAIClientError else { return false }
            return provider == .gemini && statusCode == 400 && message == "API key not valid"
        }
    }
}

// MARK: - OpenRouter

@Suite("OpenRouterAdapter request + decode", .serialized)
final class OpenRouterAdapterTests {
    init() { URLProtocol.registerClass(StubURLProtocol.self) }
    deinit { URLProtocol.unregisterClass(StubURLProtocol.self) }

    @Test("sends the Chat Completions request to OpenRouter")
    func requestShape() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 200,
            data: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        )

        _ = try await OpenRouterAdapter(apiKey: "secret-key")
            .process(text: "hello", systemPrompt: "be brief")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")

        let body = jsonBody(StubURLProtocol.lastBody)
        #expect(body["model"] as? String == "openai/gpt-4o-mini")
        #expect(body["max_tokens"] as? Int == 1024)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == "be brief")
        #expect(messages.last?["role"] as? String == "user")
        #expect(messages.last?["content"] as? String == "hello")
    }

    @Test("decodes a representative success response")
    func successDecode() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 200,
            data: Data(#"{"id":"gen-1","choices":[{"message":{"role":"assistant","content":"processed text"}}]}"#.utf8)
        )

        let result = try await OpenRouterAdapter(apiKey: "k").process(text: "x", systemPrompt: "y")
        #expect(result == "processed text")
    }

    @Test("reports an error response under OpenRouter, not OpenAI")
    func errorDecode() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            statusCode: 402,
            data: Data(#"{"error":{"code":402,"message":"Insufficient credits"}}"#.utf8)
        )

        await #expect {
            _ = try await OpenRouterAdapter(apiKey: "k").process(text: "x", systemPrompt: "y")
        } throws: { error in
            guard case let .apiError(provider, statusCode, message) = error as? CloudAIClientError else { return false }
            return provider == .openrouter && statusCode == 402 && message == "Insufficient credits"
        }
    }
}
