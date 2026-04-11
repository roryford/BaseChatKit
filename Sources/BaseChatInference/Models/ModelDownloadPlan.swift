import Foundation

/// A single file that belongs to a model download.
public struct ModelDownloadFile: Sendable, Hashable, Codable {
    /// Relative path inside the model snapshot directory.
    public let relativePath: String
    /// Direct HuggingFace download URL for this file.
    public let url: URL
    /// Expected file size in bytes, when known.
    public let sizeBytes: UInt64

    public init(relativePath: String, url: URL, sizeBytes: UInt64) {
        self.relativePath = relativePath
        self.url = url
        self.sizeBytes = sizeBytes
    }
}

/// The concrete download work needed for a `DownloadableModel`.
public enum ModelDownloadPlan: Sendable, Hashable {
    case singleFile(url: URL)
    case snapshot(files: [ModelDownloadFile])
}
