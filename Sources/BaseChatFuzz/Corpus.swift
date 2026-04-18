import Foundation

public struct CorpusEntry: Codable, Sendable, Identifiable {
    public var id: String
    public var category: String
    public var system: String?
    public var turns: [Turn]

    public struct Turn: Codable, Sendable {
        public var role: String
        public var text: String
    }
}

public enum Corpus {
    public static func load() -> [CorpusEntry] {
        guard let url = Bundle.module.url(forResource: "seeds", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([CorpusEntry].self, from: data) else {
            return []
        }
        return entries
    }
}
