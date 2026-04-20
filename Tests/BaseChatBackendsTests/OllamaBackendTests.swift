import Testing
import XCTest
import Foundation
@testable import BaseChatBackends
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

// MARK: - Helpers

/// Creates a `URLSession` whose traffic is intercepted by `MockURLProtocol`.
private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Formats a single Ollama NDJSON line.
private func ndjsonLine(_ json: String) -> Data {
    Data("\(json)\n".utf8)
}

// MARK: - OllamaBackend Tests

@Suite("OllamaBackend", .serialized)
struct OllamaBackendTests {

    // MARK: - Setup helpers

    private func makeConfiguredBackend() -> (OllamaBackend, URL) {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.2")
        return (backend, baseURL.appendingPathComponent("api/chat"))
    }

    private func loadBackend(_ backend: OllamaBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    // MARK: - Init & State

    @Test func init_defaultState() {
        let backend = OllamaBackend()
        #expect(!backend.isModelLoaded)
        #expect(!backend.isGenerating)
    }

    @Test func loadModel_withoutConfigure_throws() async {
        let backend = OllamaBackend()
        do {
            try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
            Issue.record("Expected throw when no base URL configured")
        } catch {
            // expected
        }
    }

    @Test func configure_thenLoad_succeeds() async throws {
        let (backend, _) = makeConfiguredBackend()
        try await loadBackend(backend)
        #expect(backend.isModelLoaded)
    }

    @Test func unloadModel_clearsState() async throws {
        let (backend, _) = makeConfiguredBackend()
        try await loadBackend(backend)
        backend.unloadModel()
        #expect(!backend.isModelLoaded)
        #expect(!backend.isGenerating)
    }

    @Test func generate_withoutLoad_throws() {
        let backend = OllamaBackend()
        #expect(throws: (any Error).self) {
            try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        }
    }

    // MARK: - Capabilities

    @Test func capabilities_supportsExpectedParameters() {
        let caps = OllamaBackend().capabilities
        #expect(caps.supportedParameters.contains(.temperature))
        #expect(caps.supportedParameters.contains(.topP))
        #expect(caps.supportedParameters.contains(.topK))
        #expect(caps.supportedParameters.contains(.repeatPenalty))
    }

    @Test func capabilities_supportsSystemPrompt() {
        #expect(OllamaBackend().capabilities.supportsSystemPrompt)
    }

    @Test func capabilities_noPromptTemplate() {
        #expect(!OllamaBackend().capabilities.requiresPromptTemplate)
    }

    // MARK: - Streaming

