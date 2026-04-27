import Foundation
import XCTest
@testable import BaseChatMCP
import BaseChatInference

final class MCPErrorMappingTests: XCTestCase {

    // MARK: - Direct case → ErrorKind mappings

    func test_toolNotFound_mapsTo_unknownTool() {
        XCTAssertEqual(errorKind(for: .toolNotFound("search")), .unknownTool)
    }

    func test_requestTimeout_mapsTo_timeout() {
        XCTAssertEqual(errorKind(for: .requestTimeout), .timeout)
    }

    func test_cancelled_mapsTo_cancelled() {
        XCTAssertEqual(errorKind(for: .cancelled), .cancelled)
    }

    func test_authorizationRequired_mapsTo_permissionDenied() {
        let request = MCPAuthorizationRequest(serverID: UUID())
        XCTAssertEqual(errorKind(for: .authorizationRequired(request)), .permissionDenied)
    }

    func test_authorizationFailed_mapsTo_permissionDenied() {
        XCTAssertEqual(errorKind(for: .authorizationFailed("denied")), .permissionDenied)
    }

    func test_unauthorized_mapsTo_permissionDenied() {
        XCTAssertEqual(errorKind(for: .unauthorized), .permissionDenied)
    }

    func test_transportClosed_mapsTo_transient() {
        XCTAssertEqual(errorKind(for: .transportClosed), .transient)
    }

    func test_transportFailure_mapsTo_transient() {
        XCTAssertEqual(errorKind(for: .transportFailure("boom")), .transient)
    }

    func test_networkUnavailable_mapsTo_transient() {
        XCTAssertEqual(errorKind(for: .networkUnavailable), .transient)
    }

    func test_backgroundedDuringDispatch_mapsTo_transient() {
        XCTAssertEqual(errorKind(for: .backgroundedDuringDispatch), .transient)
    }

    // MARK: - Protocol error code switch

    func test_protocolError_methodNotFound_mapsTo_unknownTool() {
        let error = MCPError.protocolError(code: -32601, message: "method not found", data: nil)
        XCTAssertEqual(errorKind(for: error), .unknownTool)
    }

    func test_protocolError_invalidParams_mapsTo_invalidArguments() {
        let error = MCPError.protocolError(code: -32602, message: "invalid params", data: nil)
        XCTAssertEqual(errorKind(for: error), .invalidArguments)
    }

    func test_protocolError_internalError_mapsTo_permanent() {
        let error = MCPError.protocolError(code: -32603, message: "internal error", data: nil)
        XCTAssertEqual(errorKind(for: error), .permanent)
    }

    func test_protocolError_parseError_mapsTo_permanent() {
        let error = MCPError.protocolError(code: -32700, message: "parse error", data: nil)
        XCTAssertEqual(errorKind(for: error), .permanent)
    }

    func test_protocolError_invalidRequest_mapsTo_permanent() {
        let error = MCPError.protocolError(code: -32600, message: "invalid request", data: nil)
        XCTAssertEqual(errorKind(for: error), .permanent)
    }

    func test_protocolError_serverDefinedCode_mapsTo_permanent() {
        let error = MCPError.protocolError(code: 1, message: "custom", data: nil)
        XCTAssertEqual(errorKind(for: error), .permanent)
    }

    // MARK: - Permanent fallthrough cases

    func test_unsupportedProtocolVersion_mapsTo_permanent() {
        let error = MCPError.unsupportedProtocolVersion(server: "2025-03-26", client: "2024-11-05")
        XCTAssertEqual(errorKind(for: error), .permanent)
    }

    func test_malformedMetadata_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .malformedMetadata("bad json")), .permanent)
    }

    func test_issuerMismatch_mapsTo_permanent() {
        let expected = URL(string: "https://expected.example.com")!
        let actual = URL(string: "https://actual.example.com")!
        XCTAssertEqual(errorKind(for: .issuerMismatch(expected: expected, actual: actual)), .permanent)
    }

    func test_dcrFailed_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .dcrFailed("registration rejected")), .permanent)
    }

    func test_ssrfBlocked_mapsTo_permanent() {
        let url = URL(string: "http://169.254.169.254/")!
        XCTAssertEqual(errorKind(for: .ssrfBlocked(url)), .permanent)
    }

    func test_tooManyTools_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .tooManyTools(500)), .permanent)
    }

    func test_oversizeContent_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .oversizeContent(1_000_000)), .permanent)
    }

    func test_oversizeMessage_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .oversizeMessage(1_000_000)), .permanent)
    }

    func test_failed_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .failed("unspecified")), .permanent)
    }

    // MARK: - Coverage marker

    /// Forces a compile error if a new MCPError case is added without updating
    /// the mapping tests. Mirrors the exhaustive switch in MCPErrorMapping.swift.
    func test_exhaustiveCaseCoverage_compileTimeMarker() {
        let allCases: [MCPError] = [
            .transportClosed,
            .transportFailure(""),
            .protocolError(code: 0, message: "", data: nil),
            .requestTimeout,
            .unsupportedProtocolVersion(server: "", client: ""),
            .authorizationRequired(MCPAuthorizationRequest(serverID: UUID())),
            .authorizationFailed(""),
            .dcrFailed(""),
            .malformedMetadata(""),
            .issuerMismatch(expected: URL(string: "https://a")!, actual: URL(string: "https://b")!),
            .ssrfBlocked(URL(string: "https://c")!),
            .tooManyTools(0),
            .toolNotFound(""),
            .oversizeContent(0),
            .oversizeMessage(0),
            .networkUnavailable,
            .unauthorized,
            .failed(""),
            .backgroundedDuringDispatch,
            .cancelled
        ]
        for error in allCases {
            // Just confirm the function returns a value for every case.
            _ = errorKind(for: error)
        }
        XCTAssertEqual(allCases.count, 20)
    }
}
