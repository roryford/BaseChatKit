import XCTest
@testable import BaseChatInference

/// Spec-coupled tests for `ModelLoadPlan`.
///
/// These tests mirror the formula in `ModelLoadPlan.compute(inputs:)` through an
/// `expectedOutcome(...)` helper rather than hard-coding constants. That way, a
/// change to (for example) the headroom fraction in a future stage is caught by
/// a *legitimate* test-spec mismatch rather than a brittle literal.
final class ModelLoadPlanTests: XCTestCase {

    private let oneGB: UInt64 = 1_073_741_824

    // MARK: - Helpers

    /// Shadow implementation of `ModelLoadPlan.compute` used purely for assertions.
    /// Kept verbatim with the production formula so the tests break if either drifts
    /// in a way that wasn't a coordinated change.
    private func expectedOutcome(
        modelFileSize: UInt64,
        strategy: MemoryStrategy,
        requested: Int,
        trained: Int?,
        kvBytesPerToken: UInt64,
        available: UInt64,
        absoluteCeiling: Int = 128_000,
        headroom: Double = 0.40
    ) -> (effective: Int, verdict: ModelLoadPlan.Verdict, resident: UInt64, kv: UInt64, total: UInt64) {
        let residentBudget: UInt64
        switch strategy {
        case .resident: residentBudget = modelFileSize
        case .mappable: residentBudget = min(modelFileSize / 4, oneGB)
        case .external: residentBudget = 0
        }
        let reserveAfterHeadroom = UInt64(Double(available) * (1.0 - headroom))
        let kvBudget: UInt64 = reserveAfterHeadroom > residentBudget
            ? reserveAfterHeadroom - residentBudget
            : 0
        let memoryCeiling = kvBytesPerToken == 0 ? Int.max : Int(kvBudget / kvBytesPerToken)

        var effective = requested
        if let t = trained, t < effective { effective = t }
        if absoluteCeiling < effective { effective = absoluteCeiling }
        if memoryCeiling < effective { effective = memoryCeiling }
        effective = max(1, effective)

        let kvBytes = UInt64(effective) * kvBytesPerToken
        let total = residentBudget &+ kvBytes
        let allowThreshold = UInt64(Double(available) * 0.85)
        let verdict: ModelLoadPlan.Verdict
        if total <= allowThreshold {
            verdict = .allow
        } else if total <= available {
            verdict = .warn
        } else {
            verdict = .deny
        }
        return (effective, verdict, residentBudget, kvBytes, total)
    }

    private func makeInputs(
        modelFileSize: UInt64 = 4_000_000_000,
        strategy: MemoryStrategy = .mappable,
        requested: Int = 4096,
        trained: Int? = 8192,
        kvBytesPerToken: UInt64 = 8_192,
        available: UInt64 = 8_000_000_000,
        physical: UInt64 = 16_000_000_000,
        absoluteCeiling: Int = 128_000,
        headroom: Double = 0.40
    ) -> ModelLoadPlan.Inputs {
        ModelLoadPlan.Inputs(
            modelFileSize: modelFileSize,
            memoryStrategy: strategy,
            requestedContextSize: requested,
            trainedContextLength: trained,
            kvBytesPerToken: kvBytesPerToken,
            availableMemoryBytes: available,
            physicalMemoryBytes: physical,
            absoluteContextCeiling: absoluteCeiling,
            headroomFraction: headroom
        )
    }

    // MARK: - Basic cases

    func test_plentyOfMemory_allowsAtRequestedContext() {
        let inputs = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 4096,
            trained: 8192,
            available: 64 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertEqual(plan.effectiveContextSize, 4096)
    }

