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
