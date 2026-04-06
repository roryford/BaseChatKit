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

// MARK: - KoboldCpp Backend SSE Tests

@Suite("KoboldCpp Backend SSE E2E", .serialized)
struct KoboldCppBackendSSETests {

    // MARK: - Helpers

    /// Each call gets a unique base URL to avoid stub collisions in parallel test runs.
    private func makeConfiguredBackend() -> (KoboldCppBackend, URL, URL) {
        let session = makeMockSession()
        let backend = KoboldCppBackend(urlSession: session)
        let baseURL = URL(string: "http://kobold-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "koboldcpp")
        let generateURL = baseURL.appendingPathComponent("api/v1/generate")
        let contextURL = baseURL.appendingPathComponent("api/v1/config/max_context_length")
        return (backend, generateURL, contextURL)
    }

    private func loadBackend(_ backend: KoboldCppBackend, contextURL: URL) async throws {
        MockURLProtocol.stub(
            url: contextURL,
            response: .immediate(data: Data(#"{"value":4096}"#.utf8), statusCode: 200)
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
    }

    // MARK: - Streaming

    @Test func streaming_yieldsTokens() async throws {
        let (backend, generateURL, contextURL) = makeConfiguredBackend()

        try await loadBackend(backend, contextURL: contextURL)

        let chunks: [Data] = [
            sseData(#"{"token":"Hello"}"#),
            sseData(#"{"token":" world"}"#),
            sseData(#"{"token":"!"}"#),
            sseDone,
        ]

        MockURLProtocol.stub(url: generateURL, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(
            prompt: "### Instruction:\nSay hello\n### Response:\n",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await event in stream {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        #expect(tokens == ["Hello", " world", "!"])
    }

    // MARK: - Non-streaming Fallback

    @Test func nonStreaming_fallback() async throws {
        // Verify that the non-streaming response format can be parsed.
        // The actual backend always uses SSE streaming, but this tests the
        // extractNonStreamingText helper for potential future use.
        let json = #"{"results":[{"text":"Hello world"}]}"#
        let text = KoboldCppBackend.extractNonStreamingText(from: json)
        #expect(text == "Hello world")
    }

    @Test func nonStreaming_multipleResults_extractsFirst() async throws {
        let json = #"{"results":[{"text":"first"},{"text":"second"}]}"#
        let text = KoboldCppBackend.extractNonStreamingText(from: json)
        #expect(text == "first")
    }

    @Test func nonStreaming_malformedJSON_returnsNil() async throws {
        let text = KoboldCppBackend.extractNonStreamingText(from: "not json")
        #expect(text == nil)
    }

    /// Extracts the HTTP body from a captured request, handling both httpBody and httpBodyStream.
    private func extractBody(from request: URLRequest?) throws -> Data {
        guard let request else {
            Issue.record("No captured request")
            return Data()
        }
        if let body = request.httpBody { return body }
        if let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { data.append(buffer, count: read) }
            }
            stream.close()
            return data
        }
        Issue.record("Request has neither httpBody nor httpBodyStream")
        return Data()
    }

    // MARK: - Grammar Constraint in Request

    @Test func grammarConstraint_includedInRequest() async throws {
        let (backend, generateURL, contextURL) = makeConfiguredBackend()

        try await loadBackend(backend, contextURL: contextURL)

        let gbnf = #"root ::= "yes" | "no""#
        backend.grammarConstraint = gbnf

        let chunks: [Data] = [
            sseData(#"{"token":"yes"}"#),
            sseDone,
        ]

        MockURLProtocol.stub(url: generateURL, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(
            prompt: "Is the sky blue?",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        for try await _ in stream { }

        // Verify the grammar field was included in the POST body
        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains(generateURL.absoluteString) == true
        })
        let body = try extractBody(from: captured)

        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let grammarValue = try #require(json["grammar"] as? String)
        #expect(grammarValue == gbnf)
    }

    @Test func noGrammarConstraint_omittedFromRequest() async throws {
        let (backend, generateURL, contextURL) = makeConfiguredBackend()

        try await loadBackend(backend, contextURL: contextURL)

        let chunks: [Data] = [
            sseData(#"{"token":"ok"}"#),
            sseDone,
        ]

        MockURLProtocol.stub(url: generateURL, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        for try await _ in stream { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains(generateURL.absoluteString) == true
        })
        let body = try extractBody(from: captured)

        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["grammar"] == nil, "Grammar field should not be present when grammarConstraint is nil")
    }

    // MARK: - Error Responses

    @Test func serverError_throws() async throws {
        let (backend, generateURL, contextURL) = makeConfiguredBackend()

        try await loadBackend(backend, contextURL: contextURL)

        let body = Data(#"{"error":"model not loaded"}"#.utf8)
        MockURLProtocol.stub(url: generateURL, response: .immediate(data: body, statusCode: 500))

        let stream = try backend.generate(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        do {
            for try await _ in stream {}
            Issue.record("Expected a server error")
        } catch let error as CloudBackendError {
            switch error {
            case .serverError(let statusCode, _):
                #expect(statusCode == 500)
            default:
                Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test func rateLimitError() async throws {
        let (backend, generateURL, contextURL) = makeConfiguredBackend()

        try await loadBackend(backend, contextURL: contextURL)

        let body = Data(#"{"error":"too many requests"}"#.utf8)
        MockURLProtocol.stub(
            url: generateURL,
            response: .immediate(data: body, statusCode: 429, headers: ["Retry-After": "0"])
        )

        let stream = try backend.generate(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        do {
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
        let (backend, generateURL, contextURL) = makeConfiguredBackend()

        try await loadBackend(backend, contextURL: contextURL)

        let chunks: [Data] = [
            sseData("not valid json"),
            sseData(#"{"token":"OK"}"#),
            sseDone,
        ]

        MockURLProtocol.stub(url: generateURL, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await event in stream {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        #expect(tokens == ["OK"])
    }

    // MARK: - Payload Handler

    @Test func payloadHandler_extractsTokenCorrectly() {
        let handler = KoboldCppBackend.payloadHandler
        #expect(handler.extractToken(from: #"{"token":"hello"}"#) == "hello")
        #expect(handler.extractToken(from: #"{"other":"data"}"#) == nil)
        #expect(handler.extractToken(from: "invalid") == nil)
    }

    @Test func payloadHandler_usageAlwaysNil() {
        let handler = KoboldCppBackend.payloadHandler
        #expect(handler.extractUsage(from: #"{"token":"hello"}"#) == nil)
    }

    @Test func payloadHandler_isStreamEnd_alwaysFalse() {
        let handler = KoboldCppBackend.payloadHandler
        #expect(handler.isStreamEnd(#"{"token":"hello"}"#) == false)
    }
}
