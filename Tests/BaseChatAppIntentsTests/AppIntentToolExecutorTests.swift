import XCTest
import BaseChatInference
@testable import BaseChatAppIntents

#if canImport(AppIntents)
import AppIntents

// MARK: - Fixtures

/// Happy-path fixture: two required string parameters and one optional.
@available(iOS 26, macOS 26, *)
struct GreetingIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Greet"

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Greeting", description: "Optional salutation override.")
    var greeting: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.name = try c.decode(String.self, forKey: .name)
        self.greeting = try c.decodeIfPresent(String.self, forKey: .greeting)
    }

    private enum CodingKeys: String, CodingKey {
        case name, greeting
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let salutation = greeting ?? "Hello"
        return .result(value: "\(salutation), \(name)")
    }
}

/// Validation fixture: throws on empty input so we can exercise the error path.
@available(iOS 26, macOS 26, *)
struct ValidatingIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Validate"

    @Parameter(title: "Value")
    var value: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.value = try c.decode(String.self, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey { case value }

    struct EmptyValueError: LocalizedError {
        var errorDescription: String? { "value must not be empty" }
    }

    func perform() async throws -> some IntentResult {
        if value.isEmpty {
            throw EmptyValueError()
        }
        return .result()
    }
}

/// Authorisation fixture: throws an error whose domain matches the
/// permission-denied heuristic so the executor classifies it correctly.
@available(iOS 26, macOS 26, *)
struct UnauthorizedIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Unauthorized"

    @Parameter(title: "Resource")
    var resource: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.resource = try c.decode(String.self, forKey: .resource)
    }

    private enum CodingKeys: String, CodingKey { case resource }

    func perform() async throws -> some IntentResult {
        let error = NSError(
            domain: "com.basechat.test.AuthorizationDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Authorization required for \(resource)"]
        )
        throw error
        // Unreachable — present so the opaque return type can be inferred.
        return .result()
    }
}

/// Multi-type fixture: covers Int, Double, Bool, Date, URL, and Optional in
/// one shot so the schema reflection path is exercised end-to-end.
@available(iOS 26, macOS 26, *)
struct WideIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Wide"

    @Parameter(title: "Count")
    var count: Int

    @Parameter(title: "Ratio")
    var ratio: Double

    @Parameter(title: "Flag")
    var flag: Bool

    @Parameter(title: "When")
    var when: Date

    @Parameter(title: "Link")
    var link: URL

    @Parameter(title: "Note")
    var note: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.count = try c.decode(Int.self, forKey: .count)
        self.ratio = try c.decode(Double.self, forKey: .ratio)
        self.flag = try c.decode(Bool.self, forKey: .flag)
        self.when = try c.decode(Date.self, forKey: .when)
        self.link = try c.decode(URL.self, forKey: .link)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey {
        case count, ratio, flag, when, link, note
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: count)
    }
}

// MARK: - Tests

@available(iOS 26, macOS 26, *)
final class AppIntentToolExecutorTests: XCTestCase {

    // MARK: definition synthesis

    func testDefinitionDerivesNameFromIntentType() {
        let executor = AppIntentToolExecutor(GreetingIntent.self)
        XCTAssertEqual(executor.definition.name, "greeting_intent")
    }

    func testDefinitionUsesCustomDescription() {
        let executor = AppIntentToolExecutor(GreetingIntent.self, description: "Greets a person.")
        XCTAssertEqual(executor.definition.description, "Greets a person.")
    }

    func testSchemaIncludesRequiredAndOptionalFields() {
        let executor = AppIntentToolExecutor(GreetingIntent.self)
        guard case .object(let root) = executor.definition.parameters else {
            return XCTFail("schema root must be an object")
        }

        XCTAssertEqual(root["type"], .string("object"))

        guard case .object(let properties) = root["properties"] else {
            return XCTFail("schema must have an object `properties` field")
        }
        XCTAssertEqual(properties["name"], .object(["type": .string("string")]))
        XCTAssertEqual(properties["greeting"], .object(["type": .string("string")]))

        guard case .array(let required) = root["required"] else {
            return XCTFail("schema must declare `required`")
        }
        XCTAssertEqual(required, [.string("name")], "optional `greeting` must not appear in `required`")
    }

