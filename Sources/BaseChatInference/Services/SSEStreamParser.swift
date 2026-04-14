import Foundation

/// Configurable caps applied to SSE (and NDJSON) parsing to defend against
/// hostile or misconfigured upstream servers.
///
/// The parser enforces three separate bounds:
///
/// - ``maxEventBytes`` caps the size of a single event payload buffer. A
///   malicious server cannot make the client swallow a 100 MB `data:` line.
/// - ``maxTotalBytes`` caps cumulative bytes across the whole stream. This
///   stops a server that drips just-small-enough events forever.
/// - ``maxEventsPerSecond`` caps the yield rate. A flood of 1-byte events is
///   rejected before it can starve the consumer.
///
/// Defaults (``default``) are intentionally well above any realistic provider
/// throughput — OpenAI, Anthropic, and Ollama all emit events far smaller
/// than 1 MB and well under 5,000 events per second — so legitimate traffic is
/// never throttled. Host apps can tune the limits globally via
/// `BaseChatConfiguration.shared.sseStreamLimits` or per-backend by setting
/// `SSECloudBackend.sseStreamLimits`.
///
/// There is deliberately no "unlimited" option: bounded caps are the point.
public struct SSEStreamLimits: Sendable, Equatable {

    /// Maximum byte size of a single event payload buffer, including bytes
    /// that have not yet reached a newline.
    public var maxEventBytes: Int

    /// Maximum cumulative byte count across the entire stream, counting all
    /// bytes the parser consumes (including control and ignored lines).
    public var maxTotalBytes: Int

    /// Maximum events the parser may yield within any one-second window.
    public var maxEventsPerSecond: Int

    public init(
        maxEventBytes: Int,
        maxTotalBytes: Int,
        maxEventsPerSecond: Int
    ) {
        self.maxEventBytes = maxEventBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxEventsPerSecond = maxEventsPerSecond
    }

    /// Conservative defaults suitable for every mainstream provider.
    ///
    /// - 1 MB per event: large enough for chunked usage payloads and tool
    ///   call metadata, small enough to reject a pathological upstream.
    /// - 50 MB per stream: covers hours of conversation tokens without
    ///   allowing unbounded streams.
    /// - 5,000 events/s: roughly 100x real provider throughput; a healthy
    ///   LLM tops out at a few hundred tokens/s.
    public static let `default` = SSEStreamLimits(
        maxEventBytes: 1_000_000,
        maxTotalBytes: 50_000_000,
        maxEventsPerSecond: 5_000
    )
}

/// Errors thrown by ``SSEStreamParser`` when a stream violates its limits.
///
/// These surface through the existing `AsyncThrowingStream` failure channel
/// exactly like any other parsing error, so backend retry/error UI continues
/// to work unchanged.
public enum SSEStreamError: Error, Equatable {
    /// A single event exceeded ``SSEStreamLimits/maxEventBytes``. The
    /// associated value is the observed size in bytes.
    case eventTooLarge(Int)

    /// Cumulative bytes across the stream exceeded
    /// ``SSEStreamLimits/maxTotalBytes``. The associated value is the total
    /// bytes consumed before the limit tripped.
    case streamTooLarge(Int)

    /// More events than ``SSEStreamLimits/maxEventsPerSecond`` were produced
    /// within a single one-second window. The associated value is the event
    /// count observed in that window.
    case eventRateExceeded(Int)

    /// The stream bytes were structurally unparseable (reserved for future
    /// strict-mode use). Not currently thrown by the tolerant parser.
    case malformed
}

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

package struct SSEStreamParser {

    /// Parses an `AsyncSequence` of bytes into an `AsyncThrowingStream` of SSE data lines.
    ///
    /// Yields the payload of each `data:` line (with the prefix stripped).
    /// Stops when the stream ends or when `[DONE]` is received.
    ///
    /// The stream is bounded by the supplied ``SSEStreamLimits``; a violation
    /// is surfaced by finishing the stream with the appropriate
    /// ``SSEStreamError``.
    ///
    /// - Parameters:
    ///   - bytes: The raw byte stream.
    ///   - limits: Caps that defend against hostile upstreams. Defaults to
    ///     `BaseChatConfiguration.shared.sseStreamLimits`.
    package static func parse<S: AsyncSequence & Sendable>(
        bytes: S,
        limits: SSEStreamLimits = BaseChatConfiguration.shared.sseStreamLimits
    ) -> AsyncThrowingStream<String, Error> where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var byteBuffer = Data()
                var iterator = bytes.makeAsyncIterator()

                // Cumulative bytes consumed across the whole stream.
                var totalBytes = 0

                // Sliding one-second event-rate window. We keep things cheap
                // by bucketing to integer seconds of the monotonic clock and
                // resetting the count when the bucket changes.
                var rateWindowStart = ContinuousClock.now
                var rateWindowCount = 0
                let maxRate = limits.maxEventsPerSecond

                func noteEventYielded() -> SSEStreamError? {
                    let now = ContinuousClock.now
                    if now - rateWindowStart >= .seconds(1) {
                        rateWindowStart = now
                        rateWindowCount = 1
                        return nil
                    }
                    rateWindowCount += 1
                    if rateWindowCount > maxRate {
                        return .eventRateExceeded(rateWindowCount)
                    }
                    return nil
                }

                do {
                    while let byte = try await iterator.next() {
                        if Task.isCancelled { break }

                        totalBytes += 1
                        if totalBytes > limits.maxTotalBytes {
                            throw SSEStreamError.streamTooLarge(totalBytes)
                        }

                        if byte == UInt8(ascii: "\n") {
                            // Decode accumulated bytes as UTF-8.
                            let line: String
                            if let decoded = String(data: byteBuffer, encoding: .utf8) {
                                line = decoded.trimmingCharacters(in: .whitespaces)
                            } else {
                                // Skip lines with invalid UTF-8 rather than crash.
                                Log.network.warning("SSEStreamParser: skipped \(byteBuffer.count)-byte line with invalid UTF-8")
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
                                    if let rateError = noteEventYielded() {
                                        throw rateError
                                    }
                                    continuation.yield(payload)
                                }
                            }
                            // Ignore event:, id:, retry:, and comment lines
                        } else {
                            byteBuffer.append(byte)
                            if byteBuffer.count > limits.maxEventBytes {
                                throw SSEStreamError.eventTooLarge(byteBuffer.count)
                            }
                        }
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Streams generation events from an HTTP response using an SSE payload handler.
    ///
    /// Combines `parse(bytes:)` with a payload handler to extract tokens,
    /// emit usage reports, detect stream end, and surface errors. This
    /// eliminates the duplicated streaming loop in each cloud backend.
    ///
    /// - Parameters:
    ///   - bytes: The raw byte stream from `URLSession.bytes(for:)`.
    ///   - handler: A payload handler that interprets the provider's JSON format.
    ///   - limits: Caps that defend against hostile upstreams. Defaults to
    ///     `BaseChatConfiguration.shared.sseStreamLimits`.
    /// - Returns: An `AsyncThrowingStream` of ``GenerationEvent`` values.
    package static func streamEvents<S: AsyncSequence & Sendable>(
        from bytes: S,
        using handler: some SSEPayloadHandler,
        limits: SSEStreamLimits = BaseChatConfiguration.shared.sseStreamLimits
    ) -> AsyncThrowingStream<GenerationEvent, Error> where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let sseStream = parse(bytes: bytes, limits: limits)
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
                    if error is CancellationError || Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
