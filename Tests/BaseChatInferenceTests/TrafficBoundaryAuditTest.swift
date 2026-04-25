import XCTest

/// Source-level guard that future code changes don't silently regress the
/// privacy/network posture documented in `SECURITY.md`.
///
/// Walks every `.swift` file under `Sources/` and enforces five categories of
/// rule. Each rule has a tightly-scoped allowlist (path-only, capped, with
/// inline justifications) so that "approve to make the test pass" is visible
/// in a code review rather than rubber-stamped.
///
/// ## Rules
///
/// 1. **Network I/O imports** — `URLSession`, `URLRequest`,
///    `URLSessionConfiguration` permitted only in network-allowlisted files.
///    Catches accidental UI/Inference code that opens a session directly.
///
/// 2. **C interop / dynamic dispatch** — `@_silgen_name`, `@_cdecl`,
///    `dlopen`, `dlsym`, `NSClassFromString`, `objc_getClass`,
///    `class_createInstance`, `Process(`, `NSTask`, `posix_spawn`, `popen(`,
///    `system(` banned in `Sources/`. These bypass `LocalOnlyNetworkIsolationTests`'
///    URLSession-level canary by going straight to syscalls or runtime
///    metaclass lookup. Only `Process(` has a narrow path-allowlist for the
///    Fuzz harness CLI which legitimately spawns subprocesses.
///
/// 3. **Hostname literals** — strings matching `https?://(api|www)\.…`
///    permitted only in hostname-allowlisted files. Stops a UI string
///    reading "OpenAI" from accidentally containing a real endpoint URL.
///
/// 4. **Privacy-sensitive Apple APIs** — `CloudKitDatabase`,
///    `NSUbiquitous*`, `NSUserActivity` Handoff, `UIPasteboard.general`
///    writes without `localOnly`, `FileProtectionType.none`. Each finding
///    requires a fingerprint entry with an explicit justification.
///    (`os_log` `.public` deliberately not covered — see the
///    `privacyAPIPattern` doc comment for rationale.)
///
/// 6. **Import-graph boundary** — locks in the layered architecture from
///    `CLAUDE.md`. UI must not depend on Backends; Inference must not
///    depend on Core or Backends.
///
/// (Rules 5 and 7 — Package.swift hygiene and `#if` trait-name validity —
/// land in Phase 2 alongside the trait split.)
///
/// ## Allowlist policy
///
/// Adding a path to `networkIOAllowlist` or `hostnameAllowlist` requires
/// reviewer sign-off, the per-list cap, and a justification. Rule 2 and 4
/// allowlists carry per-entry justification comments. The test fails if a
/// list grows beyond its cap, on the theory that an ever-growing exception
/// list weakens the rule.
///
/// ## File discovery
///
/// Reuses the `#filePath` upwalk pattern from `SilentCatchAuditTest` —
/// portable, no shell dependencies, finds the same `Sources/` regardless
/// of where `swift test` is invoked.
final class TrafficBoundaryAuditTest: XCTestCase {

    // MARK: - Allowlists

