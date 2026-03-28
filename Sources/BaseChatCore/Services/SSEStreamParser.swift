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
public struct SSEStreamParser {

    /// Parses an `AsyncSequence` of bytes into an `AsyncThrowingStream` of SSE data lines.
    ///
    /// Yields the payload of each `data:` line (with the prefix stripped).
    /// Stops when the stream ends or when `[DONE]` is received.
    public static func parse<S: AsyncSequence>(
        bytes: S
    ) -> AsyncThrowingStream<String, Error> where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = ""
                var iterator = bytes.makeAsyncIterator()

                do {
                    while let byte = try await iterator.next() {
                        if Task.isCancelled { break }

                        let char = Character(UnicodeScalar(byte))
                        if char == "\n" {
                            let line = buffer.trimmingCharacters(in: .whitespaces)
                            buffer = ""

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
                            buffer.append(char)
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
}
