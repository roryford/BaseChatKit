import Testing
import Foundation
@testable import BaseChatBackends
@testable import BaseChatCore
import BaseChatTestSupport

// MARK: - URLSession factory

/// Creates a `URLSession` whose traffic is intercepted by `MockURLProtocol`.
private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Formats a single SSE data line from a JSON string.
private func sseData(_ json: String) -> Data {
    Data("data: \(json)\n\n".utf8)
}

/// Formats the SSE `[DONE]` sentinel.
private let sseDone = Data("data: [DONE]\n\n".utf8)

// MARK: - Claude Backend SSE Tests

@Suite("Claude Backend SSE E2E", .serialized)
struct ClaudeBackendSSETests {

    // MARK: - Helpers

    /// Each call gets a unique base URL to avoid stub collisions in parallel test runs.
    private func makeConfiguredBackend() -> (ClaudeBackend, URL) {
        let session = makeMockSession()
        let backend = ClaudeBackend(urlSession: session)
        let baseURL = URL(string: "https://claude-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "sk-test-key", modelName: "claude-sonnet-4-20250514")
        return (backend, baseURL.appendingPathComponent("v1/messages"))
    }

    private func loadBackend(_ backend: ClaudeBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
    }

    // MARK: - Successful Streaming

    @Test func successfulStreamingResponse() async throws {
        let (backend, url) = makeConfiguredBackend()

        let chunks: [Data] = [
            sseData("""
            {"type":"message_start","message":{"usage":{"input_tokens":25}}}
            """),
            sseData("""
            {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}
            """),
            sseData("""
            {"type":"content_block_delta","delta":{"type":"text_delta","text":" world"}}
            """),
            sseData("""
            {"type":"message_delta","usage":{"output_tokens":2}}
            """),
            sseData("""
            {"type":"message_stop"}
            """),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await token in stream {
            tokens.append(token)
        }

        #expect(tokens == ["Hello", " world"])
    }

    // MARK: - 401 Authentication Error

    @Test func authenticationError401() async throws {
        let (backend, url) = makeConfiguredBackend()

        let body = Data("""
        {"error":{"type":"authentication_error","message":"Invalid API key"}}
        """.utf8)

        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 401))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(
                prompt: "Hi",
                systemPrompt: nil,
                config: GenerationConfig()
            )
            for try await _ in stream {}
            Issue.record("Expected authenticationFailed error")
        } catch let error as CloudBackendError {
            switch error {
            case .authenticationFailed(let provider):
                #expect(provider == "Claude")
            default:
                Issue.record("Expected authenticationFailed, got \(error)")
            }
        }
    }

    // MARK: - 429 Rate Limit

    @Test func rateLimitError429() async throws {
        let (backend, url) = makeConfiguredBackend()

        let body = Data("""
        {"error":{"type":"rate_limit_error","message":"Rate limited"}}
        """.utf8)

        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 429))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(
                prompt: "Hi",
                systemPrompt: nil,
                config: GenerationConfig()
            )
            for try await _ in stream {}
            Issue.record("Expected rateLimited error")
        } catch let error as CloudBackendError {
            switch error {
            case .rateLimited:
                break // expected
            default:
                Issue.record("Expected rateLimited, got \(error)")
            }
        }
    }

    // MARK: - Malformed SSE

    @Test func malformedSSEPayload_skippedGracefully() async throws {
        let (backend, url) = makeConfiguredBackend()

        let chunks: [Data] = [
            sseData("not valid json at all"),
            sseData("""
            {"type":"content_block_delta","delta":{"type":"text_delta","text":"OK"}}
            """),
            sseData("""
            {"type":"message_stop"}
            """),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await token in stream {
            tokens.append(token)
        }

        // Malformed JSON is simply not a token event -- extractToken returns nil.
        // The valid token should still come through.
        #expect(tokens == ["OK"])
    }

    // MARK: - Stream Error Event

    @Test func streamErrorEvent_throwsParseError() async throws {
        let (backend, url) = makeConfiguredBackend()

        let chunks: [Data] = [
            sseData("""
            {"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}
            """),
            sseData("""
            {"type":"error","error":{"type":"overloaded_error","message":"Server overloaded"}}
            """),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        do {
            for try await token in stream {
                tokens.append(token)
            }
            Issue.record("Expected an error from the stream error event")
        } catch let error as CloudBackendError {
            switch error {
            case .parseError(let message):
                #expect(message.contains("overloaded"))
            default:
                Issue.record("Expected parseError, got \(error)")
            }
        }

        // Should have received the partial token before the error
        #expect(tokens == ["partial"])
    }

    // MARK: - Connection Drop (network error)

    @Test func connectionDrop_midStream() async throws {
        let (backend, url) = makeConfiguredBackend()

        MockURLProtocol.stub(
            url: url,
            response: .error(URLError(.networkConnectionLost))
        )

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        do {
            for try await _ in stream {}
            Issue.record("Expected a network error")
        } catch {
            // Any error is acceptable here -- the important thing is we
            // don't hang or crash.
            #expect(error is URLError || error is CloudBackendError)
        }
    }
}

// MARK: - OpenAI Backend SSE Tests

@Suite("OpenAI Backend SSE E2E", .serialized)
struct OpenAIBackendSSETests {

    // MARK: - Helpers

    /// Each call gets a unique base URL to avoid stub collisions in parallel test runs.
    private func makeConfiguredBackend() -> (OpenAIBackend, URL) {
        let session = makeMockSession()
        let backend = OpenAIBackend(urlSession: session)
        let baseURL = URL(string: "https://openai-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "sk-test", modelName: "gpt-4o-mini")
        return (backend, baseURL.appendingPathComponent("v1/chat/completions"))
    }

    private func loadBackend(_ backend: OpenAIBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
    }

    // MARK: - Successful Streaming

    @Test func successfulStreaming() async throws {
        let (backend, url) = makeConfiguredBackend()

        let chunks: [Data] = [
            sseData("""
            {"choices":[{"delta":{"content":"Hello"}}]}
            """),
            sseData("""
            {"choices":[{"delta":{"content":" there"}}]}
            """),
            sseData("""
            {"choices":[{"delta":{}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await token in stream {
            tokens.append(token)
        }

        #expect(tokens == ["Hello", " there"])
    }

    // MARK: - Error Responses

    @Test func authenticationError() async throws {
        let (backend, url) = makeConfiguredBackend()

        let body = Data("""
        {"error":{"message":"Incorrect API key provided"}}
        """.utf8)

        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 401))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(
                prompt: "Hi",
                systemPrompt: nil,
                config: GenerationConfig()
            )
            for try await _ in stream {}
            Issue.record("Expected authenticationFailed error")
        } catch let error as CloudBackendError {
            switch error {
            case .authenticationFailed:
                break // expected
            default:
                Issue.record("Expected authenticationFailed, got \(error)")
            }
        }
    }

    // MARK: - Partial JSON (no content key)

    @Test func partialJSON_noContentKey_yieldsNothing() async throws {
        let (backend, url) = makeConfiguredBackend()

        let chunks: [Data] = [
            // A chunk with role only (first chunk from OpenAI)
            sseData("""
            {"choices":[{"delta":{"role":"assistant"}}]}
            """),
            sseData("""
            {"choices":[{"delta":{"content":"data"}}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await token in stream {
            tokens.append(token)
        }

        // The role-only chunk has no "content", so extractToken returns nil.
        #expect(tokens == ["data"])
    }

    // MARK: - Rate Limit

    @Test func rateLimitError() async throws {
        let (backend, url) = makeConfiguredBackend()

        let body = Data("""
        {"error":{"message":"Rate limit exceeded"}}
        """.utf8)

        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 429))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(
                prompt: "Hi",
                systemPrompt: nil,
                config: GenerationConfig()
            )
            for try await _ in stream {}
            Issue.record("Expected rateLimited error")
        } catch let error as CloudBackendError {
            switch error {
            case .rateLimited:
                break // expected
            default:
                Issue.record("Expected rateLimited, got \(error)")
            }
        }
    }
}

// MARK: - SSEStreamParser Direct Tests

@Suite("SSE Stream Parser E2E")
struct SSEStreamParserE2ETests {

    /// Converts a string into an async byte sequence for the parser.
    private struct ByteSequence: AsyncSequence {
        typealias Element = UInt8
        let data: Data

        struct AsyncIterator: AsyncIteratorProtocol {
            var index: Data.Index
            let data: Data

            mutating func next() async -> UInt8? {
                guard index < data.endIndex else { return nil }
                defer { index = data.index(after: index) }
                return data[index]
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(index: data.startIndex, data: data)
        }
    }

    @Test func parsesMultipleDataLines() async throws {
        let raw = """
        data: {"token":"a"}

        data: {"token":"b"}

        data: [DONE]

        """
        let bytes = ByteSequence(data: Data(raw.utf8))
        let stream = SSEStreamParser.parse(bytes: bytes)

        var payloads: [String] = []
        for try await payload in stream {
            payloads.append(payload)
        }

        #expect(payloads.count == 2)
        #expect(payloads[0].contains("\"a\""))
        #expect(payloads[1].contains("\"b\""))
    }

    @Test func ignoresNonDataLines() async throws {
        let raw = """
        event: message
        id: 123
        retry: 5000
        : this is a comment
        data: {"content":"only-this"}

        data: [DONE]

        """
        let bytes = ByteSequence(data: Data(raw.utf8))
        let stream = SSEStreamParser.parse(bytes: bytes)

        var payloads: [String] = []
        for try await payload in stream {
            payloads.append(payload)
        }

        #expect(payloads.count == 1)
        #expect(payloads[0].contains("only-this"))
    }

    @Test func emptyDataFieldIsSkipped() async throws {
        let raw = """
        data:

        data: {"x":1}

        data: [DONE]

        """
        let bytes = ByteSequence(data: Data(raw.utf8))
        let stream = SSEStreamParser.parse(bytes: bytes)

        var payloads: [String] = []
        for try await payload in stream {
            payloads.append(payload)
        }

        #expect(payloads.count == 1)
    }
}
