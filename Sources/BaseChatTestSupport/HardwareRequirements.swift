import Foundation
#if canImport(Metal)
import Metal
#endif

/// Static flags for hardware-gated test skipping.
///
/// Use these with `XCTSkipUnless` / `XCTSkipIf` at the top of tests that
/// require specific hardware or OS capabilities.
public enum HardwareRequirements {

    /// `true` when running on Apple Silicon (arm64). MLX and llama.cpp
    /// backends require this architecture.
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// `true` when running on a physical device rather than the iOS Simulator.
    /// Metal compute is unavailable in the simulator, so backends that use
    /// GPU acceleration (MLX, llama.cpp) will fail there.
    public static var isPhysicalDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// `true` when a real Metal GPU device is accessible in the current process context.
    ///
    /// Apple Silicon may still fail to access Metal when running `swift test` via SSH
    /// or in a headless CI environment without a GPU context. Tests that create
    /// `MLXArray` values must gate on this flag, not just `isAppleSilicon`.
    public static var hasMetalDevice: Bool {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }

    /// `true` when the OS version supports Foundation Models (macOS 26+ / iOS 26+).
    /// This does NOT check whether Apple Intelligence is enabled — use
    /// `FoundationBackend.isAvailable` for that.
    public static var hasFoundationModels: Bool {
        if #available(macOS 26, iOS 26, *) {
            return true
        }
        return false
    }

    // MARK: - Ollama

    /// `true` when a local Ollama server is reachable at `localhost:11434`.
    ///
    /// Performs a synchronous HTTP GET to `/api/tags` with a short timeout.
    /// Use with `XCTSkipUnless` to skip Ollama E2E tests when the server is down.
    public static var hasOllamaServer: Bool {
        fetchOllamaModels() != nil
    }

    /// Returns an Ollama model name, preferring one in the given parameter size range.
    ///
    /// Queries `/api/tags` synchronously. Prefers models whose `parameter_size`
    /// falls in `preferredSizeRange` (e.g. "7.2B" → 7.2). Falls back to the
    /// first available model if none match the range. Returns `nil` only if the
    /// server is unreachable or has no models.
    public static func findOllamaModel(preferredSizeRange: ClosedRange<Double> = 6.5...9.0) -> String? {
        guard let models = fetchOllamaModels() else { return nil }
        return selectOllamaModel(from: models, preferredSizeRange: preferredSizeRange)
    }

    /// Returns the first installed Ollama model whose name contains `substring`,
    /// or `nil` if none match. Returns `nil` if the server is unreachable.
    ///
    /// Unlike `findOllamaModel(preferredSizeRange:)`, this matches by name only
    /// and does not consult `parameter_size`. Use for CLI callers that let the
    /// user nominate a specific model by substring.
    public static func findOllamaModel(nameContains substring: String) -> String? {
        guard let models = fetchOllamaModels() else { return nil }
        for model in models {
            if let name = model["name"] as? String, name.contains(substring) {
                return name
            }
        }
        return nil
    }

    /// Returns the list of installed Ollama model names, or `nil` if the server
    /// is unreachable.
    public static func listOllamaModels() -> [String]? {
        guard let models = fetchOllamaModels() else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    /// Selects the best model from a pre-fetched Ollama model list.
    /// Extracted from `findOllamaModel` for testability.
    static func selectOllamaModel(
        from models: [[String: Any]],
        preferredSizeRange: ClosedRange<Double> = 6.5...9.0
    ) -> String? {
        for model in models {
            guard let name = model["name"] as? String,
                  let details = model["details"] as? [String: Any],
                  let paramSize = details["parameter_size"] as? String else { continue }
            let numeric = paramSize.replacingOccurrences(of: "B", with: "")
            if let value = Double(numeric), preferredSizeRange.contains(value) {
                return name
            }
        }
        return models.first?["name"] as? String
    }

    /// Fetches the model list from Ollama's `/api/tags` endpoint synchronously.
    /// Returns `nil` if the server is unreachable or the response is malformed.
    private static func fetchOllamaModels() -> [[String: Any]]? {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        let semaphore = DispatchSemaphore(value: 0)
        // Box to avoid "mutation of captured var in concurrently-executing code" warning.
        final class Box: @unchecked Sendable { var value: [[String: Any]]?  }
        let box = Box()

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }
            box.value = models
        }.resume()
        // Timeout slightly above the request timeout to avoid hanging if the
        // URLSession completion handler is never invoked.
        let result = semaphore.wait(timeout: .now() + 5)
        return result == .success ? box.value : nil
    }

    // MARK: - MLX Models

    /// Scans common model directories for a loadable local MLX model directory.
    ///
    /// Searches:
    /// 1. `~/Documents/Models/` (default `ModelStorageService` location)
    /// 2. App container `Documents/Models/` directories
    ///
    /// Returns the URL of the first loadable MLX directory found, or `nil`.
    public static func findMLXModelDirectory() -> URL? {
        let fm = FileManager.default

        // Collect candidate directories to scan.
        var searchDirs: [URL] = []

        // 1. Default ~/Documents/Models/
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            searchDirs.append(docs.appendingPathComponent("Models", isDirectory: true))
        }

        // 2. App container directories: ~/Library/Containers/*/Data/Documents/Models/
        if let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let containersDir = library.appendingPathComponent("Containers", isDirectory: true)
            if let containers = try? fm.contentsOfDirectory(
                at: containersDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for container in containers {
                    let modelsDir = container
                        .appendingPathComponent("Data/Documents/Models", isDirectory: true)
                    searchDirs.append(modelsDir)
                }
            }
        }

        // Scan each directory for valid MLX model subdirectories.
        for dir in searchDirs {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for candidate in contents {
                if isValidMLXDirectory(candidate, fileManager: fm) {
                    return candidate
                }
            }
        }

        return nil
    }

    // MARK: - GGUF Models

    /// Scans common model directories for a loadable `.gguf` file.
    ///
    /// Searches the same `Documents/Models/` locations as `findMLXModelDirectory`.
    /// Returns the URL of the first regular `.gguf` file >= 50 MB — the size
    /// gate filters out test fixtures (typically a few hundred bytes to a few
    /// MB) while staying well below any real quantized model. Directories
    /// that happen to be named with a `.gguf` extension are also rejected.
    public static func findGGUFModel() -> URL? {
        let fm = FileManager.default
        var searchDirs: [URL] = []

        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            searchDirs.append(docs.appendingPathComponent("Models", isDirectory: true))
        }

        if let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let containersDir = library.appendingPathComponent("Containers", isDirectory: true)
            if let containers = try? fm.contentsOfDirectory(
                at: containersDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for container in containers {
                    let modelsDir = container
                        .appendingPathComponent("Data/Documents/Models", isDirectory: true)
                    searchDirs.append(modelsDir)
                }
            }
        }

        // Scan each directory (non-recursively) for a `.gguf` file large enough
        // to be a real model. Test fixtures elsewhere in these directories can
        // be as small as a few hundred bytes or a few MB, so require at least
        // 50 MB — well below any real quantized model and well above any fixture.
        let minimumModelSize: Int64 = 50 * 1024 * 1024
        for dir in searchDirs {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for candidate in contents where candidate.pathExtension.lowercased() == "gguf" {
                // Directories named with a `.gguf` extension would otherwise
                // pass the path-extension filter and fail to load; require
                // `isRegularFile` explicitly.
                let values = try? candidate.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                )
                if values?.isRegularFile == true,
                   let size = values?.fileSize,
                   Int64(size) >= minimumModelSize {
                    return candidate
                }
            }
        }

        return nil
    }

    /// Checks whether a directory looks like a loadable local MLX snapshot.
    ///
    /// A directory must contain:
    /// - `config.json` with a non-empty `model_type`
    /// - at least one `.safetensors` weight file
    /// - a Hugging Face tokenizer artifact (`tokenizer.json` or `tokenizer.model`)
    static func isValidMLXDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let configURL = url.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path),
              let configData = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let modelType = json["model_type"] as? String,
              !modelType.isEmpty else {
            return false
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        let fileNames = Set(files.map { $0.lastPathComponent.lowercased() })
        let hasWeights = files.contains { $0.pathExtension.lowercased() == "safetensors" }
        let hasTokenizer = fileNames.contains("tokenizer.json") || fileNames.contains("tokenizer.model")

        return hasWeights && hasTokenizer
    }
}
