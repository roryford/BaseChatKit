import XCTest
@testable import BaseChatCore

final class BaseChatConfigurationTests: XCTestCase {

    // MARK: - Default Initializer

    func test_defaultInit_appName() {
        let config = BaseChatConfiguration()
        XCTAssertEqual(config.appName, "BaseChatKit")
    }

    func test_defaultInit_bundleIdentifier() {
        let config = BaseChatConfiguration()
        XCTAssertEqual(config.bundleIdentifier, "com.basechatkit")
    }

    func test_defaultInit_modelsDirectoryName() {
        let config = BaseChatConfiguration()
        XCTAssertEqual(config.modelsDirectoryName, "Models")
    }

    // MARK: - Derived Identifiers

    func test_logSubsystem_equalsBundleIdentifier() {
        let config = BaseChatConfiguration(bundleIdentifier: "com.example.app")
        XCTAssertEqual(config.logSubsystem, "com.example.app")
    }

    func test_keychainServiceName_appendsApikeys() {
        let config = BaseChatConfiguration(bundleIdentifier: "com.example.app")
        XCTAssertEqual(config.keychainServiceName, "com.example.app.apikeys")
    }

    func test_downloadSessionIdentifier_appendsModeldownload() {
        let config = BaseChatConfiguration(bundleIdentifier: "com.example.app")
        XCTAssertEqual(config.downloadSessionIdentifier, "com.example.app.modeldownload")
    }

    func test_pendingDownloadsKey_appendsPendingDownloads() {
        let config = BaseChatConfiguration(bundleIdentifier: "com.example.app")
        XCTAssertEqual(config.pendingDownloadsKey, "com.example.app.pendingDownloads")
    }

    func test_memoryPressureQueueLabel_appendsMemoryPressure() {
        let config = BaseChatConfiguration(bundleIdentifier: "com.example.app")
        XCTAssertEqual(config.memoryPressureQueueLabel, "com.example.app.memory-pressure")
    }

    // MARK: - Custom Initializer

    func test_customInit_propagatesAllFields() {
        let features = BaseChatConfiguration.Features(showContextIndicator: false)
        let config = BaseChatConfiguration(
            appName: "MyApp",
            bundleIdentifier: "com.myapp",
            modelsDirectoryName: "LLMs",
            features: features
        )

        XCTAssertEqual(config.appName, "MyApp")
        XCTAssertEqual(config.bundleIdentifier, "com.myapp")
        XCTAssertEqual(config.modelsDirectoryName, "LLMs")
        XCTAssertFalse(config.features.showContextIndicator)
    }

    // MARK: - Features Default Values

    func test_features_defaultInit_allTrue() {
        let features = BaseChatConfiguration.Features()

        XCTAssertTrue(features.showContextIndicator)
        XCTAssertTrue(features.showMemoryIndicator)
        XCTAssertTrue(features.showChatExport)
        XCTAssertTrue(features.showModelDownload)
        XCTAssertTrue(features.showStorageTab)
        XCTAssertTrue(features.showGenerationSettings)
        XCTAssertTrue(features.showAdvancedSettings)
        XCTAssertTrue(features.showCloudAPIManagement)
        XCTAssertTrue(features.showUpgradeHint)
    }

    // MARK: - Features Custom Init

    func test_features_customInit_respectsEachFlag() {
        let features = BaseChatConfiguration.Features(
            showContextIndicator: false,
            showMemoryIndicator: true,
            showChatExport: false,
            showModelDownload: true,
            showStorageTab: false,
            showGenerationSettings: true,
            showAdvancedSettings: false,
            showCloudAPIManagement: true,
            showUpgradeHint: false
        )

        XCTAssertFalse(features.showContextIndicator)
        XCTAssertTrue(features.showMemoryIndicator)
        XCTAssertFalse(features.showChatExport)
        XCTAssertTrue(features.showModelDownload)
        XCTAssertFalse(features.showStorageTab)
        XCTAssertTrue(features.showGenerationSettings)
        XCTAssertFalse(features.showAdvancedSettings)
        XCTAssertTrue(features.showCloudAPIManagement)
        XCTAssertFalse(features.showUpgradeHint)
    }

    func test_features_singleFlagDisabled_othersRemainTrue() {
        let features = BaseChatConfiguration.Features(showUpgradeHint: false)

        XCTAssertTrue(features.showContextIndicator)
        XCTAssertTrue(features.showMemoryIndicator)
        XCTAssertTrue(features.showChatExport)
        XCTAssertTrue(features.showModelDownload)
        XCTAssertTrue(features.showStorageTab)
        XCTAssertTrue(features.showGenerationSettings)
        XCTAssertTrue(features.showAdvancedSettings)
        XCTAssertTrue(features.showCloudAPIManagement)
        XCTAssertFalse(features.showUpgradeHint)
    }
}
