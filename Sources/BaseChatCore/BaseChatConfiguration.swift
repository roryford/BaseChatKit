import Foundation

/// Global configuration for BaseChatKit. Set this once at app startup before
/// using any BaseChatKit types.
///
/// ```swift
/// BaseChatConfiguration.shared = BaseChatConfiguration(
///     appName: "MyApp",
///     bundleIdentifier: "com.example.myapp"
/// )
/// ```
public struct BaseChatConfiguration: Sendable {
    public static var shared = BaseChatConfiguration()

    /// Display name used in export headers, empty states, etc.
    public var appName: String

    /// Base identifier for keychain, download sessions, logging, etc.
    public var bundleIdentifier: String

    /// Directory name inside Documents where models are stored.
    public var modelsDirectoryName: String

    public init(
        appName: String = "BaseChatKit",
        bundleIdentifier: String = "com.basechatkit",
        modelsDirectoryName: String = "Models"
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.modelsDirectoryName = modelsDirectoryName
    }

    // MARK: - Derived identifiers

    public var logSubsystem: String { bundleIdentifier }
    public var keychainServiceName: String { "\(bundleIdentifier).apikeys" }
    public var downloadSessionIdentifier: String { "\(bundleIdentifier).modeldownload" }
    public var pendingDownloadsKey: String { "\(bundleIdentifier).pendingDownloads" }
    public var memoryPressureQueueLabel: String { "\(bundleIdentifier).memory-pressure" }
}
