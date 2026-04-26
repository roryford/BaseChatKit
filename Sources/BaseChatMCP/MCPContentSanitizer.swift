import Foundation

enum MCPContentSanitizer {
    /// Wraps tool output text in an untrusted-content envelope so the model
    /// can distinguish server-provided data from system instructions.
    static func wrapForUntrustedSurface(
        _ text: String,
        serverDisplayName: String
    ) -> String {
        let escapedName = serverDisplayName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let stripped = stripUnsafe(text)
        return "<tool_output server=\"\(escapedName)\" trust=\"untrusted\">\n\(stripped)\n</tool_output>"
    }

    private static func stripUnsafe(_ text: String) -> String {
        // Strip ANSI escape sequences
        let ansiPattern = "\u{1B}\\[[0-9;]*[mGKHFABCDJT]"
        var result = text.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression
        )
        // Strip envelope-escape attempts
        result = result
            .replacingOccurrences(of: "</tool_output>", with: "&lt;/tool_output&gt;")
            .replacingOccurrences(of: "<tool_output", with: "&lt;tool_output")
        // Strip control characters (keep newline, tab, carriage return)
        result = String(result.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) {
                return scalar.value == 10 || scalar.value == 13 || scalar.value == 9
            }
            return true
        })
        return result
    }
}
