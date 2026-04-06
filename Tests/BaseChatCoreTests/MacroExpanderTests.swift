import Testing
import Foundation
import BaseChatCore

@Suite("MacroExpander")
struct MacroExpanderTests {

    private let posixLocale = Locale(identifier: "en_US_POSIX")

    private func surroundingDays(from reference: Date = Date()) -> [Date] {
        let calendar = Calendar(identifier: .gregorian)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: reference) ?? reference
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference) ?? reference
        return [yesterday, reference, tomorrow]
    }

    private func surroundingMinutes(from reference: Date = Date()) -> [Date] {
        let calendar = Calendar(identifier: .gregorian)
        let previousMinute = calendar.date(byAdding: .minute, value: -1, to: reference) ?? reference
        let nextMinute = calendar.date(byAdding: .minute, value: 1, to: reference) ?? reference
        return [previousMinute, reference, nextMinute]
    }

    // MARK: - Basic substitution

    @Test("Expands {{user}} to user name")
    func userSubstitution() {
        let ctx = MacroContext(userName: "Alice")
        let result = MacroExpander.expand("Hello, {{user}}!", context: ctx)
        #expect(result == "Hello, Alice!")
    }

    @Test("Expands {{char}} to character name")
    func charSubstitution() {
        let ctx = MacroContext(charName: "Bob")
        let result = MacroExpander.expand("I am {{char}}.", context: ctx)
        #expect(result == "I am Bob.")
    }

    // MARK: - Multiple macros

    @Test("Expands multiple macros in one string")
    func multipleMacros() {
        let ctx = MacroContext(userName: "Alice", charName: "Bob")
        let result = MacroExpander.expand("{{user}} talks to {{char}}.", context: ctx)
        #expect(result == "Alice talks to Bob.")
    }

    // MARK: - Nil context leaves macro unexpanded

    @Test("Nil userName leaves {{user}} unexpanded")
    func nilUserLeavesUnexpanded() {
        let ctx = MacroContext(charName: "Bob")
        let result = MacroExpander.expand("Hello, {{user}}!", context: ctx)
        #expect(result == "Hello, {{user}}!")
    }

    @Test("Nil charName leaves {{char}} unexpanded")
    func nilCharLeavesUnexpanded() {
        let ctx = MacroContext(userName: "Alice")
        let result = MacroExpander.expand("I am {{char}}.", context: ctx)
        #expect(result == "I am {{char}}.")
    }

    // MARK: - Case insensitivity

    @Test("Matches {{User}} case-insensitively")
    func caseInsensitiveMixedCase() {
        let ctx = MacroContext(userName: "Alice")
        let result = MacroExpander.expand("Hi {{User}}!", context: ctx)
        #expect(result == "Hi Alice!")
    }

    @Test("Matches {{USER}} case-insensitively")
    func caseInsensitiveUpperCase() {
        let ctx = MacroContext(userName: "Alice")
        let result = MacroExpander.expand("Hi {{USER}}!", context: ctx)
        #expect(result == "Hi Alice!")
    }

    // MARK: - {{date}}

    @Test("{{date}} auto-generates locale-formatted date when context is nil")
    func dateAutoGenerate() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("{{date}}", context: ctx)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        formatter.locale = posixLocale

        let validDates = Set(surroundingDays().map { formatter.string(from: $0) })
        #expect(validDates.contains(result), "Expected date near now in POSIX format, got: \(result)")
    }

    @Test("{{date}} uses explicit context value when provided")
    func dateExplicitValue() {
        let ctx = MacroContext(date: "2025-12-25")
        let result = MacroExpander.expand("Date: {{date}}", context: ctx)
        #expect(result == "Date: 2025-12-25")
    }

    // MARK: - {{time}}

    @Test("{{time}} auto-generates in HH:MM format when context is nil")
    func timeAutoGenerate() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("{{time}}", context: ctx)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = posixLocale

        let validTimes = Set(surroundingMinutes().map { formatter.string(from: $0) })
        #expect(validTimes.contains(result), "Expected current HH:mm time near now, got: \(result)")
    }

    @Test("{{time}} uses explicit context value when provided")
    func timeExplicitValue() {
        let ctx = MacroContext(time: "14:30")
        let result = MacroExpander.expand("Now: {{time}}", context: ctx)
        #expect(result == "Now: 14:30")
    }

    // MARK: - {{idle_duration}}

    @Test("{{idle_duration}} expands to empty string")
    func idleDurationReturnsEmpty() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("Idle: {{idle_duration}} seconds", context: ctx)
        #expect(result == "Idle:  seconds")
    }

    // MARK: - No macros

    @Test("String with no macros is returned unchanged")
    func noMacrosUnchanged() {
        let ctx = MacroContext(userName: "Alice", charName: "Bob")
        let input = "Plain text with no templates"
        let result = MacroExpander.expand(input, context: ctx)
        #expect(result == input)
    }

    // MARK: - Malformed macros

    @Test("Malformed {{user without closing braces is left alone")
    func malformedMacroLeftAlone() {
        let ctx = MacroContext(userName: "Alice")
        let result = MacroExpander.expand("Hello {{user, bye", context: ctx)
        #expect(result == "Hello {{user, bye")
    }

    // MARK: - Pass-through macros

    @Test("{{system}} is left as-is")
    func systemPassThrough() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("{{system}}", context: ctx)
        #expect(result == "{{system}}")
    }

    @Test("{{input}} is left as-is")
    func inputPassThrough() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("{{input}}", context: ctx)
        #expect(result == "{{input}}")
    }

    @Test("{{output}} is left as-is")
    func outputPassThrough() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("{{output}}", context: ctx)
        #expect(result == "{{output}}")
    }

    // MARK: - Unrecognized macros

    @Test("Unrecognized {{unknown}} macro is left alone")
    func unrecognizedMacroLeftAlone() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("{{unknown}} text", context: ctx)
        #expect(result == "{{unknown}} text")
    }

    // MARK: - {{newline}}

    @Test("{{newline}} expands to literal newline character")
    func newlineExpansion() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("Line1{{newline}}Line2", context: ctx)
        #expect(result == "Line1\nLine2")
    }

    // MARK: - {{random::a::b::c}}

    @Test("{{random::a::b::c}} picks one of the options")
    func randomMacro() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("{{random::alpha::beta::gamma}}", context: ctx)
        #expect(["alpha", "beta", "gamma"].contains(result))
    }

    @Test("{{random::single}} returns the single option")
    func randomSingleOption() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("{{random::only}}", context: ctx)
        #expect(result == "only")
    }

    // MARK: - {{weekday}}

    @Test("{{weekday}} expands to a day of the week name")
    func weekdayExpansion() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("{{weekday}}", context: ctx)

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.locale = posixLocale

        let validWeekdays = Set(surroundingDays().map { formatter.string(from: $0) })
        #expect(validWeekdays.contains(result), "Expected weekday near current day, got: \(result)")
    }

    // MARK: - {{isodate}}

    @Test("{{isodate}} auto-generates in YYYY-MM-DD format")
    func isodateAutoGenerate() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("Today is {{isodate}}.", context: ctx)
        let datePattern = #"^Today is \d{4}-\d{2}-\d{2}\.$"#
        #expect(result.range(of: datePattern, options: .regularExpression) != nil,
                "Expected YYYY-MM-DD format, got: \(result)")
    }

    // MARK: - Message reference macros

    @Test("Expands {{lastMessage}} from context")
    func lastMessageExpansion() {
        let ctx = MacroContext(lastMessage: "Most recent line")
        let result = MacroExpander.expand("Prev: {{lastMessage}}", context: ctx)
        #expect(result == "Prev: Most recent line")
    }

    @Test("Expands {{lastUserMessage}} from context")
    func lastUserMessageExpansion() {
        let ctx = MacroContext(lastUserMessage: "User said hi")
        let result = MacroExpander.expand("User: {{lastUserMessage}}", context: ctx)
        #expect(result == "User: User said hi")
    }

    @Test("Expands {{lastCharMessage}} from context")
    func lastCharMessageExpansion() {
        let ctx = MacroContext(lastCharMessage: "Character replied")
        let result = MacroExpander.expand("Char: {{lastCharMessage}}", context: ctx)
        #expect(result == "Char: Character replied")
    }

    @Test("Nil message references remain unexpanded")
    func nilMessageReferencesRemainUnexpanded() {
        let ctx = MacroContext()
        let result = MacroExpander.expand(
            "{{lastMessage}} / {{lastUserMessage}} / {{lastCharMessage}}",
            context: ctx
        )
        #expect(result == "{{lastMessage}} / {{lastUserMessage}} / {{lastCharMessage}}")
    }

    // MARK: - {{modelName}}

    @Test("{{modelName}} expands when context.modelName is set")
    func modelNameExpansion() {
        let ctx = MacroContext(modelName: "Llama-3-8B")
        let result = MacroExpander.expand("Model: {{modelName}}", context: ctx)
        #expect(result == "Model: Llama-3-8B")
    }

    @Test("{{modelName}} remains unexpanded when context.modelName is nil")
    func modelNameNilUnexpanded() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("Model: {{modelName}}", context: ctx)
        #expect(result == "Model: {{modelName}}")
    }

    // MARK: - {{messageCount}}

    @Test("{{messageCount}} expands when context.messageCount is set")
    func messageCountExpansion() {
        let ctx = MacroContext(messageCount: 42)
        let result = MacroExpander.expand("Messages: {{messageCount}}", context: ctx)
        #expect(result == "Messages: 42")
    }

    @Test("{{messageCount}} remains unexpanded when context.messageCount is nil")
    func messageCountNilUnexpanded() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("Messages: {{messageCount}}", context: ctx)
        #expect(result == "Messages: {{messageCount}}")
    }

    // MARK: - Date parity

    @Test("{{date}} and {{isodate}} both expand in mixed string")
    func dateAndIsoDateBothExpand() {
        let ctx = MacroContext()
        let result = MacroExpander.expand("{{date}} | {{isodate}}", context: ctx)
        let pattern = #"^\w+ \d{1,2}, \d{4} \| \d{4}-\d{2}-\d{2}$"#
        #expect(result.range(of: pattern, options: .regularExpression) != nil,
                "Expected both date formats, got: \(result)")
    }
}
