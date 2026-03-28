import SwiftUI
import BaseChatCore

/// A row displaying a summary of an `APIEndpoint` configuration.
///
/// Shows the endpoint name, provider badge, model name, and a
/// ready/incomplete status indicator based on `endpoint.isValid`.
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

                if endpoint.isValid {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("Incomplete", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(endpoint.name), \(endpoint.provider.rawValue), \(endpoint.modelName)")
        .accessibilityValue(endpoint.isValid ? "Ready" : "Incomplete")
        .accessibilityHint("Tap to edit")
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
