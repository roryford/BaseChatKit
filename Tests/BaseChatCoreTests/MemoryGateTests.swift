import XCTest
@testable import BaseChatCore

final class MemoryGateTests: XCTestCase {

    // MARK: - External Strategy

    func test_externalStrategy_alwaysAllows() {
        let gate = MemoryGate(
            availableMemoryBytes: { 1024 },
            physicalMemoryBytes: 1024
        )
        let verdict = gate.check(modelFileSize: 999_999_999_999, strategy: .external)
        XCTAssertEqual(verdict, .allow)
    }

    // MARK: - Resident Strategy

    func test_residentStrategy_allowsWhenPlentyOfMemory() {
        // 4 GB model, 1.2x = 4.8 GB estimated. 8 GB available. 4.8 < 8*0.85=6.8 -> allow
        let gate = MemoryGate(
            availableMemoryBytes: { 8_000_000_000 },
            physicalMemoryBytes: 16_000_000_000
        )
        let verdict = gate.check(modelFileSize: 4_000_000_000, strategy: .resident)
        XCTAssertEqual(verdict, .allow)
    }

    func test_residentStrategy_warnsWhenTight() {
        // 4 GB model, 1.2x = 4.8 GB estimated. 5 GB available. 4.8 > 5*0.85=4.25 but 4.8 < 5 -> warn
        let gate = MemoryGate(
            availableMemoryBytes: { 5_000_000_000 },
            physicalMemoryBytes: 16_000_000_000
        )
        let verdict = gate.check(modelFileSize: 4_000_000_000, strategy: .resident)
        if case .warn(let est, let avail) = verdict {
            XCTAssertEqual(est, 4_800_000_000)
            XCTAssertEqual(avail, 5_000_000_000)
        } else {
            XCTFail("Expected .warn, got \(verdict)")
        }
    }

    func test_residentStrategy_deniesWhenInsufficient() {
        // 4 GB model, 1.2x = 4.8 GB estimated. 3 GB available. 4.8 > 3 -> deny
        let gate = MemoryGate(
            availableMemoryBytes: { 3_000_000_000 },
            physicalMemoryBytes: 8_000_000_000
        )
        let verdict = gate.check(modelFileSize: 4_000_000_000, strategy: .resident)
        if case .deny(let est, let avail) = verdict {
            XCTAssertEqual(est, 4_800_000_000)
            XCTAssertEqual(avail, 3_000_000_000)
        } else {
            XCTFail("Expected .deny, got \(verdict)")
        }
    }

    // MARK: - Mappable Strategy

    func test_mappableStrategy_usesReducedEstimate() {
        // 4 GB model, 0.25x = 1 GB estimated for KV cache. 2 GB available. 1 < 2*0.85=1.7 -> allow
        let gate = MemoryGate(
            availableMemoryBytes: { 2_000_000_000 },
            physicalMemoryBytes: 8_000_000_000
        )
        let verdict = gate.check(modelFileSize: 4_000_000_000, strategy: .mappable)
        XCTAssertEqual(verdict, .allow)
    }

    func test_mappableStrategy_deniesWhenKVCacheWontFit() {
        // 16 GB model, 0.25x = 4 GB estimated. 2 GB available -> deny
        let gate = MemoryGate(
            availableMemoryBytes: { 2_000_000_000 },
            physicalMemoryBytes: 8_000_000_000
        )
        let verdict = gate.check(modelFileSize: 16_000_000_000, strategy: .mappable)
        if case .deny = verdict {
            // pass
        } else {
            XCTFail("Expected .deny, got \(verdict)")
        }
    }

    func test_mappableStrategy_warnsWhenTight() {
        // 16 GB model, 0.25x = 4 GB estimated. 4.5 GB available. 4 > 4.5*0.85=3.825 but 4 < 4.5 -> warn
        let gate = MemoryGate(
            availableMemoryBytes: { 4_500_000_000 },
            physicalMemoryBytes: 16_000_000_000
        )
        let verdict = gate.check(modelFileSize: 16_000_000_000, strategy: .mappable)
        if case .warn(let est, let avail) = verdict {
            XCTAssertEqual(est, 4_000_000_000)
            XCTAssertEqual(avail, 4_500_000_000)
        } else {
            XCTFail("Expected .warn, got \(verdict)")
        }
    }

    // MARK: - Zero Size

    func test_zeroSizeModel_alwaysAllows() {
        let gate = MemoryGate(
            availableMemoryBytes: { 1024 },
            physicalMemoryBytes: 1024
        )
        XCTAssertEqual(gate.check(modelFileSize: 0, strategy: .resident), .allow)
        XCTAssertEqual(gate.check(modelFileSize: 0, strategy: .mappable), .allow)
        XCTAssertEqual(gate.check(modelFileSize: 0, strategy: .external), .allow)
    }

    // MARK: - Deny Behavior

    func test_denyBehavior_defaultsToWarnOnly() {
        let gate = MemoryGate(
            availableMemoryBytes: { 1024 },
            physicalMemoryBytes: 1024
        )
        XCTAssertEqual(gate.denyBehavior, .warnOnly)
    }

    func test_denyBehavior_canBeSetToThrowError() {
        let gate = MemoryGate(
            availableMemoryBytes: { 1024 },
            physicalMemoryBytes: 1024,
            denyBehavior: .throwError
        )
        XCTAssertEqual(gate.denyBehavior, .throwError)
    }

    // MARK: - Boundary: Exact Fit

    func test_residentStrategy_exactFitIsWarn() {
        // 1 GB model, 1.2x = 1.2 GB estimated. 1.2 GB available. 1.2 == 1.2 -> warn (not allow, since 1.2 > 1.2*0.85)
        let estimated: UInt64 = 1_200_000_000
        let gate = MemoryGate(
            availableMemoryBytes: { estimated },
            physicalMemoryBytes: 4_000_000_000
        )
        let verdict = gate.check(modelFileSize: 1_000_000_000, strategy: .resident)
        if case .warn = verdict {
            // pass -- exact fit is a warning because there's no headroom
        } else {
            XCTFail("Expected .warn for exact fit, got \(verdict)")
        }
    }
}
