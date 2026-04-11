import Foundation
import BaseChatInference

// Source-compatibility shim: lets callers continue to pass the SwiftData
// `@Model APIEndpoint` directly to `InferenceService.loadCloudBackend(from:)`.
// The underlying inference API now operates on the storage-agnostic
// `APIEndpointRecord`; this extension converts the @Model to a record.
extension APIEndpoint {

    /// Returns a storage-agnostic snapshot of this endpoint suitable for
    /// passing to inference services that don't depend on SwiftData.
    public var record: APIEndpointRecord {
        APIEndpointRecord(
            id: id,
            name: name,
            provider: provider,
            baseURL: baseURL,
            modelName: modelName,
            keychainAccount: keychainAccount
        )
    }
}

extension InferenceService {

    /// Loads a cloud API backend from a SwiftData `APIEndpoint`.
    ///
    /// Convenience overload that converts the model to an `APIEndpointRecord`
    /// before delegating to the storage-agnostic core API.
    @MainActor
    public func loadCloudBackend(from endpoint: APIEndpoint) async throws {
        try await loadCloudBackend(from: endpoint.record)
    }
}
