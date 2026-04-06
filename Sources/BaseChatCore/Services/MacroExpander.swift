import Foundation

/// Context values for macro substitution.
///
/// Populate the fields relevant to your app and pass to ``MacroExpander/expand(_:context:)``.
/// Fields left `nil` cause their corresponding macros to remain unexpanded in the text.
public struct MacroContext: Sendable {
    public var userName: String?
    public var charName: String?
    public var lastMessage: String?
    public var lastUserMessage: String?
    public var lastCharMessage: String?
    public var date: String?
    public var time: String?
    public var modelName: String?
    public var messageCount: Int?

    public init(
        userName: String? = nil,
        charName: String? = nil,
        lastMessage: String? = nil,
        lastUserMessage: String? = nil,
        lastCharMessage: String? = nil,
        date: String? = nil,
        time: String? = nil,
        modelName: String? = nil,
        messageCount: Int? = nil
    ) {
        self.userName = userName
        self.charName = charName
        self.lastMessage = lastMessage
        self.lastUserMessage = lastUserMessage
        self.lastCharMessage = lastCharMessage
        self.date = date
        self.time = time
        self.modelName = modelName
        self.messageCount = messageCount
    }
}

/// A type that can provide custom macro expansions.
///
/// Register instances with ``MacroExpander/register(provider:)`` to extend the macro chain
/// with domain-specific tokens. Registered providers are consulted after built-in macros;
/// the first non-nil return wins.
public protocol MacroProvider: AnyObject {
    /// Return expanded value for token, or nil to pass through to next provider.
    func expand(_ token: String, context: MacroContext) -> String?
}

/// Expands template macros in text strings.
///
/// Supported built-in macros:
/// - `{{user}}` -- the user's name
/// - `{{char}}` -- the character's name
/// - `{{date}}` -- locale-formatted date (e.g., "March 30, 2026")
/// - `{{isodate}}` -- ISO date (YYYY-MM-DD)
/// - `{{time}}` -- current time (HH:MM)
/// - `{{weekday}}` -- current day of week name
/// - `{{newline}}` -- literal newline character
/// - `{{random::a::b::c}}` -- picks one option randomly
/// - `{{lastMessage}}` -- most recent message in context
/// - `{{lastUserMessage}}` -- most recent user message in context
/// - `{{lastCharMessage}}` -- most recent character message in context
/// - `{{modelName}}` -- name of the currently loaded model or endpoint
/// - `{{messageCount}}` -- number of messages in the current conversation
/// - `{{idle_duration}}` -- placeholder, returns empty string
/// - `{{system}}`, `{{input}}`, `{{output}}` -- instruct template markers (pass-through)
///
/// Apps can extend the macro chain with domain-specific tokens by registering a ``MacroProvider``.
public enum MacroExpander {

    // MARK: - Provider registry

    private static let registryLock = NSLock()
    // Access to `registry` is serialized through `registryLock`; the nonisolated(unsafe)
    // suppressor is correct here — Swift's strict concurrency checker cannot see the lock.
    private nonisolated(unsafe) static var registry: [(id: ObjectIdentifier, provider: any MacroProvider)] = []

    /// Appends a provider to the resolution chain.
    ///
    /// Registered providers are consulted in registration order after built-in macros.
    public static func register(provider: any MacroProvider) {
        registryLock.withLock {
            let id = ObjectIdentifier(provider)
            // Guard against double-registration
            guard !registry.contains(where: { $0.id == id }) else { return }
            registry.append((id: id, provider: provider))
        }
    }

    /// Removes a previously registered provider from the resolution chain.
    public static func unregister(provider: any MacroProvider) {
        registryLock.withLock {
            let id = ObjectIdentifier(provider)
            registry.removeAll { $0.id == id }
        }
    }

    // MARK: - Expansion

    /// Expands all recognized macros in the given text.
    ///
    /// - Parameters:
    ///   - text: The input string potentially containing `{{macro}}` placeholders.
    ///   - context: Values to substitute. Nil values leave the macro unexpanded.
    /// - Returns: The string with applicable macros replaced.
    public static func expand(_ text: String, context: MacroContext) -> String {
        guard text.contains("{{") else { return text }

        var result = text

        // Handle {{random::a::b::c}} first since it uses :: separators
        result = expandRandom(in: result)

        // Pattern matches {{word}} with case-insensitive flag
        let pattern = #"\{\{(\w+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return result
        }

        let nsText = result as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        // Process matches in reverse order so replacement ranges stay valid
        let matches = regex.matches(in: result, options: [], range: fullRange).reversed()

        for match in matches {
            guard let macroRange = Range(match.range(at: 1), in: result),
                  let fullMatchRange = Range(match.range, in: result) else { continue }

            let macroName = String(result[macroRange]).lowercased()

            if let replacement = replacement(for: macroName, context: context) {
                result = result.replacingCharacters(
                    in: fullMatchRange,
                    with: replacement
                )
            } else if let replacement = expandWithProviders(token: macroName, context: context) {
                result = result.replacingCharacters(
                    in: fullMatchRange,
                    with: replacement
                )
            }
            // If both return nil, leave the macro as-is
        }

        return result
    }

    // MARK: - Private

    private static let passThroughMacros: Set<String> = ["system", "input", "output"]

    private static func replacement(for macro: String, context: MacroContext) -> String? {
        switch macro {
        case "user":
            return context.userName
        case "char":
            return context.charName
        case "lastmessage":
            return context.lastMessage
        case "lastusermessage":
            return context.lastUserMessage
        case "lastcharmessage":
            return context.lastCharMessage
        case "date":
            return context.date ?? currentLocaleDate()
        case "isodate":
            return currentISODate()
        case "time":
            return context.time ?? currentTime()
        case "weekday":
            return currentWeekday()
        case "newline":
            return "\n"
        case "idle_duration":
            return ""
        case "modelname":
            return context.modelName
        case "messagecount":
            return context.messageCount.map(String.init)
        default:
            if passThroughMacros.contains(macro) {
                return nil // leave as-is
            }
            return nil // unrecognized macro, defer to providers
        }
    }

    /// Walks the registered provider chain and returns the first non-nil expansion.
    private static func expandWithProviders(token: String, context: MacroContext) -> String? {
        // Capture the current snapshot of providers under lock so the loop runs without holding it.
        let snapshot = registryLock.withLock { registry }
        for entry in snapshot {
            if let value = entry.provider.expand(token, context: context) {
                return value
            }
        }
        return nil
    }

    /// Expands `{{random::a::b::c}}` macros by picking one option randomly.
    private static func expandRandom(in text: String) -> String {
        let pattern = #"\{\{random::([^}]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var result = text
        let matches = regex.matches(in: text, options: [], range: fullRange).reversed()

        for match in matches {
            guard let optionsRange = Range(match.range(at: 1), in: text),
                  let fullMatchRange = Range(match.range, in: text) else { continue }

            let optionsStr = String(text[optionsRange])
            let options = optionsStr.components(separatedBy: "::")
            if let chosen = options.randomElement() {
                result = result.replacingCharacters(in: fullMatchRange, with: chosen)
            }
        }

        return result
    }

    /// Locale-formatted date (e.g., "March 30, 2026") matching ST behavior.
    private static func currentLocaleDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// ISO date in YYYY-MM-DD format.
    private static func currentISODate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private static func currentTime() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// Current day of week name (e.g., "Monday").
    private static func currentWeekday() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

// MARK: - String helpers

private extension String {
    func replacingCharacters(in range: Range<String.Index>, with replacement: String) -> String {
        var copy = self
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}
