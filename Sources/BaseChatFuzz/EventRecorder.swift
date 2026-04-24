import Foundation
import BaseChatInference

/// Consumes a `GenerationStream`, recording every event plus derived buffers.
///
/// Drives the stream itself (calls `for try await event in stream.events`),
/// so callers must not iterate the stream separately. Returns a fully populated
/// capture once the stream terminates.
public struct EventRecorder: Sendable {

    public init() {}

    public struct Capture: Sendable {
        public var events: [RunRecord.EventSnapshot]
        public var raw: String
        public var thinkingRaw: String
        public var thinkingParts: [String]
        public var thinkingCompleteCount: Int
        public var phase: String
        public var error: String?
        public var firstTokenMs: Double?
        public var totalMs: Double
        public var peakBytes: UInt64?
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var stopReason: String
    }

    /// - Parameter maxOutputTokens: the cap requested in `GenerationConfig`, used to
    ///   classify the stop reason as `maxTokens` when the final usage report meets/exceeds it.
    public func consume(_ stream: GenerationStream, maxOutputTokens: Int? = nil) async -> Capture {
        let start = ContinuousClock.now
        var events: [RunRecord.EventSnapshot] = []
        var raw = ""
        var thinkingRaw = ""
        var thinkingBuffer = ""
        var thinkingParts: [String] = []
        var thinkingCompleteCount = 0
        var firstTokenAt: ContinuousClock.Instant?
        var peakBytes: UInt64? = AppMemoryUsage.currentBytes()
        var promptTokens: Int?
        var completionTokens: Int?
        var phase = "done"
        var errorString: String?

        func memoryTick() {
            if let now = AppMemoryUsage.currentBytes() {
                peakBytes = max(peakBytes ?? now, now)
            }
        }

        do {
            for try await event in stream.events {
                let t = start.duration(to: ContinuousClock.now).seconds
                switch event {
                case .token(let text):
                    if firstTokenAt == nil { firstTokenAt = ContinuousClock.now }
                    raw += text
                    events.append(.init(t: t, kind: "token", v: text))
                case .thinkingToken(let text):
                    if firstTokenAt == nil { firstTokenAt = ContinuousClock.now }
                    thinkingRaw += text
                    thinkingBuffer += text
                    events.append(.init(t: t, kind: "thinkingToken", v: text))
                case .thinkingComplete:
                    thinkingCompleteCount += 1
                    if !thinkingBuffer.isEmpty {
                        thinkingParts.append(thinkingBuffer)
                        thinkingBuffer = ""
                    }
                    events.append(.init(t: t, kind: "thinkingComplete", v: nil))
                case .usage(let p, let c):
                    promptTokens = p
                    completionTokens = c
                    events.append(.init(t: t, kind: "usage", v: "\(p)/\(c)"))
                case .toolCall(let call):
                    events.append(.init(t: t, kind: "toolCall", v: call.toolName))
                case .toolResult(let result):
                    events.append(.init(t: t, kind: "toolResult", v: result.callId))
                case .toolLoopLimitReached(let iterations):
                    events.append(.init(t: t, kind: "toolLoopLimitReached", v: "\(iterations)"))
                case .kvCacheReuse(let tokens):
                    events.append(.init(t: t, kind: "kvCacheReuse", v: "\(tokens)"))
                }
                memoryTick()
            }
        } catch {
            phase = "failed"
            errorString = String(describing: error)
        }

        // Flush any unterminated thinking buffer so that a throw mid-thinking-block
        // (network drop, KV decode error, OOM) still preserves the partial reasoning
        // trace in `thinkingParts`. Without this, detectors like
        // `unbalanced-thinking-events` and the `looping` thinking-loop sub-check go
        // blind on mid-stream failures. On the success path the buffer is already
        // drained by the last `.thinkingComplete`, so this is a no-op.
        if !thinkingBuffer.isEmpty {
            thinkingParts.append(thinkingBuffer)
            thinkingBuffer = ""
        }

        let totalMs = start.duration(to: ContinuousClock.now).milliseconds
        let firstTokenMs = firstTokenAt.map { start.duration(to: $0).milliseconds }

        let stopReason: String
        if phase == "failed" {
            stopReason = "error"
        } else if let cap = maxOutputTokens, let c = completionTokens, c >= cap {
            stopReason = "maxTokens"
        } else {
            stopReason = "naturalStop"
        }

        return Capture(
            events: events,
            raw: raw,
            thinkingRaw: thinkingRaw,
            thinkingParts: thinkingParts,
            thinkingCompleteCount: thinkingCompleteCount,
            phase: phase,
            error: errorString,
            firstTokenMs: firstTokenMs,
            totalMs: totalMs,
            peakBytes: peakBytes,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            stopReason: stopReason
        )
    }
}

private extension Duration {
    var seconds: Double {
        let comps = self.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
    var milliseconds: Double { seconds * 1000 }
}