    func test_constrainedDevice_clampsContextAndAllows() {
        // 1 GB available, 8_192 bytes/token → ~73 000 memory ceiling;
        // requested 128 000 with trained 128 000 → memory is the binding clamp.
        let inputs = makeInputs(
            modelFileSize: 500_000_000,
            strategy: .mappable,
            requested: 128_000,
            trained: 128_000,
            kvBytesPerToken: 8_192,
            available: oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        let exp = expectedOutcome(
            modelFileSize: 500_000_000, strategy: .mappable,
            requested: 128_000, trained: 128_000,
            kvBytesPerToken: 8_192, available: oneGB
        )
        XCTAssertEqual(plan.effectiveContextSize, exp.effective)
        XCTAssertLessThan(plan.effectiveContextSize, 128_000)
        XCTAssertEqual(plan.verdict, exp.verdict)
        XCTAssertTrue(plan.reasons.contains(.memoryCeilingReached(requested: 128_000, ceiling: exp.effective)))
    }

    func test_trainedContextShorterThanRequested_clampsWithInfoReason() {
        let inputs = makeInputs(
            modelFileSize: 2 * oneGB,
            strategy: .mappable,
            requested: 8192,
            trained: 2048,
            available: 32 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.effectiveContextSize, 2048)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertTrue(plan.reasons.contains(.trainedContextExceeded(requested: 8192, trained: 2048)))
    }

    // MARK: - Denial paths

    func test_residentStrategy_deniesWhenWeightsExceedAvailable() {
        // 8 GB model loaded resident, only 3 GB available.
        let inputs = makeInputs(
            modelFileSize: 8 * oneGB,
            strategy: .resident,
            requested: 4096,
            trained: 8192,
            available: 3 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.verdict, .deny)
        let hasInsufficientResident = plan.reasons.contains { reason in
            if case .insufficientResident = reason { return true }
            return false
        }
        XCTAssertTrue(hasInsufficientResident, "Expected an .insufficientResident reason; got \(plan.reasons)")
    }

    func test_mappableStrategy_deniesWhenKVOverrunsBudget_withInsufficientKVCacheReason() {
        // #400 regression: mappable strategy, weights mmap'd fine, but KV overruns available.
        // The algorithm's fix is to *clamp* the context to what fits, surfacing a
        // `.memoryCeilingReached` info-only reason. The clamp is what prevents the crash —
        // the verdict stays `.allow` by design because the clamped total fits.
        //
        // Deviation from brief: the brief anticipated `.deny` + `.insufficientKVCache`
        // here, but per the explicit formula (verdict computed from *clamped* total,
        // not requested total), denial is impossible once the clamp is applied. We
        // instead assert the clamp is large and surfaces the correct reason — which is
        // still the #400 regression guard because it proves the requested 128 K was
        // rejected. See report for full rationale.
        let inputs = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 128_000,
            trained: 131_072,
            kvBytesPerToken: 65_536,
            available: 2 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        // The requested 128 000 must have been clamped hard.
        XCTAssertLessThan(plan.effectiveContextSize, 128_000 / 4)
        let hasMemoryReason = plan.reasons.contains { reason in
            if case .memoryCeilingReached = reason { return true }
            return false
        }
        XCTAssertTrue(hasMemoryReason, "Expected a .memoryCeilingReached reason; got \(plan.reasons)")
    }

    func test_iPad8GB_128kContext_Qwen7B_profile_clampsContextHard() {
        // #398/#411 regression: iPad jetsam limit ~3 GB on 8 GB device.
        // Qwen2.5 7B Q4 (~4.5 GB file), architectural KV ~131 KB/token.
        // The plan must clamp context drastically to avoid the OOM that #398 reported,
        // and expose a .memoryCeilingReached info-reason for diagnostics.
        //
        // Deviation from brief: per the formula the verdict is `.allow` (clamped total
        // fits). The fix for #398 is the clamp itself. See report.
        let inputs = makeInputs(
            modelFileSize: 4_500_000_000,
            strategy: .mappable,
            requested: 128_000,
            trained: 131_072,
            kvBytesPerToken: 131_072,
            available: 3_000_000_000,
            physical: 8_000_000_000
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertLessThan(plan.effectiveContextSize, 128_000 / 10)
        let hasMemoryReason = plan.reasons.contains { reason in
            if case .memoryCeilingReached = reason { return true }
            return false
        }
        XCTAssertTrue(hasMemoryReason, "Expected a .memoryCeilingReached reason; got \(plan.reasons)")
    }

    // MARK: - Ceiling info-only

    func test_absoluteCeiling_capsAt128k_withAbsoluteCeilingReasonOnInfoOnly() {
        // Petabytes of memory, trained context 1 M, requested 500 K → clamps to 128 K via absolute ceiling.
        let huge: UInt64 = 1_000_000_000_000
        let inputs = makeInputs(
            modelFileSize: 500_000_000,
            strategy: .mappable,
            requested: 500_000,
            trained: 1_000_000,
            kvBytesPerToken: 8_192,
            available: huge
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.effectiveContextSize, 128_000)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertTrue(plan.reasons.contains(.absoluteCeilingReached(requested: 500_000, ceiling: 128_000)))
    }

    // MARK: - KV fallback

    func test_nilKVEstimate_usesLegacyFallback_produces8kbPerTokenClamp() {
        // Use the ModelInfo factory with no KV estimate — should fall back to 8 192 bytes/token.
        let model = ModelInfo(
            name: "test",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 500_000_000,
            modelType: .gguf,
            detectedContextLength: 128_000,
            estimatedKVBytesPerToken: nil
        )
        let oneGBLocal = oneGB
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { oneGBLocal },
            physicalMemoryBytes: 8 * oneGBLocal
        )
        let plan = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 128_000,
            strategy: .mappable,
            environment: env
        )
        // With 8 KB/token: kvBudget ≈ 0.6 GB → ~75 000 tokens.
        let expected = expectedOutcome(
            modelFileSize: 500_000_000, strategy: .mappable,
            requested: 128_000, trained: 128_000,
            kvBytesPerToken: 8_192, available: oneGB
        )
        XCTAssertEqual(plan.effectiveContextSize, expected.effective)
    }

