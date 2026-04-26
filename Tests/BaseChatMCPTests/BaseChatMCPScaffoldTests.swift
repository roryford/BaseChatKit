import Foundation
import XCTest
@testable import BaseChatMCP

final class BaseChatMCPScaffoldTests: XCTestCase {
    func test_serverDescriptorInitializes() {
        let descriptor = MCPServerDescriptor(
            displayName: "Test",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "Test disclosure."
        )
        XCTAssertEqual(descriptor.displayName, "Test")
    }

    func test_fixtureScaffoldExists() {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Providers", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureRoot.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        for provider in ["github", "linear", "notion"] {
            let providerRoot = fixtureRoot.appendingPathComponent(provider, isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: providerRoot.path), "Missing provider fixture directory for \(provider)")
            for file in ["server.json", "initialize.result.json", "tools.list.result.json"] {
                let path = providerRoot.appendingPathComponent(file).path
                XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Missing fixture \(provider)/\(file)")
            }
        }
    }

    #if MCPBuiltinCatalog
    func test_builtinCatalogDescriptorsUseHTTPSAndStableIDs() throws {
        let catalog = MCPCatalog.all
        XCTAssertEqual(catalog.count, 3)
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)

        for descriptor in catalog {
            guard case let .streamableHTTP(endpoint, _) = descriptor.transport else {
                XCTFail("Expected streamableHTTP transport for \(descriptor.displayName)")
                continue
            }
            XCTAssertEqual(endpoint.scheme?.lowercased(), "https")
            XCTAssertFalse(descriptor.dataDisclosure.isEmpty)
        }
    }
    #endif
}