    func testSchemaCoversCommonPrimitiveTypes() {
        let executor = AppIntentToolExecutor(WideIntent.self)
        guard case .object(let root) = executor.definition.parameters,
              case .object(let properties) = root["properties"]
        else {
            return XCTFail("schema root must be an object with properties")
        }

        XCTAssertEqual(properties["count"], .object(["type": .string("integer")]))
        XCTAssertEqual(properties["ratio"], .object(["type": .string("number")]))
        XCTAssertEqual(properties["flag"], .object(["type": .string("boolean")]))
        XCTAssertEqual(properties["when"], .object([
            "type": .string("string"),
            "format": .string("date-time"),
        ]))
        XCTAssertEqual(properties["link"], .object([
            "type": .string("string"),
            "format": .string("uri"),
        ]))
        // Optional → still in `properties`, but missing from `required`.
        XCTAssertEqual(properties["note"], .object(["type": .string("string")]))

        guard case .array(let required) = root["required"] else {
            return XCTFail("schema must declare `required`")
        }
        let requiredNames = required.compactMap { value -> String? in
            if case .string(let s) = value { return s } else { return nil }
        }
        XCTAssertFalse(requiredNames.contains("note"), "optional fields must not be required")
        XCTAssertTrue(requiredNames.contains("count"))
        XCTAssertTrue(requiredNames.contains("ratio"))
        XCTAssertTrue(requiredNames.contains("flag"))
        XCTAssertTrue(requiredNames.contains("when"))
        XCTAssertTrue(requiredNames.contains("link"))
    }

    // MARK: execution

    func testExecuteHappyPathSerialisesResult() async throws {
        let executor = AppIntentToolExecutor(GreetingIntent.self)
        let args = JSONSchemaValue.object([
            "name": .string("Ada"),
            "greeting": .string("Salut"),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertNil(result.errorKind, "happy path must not surface an error kind")
        XCTAssertTrue(
            result.content.contains("Salut") && result.content.contains("Ada"),
            "result body must include intent output, got \(result.content)"
        )
    }

    func testExecuteWithMissingRequiredFieldReturnsInvalidArguments() async throws {
        let executor = AppIntentToolExecutor(GreetingIntent.self)
        // No `name` key → JSONDecoder will throw a keyNotFound error.
        let args = JSONSchemaValue.object([:])

        let result = try await executor.execute(arguments: args)

        XCTAssertEqual(result.errorKind, .invalidArguments)
        XCTAssertTrue(result.content.contains("AppIntent arguments"))
    }

    func testExecuteSurfacesIntentValidationErrorAsPermanent() async throws {
        let executor = AppIntentToolExecutor(ValidatingIntent.self)
        let args = JSONSchemaValue.object([
            "value": .string(""),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertEqual(result.errorKind, .permanent)
        XCTAssertTrue(result.content.contains("must not be empty"))
    }

    func testExecuteDetectsAuthorizationFailure() async throws {
        let executor = AppIntentToolExecutor(UnauthorizedIntent.self)
        let args = JSONSchemaValue.object([
            "resource": .string("camera"),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertEqual(
            result.errorKind,
            .permissionDenied,
            "authorisation-domain errors must surface as .permissionDenied"
        )
        XCTAssertTrue(result.content.contains("Authorization required"))
    }

    func testExecutorIsToolExecutorConformant() {
        // Compile-time conformance check + runtime dispatch through the
        // protocol existential, mirroring how ToolRegistry will see the
        // executor in production.
        let executor: any ToolExecutor = AppIntentToolExecutor(GreetingIntent.self)
        XCTAssertEqual(executor.definition.name, "greeting_intent")
        XCTAssertFalse(executor.requiresApproval, "default `requiresApproval` is false")
        XCTAssertFalse(executor.supportsConcurrentDispatch, "default sequential dispatch")
    }
}

#endif // canImport(AppIntents)
