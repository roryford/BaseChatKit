import Foundation
import CryptoKit

public enum HarnessMetadata {

    public static let fuzzVersion = "0.1.0"

    public static func snapshot(repoRoot: URL?) -> RunRecord.HarnessSnapshot {
        let (rev, dirty) = gitRev(repoRoot: repoRoot)
        return RunRecord.HarnessSnapshot(
            fuzzVersion: fuzzVersion,
            packageGitRev: rev,
            packageGitDirty: dirty,
            swiftVersion: swiftVersion(),
            osBuild: osBuild(),
            thermalState: thermalState()
        )
    }

    /// Computes the SHA256 of a file in 1 MiB chunks. Returns nil for missing or unreadable files.
    public static func fileSHA256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.availableData
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func gitRev(repoRoot: URL?) -> (String, Bool) {
        let cwd = repoRoot?.path ?? FileManager.default.currentDirectoryPath
        let rev = run("/usr/bin/git", ["-C", cwd, "rev-parse", "--short", "HEAD"]) ?? "unknown"
        let status = run("/usr/bin/git", ["-C", cwd, "status", "--porcelain"]) ?? ""
        return (rev.trimmingCharacters(in: .whitespacesAndNewlines), !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private static func swiftVersion() -> String {
        run("/usr/bin/env", ["swift", "--version"])?
            .components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespaces) ?? "unknown"
    }

    private static func osBuild() -> String {
        let info = ProcessInfo.processInfo
        return "\(info.operatingSystemVersionString)"
    }

    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
