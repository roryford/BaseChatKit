import Foundation

/// Parses Server-Sent Events (SSE) from a byte stream.
///
/// SSE format:
/// ```
/// data: {"content": "token"}
///
/// data: [DONE]
/// ```
///
/// Used by both OpenAI-compatible and Claude backends to stream tokens
/// from cloud API responses.
/// Interprets SSE JSON payloads for a specific API format.
///
/// Each cloud backend provides its own implementation to extract tokens,
/// usage, stream-end signals, and errors from the provider's JSON format.
public protocol SSEPayloadHandler: Sendable {
    /// Extracts a text token from a JSON payload, or `nil` if not a token event.
    func extractToken(from payload: String) -> String?

    /// Extracts token usage from a JSON payload, or `nil` if not a usage event.
    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)?

    /// Returns `true` if the payload signals end of stream.
    func isStreamEnd(_ payload: String) -> Bool

    /// Extracts an error from a JSON payload, or `nil` if not an error event.
    func extractStreamError(from payload: String) -> Error?
}

public struct SSEStreamParser {

    /// Parses an `AsyncSequence` of bytes into an `AsyncThrowingStream` of SSE data lines.
    ///
    /// Yields the payload of each `data:` line (with the prefix stripped).
    /// Stops when the stream ends or when `[DONE]` is received.
    public static func parse<S: AsyncSequence & Sendable>(
        bytes: S
    ) -> AsyncThrowingStream<String, Error> where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var byteBuffer = Data()
                var iterator = bytes.makeAsyncIterator()

                do {
                    while let byte = try await iterator.next() {
                        if Task.isCancelled { break }

                        if byte == UInt8(ascii: "\n") {
                            // Decode accumulated bytes as UTF-8.
                            let line: String
                            if let decoded = String(data: byteBuffer, encoding: .utf8) {
                                line = decoded.trimmingCharacters(in: .whitespaces)
                            } else {
                                // Skip lines with invalid UTF-8 rather than crash.
                                byteBuffer.removeAll(keepingCapacity: true)
                                continue
                            }
                            byteBuffer.removeAll(keepingCapacity: true)

                            if line.isEmpty { continue }

                            if line.hasPrefix("data:") {
                                let payload = String(line.dropFirst(5))
                                    .trimmingCharacters(in: .whitespaces)

                                if payload == "[DONE]" {
                                    break
                                }

                                if !payload.isEmpty {
                                    continuation.yield(payload)
                                }
                            }
                            // Ignore event:, id:, retry:, and comment lines
                        } else {
                            byteBuffer.append(byte)
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                        return
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Streams tokens from an HTTP response using an SSE payload handler.
    ///
    /// Combines `parse(bytes:)` with a payload handler to extract tokens,
    /// track usage, detect stream end, and surface errors. This eliminates
    /// the duplicated streaming loop in each cloud backend.
    ///
    /// - Parameters:
    ///   - bytes: The raw byte stream from `URLSession.bytes(for:)`.
    ///   - handler: A payload handler that interprets the provider's JSON format.
    ///   - onUsage: Called when usage information is extracted from a payload.
    /// - Returns: An `AsyncThrowingStream` of text tokens.
    public static func streamEvents<S: AsyncSequence & Sendable>(
        from bytes: S,
        using handler: some SSEPayloadHandler
    ) -> AsyncThrowingStream<GenerationEvent, Error> where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let sseStream = parse(bytes: bytes)
                    for try await payload in sseStream {
                        if Task.isCancelled { break }

                        if let token = handler.extractToken(from: payload) {
                            continuation.yield(.token(token))
                        }

                        if let usage = handler.extractUsage(from: payload),
                           let prompt = usage.promptTokens,
                           let completion = usage.completionTokens {
                            continuation.yield(.usage(prompt: prompt, completion: completion))
                        }

                        if handler.isStreamEnd(payload) {
                            break
                        }

                        if let error = handler.extractStreamError(from: payload) {
                            throw error
                        }
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
