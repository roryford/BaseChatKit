import Foundation

/// Declarative scenario spec. Loaded from the JSON files in
/// `Scenarios/built-in/` and from any `--scenario-file` path passed on the
/// CLI.
///
/// Keeping the configuration declarative (rather than Swift code) means tests
/// can enumerate the full scenario surface without importing any harness
/// types, and new scenarios can be added by dropping a JSON file in the
/// resources directory without recompiling.
public struct Scenario: Codable, Sendable, Equatable {

    public let id: String
    public let description: String
    public let systemPrompt: String
    public let userPrompt: String
    public let requiredTools: [String]
    public let assertions: [Assertion]
    public let backend: BackendSpec

    public struct BackendSpec: Codable, Sendable, Equatable {
        public let kind: String            // "ollama", "mock"
        public let model: String
        public let fallbackModel: String?
        public let temperature: Double?
        public let seed: Int?
        public let topK: Int?
    }

    public struct Assertion: Codable, Sendable, Equatable {
        public let kind: String            // "containsLiteral" | "equalsLiteral" | "containsAny"
        public let value: String?
        public let values: [String]?
        public let message: String?
    }
}

/// Result of evaluating a single assertion against the runner transcript.
public struct AssertionOutcome: Equatable, Sendable {
    public let passed: Bool
    public let message: String

    public init(passed: Bool, message: String) {
        self.passed = passed
        self.message = message
    }
}

/// Evaluates an assertion against the final-answer text the runner observed.
///
/// Pure, synchronous, and free of any side effects so unit tests can drive it
/// directly with canned strings without spinning up a backend.
public enum AssertionEvaluator {

    public static func evaluate(_ assertion: Scenario.Assertion, finalAnswer: String) -> AssertionOutcome {
        switch assertion.kind {
        case "containsLiteral":
            guard let value = assertion.value else {
                return AssertionOutcome(passed: false, message: "containsLiteral missing 'value'")
            }
            let passed = finalAnswer.contains(value)
            let detail = passed ? "found" : "missing"
            let label = assertion.message ?? "contains '\(value)'"
            return AssertionOutcome(passed: passed, message: "\(label) — \(detail)")

        case "equalsLiteral":
            guard let value = assertion.value else {
                return AssertionOutcome(passed: false, message: "equalsLiteral missing 'value'")
            }
            let passed = finalAnswer == value
            let label = assertion.message ?? "equals '\(value)'"
            return AssertionOutcome(passed: passed, message: label)

        case "containsAny":
            guard let values = assertion.values, !values.isEmpty else {
                return AssertionOutcome(passed: false, message: "containsAny missing 'values'")
            }
            let passed = values.allSatisfy { finalAnswer.contains($0) }
            let label = assertion.message ?? "contains all of \(values)"
            return AssertionOutcome(passed: passed, message: label)

        default:
            return AssertionOutcome(
                passed: false,
                message: "unknown assertion kind '\(assertion.kind)'"
            )
        }
    }
}
