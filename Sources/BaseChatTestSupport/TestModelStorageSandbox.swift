import Foundation
import BaseChatInference

/// Creates an isolated on-disk models directory for tests.
///
/// Tests that exercise `ModelStorageService`, `ChatViewModel.refreshModels()`,
/// or model import flows must not touch the real user's Documents/Models
/// directory. This sandbox provides a per-test storage root and cleans it up
/// when the test ends.
public final class TestModelStorageSandbox {
    private let fileManager: FileManager

    public let rootDirectory: URL
    public let modelsDirectory: URL
    public let storageService: ModelStorageService

    public init(prefix: String = "BaseChatModelsTest", fileManager: FileManager = .default) throws {
        self.fileManager = fileManager

        let safePrefix = prefix.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let rootDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("\(safePrefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let modelsDirectory = rootDirectory.appendingPathComponent("Models", isDirectory: true)
        self.rootDirectory = rootDirectory
        self.modelsDirectory = modelsDirectory
        self.storageService = ModelStorageService(fileManager: fileManager, baseDirectory: modelsDirectory)
    }

    public func cleanup() {
        do {
            try fileManager.removeItem(at: rootDirectory)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        } catch {
            NSLog("Failed to remove test model sandbox at %@: %@", rootDirectory.path, error.localizedDescription)
        }
    }

    deinit {
        cleanup()
    }
}
