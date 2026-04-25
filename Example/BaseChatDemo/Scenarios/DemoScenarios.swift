import Foundation

/// Registry of P1 demo scenarios. Adding a new scenario means adding an
/// entry here and a corresponding turn sequence in `DemoScenarios+Scripts.swift`.
enum DemoScenarios {

    static let tipCalc = DemoScenario(
        id: "tip-calc",
        title: "Split the bill",
        blurb: "Tip 18% on $73.40 and split it four ways — single tool call.",
        systemImage: "dollarsign.circle",
        prompt: "What's an 18% tip on $73.40, and what's each person's share for 4 people?",
        expectedTools: ["calc"],
        autoSend: true,
        accessibilityID: "demo-card-tip-calc",
        configure: nil
    )

    static let worldClock = DemoScenario(
        id: "world-clock",
        title: "What time is it in Tokyo?",
        blurb: "A single tool call with a non-numeric argument.",
        systemImage: "clock",
        prompt: "What time is it in Tokyo right now?",
        expectedTools: ["now"],
        autoSend: true,
        accessibilityID: "demo-card-world-clock",
        configure: nil
    )

    static let workspaceSearch = DemoScenario(
        id: "workspace-search",
        title: "Find that note",
        blurb: "Search a fixture workspace and cite the matching line.",
        systemImage: "magnifyingglass",
        prompt: "Find any note that mentions 'MCP' and quote the line.",
        expectedTools: ["sample_repo_search"],
        autoSend: true,
        accessibilityID: "demo-card-workspace-search",
        configure: nil
    )

    static let journalWrite = DemoScenario(
        id: "journal-write",
        title: "Save with my permission",
        blurb: "Triggers the per-call approval sheet before a side-effecting tool runs.",
        systemImage: "square.and.pencil",
        prompt: "Write a short journal entry for today named 'today.md' with a one-sentence mood summary.",
        expectedTools: ["write_file"],
        autoSend: false,
        accessibilityID: "demo-card-journal-write",
        configure: nil
    )

    /// Order matches card display order on the empty state.
    static let all: [DemoScenario] = [tipCalc, worldClock, workspaceSearch, journalWrite]

    static func scenario(id: String) -> DemoScenario? {
        all.first { $0.id == id }
    }
}
