import Foundation

enum OllamaDiscovery {
    /// Synchronously fetches the list of installed Ollama model names from `localhost:11434`.
    /// Returns `nil` if the server is unreachable or returns malformed JSON.
    static func fetchModels() -> [String]? {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value: [String]? }
        let box = Box()

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }
            box.value = models.compactMap { $0["name"] as? String }
        }.resume()
        let result = semaphore.wait(timeout: .now() + 5)
        return result == .success ? box.value : nil
    }
}
