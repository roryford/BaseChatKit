import Foundation

/// Common protocol adopted by all backend error types so that catch sites
/// in InferenceService and the UI layer can handle errors uniformly without
/// knowing whether the failure came from a local or cloud backend.
public protocol BackendError: LocalizedError, Sendable {}

extension InferenceError: BackendError {}
extension CloudBackendError: BackendError {}