    @Test func streaming_yieldsTokens() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"Hello"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":" world"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"!"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "Say hello", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        #expect(tokens == ["Hello", " world", "!"])
    }

    @Test func streaming_withSystemPrompt_includesInMessages() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: "You are a test bot.", config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.first?["role"] == "system")
        #expect(messages.first?["content"] == "You are a test bot.")
    }

    /// Ollama's final NDJSON chunk can carry several `done_reason` values —
    /// `stop` (normal termination), `length` (hit `num_predict`), `load` /
    /// `unload` (server-side model swap). None of these should produce an
    /// extra `.token` event because their `message.content` is empty. This
    /// fixture pins the current behaviour so future wiring of `done_reason`
    /// into `GenerationStream.phase` has a green baseline to diff against.
    /// Closes #507.
    @Test func streaming_doneReasonVariants_notYielded() async throws {
        let variants = ["length", "load", "unload"]
        for reason in variants {
            let (backend, chatURL) = makeConfiguredBackend()
            try await loadBackend(backend)

            let chunks: [Data] = [
                ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"\#(reason)","total_duration":42000000,"eval_count":128}"#),
            ]
            MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            var tokens: [String] = []
            for try await event in stream.events {
                if case .token(let t) = event { tokens.append(t) }
            }
            #expect(tokens.isEmpty, "done_reason=\(reason) should produce no .token events (got \(tokens))")
        }
    }

    @Test func streaming_doneChunk_notYielded() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // "done":true chunk should produce no token.
        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"Hi"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","total_duration":1234}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events { if case .token(let text) = event { tokens.append(text) } }

        #expect(tokens == ["Hi"])
    }

    // MARK: - Chunk Boundary

    /// Under real network conditions, `URLSession.AsyncBytes` will deliver a
    /// JSON object split across TCP reads — a partial payload followed by the
    /// rest on the next chunk, with the newline landing on the second read.
    /// Every other streaming test delivers one complete JSON object per chunk,
    /// so the byte-buffer path is otherwise untested for splits. A refactor
    /// that swaps the per-byte reader for a chunked reader must still assemble
    /// pre-newline bytes with post-newline bytes before JSON parse.
    /// Closes #509.
    @Test func streaming_midLineSplit_reassembles() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // Split a single JSON object across two chunks. The newline arrives
        // on the second chunk so the parser must join the two buffers.
        let chunks: [Data] = [
            Data(#"{"model":"llama3.2","message":{"role":"assistant","content":"Hel"#.utf8),
            Data(#"lo"},"done":false}"#.utf8) + Data("\n".utf8),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }

        #expect(tokens == ["Hello"], "mid-line split must be reassembled before JSON parse")
    }

    @Test func streaming_malformedLine_skipped() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine("not valid json"),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"OK"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events { if case .token(let text) = event { tokens.append(text) } }

        #expect(tokens == ["OK"])
    }

    // MARK: - Error Responses

    @Test func serverError_404_modelNotFound() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let body = Data(#"{"error":"model not found"}"#.utf8)
        MockURLProtocol.stub(url: chatURL, response: .immediate(data: body, statusCode: 404))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
            switch error {
            case .serverError(let code, _): #expect(code == 404)
            default: Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test func serverError_500_throws() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        MockURLProtocol.stub(url: chatURL, response: .immediate(data: Data(), statusCode: 500))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
            switch error {
            case .serverError(let code, _): #expect(code == 500)
            default: Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test func rateLimitError_429() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        MockURLProtocol.stub(url: chatURL, response: .immediate(
            data: Data(),
            statusCode: 429,
            headers: ["Retry-After": "0"]
        ))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream.events {}
            Issue.record("Expected rateLimited error")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
            switch error {
            case .rateLimited: break
            default: Issue.record("Expected rateLimited, got \(error)")
            }
        }
    }

    /// `OllamaBackend.checkStatusCode` parses `Retry-After` via
    /// `TimeInterval(init)`, which accepts integer seconds but silently fails
    /// on the RFC 7231 HTTP-date form (`Wed, 21 Oct 2026 07:28:00 GMT`). Pin
    /// both: integer parses to a retry hint, HTTP-date currently becomes `nil`
    /// so retry policy loses the hint. Once a date parser lands, flip the
    /// HTTP-date assertion.
    ///
    /// We set `maxRetries: 0` on both sub-cases so the integer-seconds variant
    /// doesn't actually sleep 30s waiting to retry.
    /// Closes #512.
    @Test func rateLimitError_429_retryAfterVariants() async throws {
        // Integer seconds — parses as expected.
        do {
            let (backend, chatURL) = makeConfiguredBackend()
            backend.retryStrategy = ExponentialBackoffStrategy(maxRetries: 0)
            try await loadBackend(backend)

            MockURLProtocol.stub(url: chatURL, response: .immediate(
                data: Data(),
                statusCode: 429,
                headers: ["Retry-After": "30"]
            ))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            do {
                for try await _ in stream.events {}
                Issue.record("Expected rateLimited error for integer Retry-After")
            } catch {
                guard let error = extractCloudError(error) else {
                    Issue.record("Expected CloudBackendError, got \(error)")
                    return
                }
                switch error {
                case .rateLimited(let retryAfter):
                    #expect(retryAfter == 30, "integer Retry-After must parse to 30s (got \(String(describing: retryAfter)))")
                default:
                    Issue.record("Expected rateLimited, got \(error)")
                }
            }
        }

        // HTTP-date form — currently unsupported by TimeInterval(init).
        // Documented behaviour: retryAfter is nil. Flip when a date parser exists.
        do {
            let (backend, chatURL) = makeConfiguredBackend()
            backend.retryStrategy = ExponentialBackoffStrategy(maxRetries: 0)
            try await loadBackend(backend)

            MockURLProtocol.stub(url: chatURL, response: .immediate(
                data: Data(),
                statusCode: 429,
                headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]
            ))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            do {
                for try await _ in stream.events {}
                Issue.record("Expected rateLimited error for HTTP-date Retry-After")
            } catch {
                guard let error = extractCloudError(error) else {
                    Issue.record("Expected CloudBackendError, got \(error)")
                    return
                }
                switch error {
                case .rateLimited(let retryAfter):
                    // Current behaviour: HTTP-date parse falls through to nil.
                    #expect(retryAfter == nil, "HTTP-date Retry-After is currently unparsed (hint lost)")
                default:
                    Issue.record("Expected rateLimited, got \(error)")
                }
            }
        }
    }

    // MARK: - Usage Stats (ignored)

    /// The Ollama final chunk carries per-call usage — `prompt_eval_count`,
    /// `eval_count`, `eval_duration`, `total_duration`. The
    /// ``OllamaPayloadHandler.extractUsage`` hook returns `nil` today, so
    /// usage never flows into a `TokenUsageProvider`. This fixture pins that
    /// "ignored" contract: once usage wiring lands, flip the assertion.
    /// Closes #508.
    @Test func payloadHandler_extractUsage_returnsNil_evenWithUsageFields() {
        let handler = OllamaBackend.OllamaPayloadHandler()
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":15,"eval_count":42,"eval_duration":1500000000,"total_duration":2200000000}"#
        // Current contract: usage is not surfaced. Flip to a concrete expectation
        // once `TokenUsageProvider` wiring lands in OllamaBackend.
        #expect(handler.extractUsage(from: json) == nil)
    }

    // MARK: - /api/generate Endpoint Shape

    /// `/api/generate` (non-chat) uses top-level `response` instead of
    /// `message.content`. Older Ollama clients and third-party proxies still
    /// speak it. Today's `parseLine` normalises both shapes, so `extractToken`
    /// DOES surface `response`. This differs from the original issue #510
    /// premise (which assumed `response` was dropped) — the backend gained
    /// `/api/generate` support alongside #487 thinking-field handling. Pin
    /// the current normalised behaviour so any regression that re-breaks
    /// /api/generate is caught.
    /// Closes #510.
    @Test func extractToken_generateEndpointShape_surfacesResponse() {
        // Streaming intermediate chunks — `response` surfaces as a token.
        let midLine = #"{"model":"llama3.2","response":"Hello","done":false}"#
        #expect(OllamaBackend.extractToken(from: midLine) == "Hello")

        let midLine2 = #"{"model":"llama3.2","response":" world","done":false}"#
        #expect(OllamaBackend.extractToken(from: midLine2) == " world")

        // Final chunk — `done:true` suppresses token emission regardless of shape.
        let doneLine = #"{"model":"llama3.2","response":"","done":true,"done_reason":"stop"}"#
        #expect(OllamaBackend.extractToken(from: doneLine) == nil)
    }

    // MARK: - SSE Stream Limits (NDJSON path)

    /// `parseResponseStream` enforces the same `SSEStreamLimits` caps as the
    /// SSE path — `maxTotalBytes`, `maxEventBytes`, `maxEventsPerSecond`.
    /// Three drivers in one test, each with a dedicated backend so per-backend
    /// limit overrides don't leak. A future change to the counters or
    /// `noteEventYielded()` gating would otherwise silently stop enforcing
    /// caps against a malicious Ollama-compatible server.
    /// Closes #511.
    @Test func streaming_sseStreamLimits_enforced() async throws {
        // --- streamTooLarge: total bytes exceed maxTotalBytes ---
        do {
            let (backend, chatURL) = makeConfiguredBackend()
            backend.sseStreamLimits = SSEStreamLimits(
                maxEventBytes: 1_000_000,
                maxTotalBytes: 100,
                maxEventsPerSecond: 5_000
            )
            try await loadBackend(backend)

            // ~200 bytes of valid NDJSON — comfortably over maxTotalBytes=100.
            let line = #"{"model":"llama3.2","message":{"role":"assistant","content":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"},"done":false}"#
            let chunks: [Data] = [ndjsonLine(line)]
            MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            do {
                for try await _ in stream.events {}
                Issue.record("Expected SSEStreamError.streamTooLarge")
            } catch let error as SSEStreamError {
                switch error {
                case .streamTooLarge: break
                default: Issue.record("Expected streamTooLarge, got \(error)")
                }
            } catch {
                // The error may be wrapped; accept any throw but prefer SSEStreamError.
                Issue.record("Expected SSEStreamError.streamTooLarge, got \(error)")
            }
        }

        // --- eventTooLarge: single line exceeds maxEventBytes before newline ---
        do {
            let (backend, chatURL) = makeConfiguredBackend()
            backend.sseStreamLimits = SSEStreamLimits(
                maxEventBytes: 50,
                maxTotalBytes: 10_000_000,
                maxEventsPerSecond: 5_000
            )
            try await loadBackend(backend)

            // A single JSON line longer than 50 bytes with no newline until the end.
            let oversizeLine = #"{"model":"llama3.2","message":{"role":"assistant","content":"overflow-content-goes-well-beyond-fifty-bytes"},"done":false}"#
            let chunks: [Data] = [Data(oversizeLine.utf8)] // no newline
            MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            do {
                for try await _ in stream.events {}
                Issue.record("Expected SSEStreamError.eventTooLarge")
            } catch let error as SSEStreamError {
                switch error {
                case .eventTooLarge: break
                default: Issue.record("Expected eventTooLarge, got \(error)")
                }
            } catch {
                Issue.record("Expected SSEStreamError.eventTooLarge, got \(error)")
            }
        }

        // --- eventRateExceeded: more than maxEventsPerSecond within 1s window ---
        do {
            let (backend, chatURL) = makeConfiguredBackend()
            backend.sseStreamLimits = SSEStreamLimits(
                maxEventBytes: 1_000_000,
                maxTotalBytes: 10_000_000,
                maxEventsPerSecond: 3
            )
            try await loadBackend(backend)

            // Five rapid content events — well above the cap of 3/s — delivered
            // all at once so they land inside the same rate window.
            var chunks: [Data] = []
            for i in 0..<5 {
                chunks.append(ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"t\#(i)"},"done":false}"#))
            }
            chunks.append(ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#))
            MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            do {
                for try await _ in stream.events {}
                Issue.record("Expected SSEStreamError.eventRateExceeded")
            } catch let error as SSEStreamError {
                switch error {
                case .eventRateExceeded: break
                default: Issue.record("Expected eventRateExceeded, got \(error)")
                }
            } catch {
                Issue.record("Expected SSEStreamError.eventRateExceeded, got \(error)")
            }
        }
    }

    // MARK: - Request Body

    @Test func requestBody_containsModelAndMessages() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"hi"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "Hello there", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "llama3.2")
        #expect(json["stream"] as? Bool == true)

        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.last?["role"] == "user")
        #expect(messages.last?["content"] == "Hello there")
    }

    // MARK: - Conversation History

    @Test func conversationHistory_usedInMessages() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        backend.setConversationHistory([
            (role: "user", content: "First message"),
            (role: "assistant", content: "First reply"),
        ])

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "ignored when history set", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])

        #expect(messages.count == 2)
        #expect(messages[0]["content"] == "First message")
        #expect(messages[1]["content"] == "First reply")
    }

    /// Network-mocked unit test: verifies that every turn passed to
    /// `setConversationHistory` appears in the outgoing `messages` array in
    /// order. The coverage gap this closes: prior tests only set 2-turn history
    /// and didn't assert positional correctness of each entry.
    ///
    /// Sabotage check: deleting the `setConversationHistory` call below causes
    /// the messages count assertion to fail (backend falls back to the bare
    /// prompt-only message), confirming the assertion is load-bearing.
    @Test func generate_forwardsFullConversationHistoryInRequestBody() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        backend.setConversationHistory([
            (role: "user",      content: "What is 2+2?"),
            (role: "assistant", content: "4."),
            (role: "user",      content: "And 3+3?"),
        ])

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"6"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "And 3+3?", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])

        // All three history turns must be forwarded in order.
        #expect(messages.count == 3)
        #expect(messages[0]["role"] == "user")
        #expect(messages[0]["content"] == "What is 2+2?")
        #expect(messages[1]["role"] == "assistant")
        #expect(messages[1]["content"] == "4.")
        // The final turn must be the last user message with exact content.
        #expect(messages[2]["role"] == "user")
        #expect(messages[2]["content"] == "And 3+3?")
    }

    // MARK: - stopGeneration

    @Test func stopGeneration_setsIsGeneratingFalse() async throws {
        let (backend, _) = makeConfiguredBackend()
        try await loadBackend(backend)
        backend.stopGeneration()
        #expect(!backend.isGenerating)
    }

    // MARK: - NDJSON Parsing

    @Test func extractToken_parsesContent() {
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":"Hello"},"done":false}"#
        #expect(OllamaBackend.extractToken(from: json) == "Hello")
    }

    @Test func extractToken_skipsEmptyContent() {
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":false}"#
        #expect(OllamaBackend.extractToken(from: json) == nil)
    }

    @Test func extractToken_skipsDoneChunk() {
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#
        #expect(OllamaBackend.extractToken(from: json) == nil)
    }

    @Test func extractToken_malformedJSON_returnsNil() {
        #expect(OllamaBackend.extractToken(from: "not json") == nil)
    }

    // MARK: - Thinking field (issue #487)

    /// Reasoning models (qwen3, qwen3.5:4b, deepseek-r1) emit chain-of-thought in
    /// a separate `thinking` field on the `/api/chat` endpoint. The backend
    /// must surface these as `.thinkingToken` events and close with
    /// `.thinkingComplete` when thinking transitions back to empty.
    @Test func streaming_chatEndpoint_thinkingFieldEmitsThinkingEvents() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"Reasoning step 1","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"","content":"answer"},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        // Ordering: .thinkingToken → .thinkingComplete → .token
        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        let completeCount = events.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }.count

        #expect(thinkingTokens == ["Reasoning step 1"])
        #expect(tokens == ["answer"])
        #expect(completeCount == 1)

        // Verify event ordering: thinkingToken precedes thinkingComplete precedes token.
        var sawThinking = false
        var sawComplete = false
        for event in events {
            switch event {
            case .thinkingToken:
                #expect(!sawComplete, "thinkingToken must precede thinkingComplete")
                sawThinking = true
            case .thinkingComplete:
                #expect(sawThinking, "thinkingComplete must follow at least one thinkingToken")
                sawComplete = true
            case .token:
                #expect(sawComplete, "visible token must follow thinkingComplete")
            default: break
            }
        }
    }

    /// `/api/generate` surfaces reasoning at top-level `thinking` rather than
    /// under `message.thinking`. The backend must handle both endpoint shapes.
    @Test func streaming_generateEndpoint_topLevelThinkingEmitsThinkingEvents() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"response":"","thinking":"Thinking...","done":false}"#),
            ndjsonLine(#"{"response":"answer","thinking":"","done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        let completeCount = events.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }.count

        #expect(thinkingTokens == ["Thinking..."])
        #expect(tokens == ["answer"])
        #expect(completeCount == 1)
    }

    /// Actual #487 repro: reasoning model exhausts `num_predict` entirely in
    /// `<think>` and Ollama returns a single line with `done:true`,
    /// `done_reason:length`, non-empty `thinking`, and empty `response`.
    /// Previously dropped on the floor — users saw a blank message.
    @Test func streaming_thinkingOnly_thenDone_flushesThinkingComplete() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"response":"","thinking":"entire reasoning","done":true,"done_reason":"length"}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let completeCount = events.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }.count

        #expect(thinkingTokens == ["entire reasoning"])
        #expect(completeCount == 1)
    }

    /// `config.maxThinkingTokens` caps reasoning emission so a runaway
    /// reasoning model doesn't flood the UI. Lines with thinking beyond the
    /// cap are dropped; visible content still flows through.
    @Test func streaming_maxThinkingTokens_capsEmission() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // 5 thinking-bearing lines, then transition to visible answer.
        let chunks: [Data] = [
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t1","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t2","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t3","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t4","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t5","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"","content":"answer"},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxThinkingTokens = 2
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }

        // Only the first 2 thinking chunks emit; t3, t4, t5 are dropped.
        #expect(thinkingTokens == ["t1", "t2"])
        #expect(tokens == ["answer"])
    }

    // MARK: - NDJSON parseLine

    @Test func parseLine_chatThinking() {
        let json = #"{"message":{"role":"assistant","thinking":"reasoning","content":"hi"},"done":false}"#
        let parsed = try? #require(OllamaBackend.parseLine(json))
        #expect(parsed?.thinking == "reasoning")
        #expect(parsed?.content == "hi")
        #expect(parsed?.done == false)
    }

    @Test func parseLine_generateTopLevelThinking() {
        let json = #"{"response":"answer","thinking":"reasoning","done":true}"#
        let parsed = try? #require(OllamaBackend.parseLine(json))
        #expect(parsed?.thinking == "reasoning")
        #expect(parsed?.content == "answer")
        #expect(parsed?.done == true)
    }

    @Test func extractThinking_returnsThinkingField() {
        let json = #"{"response":"","thinking":"reasoning","done":false}"#
        #expect(OllamaBackend.extractThinking(from: json) == "reasoning")
    }

    @Test func extractThinking_emptyThinking_returnsNil() {
        let json = #"{"response":"hi","thinking":"","done":false}"#
        #expect(OllamaBackend.extractThinking(from: json) == nil)
    }

    @Test func extractThinking_noThinkingField_returnsNil() {
        let json = #"{"message":{"role":"assistant","content":"hi"},"done":false}"#
        #expect(OllamaBackend.extractThinking(from: json) == nil)
    }

    // MARK: - num_predict Budget (thinking + visible)

    /// Regression for the gemma4:e4b empty-response bug: Ollama counts
    /// chain-of-thought tokens against `num_predict`, so a single budget of
    /// `maxOutputTokens` was being fully consumed inside `<think>` on thinking
    /// models, leaving zero budget for visible output. The fix splits the
    /// server-side budget into `visibleBudget + thinkingBudget` and re-caps
    /// visible output client-side in `parseResponseStream`.
    ///
    /// Sabotage check (verified locally): reverting the production change to
    /// `"num_predict": config.maxOutputTokens ?? 2048` makes this test fail
    /// with `num_predict == 100` instead of `150`.
    @Test func generate_numPredict_equalsVisiblePlusThinkingBudget() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxOutputTokens = 100
        config.maxThinkingTokens = 50
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        let numPredict = try #require(options["num_predict"] as? Int)
        #expect(numPredict == 150)
    }

    /// When both caps are `nil` (default `GenerationConfig()`), each side
    /// defaults to 2048, so `num_predict` must land on `4096`. Pins the
    /// default-default arithmetic so a future refactor doesn't silently
    /// shift the server-side ceiling.
    @Test func generate_numPredict_bothCapsNil_defaultsTo4096() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        // GenerationConfig() ships maxOutputTokens = 2048 by default. Null it
        // out so we exercise the `?? 2048` fallback on both sides.
        var config = GenerationConfig()
        config.maxOutputTokens = nil
        config.maxThinkingTokens = nil
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        let numPredict = try #require(options["num_predict"] as? Int)
        #expect(numPredict == 4096)
    }

    /// Because we doubled the server-side budget, visible output must be
    /// re-capped client-side. This fixture emits 5 content lines but sets
    /// `maxOutputTokens = 3`; the consumer must see exactly 3 `.token`
    /// events, then the stream terminates cleanly (no error thrown, no
    /// `.thinkingComplete` because no thinking was ever emitted).
    ///
    /// Sabotage check (verified locally): deleting the `continuation.finish();
    /// return` guard in `parseResponseStream` makes this test fail with
    /// tokens.count == 5.
    ///
    /// Known limitation (documented on the PR): `visibleTokenCount` counts
    /// NDJSON lines, not true tokens. A follow-up will switch to Ollama's
    /// `eval_count` field for exact accounting.
    @Test func streaming_visibleCap_terminatesStreamCleanly() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"a"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"b"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"c"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"d"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"e"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxOutputTokens = 3
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)

        var tokens: [String] = []
        var sawThinkingComplete = false
        for try await event in stream.events {
            switch event {
            case .token(let t): tokens.append(t)
            case .thinkingComplete: sawThinkingComplete = true
            default: break
            }
        }

        #expect(tokens == ["a", "b", "c"])
        #expect(!sawThinkingComplete, "no thinking was emitted so no .thinkingComplete should fire")
    }
}

