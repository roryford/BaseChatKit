import Foundation

/// A model available for download from HuggingFace.
///
/// Created from either the curated list or HuggingFace search results.
/// Separate from `ModelInfo` (which represents an on-disk model) to keep
/// download-time concerns (repo ID, download count) apart from runtime
/// concerns (loaded state, inference backend).
public struct DownloadableModel: Identifiable, Sendable, Hashable {
    /// Unique identifier: `repoID/fileName`.
    public let id: String
    /// HuggingFace repository ID (e.g., "bartowski/Mistral-7B-Instruct-v0.3-GGUF").
    public let repoID: String
    /// File to download (GGUF filename or MLX directory name).
    public let fileName: String
    /// Human-readable name for display.
    public let displayName: String
    /// Which backend this model requires.
    public let modelType: ModelType
    /// Approximate download size in bytes.
    public let sizeBytes: UInt64
    /// HuggingFace download count, for sorting/display.
    public let downloads: Int?
    /// Whether this came from the curated list (vs search).
    public let isCurated: Bool
    /// Known prompt template, if any.
    public let promptTemplate: PromptTemplate?
    /// One-line description for UI.
    public let description: String?

    /// Human-readable size (e.g., "4.1 GB").
    public var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    /// Quantization tag extracted from the filename (e.g., "Q4_K_M", "Q8_0"), or nil.
    public var quantization: String? {
        guard modelType == .gguf else { return nil }
        // Match common GGUF quant patterns: Q4_K_M, Q8_0, IQ2_XS, F16, etc.
        let pattern = #"[_\-\.]((?:Q|IQ|F|BF)\d+(?:_[A-Z0-9]+)*)\."#
        guard let range = fileName.range(of: pattern, options: .regularExpression) else { return nil }
        let match = fileName[range].dropFirst().dropLast() // strip leading separator and trailing dot
        return String(match)
    }

    // MARK: - Factory from CuratedModel

    public init(from curated: CuratedModel) {
        self.id = "\(curated.repoID)/\(curated.fileName)"
        self.repoID = curated.repoID
        self.fileName = curated.fileName
        self.displayName = curated.displayName
        self.modelType = curated.modelType
        self.sizeBytes = curated.approximateSizeBytes
        self.downloads = nil
        self.isCurated = true
        self.promptTemplate = curated.promptTemplate
        self.description = curated.description
    }

    // MARK: - Memberwise

    public init(
        repoID: String,
        fileName: String,
        displayName: String,
        modelType: ModelType,
        sizeBytes: UInt64,
        downloads: Int? = nil,
        isCurated: Bool = false,
        promptTemplate: PromptTemplate? = nil,
        description: String? = nil
    ) {
        self.id = "\(repoID)/\(fileName)"
        self.repoID = repoID
        self.fileName = fileName
        self.displayName = displayName
        self.modelType = modelType
        self.sizeBytes = sizeBytes
        self.downloads = downloads
        self.isCurated = isCurated
        self.promptTemplate = promptTemplate
        self.description = description
    }
}

// MARK: - Grouped Models

/// Groups multiple downloadable variants (quant levels) under one repo.
public struct DownloadableModelGroup: Identifiable {
    public let id: String  // repoID
    public let repoID: String
    public let displayName: String
    public let downloads: Int?
    public let variants: [DownloadableModel]

    /// Human-readable size range (e.g., "1.6 GB – 7.7 GB"), or nil if all sizes are zero.
    public var sizeRange: String? {
        let sizes = variants.map(\.sizeBytes).filter { $0 > 0 }
        guard let minSize = sizes.min(), let maxSize = sizes.max() else { return nil }
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        if minSize == maxSize {
            return fmt.string(fromByteCount: Int64(minSize))
        }
        return "\(fmt.string(fromByteCount: Int64(minSize))) – \(fmt.string(fromByteCount: Int64(maxSize)))"
    }

    /// Groups a flat list of downloadable models by their `repoID`.
    ///
    /// When `sortKey` is provided, groups are sorted by that key first (ascending),
    /// then by HuggingFace download count (descending) within the same key value.
    /// Without a sort key, groups are sorted by download count only.
    public static func group(
        _ models: [DownloadableModel],
        sortKey: ((DownloadableModelGroup) -> Int)? = nil
    ) -> [DownloadableModelGroup] {
        let grouped = Dictionary(grouping: models, by: \.repoID)
        let groups = grouped.map { repoID, variants in
            // Use the shortest display name as the group name (avoids quant suffix).
            let baseName = variants
                .map(\.displayName)
                .min(by: { $0.count < $1.count }) ?? repoID
            // Clean up common suffixes from the group name.
            let cleanName = Self.cleanGroupName(baseName)
            return DownloadableModelGroup(
                id: repoID,
                repoID: repoID,
                displayName: cleanName,
                downloads: variants.first?.downloads,
                variants: variants.sorted { $0.sizeBytes < $1.sizeBytes }
            )
        }

        if let sortKey {
            return groups.sorted {
                let keyA = sortKey($0)
                let keyB = sortKey($1)
                if keyA != keyB { return keyA < keyB }
                return ($0.downloads ?? 0) > ($1.downloads ?? 0)
            }
        }

        return groups.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
    }

    /// Returns the recommended variant for the given device capability.
    ///
    /// The recommended variant is the largest quantization (by `sizeBytes`) that still
    /// passes `deviceCapability.canLoadModel(estimatedMemoryBytes:)`. When no variant
    /// fits, returns the smallest variant (the most likely to succeed at runtime).
    public func recommendedVariant(for deviceCapability: DeviceCapabilityService) -> DownloadableModel? {
        guard !variants.isEmpty else { return nil }

        // Variants are already sorted ascending by sizeBytes (see group()).
        // The largest fitting variant is the last one that passes the check.
        let fittingVariants = variants.filter {
            $0.sizeBytes > 0 && deviceCapability.canLoadModel(estimatedMemoryBytes: $0.sizeBytes)
        }

        if let best = fittingVariants.last {
            return best
        }

        // No variant fits — return the smallest as a fallback.
        return variants.first
    }

    private static func cleanGroupName(_ name: String) -> String {
        // Remove trailing quant identifiers like "Q4 K M", "IQ2 XS", etc.
        let pattern = #"\s+(?:Q|IQ|F|BF)\d+.*$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return name }
        let cleaned = String(name[..<range.lowerBound])
        return cleaned.isEmpty ? name : cleaned
    }
}
