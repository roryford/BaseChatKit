import XCTest
@testable import BaseChatInference

final class DeviceCapabilityServiceTests: XCTestCase {

    // MARK: - Helpers

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    /// Compute what safeContextSize should produce for a given set of inputs,
    /// mirroring the formula in DeviceCapabilityService so tests stay coupled
    /// to the spec, not a specific constant layout.
    private func expectedSafeContext(
        availableBytes: UInt64,
        detectedLength: Int?,
        absoluteCeiling: Int = 128_000,
        unknownDefault: Int = 8_192,
        kvBytesPerToken: UInt64 = 8_192,
        headroomFraction: Double = 0.40
    ) -> Int32 {
        let kvBudget = UInt64(Double(availableBytes) * (1.0 - headroomFraction))
        let memoryCeiling = Int(kvBudget / kvBytesPerToken)
        let trainedCeiling = detectedLength ?? unknownDefault
        let result = min(memoryCeiling, trainedCeiling, absoluteCeiling)
        return Int32(max(1, result))
    }

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

    // MARK: - safeContextSize

    func test_safeContextSize_clampsBelowDetectedLength() {
        // When available memory yields a ceiling below the model's trained length,
        // the memory ceiling wins — not the trained length.
        //
        // 1 GB available × 60% KV budget = 614 MB → 614 MB / 8 KB = ~75 000 tokens
        // Trained length = 128 000 → clamped to ~75 000.
        let available = oneGB
        let result = DeviceCapabilityService.safeContextSize(
            for: 128_000,
            availableMemoryBytes: available
        )
        let expected = expectedSafeContext(availableBytes: available, detectedLength: 128_000)
        XCTAssertEqual(result, expected,
                       "Should clamp to memory ceiling when model context exceeds available-memory budget")
        XCTAssertLessThan(result, 128_000,
                          "Result must be less than the model's trained length when memory is the bottleneck")
    }

    func test_safeContextSize_respectsModelTrainedContext() {
        // When available memory is abundant (64 GB), the trained context length is the binding constraint.
        let abundant: UInt64 = 64 * oneGB
        let trained = 4096
        let result = DeviceCapabilityService.safeContextSize(
            for: trained,
            availableMemoryBytes: abundant
        )
        XCTAssertEqual(result, Int32(trained),
                       "When memory is abundant, the model's trained context length must be the ceiling")
    }

    func test_safeContextSize_fallbackWhenDetectedContextIsNil() {
        // When detectedContextLength is nil, the helper should use the 8 192 default,
        // not the old 2 048 that ChatViewModel previously used.
        //
        // With 64 GB available (abundant), the result should equal the default (8 192).
        let abundant: UInt64 = 64 * oneGB
        let result = DeviceCapabilityService.safeContextSize(
            for: nil,
            availableMemoryBytes: abundant
        )
        XCTAssertEqual(result, 8_192,
                       "Nil detectedContextLength must fall back to the 8 192 default, not 2 048")
    }

    func test_safeContextSize_neverExceedsAbsoluteCeiling() {
        // Even with unlimited memory and a trained context of 1 000 000, the result
        // is capped at 128 000.
        let unlimited: UInt64 = 512 * oneGB
        let result = DeviceCapabilityService.safeContextSize(
            for: 1_000_000,
            availableMemoryBytes: unlimited
        )
        XCTAssertLessThanOrEqual(result, 128_000,
                                 "safeContextSize must never exceed the 128 000 absolute ceiling")
    }

    func test_safeContextSize_respectsAvailableMemory() {
        // With 512 MB available (simulating extreme iOS memory pressure), the result
        // must be far below the model's 128 000 trained length.
        //
        // 512 MB × 60% KV budget = 307 MB → 307 MB / 8 KB ≈ 39 321 tokens.
        let halfGB: UInt64 = oneGB / 2
        let result = DeviceCapabilityService.safeContextSize(
            for: 128_000,
            availableMemoryBytes: halfGB
        )
        let expected = expectedSafeContext(availableBytes: halfGB, detectedLength: 128_000)
        XCTAssertEqual(result, expected,
                       "Should apply memory ceiling from available bytes, not physical RAM")

        // Sabotage check: if we removed the memory ceiling and returned just the trained
        // context, the result would be 128 000. Verify the actual result is less.
        XCTAssertLessThan(result, 128_000,
                          "512 MB budget should constrain context well below 128 000 tokens")
    }

    func test_safeContextSize_floorsAtOne_whenAvailableMemoryIsNearZero() {
        // Pathological case: essentially no memory available — result should be 1, not 0 or negative.
        let nearZero: UInt64 = 1000
        let result = DeviceCapabilityService.safeContextSize(
            for: 128_000,
            availableMemoryBytes: nearZero
        )
        XCTAssertGreaterThanOrEqual(result, 1,
                                    "safeContextSize must floor at 1 even in near-zero memory conditions")
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
