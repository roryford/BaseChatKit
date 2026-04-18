import Foundation

enum OllamaDiscovery {
    /// Asynchronously fetches the list of installed Ollama model names from `localhost:11434`.
    /// Throws on network errors or malformed JSON; returns an empty array if the
    /// server responds with no installed models.
    static func fetchModels() async throws -> [String] {
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            throw CLIError("OllamaDiscovery: bad URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CLIError("OllamaDiscovery: non-HTTP response from \(url)")
        }
        guard http.statusCode == 200 else {
            throw CLIError("OllamaDiscovery: HTTP \(http.statusCode) from \(url)")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CLIError("OllamaDiscovery: JSON parse failed: \(error)")
        }
        guard let json = parsed as? [String: Any], let models = json["models"] as? [[String: Any]] else {
            throw CLIError("OllamaDiscovery: unexpected JSON shape (missing `models` array)")
        }
        return models.compactMap { $0["name"] as? String }
    }
}
