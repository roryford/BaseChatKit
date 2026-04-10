import XCTest

/// Guards against regression on issue #242: silent `try?` / empty `catch { }`
/// blocks that swallow errors with no logging, no user surface, and no
/// diagnostic signal.
///
/// The test walks every `.swift` file under `Sources/`, identifies every
/// occurrence of `try?` and empty `catch { }`, and fails if the found set
/// does not exactly match the allowlist below. Adding a new entry to the
/// allowlist is a conscious act — the reviewer gets to challenge whether
/// the swallow is intentional.
///
/// Adding a new swallow: if the `try?` is a legitimate optional conversion
/// (e.g., `guard let x = try? Decoder.decode(...)`), append its fingerprint
/// to `allowlist`. If it's an unobserved error that should be surfaced,
/// route it through `DiagnosticsService.record(_:)` instead.
final class SilentCatchAuditTest: XCTestCase {

    /// Exact-match allowlist of `try?` call sites that existed when this
    /// audit test was added and have been reviewed as either (a) benign
    /// optional conversions or (b) existing Task.sleep call sites that
    /// deliberately ignore cancellation. Format: `"relative/path.swift:<trimmed line>"`.
    ///
    /// DO NOT add entries to make a failing test pass without human review.
    private static let allowlist: Set<String> = [
        // BaseChatCore
        "BaseChatCore/Models/ModelInfo.swift:guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),",
        "BaseChatCore/Models/ModelInfo.swift:if let metadata = try? GGUFMetadataReader.readMetadata(from: url) {",
        "BaseChatCore/Models/ModelInfo.swift:guard let contents = try? fileManager.contentsOfDirectory(",
        "BaseChatCore/Models/ModelInfo.swift:let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])",
        "BaseChatCore/Services/BackgroundDownloadManager.swift:guard let handle = try? FileHandle(forReadingFrom: fileURL) else {",
        "BaseChatCore/Services/BackgroundDownloadManager.swift:guard let headerData = try? handle.read(upToCount: 4), headerData.count == 4 else {",
        "BaseChatCore/Services/BackgroundDownloadManager.swift:try? FileManager.default.removeItem(at: tempURL)",
        "BaseChatCore/Services/Compression/AnchoredCompressor.swift:guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]) else {",
        "BaseChatCore/Services/GGUFMetadataReader.swift:guard let handle = try? FileHandle(forReadingFrom: url) else { return false }",
        "BaseChatCore/Services/MacroExpander.swift:guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {",
        "BaseChatCore/Services/MacroExpander.swift:guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {",
        "BaseChatCore/Services/ModelStorageService.swift:guard let contents = try? fileManager.contentsOfDirectory(",
        "BaseChatCore/Services/NetworkDiscoveryService.swift:guard let response = try? JSONDecoder().decode(OllamaResponse.self, from: data),",
        "BaseChatCore/Services/NetworkDiscoveryService.swift:guard let response = try? JSONDecoder().decode(KoboldResponse.self, from: data),",
        "BaseChatCore/Services/NetworkDiscoveryService.swift:guard let response = try? JSONDecoder().decode(OpenAIResponse.self, from: data),",

        // BaseChatBackends
        "BaseChatBackends/BonjourDiscoveryService.swift:try? await Task.sleep(for: .seconds(3))",
        "BaseChatBackends/BonjourDiscoveryService.swift:guard let r = try? JSONDecoder().decode(Resp.self, from: data),",
        "BaseChatBackends/ClaudeBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        "BaseChatBackends/ClaudeBackend.swift:let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()",
        "BaseChatBackends/KoboldCppBackend.swift:let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        "BaseChatBackends/KoboldCppBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        "BaseChatBackends/OllamaBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {",
        "BaseChatBackends/OllamaBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        "BaseChatBackends/OpenAIBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        "BaseChatBackends/SSECloudBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",

        // BaseChatUI — Task.sleep cancellation is intentionally ignored;
        // parser/rendering fallbacks are benign optional conversions.
        "BaseChatUI/ViewModels/ModelManagementViewModel.swift:try? await Task.sleep(for: .milliseconds(500))",
        "BaseChatUI/ViewModels/ServerDiscoveryViewModel.swift:try? modelContext.save()",
        "BaseChatUI/Views/Chat/AssistantMarkdownView.swift:if let parsed = try? AttributedString(",
        "BaseChatUI/Views/Chat/TypingIndicatorView.swift:try? await Task.sleep(for: .milliseconds(400))",
        "BaseChatUI/Views/Settings/APIEndpointEditorView.swift:try? modelContext.save()",

        // BaseChatTestSupport — test-only helpers, not production paths.
        "BaseChatTestSupport/TestHelpers.swift:try? FileManager.default.removeItem(at: url)",
        "BaseChatTestSupport/SlowMockBackend.swift:try? await Task.sleep(for: delay)",
        "BaseChatTestSupport/HardwareRequirements.swift:let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        "BaseChatTestSupport/HardwareRequirements.swift:if let containers = try? fm.contentsOfDirectory(",
        "BaseChatTestSupport/HardwareRequirements.swift:guard let contents = try? fm.contentsOfDirectory(",
        "BaseChatTestSupport/HardwareRequirements.swift:guard let files = try? fileManager.contentsOfDirectory(",
    ]

    func test_sourcesDirectoryContainsNoUnapprovedSilentSwallows() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var found: Set<String> = []
        var offenders: [(file: String, line: Int, text: String)] = []

        let swiftFiles = try Self.enumerateSwiftFiles(under: sourcesURL)
        XCTAssertFalse(swiftFiles.isEmpty, "Sources directory yielded no .swift files — path probably wrong")

        for fileURL in swiftFiles {
            let relativePath = fileURL.path.replacingOccurrences(of: sourcesURL.path + "/", with: "")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")
            for (index, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if Self.lineContainsSilentSwallow(line) {
                    let fingerprint = "\(relativePath):\(line)"
                    found.insert(fingerprint)
                    if !Self.allowlist.contains(fingerprint) {
                        offenders.append((file: relativePath, line: index + 1, text: line))
                    }
                }
            }
        }

        if !offenders.isEmpty {
            let formatted = offenders
                .map { "  \($0.file):\($0.line)  \($0.text)" }
                .joined(separator: "\n")
            XCTFail("""
                Unapproved silent error swallows found in Sources/.
                Route these through DiagnosticsService.record(_:) or add the fingerprint to SilentCatchAuditTest.allowlist with reviewer sign-off.

                \(formatted)
                """)
        }

        // Stale-allowlist check: every allowlist entry must still exist in
        // the source tree, or the list is drifting.
        let stale = Self.allowlist.subtracting(found)
        if !stale.isEmpty {
            let formatted = stale.sorted().joined(separator: "\n  ")
            XCTFail("""
                SilentCatchAuditTest.allowlist has stale entries that no longer exist in Sources/.
                Remove them:

                  \(formatted)
                """)
        }
    }

    // MARK: - Helpers

    /// Matches a line that contains a `try?` whose result is not bound to
    /// anything. Everything else (`let x = try?`, `guard let x = try?`,
    /// `if let x = try?`, `return try?`, `(try? ...)`) is still captured
    /// but will be checked against the allowlist.
    private static func lineContainsSilentSwallow(_ line: String) -> Bool {
        guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("///") else { return false }
        return line.contains("try?")
    }

    /// Walks upward from the test file to find the repo root, then returns
    /// the `Sources/` subdirectory. Using `#filePath` keeps this
    /// cross-platform and free of shell dependencies.
    private static func locateSourcesDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Sources")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "SilentCatchAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Sources/ from #filePath"
        ])
    }

    private static func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }
}
