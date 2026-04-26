import BaseChatCore
import BaseChatInference

/// Validates in-progress endpoint edits against BaseChatKit's canonical endpoint policy.
enum APIEndpointDraftValidator {
    static func validate(
        provider: APIProvider,
        baseURL: String,
        modelName: String
    ) -> Result<Void, APIEndpointValidationReason> {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = APIEndpoint(
            name: provider.rawValue,
            provider: provider,
            baseURL: trimmedURL.isEmpty ? nil : trimmedURL,
            modelName: trimmedModel.isEmpty ? nil : trimmedModel
        )
        return endpoint.validate()
    }
}
