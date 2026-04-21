import XCTest

/// Guards against regression on issue #242: silent `try?` and empty
/// `catch { }` blocks that swallow errors with no logging, no user
/// surface, and no diagnostic signal.
///
/// The test walks every `.swift` file under `Sources/` and reports two
/// kinds of offences:
///
/// 1. `try?` used as an unobserved error swallow. Any line containing
///    `try?` is captured and checked against ``allowlist``.
///
/// 2. Empty `catch { }` blocks. A catch block is considered empty when,
///    after the opening `catch { ... {` on one line, the next non-blank,
///    non-comment line is the closing `}`. One-line `catch { }` /
///    `catch {}` forms are detected directly.
///
/// Both categories use the same `"relative/path.swift:<trimmed line>"`
/// fingerprint format and are checked against the same ``allowlist``.
///
/// Adding a new swallow: if the `try?` or empty catch is a legitimate
/// optional conversion (e.g., `guard let x = try? Decoder.decode(...)`)
/// or an intentional best-effort cleanup, append its fingerprint to
/// ``allowlist``. If it's an unobserved error that should be surfaced,
/// route it through ``DiagnosticsService.record(_:)`` instead.
///
/// Limitation: the empty-catch detector is line-based, not AST-based,
/// so nested `catch` inside interpolated strings or multi-line
/// expressions could theoretically confuse it. In practice the codebase
/// uses idiomatic `} catch {` layout, and the stale-allowlist check
/// catches drift immediately.
final class SilentCatchAuditTest: XCTestCase {