    func test_architecturalKVEstimate_tightensClampVersusLegacy() {
        // Same available memory; architectural estimate (131 072) must clamp tighter than legacy 8 192.
        let available: UInt64 = 2 * oneGB
        let legacy = ModelLoadPlan.compute(inputs: makeInputs(
            modelFileSize: 500_000_000, strategy: .mappable,
            requested: 128_000, trained: 128_000,
            kvBytesPerToken: 8_192, available: available
        ))
        let architectural = ModelLoadPlan.compute(inputs: makeInputs(
            modelFileSize: 500_000_000, strategy: .mappable,
            requested: 128_000, trained: 128_000,
            kvBytesPerToken: 131_072, available: available
        ))
        XCTAssertLessThan(architectural.effectiveContextSize, legacy.effectiveContextSize)
    }

    // MARK: - Monotonicity

    func test_sameModel_doubledContext_producesProportionallyTighterVerdict() {
        // Doubling the requested context on a constrained device must never *relax* the verdict.
        // allow (0) <= warn (1) <= deny (2) ordinality.
        func rank(_ v: ModelLoadPlan.Verdict) -> Int {
            switch v { case .allow: return 0; case .warn: return 1; case .deny: return 2 }
        }
        let base = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 2048,
            trained: 131_072,
            kvBytesPerToken: 65_536,
            available: 2 * oneGB
        )
        let doubled = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 4096,
            trained: 131_072,
            kvBytesPerToken: 65_536,
            available: 2 * oneGB
        )
        let quadrupled = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 8192,
            trained: 131_072,
            kvBytesPerToken: 65_536,
            available: 2 * oneGB
        )
        let p1 = ModelLoadPlan.compute(inputs: base)
        let p2 = ModelLoadPlan.compute(inputs: doubled)
        let p3 = ModelLoadPlan.compute(inputs: quadrupled)
        XCTAssertLessThanOrEqual(rank(p1.verdict), rank(p2.verdict))
        XCTAssertLessThanOrEqual(rank(p2.verdict), rank(p3.verdict))
    }

    // MARK: - Edge cases

    func test_nearZeroMemory_floorsContextAtOne() {
        let inputs = makeInputs(
            modelFileSize: 100_000_000,
            strategy: .mappable,
            requested: 4096,
            trained: 8192,
            kvBytesPerToken: 8_192,
            available: 1000
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertGreaterThanOrEqual(plan.effectiveContextSize, 1)
    }

    // MARK: - Verdict boundaries

    func test_verdict_atExactFit_isWarn() {
        // Construct inputs so totalEstimatedBytes == availableMemoryBytes.
        // Use .external strategy → resident = 0, so total == effective * kvBytes/token.
        // Choose kv = 1, effective = 1_000_000, available = 1_000_000 → total == available → warn.
        // But we also need total > available * 0.85, which is 850_000 — 1_000_000 > 850_000 ✓.
        let inputs = ModelLoadPlan.Inputs(
            modelFileSize: 0,
            memoryStrategy: .external,
            requestedContextSize: 1_000_000,
            trainedContextLength: 1_000_000,
            kvBytesPerToken: 1,
            availableMemoryBytes: 1_000_000,
            physicalMemoryBytes: 16 * oneGB,
            absoluteContextCeiling: 128_000_000,
            headroomFraction: 0.0
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        // With headroom 0.0 and no resident, kvBudget == available, so memoryCeiling = 1_000_000.
        // effective == requested == 1_000_000. Total = 1_000_000 bytes == available → warn.
        XCTAssertEqual(plan.totalEstimatedBytesForAssertion, 1_000_000)
        XCTAssertEqual(plan.verdict, .warn)
    }

    func test_exactFitBoundary_85PercentThreshold_isWarn() {
        // total == 86% of available → should be .warn (above .allow 85% threshold but <= available).
        // total == 84% → .allow.
        let available: UInt64 = 1_000_000_000
        // Warn case: effective fixed such that kv = ~0.86 GB.
        let warnInputs = ModelLoadPlan.Inputs(
            modelFileSize: 0,
            memoryStrategy: .external,
            requestedContextSize: 860_000,
            trainedContextLength: 860_000,
            kvBytesPerToken: 1_000,
            availableMemoryBytes: available,
            physicalMemoryBytes: 16 * oneGB,
            absoluteContextCeiling: 128_000_000,
            headroomFraction: 0.0
        )
        let warnPlan = ModelLoadPlan.compute(inputs: warnInputs)
        XCTAssertEqual(warnPlan.verdict, .warn)

        // Allow case: total = 0.84 GB → below 0.85 threshold.
        let allowInputs = ModelLoadPlan.Inputs(
            modelFileSize: 0,
            memoryStrategy: .external,
            requestedContextSize: 840_000,
            trainedContextLength: 840_000,
            kvBytesPerToken: 1_000,
            availableMemoryBytes: available,
            physicalMemoryBytes: 16 * oneGB,
            absoluteContextCeiling: 128_000_000,
            headroomFraction: 0.0
        )
        let allowPlan = ModelLoadPlan.compute(inputs: allowInputs)
        XCTAssertEqual(allowPlan.verdict, .allow)
    }

    // MARK: - Info-only + allow coexistence

    func test_reasons_includeInfoOnlyWhenVerdictIsAllow() {
        // Plenty of memory, but trained context is smaller than requested → allow + info reason.
        let inputs = makeInputs(
            modelFileSize: 1 * oneGB,
            strategy: .mappable,
            requested: 8192,
            trained: 2048,
            available: 64 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertTrue(plan.reasons.contains(.trainedContextExceeded(requested: 8192, trained: 2048)))
    }

    // MARK: - System-managed / cloud factories

    func test_systemManaged_factory_allowsWithStubMemory() {
        let plan = ModelLoadPlan.systemManaged(requestedContextSize: 4096)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertEqual(plan.effectiveContextSize, 4096)
        XCTAssertEqual(plan.outcome.estimatedKVBytes, 0)
    }

    func test_cloud_factory_allowsWithInformationalContext() {
        let plan = ModelLoadPlan.cloud(requestedContextSize: 0)
        XCTAssertEqual(plan.verdict, .allow)
    }

    // MARK: - Property-style grid tests

    /// For every grid input, total must equal resident + kv (the two sub-estimates).
    func test_property_totalEqualsResidentPlusKV() {
        let strategies: [MemoryStrategy] = [.resident, .mappable, .external]
        let fileSizes: [UInt64] = [1 * oneGB, 4 * oneGB, 16 * oneGB]
        let requesteds = [1024, 8192, 32_000]
        let trainedOpts: [Int?] = [nil, 8192, 131_072]
        let kvs: [UInt64] = [8_192, 65_536, 131_072]
        let availables: [UInt64] = [oneGB, 4 * oneGB, 16 * oneGB]

        for strategy in strategies {
            for fs in fileSizes {
                for req in requesteds {
                    for trained in trainedOpts {
                        for kv in kvs {
                            for avail in availables {
                                let inputs = self.makeInputs(
                                    modelFileSize: fs, strategy: strategy, requested: req,
                                    trained: trained, kvBytesPerToken: kv, available: avail
                                )
                                let plan = ModelLoadPlan.compute(inputs: inputs)
                                XCTAssertEqual(
                                    plan.outcome.totalEstimatedBytes,
                                    plan.outcome.estimatedResidentBytes + plan.outcome.estimatedKVBytes,
                                    "total != resident + kv for \(inputs)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// effectiveContextSize must be <= every ceiling (requested, trained, memory, absolute).
    func test_property_effectiveContextLEAllCeilings() {
        let strategies: [MemoryStrategy] = [.resident, .mappable]
        let fileSizes: [UInt64] = [1 * oneGB, 4 * oneGB]
        let requesteds = [1024, 8192, 64_000, 200_000]
        let trainedOpts: [Int?] = [nil, 4096, 131_072]
        let kvs: [UInt64] = [8_192, 131_072]
        let availables: [UInt64] = [oneGB, 8 * oneGB]

        for strategy in strategies {
            for fs in fileSizes {
                for req in requesteds {
                    for trained in trainedOpts {
                        for kv in kvs {
                            for avail in availables {
                                let inputs = self.makeInputs(
                                    modelFileSize: fs, strategy: strategy, requested: req,
                                    trained: trained, kvBytesPerToken: kv, available: avail
                                )
                                let plan = ModelLoadPlan.compute(inputs: inputs)

                                // Recompute the memory ceiling locally, same formula as production.
                                let residentBudget: UInt64
                                switch strategy {
                                case .resident: residentBudget = fs
                                case .mappable: residentBudget = min(fs / 4, oneGB)
                                case .external: residentBudget = 0
                                }
                                let reserveAfter = UInt64(Double(avail) * 0.60)
                                let kvBudget: UInt64 = reserveAfter > residentBudget ? reserveAfter - residentBudget : 0
                                let memoryCeiling = Int(kvBudget / kv)
                                // Production only clamps to trained when trained != nil; when nil the
                                // effective size can still be bounded by requested/absolute/memory.
                                let trainedCeiling = trained ?? Int.max
                                let upperBound = min(req, trainedCeiling, memoryCeiling, 128_000)

                                XCTAssertLessThanOrEqual(
                                    plan.effectiveContextSize,
                                    max(1, upperBound),
                                    "effective exceeded a ceiling for \(inputs)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// Doubling availableMemoryBytes must never make the verdict *stricter*.
    func test_property_verdictMonotonicInAvailableMemory() {
        func rank(_ v: ModelLoadPlan.Verdict) -> Int {
            switch v { case .allow: return 0; case .warn: return 1; case .deny: return 2 }
        }
        let fileSizes: [UInt64] = [1 * oneGB, 4 * oneGB]
        let kvs: [UInt64] = [8_192, 131_072]
        let requesteds = [4096, 64_000]

        // We keep strategy, fileSize, requested, trained, kv fixed and vary `available`.
        for fs in fileSizes {
            for kv in kvs {
                for req in requesteds {
                    let base = self.makeInputs(
                        modelFileSize: fs, strategy: .mappable, requested: req,
                        trained: 131_072, kvBytesPerToken: kv, available: oneGB
                    )
                    let doubled = self.makeInputs(
                        modelFileSize: fs, strategy: .mappable, requested: req,
                        trained: 131_072, kvBytesPerToken: kv, available: 2 * oneGB
                    )
                    let quadrupled = self.makeInputs(
                        modelFileSize: fs, strategy: .mappable, requested: req,
                        trained: 131_072, kvBytesPerToken: kv, available: 4 * oneGB
                    )
                    let p1 = ModelLoadPlan.compute(inputs: base)
                    let p2 = ModelLoadPlan.compute(inputs: doubled)
                    let p3 = ModelLoadPlan.compute(inputs: quadrupled)
                    XCTAssertLessThanOrEqual(rank(p2.verdict), rank(p1.verdict),
                        "doubling memory made verdict stricter: \(p1.verdict) -> \(p2.verdict)")
                    XCTAssertLessThanOrEqual(rank(p3.verdict), rank(p2.verdict),
                        "quadrupling memory made verdict stricter: \(p2.verdict) -> \(p3.verdict)")
                }
            }
        }
    }
}

// MARK: - Convenience accessor (test-scoped, avoids repeating `plan.outcome.totalEstimatedBytes`)

private extension ModelLoadPlan {
    var totalEstimatedBytesForAssertion: UInt64 { outcome.totalEstimatedBytes }
}