// MARK: - OllamaModelListService Tests

@Suite("OllamaModelListService", .serialized)
struct OllamaModelListServiceTests {

    private func makeService() -> (OllamaModelListService, URL) {
        let session = makeMockSession()
        let service = OllamaModelListService(urlSession: session)
        let baseURL = URL(string: "http://ollama-models-\(UUID().uuidString).test")!
        return (service, baseURL)
    }

    @Test func fetchModels_parsesResponse() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        let response = """
        {"models":[
            {"name":"llama3.2:8b","size":5368709120},
            {"name":"mistral:7b","size":4294967296},
            {"name":"phi3:mini","size":2147483648}
        ]}
        """
        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(response.utf8), statusCode: 200))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        let models = try await service.fetchModels(from: baseURL)

        #expect(models.count == 3)
        // Should be sorted alphabetically.
        #expect(models[0].name == "llama3.2:8b")
        #expect(models[1].name == "mistral:7b")
        #expect(models[2].name == "phi3:mini")
    }

    @Test func fetchModels_extractsQuantization() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        let response = #"{"models":[{"name":"llama3.2:8b-q4_0","size":4294967296}]}"#
        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(response.utf8), statusCode: 200))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        let models = try await service.fetchModels(from: baseURL)
        #expect(models.first?.quantization == "8b-q4_0")
    }

    @Test func fetchModels_emptyList_returnsEmpty() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(#"{"models":[]}"#.utf8), statusCode: 200))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        let models = try await service.fetchModels(from: baseURL)
        #expect(models.isEmpty)
    }

    @Test func fetchModels_serverError_throws() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(), statusCode: 503))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        do {
            _ = try await service.fetchModels(from: baseURL)
            Issue.record("Expected error on 503 response")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
            switch error {
            case .serverError(let code, _): #expect(code == 503)
            default: Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test func fetchModels_networkError_throws() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .error(URLError(.notConnectedToInternet)))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        do {
            _ = try await service.fetchModels(from: baseURL)
            Issue.record("Expected network error")
        } catch {
            // expected
        }
    }
}

// MARK: - Backend Contract

/// XCTestCase subclass for BackendContractChecks (which uses XCTest assertions).
final class OllamaBackendContractTests: XCTestCase {
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { OllamaBackend() }
    }
}

// MARK: - Body Extraction Helper

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