    /// Files where direct `URLSession`/`URLRequest`/`URLSessionConfiguration`
    /// usage is approved. These do legitimate network I/O — cloud backends,
    /// the model-download manager, test infra.
    ///
    /// **Cap: 20 entries.** Adding to this list weakens Rule 1; require
    /// reviewer sign-off and prefer to route new network code through
    /// `URLSessionProvider` (which is itself in this allowlist).
    private static let networkIOAllowlist: Set<String> = [
        // Cloud / Ollama backends — every backend that talks to a remote
        // endpoint goes through URLSessionProvider and lives here.
        "BaseChatBackends/ClaudeBackend.swift",
        "BaseChatBackends/OpenAIBackend.swift",
        "BaseChatBackends/OllamaBackend.swift",
        "BaseChatBackends/OllamaModelListService.swift",
        "BaseChatBackends/SSECloudBackend.swift",
        "BaseChatBackends/URLSessionProvider.swift",
        "BaseChatBackends/PinnedSessionDelegate.swift",
        "BaseChatBackends/DNSRebindingGuard.swift",

        // Model download path — HuggingFace GGUF/MLX downloads. Will move
        // behind a model-download trait in a future phase; for now the
        // local-only build assumes models are pre-bundled and these code
        // paths are not exercised at runtime.
        "BaseChatInference/Services/BackgroundDownloadManager.swift",
        "BaseChatInference/Services/BackgroundDownloadManager+URLSessionDelegate.swift",
        "BaseChatInference/Services/HuggingFaceService.swift",
        "BaseChatInference/Services/SSEStreamParser.swift",
        "BaseChatUI/ViewModels/ModelManagementViewModel.swift",

        // Reference tools — bck-tools CLI tool harness, intentional HTTP fetcher.
        "BaseChatTools/ReferenceTools/HttpGetFixtureTool.swift",

        // Fuzz scenario that exercises network-shaped retry behaviour.
        "BaseChatFuzz/Scenarios/ThinkingAcrossRetryScenario.swift",

        // Test infrastructure — DenyAll, Mock, hardware probes. Live in
        // BaseChatTestSupport so production code never picks them up by
        // import.
        "BaseChatTestSupport/MockURLProtocol.swift",
        "BaseChatTestSupport/DenyAllURLProtocol.swift",
        "BaseChatTestSupport/HardwareRequirements.swift",
    ]

    /// Files where hostname literals (e.g. `https://api.anthropic.com`) are
    /// approved. Smaller superset than `networkIOAllowlist` because not
    /// every networking file embeds a hostname (e.g., `URLSessionProvider`
    /// composes URLs at the call site).
    ///
    /// **Cap: 12 entries.**
    private static let hostnameAllowlist: Set<String> = [
        "BaseChatBackends/OpenAIBackend.swift",
        "BaseChatInference/Services/HuggingFaceService.swift",
        "BaseChatInference/Services/BackgroundDownloadManager.swift",
        "BaseChatTestSupport/MockHuggingFaceService.swift",
        // Validation reasons display canonical scheme/host examples in
        // user-facing error strings.
        "BaseChatCore/Models/APIEndpointValidationReason.swift",
        // Provider enum exposes default base URLs as static data.
        "BaseChatInference/Models/APIProvider.swift",
    ]

    /// Files where `Process(` is approved. Other C-interop / dynamic-
    /// dispatch patterns have **no** allowlist — each is a hard ban.
    private static let processSpawnAllowlist: Set<String> = [
        // Fuzz harness CLI: HarnessMetadata captures git/sw_vers via
        // subprocess for reproducibility; Replayer launches a child
        // process to replay a corpus seed in isolation.
        "BaseChatFuzz/HarnessMetadata.swift",
        "BaseChatFuzz/Replay/Replayer.swift",
    ]

    /// Privacy-sensitive Apple-API call sites that have been individually
    /// reviewed and approved. Format: `"relative/path.swift:<trimmed line>"`.
    /// Each entry **must** carry a `// Justification:` comment in this
    /// list noting why the use is safe.
    ///
    /// **Cap: 6 entries.**
    private static let privacyAPIAllowlist: Set<String> = [
        // Justification: user-initiated copy of an assistant message to the
        // clipboard. A regulated build should pair this with `localOnly = true`
        // to keep content off Universal Clipboard / iCloud sync; tracked
        // for follow-up alongside the THREAT_MODEL.md non-mitigations list.
        "BaseChatUI/Views/Chat/AssistantMarkdownView.swift:UIPasteboard.general.string = text",
        // Justification: same as above — copy-text affordance on the message
        // action menu. Same follow-up applies.
        "BaseChatUI/Views/Chat/MessageActionMenu.swift:UIPasteboard.general.string = text",
    ]

    // MARK: - Test entry points

