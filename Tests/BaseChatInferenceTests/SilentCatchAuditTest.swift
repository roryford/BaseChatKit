import XCTest

/// Guards against regression on issue #242: silent `try?` and empty
/// `catch { }` blocks that swallow errors with no logging, no user
/// surface, and no diagnostic signal.
///
/// The test walks every `.swift` file under `Sources/` and reports two
/// kinds of offences:
///
/// 1. `try?` used as an unobserved error swallow. Any line containing
///    `try?` is captured and checked against the allowlist.
///
/// 2. Empty `catch { }` blocks. A catch block is considered empty when,
///    after the opening `catch { ... {` on one line, the next non-blank,
///    non-comment line is the closing `}`. One-line `catch { }` /
///    `catch {}` forms are detected directly.
///
/// Both categories use the same `"relative/path.swift:<trimmed line>"`
/// fingerprint format and are checked against the same allowlist.
///
/// ## Allowlist
///
/// Approved exceptions live in `silent_catch_allowlist.txt`, sitting next
/// to this file. The format is one fingerprint per line; `#`-prefixed
/// lines and blank lines are ignored. Adding a new swallow: if the
/// `try?` or empty catch is a legitimate optional conversion (e.g.,
/// `guard let x = try? Decoder.decode(...)`) or an intentional
/// best-effort cleanup, append its fingerprint to that file with a brief
/// `#` comment explaining why. If it's an unobserved error that should be
/// surfaced, route it through ``DiagnosticsService.record(_:)`` instead.
///
/// Externalising the list (PR refactoring out a hard-coded `Set<String>`)
/// means refactor PRs no longer have to touch this test file to add a
/// reviewed exception — they edit `silent_catch_allowlist.txt`.
///
/// Limitation: the empty-catch detector is line-based, not AST-based,
/// so nested `catch` inside interpolated strings or multi-line
/// expressions could theoretically confuse it. In practice the codebase
/// uses idiomatic `} catch {` layout, and the stale-allowlist check
/// catches drift immediately.
final class SilentCatchAuditTest: XCTestCase {

    /// Lazily loaded set of approved fingerprints from
    /// `silent_catch_allowlist.txt`. The file lives next to this test
    /// source file; we resolve it via `#filePath` so it works under both
    /// `swift test` and `xcodebuild test` without requiring the resource
    /// to be bundled into the test target.
    private static let allowlist: Set<String> = {
        do {
            return try loadAllowlist()
        } catch {
            // Fall back to an empty allowlist; the test will then fail
            // loudly with the file-loading error reported alongside the
            // first offender.
            XCTFail("Failed to load silent_catch_allowlist.txt: \(error)")
            return []
        }
    }()

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
                Route these through DiagnosticsService.record(_:) or add the fingerprint to Tests/BaseChatInferenceTests/silent_catch_allowlist.txt with reviewer sign-off.

                \(formatted)
                """)
        }

        // Stale-allowlist check: every allowlist entry must still exist in
        // the source tree, or the list is drifting.
        let stale = Self.allowlist.subtracting(found)
        if !stale.isEmpty {
            let formatted = stale.sorted().joined(separator: "\n  ")
            XCTFail("""
                silent_catch_allowlist.txt has stale entries that no longer exist in Sources/.
                Remove them:

                  \(formatted)
                """)
        }
    }

    // MARK: - Allowlist loading

    /// Reads `silent_catch_allowlist.txt` from beside this source file
    /// and returns the set of approved fingerprints. Blank lines and
    /// lines whose first non-whitespace character is `#` are skipped.
    /// Each remaining line is trimmed of trailing whitespace only —
    /// leading whitespace is preserved because some fingerprints embed
    /// indentation-significant tokens.
    static func loadAllowlist(filePath: StaticString = #filePath) throws -> Set<String> {
        let url = allowlistURL(filePath: filePath)
        let content = try String(contentsOf: url, encoding: .utf8)
        var entries: Set<String> = []
        for rawLine in content.components(separatedBy: "\n") {
            // Strip trailing CR (handles CRLF files) and trailing
            // whitespace introduced by editors.
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            while let last = line.last, last == " " || last == "\t" {
                line.removeLast()
            }
            // Skip blank lines.
            let leading = line.drop(while: { $0 == " " || $0 == "\t" })
            if leading.isEmpty { continue }
            // Skip comment lines (first non-whitespace char is `#`).
            if leading.first == "#" { continue }
            entries.insert(line)
        }
        return entries
    }

    /// URL of `silent_catch_allowlist.txt` next to this test source file.
    private static func allowlistURL(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .appendingPathComponent("silent_catch_allowlist.txt")
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
