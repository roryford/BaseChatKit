import Foundation
import XCTest
@testable import BaseChatMCP
import BaseChatInference

/// Tests for D18 (Foundation Models tool count cap) and D21 (schema-based
/// compatibility filter). These are the predicates the demo (and host apps)
/// use to narrow the MCP tool surface when Apple's on-device model is the
/// active backend.
@MainActor
final class MCPFoundationModelsCompatibilityTests: XCTestCase {

    // MARK: - D21 — schema compatibility predicate

    func test_flatObjectSchemaIsCompatible() {
        let schema = JSONSchemaValue.object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("city")]),
        ])
        XCTAssertTrue(isFoundationModelsCompatible(schema, maxDepth: 4))
    }

    func test_oneOfSchemaIsRejected() {
        let schema = JSONSchemaValue.object([
            "oneOf": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("number")]),
            ]),
        ])
        XCTAssertFalse(isFoundationModelsCompatible(schema, maxDepth: 4))
        // Sabotage check: deleting the oneOf guard in
        // schemaDepthIfCompatible would let this slip through.
    }

    func test_anyOfSchemaIsRejected() {
        let schema = JSONSchemaValue.object([
            "anyOf": .array([
                .object(["type": .string("string")]),
            ]),
        ])
        XCTAssertFalse(isFoundationModelsCompatible(schema, maxDepth: 4))
    }

    func test_refSchemaIsRejected() {
        let schema = JSONSchemaValue.object([
            "type": .string("object"),
            "properties": .object([
                "user": .object(["$ref": .string("#/definitions/User")]),
            ]),
        ])
        XCTAssertFalse(isFoundationModelsCompatible(schema, maxDepth: 4))
    }

    func test_deeplyNestedObjectIsRejected() {
        // wrap(inner) wraps `inner` in an object with a `properties.next: inner`
        // edge — each wrap descends one level. Both `wrap` and the leaf are
        // `.object` values, so each contributes one level to the depth count.
        func wrap(_ inner: JSONSchemaValue) -> JSONSchemaValue {
            .object([
                "type": .string("object"),
                "properties": .object(["next": inner]),
            ])
        }
        // String leaf is a scalar (depth contribution = 1 at its position).
        let leaf = JSONSchemaValue.object(["type": .string("string")])

        // wrap^3(leaf) = root(1) -> next(2) -> next(3) -> leaf(4) → fits maxDepth 4.
        let depth4 = wrap(wrap(wrap(leaf)))
        XCTAssertTrue(isFoundationModelsCompatible(depth4, maxDepth: 4))

        // wrap^4(leaf) = depth 5 → rejected.
        let depth5 = wrap(wrap(wrap(wrap(leaf))))
        XCTAssertFalse(isFoundationModelsCompatible(depth5, maxDepth: 4))
        // Sabotage check: removing the `if currentDepth > maxDepth` guard
        // would let depth5 slip through.
    }

    func test_deeplyNestedArrayIsRejected() {
        // Array of array of array of array of array of object — depth 6.
        func arr(_ inner: JSONSchemaValue) -> JSONSchemaValue {
            .object([
                "type": .string("array"),
                "items": inner,
            ])
        }
        let leaf = JSONSchemaValue.object(["type": .string("string")])
        let deep = arr(arr(arr(arr(arr(leaf)))))
        XCTAssertFalse(isFoundationModelsCompatible(deep, maxDepth: 4))
    }

    // MARK: - D21 — query on MCPToolSource

    func test_foundationModelsCompatibleNamesFiltersIncompatibleSchemas() async {
        let source = makeSource(toolSpecs: [
            ("simple", .object([
                "type": .string("object"),
                "properties": .object(["q": .object(["type": .string("string")])]),
            ])),
            ("oneof_tool", .object([
                "oneOf": .array([
                    .object(["type": .string("string")]),
                ]),
            ])),
            ("ref_tool", .object([
                "$ref": .string("#/defs/Foo"),
            ])),
            ("flat_array", .object([
                "type": .string("object"),
                "properties": .object([
                    "items": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
            ])),
        ])
        try? await source.refreshTools()

        let compatible = await source.foundationModelsCompatibleNames(maxDepth: 4)
        XCTAssertEqual(compatible, ["flat_array", "simple"])
    }

    // MARK: - D18 — cap composition

    func test_foundationModelsEnabledNamesAppliesCap() async {
        let manyNames = (0..<25).map { String(format: "tool_%02d", $0) }
        let source = makeSource(
            toolSpecs: manyNames.map { ($0, .object(["type": .string("object")])) },
            // Loosen the source-level filter cap so the underlying refresh succeeds.
            toolFilter: .init(mode: .allowAll, maxToolCount: 100)
        )
        try? await source.refreshTools()

        // Default cap = 16.
        let enabled = await source.foundationModelsEnabledNames()
        XCTAssertEqual(enabled.count, 16)
        XCTAssertEqual(enabled, Array(manyNames.sorted().prefix(16)))

        // Custom cap respected.
        let small = await source.foundationModelsEnabledNames(cap: 3)
        XCTAssertEqual(small, Array(manyNames.sorted().prefix(3)))
    }

    func test_foundationModelsEnabledNamesIsIntersectedAndCapped() async {
        // Mix of compatible and incompatible — cap chooses from the
        // compatible-and-sorted set, never returning incompatible names.
        var specs: [(String, JSONSchemaValue)] = []
        for index in 0..<10 {
            specs.append(("good_\(index)", .object(["type": .string("object")])))
        }
        for index in 0..<10 {
            specs.append(("bad_\(index)", .object([
                "oneOf": .array([.object(["type": .string("string")])]),
            ])))
        }
        let source = makeSource(toolSpecs: specs, toolFilter: .init(mode: .allowAll, maxToolCount: 100))
        try? await source.refreshTools()

        let enabled = await source.foundationModelsEnabledNames(cap: 5)
        XCTAssertEqual(enabled.count, 5)
        for name in enabled {
            XCTAssertTrue(name.hasPrefix("good_"), "\(name) leaked into the enabled set")
        }
        // Sabotage check: removing the .filter call in
        // foundationModelsCompatibleNames would let the bad_ tools sort to
        // the front and fail this check.
    }

    func test_capExposesPublicConstantOf16() {
        XCTAssertEqual(MCPToolFilter.foundationModelsToolCap, 16)
    }

    // MARK: - Helpers

    private func makeSource(
        toolSpecs: [(name: String, schema: JSONSchemaValue)],
        toolFilter: MCPToolFilter = .allowAll
    ) -> MCPToolSource {
        let toolsArray: [JSONSchemaValue] = toolSpecs.map { spec in
            .object([
                "name": .string(spec.name),
                "description": .string("Test tool \(spec.name)"),
                "inputSchema": spec.schema,
            ])
        }
        return MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: toolFilter,
            approvalPolicy: .perCall,
            listTools: {
                .object(["tools": .array(toolsArray)])
            },
            callTool: { _, _ in nil }
        )
    }
}
