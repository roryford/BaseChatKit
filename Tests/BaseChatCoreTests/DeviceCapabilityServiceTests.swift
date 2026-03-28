import XCTest
@testable import BaseChatCore

final class DeviceCapabilityServiceTests: XCTestCase {

    // MARK: - Helpers

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeService(ramGB: UInt64) -> DeviceCapabilityService {
        DeviceCapabilityService(physicalMemory: ramGB * oneGB)
    }

    // MARK: - canLoadModel

    func test_canLoadModel_smallModelOn8GBDevice_returnsTrue() {
        let service = makeService(ramGB: 8)
        // 2 GB model -> 2.4 GB with 20% KV overhead; 8 GB * 0.70 = 5.6 GB budget
        let twoGB: UInt64 = 2 * oneGB
        XCTAssertTrue(service.canLoadModel(estimatedMemoryBytes: twoGB))
    }

    func test_canLoadModel_modelTooLargeForDevice_returnsFalse() {
        let service = makeService(ramGB: 8)
        // 6 GB model -> 7.2 GB with 20% KV overhead; 8 GB * 0.70 = 5.6 GB budget
        let sixGB: UInt64 = 6 * oneGB
        XCTAssertFalse(service.canLoadModel(estimatedMemoryBytes: sixGB))
    }

    func test_canLoadModel_modelExactlyAtBoundary_returnsTrue() {
        // Available budget = physicalMemory * 0.70
        // Total required = estimatedMemoryBytes * 1.20
        // At boundary: estimatedMemoryBytes * 1.20 == physicalMemory * 0.70
        //   -> estimatedMemoryBytes = physicalMemory * 0.70 / 1.20
        let physicalMemory: UInt64 = 8 * oneGB
        let exactModel = UInt64(Double(physicalMemory) * 0.70 / 1.20)
        let service = DeviceCapabilityService(physicalMemory: physicalMemory)
        XCTAssertTrue(service.canLoadModel(estimatedMemoryBytes: exactModel))
    }

    // MARK: - recommendedModelSize

    func test_recommendedModelSize_6GBDevice_returnsSmall() {
        let service = makeService(ramGB: 6)
        XCTAssertEqual(service.recommendedModelSize(), .small)
    }

    func test_recommendedModelSize_8GBDevice_returnsMedium() {
        let service = makeService(ramGB: 8)
        XCTAssertEqual(service.recommendedModelSize(), .medium)
    }

    func test_recommendedModelSize_16GBDevice_returnsLarge() {
        let service = makeService(ramGB: 16)
        XCTAssertEqual(service.recommendedModelSize(), .large)
    }

    func test_recommendedModelSize_32GBDevice_returnsXLarge() {
        let service = makeService(ramGB: 32)
        XCTAssertEqual(service.recommendedModelSize(), .xlarge)
    }

    // MARK: - deviceDescription

    func test_deviceDescription_contains_correctRAMValue() {
        let service = makeService(ramGB: 16)
        let description = service.deviceDescription
        XCTAssertTrue(description.contains("16 GB RAM"),
                      "Expected '16 GB RAM' in description, got: \(description)")
    }

    // MARK: - ModelSizeRecommendation.maxModelBytes

    func test_maxModelBytes_small_returnsCorrectValue() {
        XCTAssertEqual(ModelSizeRecommendation.small.maxModelBytes, 2_500_000_000)
    }

    func test_maxModelBytes_medium_returnsCorrectValue() {
        XCTAssertEqual(ModelSizeRecommendation.medium.maxModelBytes, 4_500_000_000)
    }

    func test_maxModelBytes_large_returnsCorrectValue() {
        XCTAssertEqual(ModelSizeRecommendation.large.maxModelBytes, 6_000_000_000)
    }

    func test_maxModelBytes_xlarge_returnsCorrectValue() {
        XCTAssertEqual(ModelSizeRecommendation.xlarge.maxModelBytes, 40_000_000_000)
    }
}
