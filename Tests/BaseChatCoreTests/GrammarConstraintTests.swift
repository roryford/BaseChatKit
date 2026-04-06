import XCTest
@testable import BaseChatCore

/// Tests for GrammarConstraint: GBNF string handling and schema-to-GBNF conversion.
final class GrammarConstraintTests: XCTestCase {

    // MARK: - GBNF Round-Trip

    func test_gbnf_roundTrip() {
        let grammar = #"root ::= "hello" | "world""#
        let constraint = GrammarConstraint.gbnf(grammar)

        XCTAssertEqual(constraint.toGBNF(), grammar)
    }

    func test_gbnf_equatable() {
        let a = GrammarConstraint.gbnf("root ::= [a-z]+")
        let b = GrammarConstraint.gbnf("root ::= [a-z]+")
        let c = GrammarConstraint.gbnf("root ::= [0-9]+")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - JSON Schema to GBNF

    func test_jsonSchema_stringType() throws {
        let constraint = try GrammarConstraint.jsonSchema(from: ["type": "string"])
        let gbnf = constraint.toGBNF()

        XCTAssertNotNil(gbnf)
        XCTAssertTrue(gbnf!.contains("root"))
    }

    func test_jsonSchema_numberType() throws {
        let constraint = try GrammarConstraint.jsonSchema(from: ["type": "number"])
        let gbnf = constraint.toGBNF()

        XCTAssertNotNil(gbnf)
        XCTAssertTrue(gbnf!.contains("[0-9]"))
        XCTAssertTrue(gbnf!.contains("."))
    }

    func test_jsonSchema_integerType() throws {
        let constraint = try GrammarConstraint.jsonSchema(from: ["type": "integer"])
        let gbnf = constraint.toGBNF()

        XCTAssertNotNil(gbnf)
        XCTAssertTrue(gbnf!.contains("[0-9]"))
    }

    func test_jsonSchema_booleanType() throws {
        let constraint = try GrammarConstraint.jsonSchema(from: ["type": "boolean"])
        let gbnf = constraint.toGBNF()

        XCTAssertNotNil(gbnf)
        XCTAssertTrue(gbnf!.contains("true"))
        XCTAssertTrue(gbnf!.contains("false"))
    }

    func test_jsonSchema_objectType_withProperties() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "Person name"] as [String: Any],
                "age": ["type": "integer", "description": "Person age"] as [String: Any]
            ] as [String: Any]
        ]
        let constraint = try GrammarConstraint.jsonSchema(from: schema)
        let gbnf = constraint.toGBNF()

        XCTAssertNotNil(gbnf)
        // Object GBNF should reference property names
        XCTAssertTrue(gbnf!.contains("age"))
        XCTAssertTrue(gbnf!.contains("name"))
        XCTAssertTrue(gbnf!.contains("root"))
        XCTAssertTrue(gbnf!.contains("ws"))
    }

    func test_jsonSchema_emptyObject() throws {
        let constraint = try GrammarConstraint.jsonSchema(from: [
            "type": "object"
        ])
        let gbnf = constraint.toGBNF()

        XCTAssertNotNil(gbnf)
        XCTAssertTrue(gbnf!.contains("root"))
    }

    func test_jsonSchema_unknownType_returnsNil() throws {
        let constraint = try GrammarConstraint.jsonSchema(from: ["type": "unknown_type"])
        XCTAssertNil(constraint.toGBNF())
    }

    func test_jsonSchema_noType_returnsNil() throws {
        let constraint = try GrammarConstraint.jsonSchema(from: ["foo": "bar"])
        XCTAssertNil(constraint.toGBNF())
    }

    // MARK: - Equatable

    func test_jsonSchema_equatable() throws {
        let a = try GrammarConstraint.jsonSchema(from: ["type": "string"])
        let b = try GrammarConstraint.jsonSchema(from: ["type": "string"])

        XCTAssertEqual(a, b)
    }

    func test_gbnf_vs_jsonSchema_notEqual() throws {
        let a = GrammarConstraint.gbnf("root ::= [a-z]+")
        let b = try GrammarConstraint.jsonSchema(from: ["type": "string"])

        XCTAssertNotEqual(a, b)
    }

    // MARK: - Schema Dictionary Access

    func test_schemaAsDictionary_forJsonSchema() throws {
        let original: [String: Any] = ["type": "string"]
        let constraint = try GrammarConstraint.jsonSchema(from: original)
        let dict = constraint.schemaAsDictionary()

        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["type"] as? String, "string")
    }

    func test_schemaAsDictionary_forGbnf_returnsNil() {
        let constraint = GrammarConstraint.gbnf("root ::= [a-z]+")
        XCTAssertNil(constraint.schemaAsDictionary())
    }
}
