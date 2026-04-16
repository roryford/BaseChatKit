import XCTest
@testable import BaseChatInference

final class GGUFKVCacheEstimatorTests: XCTestCase {

    func test_estimateBytesPerToken_llama7BGQAMatchesExpectedMath() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 32,
            embeddingLength: 4096,
            attentionHeadCount: 32,
            attentionHeadCountKV: 8
        )

        let estimate = GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters)

        XCTAssertEqual(estimate, 131_072)
    }

    func test_estimateBytesPerToken_explicitKeyAndValueLengthsOverrideEmbeddingHeuristic() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 28,
            embeddingLength: 3072,
            attentionHeadCount: 24,
            attentionHeadCountKV: 6,
            attentionKeyLength: 96,
            attentionValueLength: 128
        )

        let estimate = GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters)

        XCTAssertEqual(estimate, 75_264)
    }

    func test_estimateBytesPerToken_returnsNilWhenMetadataIsIncomplete() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 32,
            attentionHeadCountKV: 8
        )

        XCTAssertNil(GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters))
    }
}
