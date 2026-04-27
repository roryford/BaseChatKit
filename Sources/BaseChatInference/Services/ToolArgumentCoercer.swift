import Foundation

// MARK: - ToolArgumentCoercer

/// Coerces top-level string-typed arguments to the primitive type declared in
/// a JSON Schema's `properties` map.
///
/// Models — especially smaller open-weight ones — frequently emit
/// JSON-encoded tool arguments where every value is a string, even when the
/// schema declares `integer`, `number`, or `boolean`. Without coercion, the
/// schema validator rejects these calls before they reach the executor and
/// the user sees a hard failure for what is effectively a serialisation
/// quirk.
///
/// Behaviour mirrors Goose AI's `coerce_tool_arguments` helper
/// (`crates/goose/src/agents/reply_parts.rs`):
///
/// - Coercion only runs at the top level of `properties`. Nested objects
///   and arrays pass through unchanged — matching Goose's scope, and
///   keeping the cost bounded so the coercer is safe to run on every
///   dispatch.
/// - Strings that fail to parse fall through unchanged so the validator
///   still produces its real error message.
/// - Already-correct types (an actual JSON number against a `number`
///   schema, etc.) pass through untouched.
///
/// The coercer is intentionally a free namespace rather than a stored
/// dependency on ``ToolRegistry``: it has no state and no allocation cost
/// on the no-op path.
enum ToolArgumentCoercer {

    /// Returns `value` with top-level string entries coerced to match the
    /// primitive types declared in `schema.properties`. Inputs that aren't
    /// objects, or schemas without a `properties` map, pass through
    /// unchanged.
    static func coerce(_ value: JSONSchemaValue, against schema: JSONSchemaValue) -> JSONSchemaValue {
        guard case .object(let args) = value else { return value }
        guard case .object(let schemaObject) = schema,
              case .object(let properties) = schemaObject["properties"] ?? .null
        else {
            return value
        }

        var coerced: [String: JSONSchemaValue] = [:]
        coerced.reserveCapacity(args.count)
        for (key, argValue) in args {
            if case .string(let s) = argValue, let propertySchema = properties[key] {
                coerced[key] = coerceScalar(s, against: propertySchema)
            } else {
                coerced[key] = argValue
            }
        }
        return .object(coerced)
    }

    /// Coerces a single string against a property's declared `type`.
    ///
    /// Returns the original `.string(s)` when the schema doesn't ask for a
    /// primitive type or when parsing fails — the registry's validator then
    /// surfaces a precise type-mismatch error if the call really is
    /// malformed.
    private static func coerceScalar(_ s: String, against schema: JSONSchemaValue) -> JSONSchemaValue {
        guard case .object(let schemaObject) = schema,
              case .string(let typeName) = schemaObject["type"] ?? .null
        else {
            return .string(s)
        }
        switch typeName {
        case "integer", "number":
            return tryCoerceNumber(s)
        case "boolean":
            return tryCoerceBoolean(s)
        default:
            return .string(s)
        }
    }

    /// Parses `s` as a JSON number. Whole-valued floats within the Int64
    /// range collapse to `.number(Int)` so downstream `integer` checks
    /// succeed; non-integer values keep their fractional component.
    private static func tryCoerceNumber(_ s: String) -> JSONSchemaValue {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let n = Double(trimmed), n.isFinite else { return .string(s) }
        // JSONSchemaValue stores all numbers as Double; `n.fract == 0`
        // round-trips losslessly for the integer case, which is what the
        // validator's `integer` check looks for.
        return .number(n)
    }

    private static func tryCoerceBoolean(_ s: String) -> JSONSchemaValue {
        switch s.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return .string(s)
        }
    }
}
