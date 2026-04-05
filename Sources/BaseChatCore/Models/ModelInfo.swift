import Foundation

/// The inference backend a model requires, determined by its file format.
public enum ModelType: Hashable, Sendable {
    /// A single `.gguf` file — uses the llama.cpp backend.
    case gguf
    /// A directory containing `config.json` + `.safetensors` weights — uses MLX.
    case mlx
    /// Apple on-device model, no file needed.
    case foundation
}

/// Represents a model available on disk (either a GGUF file or an MLX model directory).
public struct ModelInfo: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let fileName: String
    public let url: URL
    public let fileSize: UInt64
    public let modelType: ModelType

    // MARK: - GGUF Metadata (populated for .gguf models)

    /// The prompt template detected from GGUF metadata (chat template or architecture).
    public var detectedPromptTemplate: PromptTemplate?
    /// The context length read from the GGUF header (e.g. 4096, 8192).
    public var detectedContextLength: Int?
    /// The model architecture string from `general.architecture` (e.g. "llama", "phi").
    public var modelArchitecture: String?
    /// The raw Jinja chat template string from `tokenizer.chat_template`, if present.
    public var chatTemplateRaw: String?

    /// Human-readable file size (e.g. "2.3 GB").
    public var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    /// Short label for the backend type.
    public var backendLabel: String {
        switch modelType {
        case .gguf: "GGUF"
        case .mlx: "MLX"
        case .foundation: "Apple"
        }
    }

    // MARK: - Built-in Foundation Model

    /// The built-in Apple Foundation Model (available on iOS 26+ / macOS 26+).
    /// This is not a file on disk — it's provided by the OS.
    public static let builtInFoundation = ModelInfo(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Apple Foundation Model",
        fileName: "Built-in",
        url: URL(fileURLWithPath: "/"),  // Unused for foundation models
        fileSize: 0,
        modelType: .foundation
    )

    // MARK: - GGUF Initializer

    /// Creates a ModelInfo from a `.gguf` file URL, reading its size from disk.
    ///
    /// Returns `nil` if the file's attributes cannot be read.
    public init?(ggufURL url: URL) {
        guard url.pathExtension.lowercased() == "gguf" else { return nil }

        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64 else {
            return nil
        }

        self.id = UUID()
        self.fileName = url.lastPathComponent
        self.name = Self.displayName(from: url.lastPathComponent, strippingExtension: ".gguf")
        self.url = url
        self.fileSize = size
        self.modelType = .gguf

        // Attempt to read GGUF header metadata for template detection.
        if let metadata = try? GGUFMetadataReader.readMetadata(from: url) {
            self.detectedPromptTemplate = PromptTemplateDetector.detect(from: metadata)
            self.detectedContextLength = metadata.contextLength
            self.modelArchitecture = metadata.generalArchitecture
            self.chatTemplateRaw = metadata.chatTemplate
        }
    }

    // MARK: - MLX Initializer

    /// Creates a ModelInfo from an MLX model directory containing `config.json`.
    ///
    /// Returns `nil` if the directory doesn't contain `config.json` or can't be read.
    public init?(mlxDirectory url: URL) {
        let fileManager = FileManager.default

        // Must be a directory containing config.json.
        let configURL = url.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path) else { return nil }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let allFiles = contents.flatMap { child -> [URL] in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return [child]
            }
            guard let enumerator = fileManager.enumerator(
                at: child,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return [child]
            }
            return enumerator.compactMap { $0 as? URL }
        }

        let totalSize = allFiles.reduce(UInt64(0)) { sum, fileURL in
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return sum }
            return sum + UInt64(values?.fileSize ?? 0)
        }
        let hasSafetensors = allFiles.contains { $0.pathExtension.lowercased() == "safetensors" }
        guard hasSafetensors else { return nil }

        self.id = UUID()
        self.fileName = url.lastPathComponent
        self.name = Self.displayName(from: url.lastPathComponent, strippingExtension: nil)
        self.url = url
        self.fileSize = totalSize
        self.modelType = .mlx
    }

    // MARK: - Memberwise

    /// Memberwise initializer for testing or manual construction.
    public init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        url: URL,
        fileSize: UInt64,
        modelType: ModelType,
        detectedPromptTemplate: PromptTemplate? = nil,
        detectedContextLength: Int? = nil,
        modelArchitecture: String? = nil,
        chatTemplateRaw: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.url = url
        self.fileSize = fileSize
        self.modelType = modelType
        self.detectedPromptTemplate = detectedPromptTemplate
        self.detectedContextLength = detectedContextLength
        self.modelArchitecture = modelArchitecture
        self.chatTemplateRaw = chatTemplateRaw
    }

    // MARK: - Private

    /// Derives a human-readable display name from a filename.
    private static func displayName(from fileName: String, strippingExtension ext: String?) -> String {
        var name = fileName
        if let ext, name.lowercased().hasSuffix(ext.lowercased()) {
            name = String(name.dropLast(ext.count))
        }
        name = name.replacingOccurrences(of: "-", with: " ")
        name = name.replacingOccurrences(of: "_", with: " ")
        return name
    }
}
