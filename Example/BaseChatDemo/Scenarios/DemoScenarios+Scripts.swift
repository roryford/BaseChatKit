import Foundation
import BaseChatTools

/// Per-scenario scripted-turn sequences for `ScriptedBackend`.
///
/// Each scenario's first turn emits the expected `.toolCall`; the second
/// emits a token-only synthesis the runner treats as the final assistant
/// message. Layer 2 XCUITests rely on this fixed shape — adding a new
/// scenario to `DemoScenarios.all` requires a matching entry here.
extension DemoScenarios {

    /// Returns the turn list for `scenarioID`, or a small fallback when no
    /// scenario was supplied via the launch arg (preserves the legacy
    /// `--uitesting`-only behaviour for `ToolApprovalUITests` and similar).
    static func scriptedTurns(for scenarioID: String?) -> [ScriptedBackend.Turn] {
        guard let scenarioID else { return fallbackTurns }
        switch scenarioID {
        case tipCalc.id:
            return [
                // CalcTool.Args expects {a, op, b}; `expression` is not part of
                // the schema and would fail the real executor's Decodable probe.
                .toolCall(name: "calc", arguments: #"{"a":73.40,"op":"*","b":0.18}"#),
                .tokens([
                    "An ", "18% ", "tip ", "on ", "$73.40 ", "is ", "$13.21. ",
                    "Each ", "person's ", "share ", "is ", "about ", "$21.65."
                ])
            ]

        case worldClock.id:
            return [
                // NowTool accepts zero arguments; its schema declares
                // `properties: {}` / `required: []`. Pass an empty object so
                // the scripted call mirrors what a well-behaved model emits.
                .toolCall(name: "now", arguments: #"{}"#),
                .tokens([
                    "It's ", "currently ", "the ", "afternoon ", "in ", "Tokyo."
                ])
            ]

        case workspaceSearch.id:
            return [
                .toolCall(name: "sample_repo_search", arguments: #"{"query":"MCP"}"#),
                .tokens([
                    "I ", "found ", "a ", "match ", "in ", "your ", "workspace ",
                    "mentioning ", "MCP."
                ])
            ]

        case journalWrite.id:
            // Use a plain Swift string (not a raw string) so JSON \n escapes
            // remain valid two-character sequences when decoded.
            let body = "{\"path\":\"journal/today.md\",\"content\":\"# Today\\n\\nQuiet, focused day.\"}"
            return [
                .toolCall(name: "write_file", arguments: body),
                .tokens([
                    "Saved ", "today's ", "journal ", "entry."
                ])
            ]

        default:
            return fallbackTurns
        }
    }

    /// Legacy turn list for `--uitesting` runs without a scenario arg —
    /// preserves `ToolApprovalUITests` behaviour against the README search.
    private static let fallbackTurns: [ScriptedBackend.Turn] = [
        .toolCall(name: "sample_repo_search", arguments: #"{"query":"readme"}"#),
        .tokens(["Here's ", "a ", "summary ", "of ", "your ", "workspace."])
    ]
}