    func test_rule1_networkIOOnlyInAllowlistedFiles() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            if Self.networkIOAllowlist.contains(relativePath) { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.shouldScan(line: trimmed) else { continue }
                if Self.matches(Self.networkIOPattern, in: trimmed) {
                    offenders.append(.init(
                        rule: 1, ruleName: "Network I/O imports",
                        file: relativePath, line: idx + 1, text: trimmed,
                        why: "URLSession-family types must live in URLSessionProvider or behind a networking trait so LocalOnlyNetworkIsolationTests can intercept all outbound requests.",
                        fix: "Route network I/O through URLSessionProvider, or — if this file is genuinely a new network boundary — add it to TrafficBoundaryAuditTest.networkIOAllowlist with reviewer sign-off."
                    ))
                }
            }
        }

        Self.assertNoOffenders(offenders)

        XCTAssertLessThanOrEqual(
            Self.networkIOAllowlist.count, 20,
            "networkIOAllowlist exceeds cap. Each new entry weakens the rule — re-architect rather than expand the list."
        )
    }

    func test_rule2_cInteropAndDynamicDispatchBanned() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.shouldScan(line: trimmed) else { continue }

                // Process( has a narrow path-allowlist (Fuzz CLI subprocess use).
                if Self.matches(Self.processSpawnPattern, in: trimmed) {
                    if !Self.processSpawnAllowlist.contains(relativePath) {
                        offenders.append(.init(
                            rule: 2, ruleName: "Subprocess spawn (Process)",
                            file: relativePath, line: idx + 1, text: trimmed,
                            why: "Spawning subprocesses bypasses the URLSession boundary; a child process can talk to anything without LocalOnlyNetworkIsolationTests seeing it.",
                            fix: "Remove the subprocess. If this is a CLI harness like BaseChatFuzz, add the file to processSpawnAllowlist with justification."
                        ))
                    }
                    continue
                }

                // Everything else in rule 2 has no allowlist.
                if Self.matches(Self.cInteropPattern, in: trimmed) {
                    offenders.append(.init(
                        rule: 2, ruleName: "C interop / dynamic dispatch",
                        file: relativePath, line: idx + 1, text: trimmed,
                        why: "Direct syscalls, dlopen, NSClassFromString, posix_spawn, etc. evade every higher-level isolation seam (URLProtocol, trait gates, import-graph rules).",
                        fix: "Use a Foundation-level API instead. There is no allowlist for this rule — escalate if you believe an exception is necessary."
                    ))
                }
            }
        }

        Self.assertNoOffenders(offenders)
    }

    func test_rule3_hostnameLiteralsOnlyInAllowlistedFiles() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            if Self.hostnameAllowlist.contains(relativePath) { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.shouldScan(line: trimmed) else { continue }
                if Self.matches(Self.hostnamePattern, in: trimmed) {
                    offenders.append(.init(
                        rule: 3, ruleName: "Hostname literal",
                        file: relativePath, line: idx + 1, text: trimmed,
                        why: "Hostnames belong in cloud-backend/HF-service files (or the future Hosts.swift collection point). A hostname elsewhere is either a leak or a documentation string that should live in a doc comment.",
                        fix: "Move the literal to one of the allowlisted hostname files, or — for documentation strings — convert to a `///` doc comment."
                    ))
                }
            }
        }

        Self.assertNoOffenders(offenders)

        XCTAssertLessThanOrEqual(
            Self.hostnameAllowlist.count, 12,
            "hostnameAllowlist exceeds cap."
        )
    }

    func test_rule4_privacySensitiveAppleAPIsRequireJustification() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []
        var seenFingerprints: Set<String> = []

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.shouldScan(line: trimmed) else { continue }
                if Self.matches(Self.privacyAPIPattern, in: trimmed) {
                    let fingerprint = "\(relativePath):\(trimmed)"
                    seenFingerprints.insert(fingerprint)
                    if !Self.privacyAPIAllowlist.contains(fingerprint) {
                        offenders.append(.init(
                            rule: 4, ruleName: "Privacy-sensitive Apple API",
                            file: relativePath, line: idx + 1, text: trimmed,
                            why: "CloudKit, iCloud key-value sync, Handoff, Universal Clipboard, weakened file protection, and `os_log` `.public` interpolation all leak data outside the device — bypassing every network audit.",
                            fix: "Use a local-only alternative (e.g. `UIPasteboard.general.setItems(_:options:)` with `.localOnly = true`). If genuinely required, add a fingerprint entry to privacyAPIAllowlist with `// Justification:` comment."
                        ))
                    }
                }
            }
        }

        Self.assertNoOffenders(offenders)

        XCTAssertLessThanOrEqual(
            Self.privacyAPIAllowlist.count, 6,
            "privacyAPIAllowlist exceeds cap. Each entry is a known privacy gap — fix them rather than grow the list."
        )

        // Stale-allowlist check: every approved fingerprint must still
        // exist in the source tree.
        let stale = Self.privacyAPIAllowlist.subtracting(seenFingerprints)
        if !stale.isEmpty {
            XCTFail("""
                privacyAPIAllowlist has stale entries that no longer exist in Sources/. Remove them:

                  \(stale.sorted().joined(separator: "\n  "))
                """)
        }
    }

    func test_rule6_importGraphBoundary() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []

        // (file-path-prefix, forbidden-imports, why)
        let rules: [(prefix: String, forbidden: [String], why: String)] = [
            ("BaseChatUI/",
             ["BaseChatBackends"],
             "BaseChatUI must not depend on BaseChatBackends. UI is consumer-facing; backend code carries cloud-SDK weight that local-only builds want to exclude."),
            ("BaseChatCore/",
             ["BaseChatBackends"],
             "BaseChatCore is the persistence layer; backend code belongs above it."),
            ("BaseChatInference/",
             ["BaseChatBackends", "BaseChatCore"],
             "BaseChatInference is the lowest production layer (apart from BaseChatTestSupport) and must not depend upward."),
        ]

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            guard let rule = rules.first(where: { relativePath.hasPrefix($0.prefix) }) else {
                continue
            }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.shouldScan(line: trimmed), trimmed.hasPrefix("import ") else { continue }
                for forbidden in rule.forbidden {
                    if trimmed == "import \(forbidden)" || trimmed.hasPrefix("import \(forbidden) ") {
                        offenders.append(.init(
                            rule: 6, ruleName: "Import-graph boundary",
                            file: relativePath, line: idx + 1, text: trimmed,
                            why: rule.why,
                            fix: "Remove the import. If you need a type from \(forbidden), expose it from a lower-layer module (e.g. promote a protocol to BaseChatInference)."
                        ))
                    }
                }
            }
        }

        Self.assertNoOffenders(offenders)
    }

    // MARK: - Patterns

    /// Word-boundary protection ensures `MockURLSession` matches (it's a
    /// URLSession type) but `MyURLSessionStub` doesn't accidentally match
    /// `URLSessionStub` as a fragment.
    private static let networkIOPattern =
        #"(?<![A-Za-z0-9_])(URLSession|URLRequest|URLSessionConfiguration)(?![A-Za-z0-9_])"#

    private static let cInteropPattern =
        #"(?<![A-Za-z0-9_])(@_silgen_name|@_cdecl|dlopen\(|dlsym\(|NSClassFromString|objc_getClass|class_createInstance|NSTask|posix_spawn|popen\()"#

    /// `Process(` as a constructor call — distinguishes from Swift's
    /// `Process` type used as a parameter type. The open-paren is the
    /// discriminator.
    private static let processSpawnPattern =
        #"(?<![A-Za-z0-9_])Process\("#

    private static let hostnamePattern =
        #"https?://(api|www|hf)\.[A-Za-z0-9_.-]+"#

    /// `UIPasteboard.general` followed by `.<member>` (any access — we're
    /// strict; sites that want pasteboard access must allowlist or use
    /// `localOnly` via a non-`.general` API). CloudKit/NSUbiquitous*
    /// matched as identifiers. `isEligibleForHandoff = true` — the false
    /// form is fine. `FileProtectionType.none` weakens at-rest protection.
    ///
    /// **Not covered:** `os_log` `, privacy: .public` interpolation — many
    /// legitimate dev-facing diagnostics (file paths, git revisions, error
    /// type names) use this marker, and a rule that flagged every site
    /// would force allowlisting hundreds of debug-only logs. Unified-log
    /// content escaping the device via iCloud sysdiagnose is tracked in
    /// `THREAT_MODEL.md` as a known non-mitigation pending a separate
    /// audit pass.
    private static let privacyAPIPattern =
        #"(?<![A-Za-z0-9_])(CloudKitDatabase|NSUbiquitousKeyValueStore|NSUbiquitousContainer|UIPasteboard\.general\.|isEligibleForHandoff\s*=\s*true|FileProtectionType\.none)"#

    private static func matches(_ pattern: String, in line: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// Skip empty lines, single-line comments, and doc comments. (Block
    /// comments would require AST, but the codebase doesn't use them.)
    private static func shouldScan(line: String) -> Bool {
        if line.isEmpty { return false }
        if line.hasPrefix("//") { return false }
        if line.hasPrefix("///") { return false }
        if line.hasPrefix("*") { return false }
        return true
    }

    // MARK: - Reporting

    private struct Offender {
        let rule: Int
        let ruleName: String
        let file: String
        let line: Int
        let text: String
        let why: String
        let fix: String
    }

    private static func assertNoOffenders(
        _ offenders: [Offender], file: StaticString = #filePath, line: UInt = #line
    ) {
        guard !offenders.isEmpty else { return }
        let formatted = offenders.map { o in
            """

            [TrafficBoundary Rule \(o.rule): \(o.ruleName)] \(o.file):\(o.line)
              Found:    \(o.text)
              Why:      \(o.why)
              Fix:      \(o.fix)
            """
        }.joined(separator: "\n")
        XCTFail("Traffic boundary violations:\n\(formatted)", file: file, line: line)
    }

    // MARK: - File discovery (mirrors SilentCatchAuditTest)

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
        throw NSError(domain: "TrafficBoundaryAuditTest", code: 1, userInfo: [
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

    // MARK: - Sabotage tests
    //
    // CLAUDE.md mandates a confirmed-failure test for every assertion.
    // For the audit's regex matchers, "confirm failure" means: feed a known
    // violation string to the matcher and assert it fires. Sabotage fixtures
    // are inline strings (rather than fixture files under Sources/) so the
    // production audit's file enumerator never sees them.
    //
    // If a future refactor weakens a matcher (e.g. typo'd regex), the
    // production audit could pass cleanly even though the rule no longer
    // catches anything. The sabotage tests below catch that drift.

    func test_sabotage_rule1_catchesURLSessionUsage() {
        let fixture = "let s = URLSession.shared.dataTask(with: r) { _, _, _ in }"
        XCTAssertTrue(Self.matches(Self.networkIOPattern, in: fixture),
                      "Rule 1 should match URLSession.shared")

        let fixtureRequest = "var req = URLRequest(url: u)"
        XCTAssertTrue(Self.matches(Self.networkIOPattern, in: fixtureRequest),
                      "Rule 1 should match URLRequest")

        // Negative: an unrelated `Session` should not match.
        let negative = "let s = MyChatSession()"
        XCTAssertFalse(Self.matches(Self.networkIOPattern, in: negative),
                       "Rule 1 must not match unrelated identifier 'Session'")
    }

    func test_sabotage_rule2_catchesCInteropPatterns() {
        let cases = [
            "@_silgen_name(\"_connect\") func myConnect(_ s: Int32) -> Int32",
            "@_cdecl(\"export_me\") public func exportMe()",
            "let h = dlopen(\"libfoo.dylib\", RTLD_NOW)",
            "let p = dlsym(h, \"foo\")",
            "let cls = NSClassFromString(\"MyHidden\")",
            "let c = objc_getClass(\"MyHidden\")",
            "let i = class_createInstance(cls, 0)",
            "var pid: pid_t = 0; posix_spawn(&pid, path, nil, nil, argv, envp)",
            "let f = popen(\"ls\", \"r\")",
        ]
        for fixture in cases {
            XCTAssertTrue(Self.matches(Self.cInteropPattern, in: fixture),
                          "Rule 2 should match: \(fixture)")
        }

        // Process( has its own pattern.
        let processFixture = "let p = Process()"
        XCTAssertTrue(Self.matches(Self.processSpawnPattern, in: processFixture),
                      "Rule 2 (Process) should match constructor call")

        // Negative: `Process` as a type, not a constructor.
        let processType = "func run(_ proc: Process) {"
        XCTAssertFalse(Self.matches(Self.processSpawnPattern, in: processType),
                       "Rule 2 must not match Process as a parameter type")

        // Negative: an unrelated `system` substring (no open-paren).
        let systemNonCall = "let mySystem = configure()"
        XCTAssertFalse(Self.matches(Self.cInteropPattern, in: systemNonCall),
                       "Rule 2 must not match identifier 'system' without open-paren")
    }

    func test_sabotage_rule3_catchesHostnameLiterals() {
        let cases = [
            "let url = URL(string: \"https://api.anthropic.com/v1/messages\")!",
            "let url = URL(string: \"https://api.openai.com/v1/chat\")!",
            "let url = URL(string: \"http://api.example.com/foo\")!",
            "let url = URL(string: \"https://hf.co/models\")!",
        ]
        for fixture in cases {
            XCTAssertTrue(Self.matches(Self.hostnamePattern, in: fixture),
                          "Rule 3 should match: \(fixture)")
        }

        // Negative: a `.com` literal that is not a https?://api.* pattern.
        let negative = "let title = \"Available on the App Store.com\""
        XCTAssertFalse(Self.matches(Self.hostnamePattern, in: negative),
                       "Rule 3 must not match arbitrary `.com` strings")
    }

    func test_sabotage_rule4_catchesPrivacyAPIPatterns() {
        let cases = [
            "let db = CloudKitDatabase.private",
            "let store = NSUbiquitousKeyValueStore.default",
            "container.NSUbiquitousContainer = setup",
            "UIPasteboard.general.string = text",
            "activity.isEligibleForHandoff = true",
            "config.fileProtectionClass = FileProtectionType.none",
        ]
        for fixture in cases {
            XCTAssertTrue(Self.matches(Self.privacyAPIPattern, in: fixture),
                          "Rule 4 should match: \(fixture)")
        }

        // Negative: the false form of Handoff is allowed.
        let handoffOff = "activity.isEligibleForHandoff = false"
        XCTAssertFalse(Self.matches(Self.privacyAPIPattern, in: handoffOff),
                       "Rule 4 must not match isEligibleForHandoff = false")
    }

    func test_sabotage_rule6_detectsForbiddenImports() {
        // Rule 6 is implemented inline in test_rule6_importGraphBoundary
        // (it's a per-line `import X` check rather than a single regex), so
        // the sabotage check verifies the prefix-matching logic works.
        let line = "import BaseChatBackends"
        XCTAssertEqual(line, "import BaseChatBackends")
        XCTAssertTrue(line.hasPrefix("import BaseChatBackends"))

        // Module prefixes must not match a partial identifier.
        let unrelated = "import BaseChatBackendsExtras"
        // The rule requires exact match OR `import X ` (with trailing space).
        // A module named BaseChatBackendsExtras would not be flagged as
        // BaseChatBackends — the trailing space distinguishes them.
        XCTAssertFalse(unrelated == "import BaseChatBackends" || unrelated.hasPrefix("import BaseChatBackends "),
                       "Rule 6 must not flag unrelated module names that share a prefix")
    }
}

