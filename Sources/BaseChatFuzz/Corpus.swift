import Foundation
import BaseChatInference

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
    /// Loads `Resources/corpus/seeds.json`. Failures are surfaced via `Log.inference`
    /// and stderr — callers (e.g. `FuzzRunner.run`) treat an empty corpus as a hard
    /// error rather than silently iterating zero times.
    public static func load() -> [CorpusEntry] {
        guard let url = Bundle.module.url(forResource: "seeds", withExtension: "json") else {
            let msg = "Corpus.load: seeds.json missing from Bundle.module — Swift Package resource not bundled."
            Log.inference.error("\(msg, privacy: .public)")
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let msg = "Corpus.load: failed to read \(url.path): \(error)"
            Log.inference.error("\(msg, privacy: .public)")
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            return []
        }
        do {
            return try JSONDecoder().decode([CorpusEntry].self, from: data)
        } catch {
            let msg = "Corpus.load: JSON decode failed for \(url.path): \(error)"
            Log.inference.error("\(msg, privacy: .public)")
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            return []
        }
    }
}
