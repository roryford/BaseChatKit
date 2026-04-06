import Testing
import BaseChatCore

@Suite("MacroProvider")
struct MacroProviderTests {

    // MARK: - Helpers

    final class ConstantProvider: MacroProvider {
        let token: String
        let value: String
        init(token: String, value: String) {
            self.token = token
            self.value = value
        }
        func expand(_ t: String, context: MacroContext) -> String? {
            t == token ? value : nil
        }
    }

    final class PassThroughProvider: MacroProvider {
        func expand(_ token: String, context: MacroContext) -> String? { nil }
    }

    final class SpyProvider: MacroProvider {
        private(set) var calledTokens: [String] = []
        let answer: String?
        init(answer: String? = nil) { self.answer = answer }
        func expand(_ token: String, context: MacroContext) -> String? {
            calledTokens.append(token)
            return answer
        }
    }

    // MARK: - Registration and expansion

    @Test("Registered provider is called for unrecognized token")
    func registeredProviderExpands() {
        let provider = ConstantProvider(token: "greeting", value: "Hello!")
        MacroExpander.register(provider: provider)
        defer { MacroExpander.unregister(provider: provider) }

        let ctx = MacroContext()
        let result = MacroExpander.expand("{{greeting}}", context: ctx)
        #expect(result == "Hello!")
    }

    // MARK: - Registration order: first registered provider wins

    @Test("First registered provider wins when multiple providers handle the same token")
    func firstRegisteredProviderWins() {
        let first = ConstantProvider(token: "color", value: "red")
        let second = ConstantProvider(token: "color", value: "blue")
        MacroExpander.register(provider: first)
        MacroExpander.register(provider: second)
        defer {
            MacroExpander.unregister(provider: first)
            MacroExpander.unregister(provider: second)
        }

        let ctx = MacroContext()
        let result = MacroExpander.expand("{{color}}", context: ctx)
        #expect(result == "red")
    }

    // MARK: - Nil pass-through

    @Test("Provider returning nil defers to next provider in chain")
    func nilDeferToNext() {
        let pass = PassThroughProvider()
        let answer = ConstantProvider(token: "mood", value: "happy")
        MacroExpander.register(provider: pass)
        MacroExpander.register(provider: answer)
        defer {
            MacroExpander.unregister(provider: pass)
            MacroExpander.unregister(provider: answer)
        }

        let ctx = MacroContext()
        let result = MacroExpander.expand("{{mood}}", context: ctx)
        #expect(result == "happy")
    }

    // MARK: - Built-ins not shadowed

    @Test("Provider cannot override a built-in macro")
    func builtInNotShadowed() {
        // Attempt to override {{user}} — built-ins always run first.
        let interloper = ConstantProvider(token: "user", value: "Interloper")
        MacroExpander.register(provider: interloper)
        defer { MacroExpander.unregister(provider: interloper) }

        let ctx = MacroContext(userName: "Alice")
        let result = MacroExpander.expand("{{user}}", context: ctx)
        #expect(result == "Alice")
    }

    // MARK: - Unregistration

    @Test("Unregistered provider is no longer called")
    func unregisteredProviderNotCalled() {
        let spy = SpyProvider(answer: "surprise")
        MacroExpander.register(provider: spy)
        MacroExpander.unregister(provider: spy)

        let ctx = MacroContext()
        let result = MacroExpander.expand("{{anything}}", context: ctx)

        #expect(spy.calledTokens.isEmpty)
        #expect(result == "{{anything}}")
    }

    // MARK: - Multiple providers

    @Test("Chain works correctly across multiple providers handling different tokens")
    func multipleProvidersChain() {
        let aProvider = ConstantProvider(token: "animal", value: "cat")
        let bProvider = ConstantProvider(token: "sound", value: "meow")
        MacroExpander.register(provider: aProvider)
        MacroExpander.register(provider: bProvider)
        defer {
            MacroExpander.unregister(provider: aProvider)
            MacroExpander.unregister(provider: bProvider)
        }

        let ctx = MacroContext()
        let result = MacroExpander.expand("A {{animal}} says {{sound}}.", context: ctx)
        #expect(result == "A cat says meow.")
    }
}
