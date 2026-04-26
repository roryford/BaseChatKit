import SwiftUI
import BaseChatCore

/// A row displaying a summary of an `APIEndpoint` configuration.
///
/// Shows the endpoint name, provider badge, model name, and a
/// ready/incomplete status indicator based on `endpoint.validate()`.
/// When the endpoint is invalid, the specific
/// ``APIEndpointValidationReason`` is surfaced as a subtitle so the user
/// knows what to fix.
public struct APIEndpointRow: View {

    public let endpoint: APIEndpoint

    public init(endpoint: APIEndpoint) {
        self.endpoint = endpoint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(endpoint.name)
                    .font(.headline)

                Spacer()

                Text(endpoint.provider.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary, in: Capsule())
            }

            HStack(spacing: 8) {
                Text(endpoint.modelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch endpoint.validate() {
                case .success:
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failure:
                    Label("Incomplete", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if case .failure(let reason) = endpoint.validate(),
               let description = reason.errorDescription {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(endpoint.name), \(endpoint.provider.rawValue), \(endpoint.modelName)")
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint("Tap to edit")
    }

    /// Voice-over status string: "Ready" or the specific failure reason.
    private var accessibilityStatus: String {
        switch endpoint.validate() {
        case .success:
            return "Ready"
        case .failure(let reason):
            return reason.errorDescription ?? "Incomplete"
        }
    }
}

// MARK: - Preview

#Preview("Endpoint Row") {
    List {
        APIEndpointRow(
            endpoint: APIEndpoint(name: "My OpenAI", provider: .openAI)
        )
        APIEndpointRow(
            endpoint: APIEndpoint(name: "Local Ollama", provider: .ollama)
        )
    }
}