    /// Exact-match allowlist of `try?` call sites that existed when this
    /// audit test was added and have been reviewed as either (a) benign
    /// optional conversions or (b) existing Task.sleep call sites that
    /// deliberately ignore cancellation. Format: `"relative/path.swift:<trimmed line>"`.
    ///
    /// DO NOT add entries to make a failing test pass without human review.
    private static let allowlist: Set<String> = [
        // BaseChatInference
        // JSONSchemaValue uses the standard "try-each-type-in-order" decoder pattern for
        // heterogeneous JSON. Each `try?` is bound to a named constant and the result is
        // used immediately; there is no silent discard — the next branch handles the miss.
        "BaseChatInference/Models/ToolTypes.swift:} else if let b = try? container.decode(Bool.self) {",
        "BaseChatInference/Models/ToolTypes.swift:} else if let n = try? container.decode(Double.self) {",
        "BaseChatInference/Models/ToolTypes.swift:} else if let s = try? container.decode(String.self) {",
        "BaseChatInference/Models/ToolTypes.swift:} else if let arr = try? container.decode([JSONSchemaValue].self) {",
        "BaseChatInference/Models/ModelInfo.swift:guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),",
        "BaseChatInference/Models/ModelInfo.swift:if let metadata = try? GGUFMetadataReader.readMetadata(from: url) {",
        "BaseChatInference/Models/ModelInfo.swift:guard let contents = try? fileManager.contentsOfDirectory(",
        "BaseChatInference/Models/ModelInfo.swift:let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])",
        "BaseChatInference/Services/BackgroundDownloadManager.swift:try? FileManager.default.removeItem(at: tempURL)",
        // Best-effort temp-file cleanup before throwing a path-traversal error; the removal
        // failure is irrelevant since the download is already being rejected.
        "BaseChatInference/Services/BackgroundDownloadManager+URLSessionDelegate.swift:try? FileManager.default.removeItem(at: tempURL)",
        // File-based persistence helpers: reading optional data whose absence is expected
        // (no pending downloads or no resume data), decoding optional JSON (corrupt file
        // falls back to empty dict), and best-effort cleanup of stale/consumed files.
        "BaseChatInference/Services/BackgroundDownloadManager.swift:guard let data = try? Data(contentsOf: url) else { return nil }",
        "BaseChatInference/Services/BackgroundDownloadManager.swift:try? FileManager.default.removeItem(at: url)",
        "BaseChatInference/Services/BackgroundDownloadManager.swift:guard let data = try? Data(contentsOf: pendingMetadataFileURL) else { return nil }",
        "BaseChatInference/Services/BackgroundDownloadManager.swift:return try? JSONDecoder().decode([String: [String: String]].self, from: data)",
        "BaseChatInference/Services/BackgroundDownloadManager.swift:try? FileManager.default.removeItem(at: resumeDataFileURL(for: id))",
        "BaseChatInference/Services/BackgroundDownloadManager.swift:guard let contents = try? FileManager.default.contentsOfDirectory(",
        "BaseChatInference/Services/DownloadFileValidator.swift:guard let handle = try? FileHandle(forReadingFrom: fileURL) else {",
        "BaseChatInference/Services/DownloadFileValidator.swift:guard let headerData = try? handle.read(upToCount: 4), headerData.count == 4 else {",
        "BaseChatInference/Services/GGUFMetadataReader.swift:guard let handle = try? FileHandle(forReadingFrom: url) else { return false }",
        "BaseChatInference/Services/ModelStorageService.swift:guard let contents = try? fileManager.contentsOfDirectory(",

        // BaseChatCore
        // File-protection hardening: enumerating the store directory to locate
        // SQLite WAL sidecars is best-effort. If the directory read fails
        // (permissions race, parent unmounted), we skip sidecar protection and
        // the main store is still protected — the error is not actionable.
        "BaseChatCore/ModelContainerFactory.swift:guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else {",

        // BaseChatBackends
        "BaseChatBackends/ClaudeBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        // parseEventType / parseThinkingDelta: SSE payload probes. Malformed
        // JSON is a non-event (ignore the payload) — same pattern as parseToken.
        "BaseChatBackends/ClaudeBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {",
        "BaseChatBackends/OllamaBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {",
        "BaseChatBackends/OllamaBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        // /api/show thinking-detection probe: best-effort optimization that skips
        // the 2048-token reserve on non-thinking models. Failures are logged at
        // info level and fall through to `isThinkingModel = false`, which is the
        // same safe default we'd pick if the endpoint didn't exist (older Ollama).
        "BaseChatBackends/OllamaBackend.swift:self.isThinkingModel = (try? await detectThinkingCapability()) ?? false",
        "BaseChatBackends/OllamaBackend.swift:guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {",
        "BaseChatBackends/OpenAIBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        "BaseChatBackends/SSECloudBackend.swift:let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        // MLXBackend.validateArchitecture: best-effort read of the MLX model's
        // `config.json`. A missing/unreadable/malformed config is not fatal here
        // — we deliberately fall through so mlx-swift-lm's own load path produces
        // the real diagnostic (missing weights, malformed directory, etc.) rather
        // than masking it with a false architecture error.
        "BaseChatBackends/MLXBackend.swift:guard let data = try? Data(contentsOf: configURL),",
        "BaseChatBackends/MLXBackend.swift:let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {",

        // BaseChatFuzz — SessionScript resource loader uses the "try-each-shape-in-order"
        // decoder pattern: each `try?` is a shape probe (single-object vs. array of scripts).
        // When both shape probes miss, SessionScript.loadAll writes an explicit stderr
        // diagnostic on the next line. The Data(contentsOf:) swallow is a benign
        // skip-this-resource case — the loader continues with the remaining scripts.
        "BaseChatFuzz/SessionScript.swift:guard let data = try? Data(contentsOf: url) else { continue }",
        "BaseChatFuzz/SessionScript.swift:if let one = try? decoder.decode(SessionScript.self, from: data) {",
        "BaseChatFuzz/SessionScript.swift:if let many = try? decoder.decode([SessionScript].self, from: data) {",

        // BaseChatFuzz/Scenarios — ScenarioTestBackend pauses mid-thinking to give
        // cancel/retry scenarios a deterministic window. The sleep is best-effort:
        // if the Task is cancelled during the pause, we deliberately fall through
        // to the post-thinking emit check (which honours Task.isCancelled on its
        // own) rather than observing the CancellationError.
        "BaseChatFuzz/Scenarios/ScenarioTestBackend.swift:try? await Task.sleep(for: pause)",

        // BaseChatUI — Task.sleep cancellation is intentionally ignored;
        // parser/rendering fallbacks are benign optional conversions.
        "BaseChatUI/ViewModels/ModelManagementViewModel.swift:try? await Task.sleep(for: .milliseconds(500))",
        "BaseChatUI/Views/Chat/AssistantMarkdownView.swift:if let parsed = try? AttributedString(",
        "BaseChatUI/Views/Chat/TypingIndicatorView.swift:try? await Task.sleep(for: .milliseconds(400))",

        // BaseChatTestSupport — test-only helpers, not production paths.
        "BaseChatTestSupport/TestHelpers.swift:try? FileManager.default.removeItem(at: url)",
        "BaseChatTestSupport/SlowMockBackend.swift:try? await Task.sleep(for: delay)",
        "BaseChatTestSupport/PerceivedLatencyBackend.swift:try? await Task.sleep(for: ttft)",
        "BaseChatTestSupport/PerceivedLatencyBackend.swift:try? await Task.sleep(for: delay)",
        "BaseChatTestSupport/ChaosBackend.swift:try? await Task.sleep(for: delay)",
        "BaseChatTestSupport/ChaosBackend.swift:try? await Task.sleep(for: stallDuration)",
        "BaseChatTestSupport/HardwareRequirements.swift:let configData = try? Data(contentsOf: configURL),",
        "BaseChatTestSupport/HardwareRequirements.swift:let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],",
        "BaseChatTestSupport/HardwareRequirements.swift:let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],",
        "BaseChatTestSupport/HardwareRequirements.swift:if let containers = try? fm.contentsOfDirectory(",
        "BaseChatTestSupport/HardwareRequirements.swift:guard let contents = try? fm.contentsOfDirectory(",
        "BaseChatTestSupport/HardwareRequirements.swift:guard let files = try? fileManager.contentsOfDirectory(",
        "BaseChatTestSupport/HardwareRequirements.swift:let values = try? candidate.resourceValues(",

        // Empty `catch { }` blocks. These are best-effort reads whose
        // partial result is still useful; swallowing the error is
        // intentional and the remaining behaviour is correct.
        //
        // ClaudeBackend.readErrorBody: we're assembling an error body
        // for a log message after the upstream request already failed.
        // A truncated body is better than crashing the error handler.
        "BaseChatBackends/ClaudeBackend.swift:} catch {",
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

            // Pass 1: unbound / unobserved `try?` call sites.
            for (index, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if Self.lineContainsSilentTry(line) {
                    let fingerprint = "\(relativePath):\(line)"
                    found.insert(fingerprint)
                    if !Self.allowlist.contains(fingerprint) {
                        offenders.append((file: relativePath, line: index + 1, text: line))
                    }
                }
            }

            // Pass 2: empty `catch { }` blocks — inline `catch {}` /
            // `catch { }` and the multi-line form where the next
            // non-blank, non-comment line after `catch {` is just `}`.
            for emptyCatch in Self.findEmptyCatches(in: lines) {
                let fingerprint = "\(relativePath):\(emptyCatch.text)"
                found.insert(fingerprint)
                if !Self.allowlist.contains(fingerprint) {
                    offenders.append((file: relativePath, line: emptyCatch.line, text: emptyCatch.text))
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

    /// Matches a line containing `try?`. Both unbound (`try? foo()`) and
    /// bound (`let x = try? foo()`) forms are captured; the allowlist
    /// decides which bound conversions are intentional.
    private static func lineContainsSilentTry(_ line: String) -> Bool {
        guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("///") else { return false }
        return line.contains("try?")
    }

    /// Scans an array of lines and returns every empty `catch { }` block.
    /// The returned `text` is the trimmed `catch {` opener (so the
    /// fingerprint is stable regardless of the closing brace position).
    ///
    /// A catch is considered empty when:
    ///
    /// - The inline form `} catch {}` / `} catch { }` appears on one line
    ///   (possibly with a pattern such as `catch let error {}`), or
    /// - A line matches `catch {` (optionally with a pattern) and the
    ///   next non-blank, non-comment line in the file is `}`.
    private static func findEmptyCatches(in lines: [String]) -> [(line: Int, text: String)] {
        var results: [(line: Int, text: String)] = []
        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                continue
            }
            // Inline empty catch: `catch {}`, `catch { }`,
            // `catch let err {}`, etc. Match on the trimmed line.
            if Self.isInlineEmptyCatch(trimmed) {
                results.append((line: index + 1, text: trimmed))
                continue
            }
            // Multi-line opener: ends with `catch {` (possibly with a
            // pattern like `catch let error as MyError {`).
            guard Self.lineOpensCatchBlock(trimmed) else { continue }
            // Look ahead for the first non-blank, non-comment line.
            var peek = index + 1
            while peek < lines.count {
                let next = lines[peek].trimmingCharacters(in: .whitespaces)
                if next.isEmpty { peek += 1; continue }
                if next.hasPrefix("//") || next.hasPrefix("///") || next.hasPrefix("*") {
                    peek += 1
                    continue
                }
                if next == "}" {
                    results.append((line: index + 1, text: trimmed))
                }
                break
            }
        }
        return results
    }

    /// `true` when the trimmed line is a complete empty catch statement
    /// on a single line: `catch {}`, `} catch { }`, `catch let e {}`, etc.
    private static func isInlineEmptyCatch(_ line: String) -> Bool {
        guard line.contains("catch") else { return false }
        // Collapse interior whitespace, then look for `catch <pattern?> {}`.
        let collapsed = line.replacingOccurrences(
            of: "[ \t]+",
            with: " ",
            options: .regularExpression
        )
        // Examples that should match:
        //   "catch {}"                 → contains "catch {}"
        //   "catch { }"                → after collapse: "catch { }"
        //   "} catch {}"               → contains "catch {}"
        //   "catch let e as Foo {}"    → ends with "{}"
        if collapsed.contains("catch {}") || collapsed.contains("catch { }") {
            return true
        }
        // Catch-with-pattern inline form: look for a `catch` token
        // followed later by an empty `{}`/`{ }` on the same line.
        if let catchRange = collapsed.range(of: "catch ") {
            let tail = collapsed[catchRange.upperBound...]
            if tail.hasSuffix("{}") || tail.hasSuffix("{ }") {
                return true
            }
        }
        return false
    }

    /// `true` when the line opens a (possibly multi-line) catch block
    /// that could be empty: its trimmed form ends with `{` and contains
    /// a `catch` token. Excludes single-line forms already handled by
    /// ``isInlineEmptyCatch(_:)``.
    private static func lineOpensCatchBlock(_ line: String) -> Bool {
        guard line.hasSuffix("{") else { return false }
        guard line.contains("catch") else { return false }
        // Heuristic: require `catch` to be a standalone token, not part
        // of a larger identifier like `catchAll`.
        let pattern = #"(^|[^A-Za-z0-9_])catch([^A-Za-z0-9_]|$)"#
        return line.range(of: pattern, options: .regularExpression) != nil
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
