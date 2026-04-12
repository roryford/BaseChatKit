import Foundation
import Observation

/// Owns backend registration, model loading/unloading, the `LoadRequestToken`
/// lifecycle, progress reporting, memory gating, and capability/compatibility queries.
///
/// This is an internal implementation detail of `BaseChatInference`.
/// `InferenceService` delegates all lifecycle operations to this coordinator
/// and preserves the unchanged public API.
@Observable
@MainActor
final class ModelLifecycleCoordinator {

    // MARK: - Published State

    private(set) var isModelLoaded = false
    private(set) var activeBackendName: String?
    private(set) var modelLoadProgress: Double?

    // MARK: - Backend

    private(set) var backend: (any InferenceBackend)?

    // MARK: - Memory Gate

    var memoryGate: MemoryGate?

    // MARK: - Prompt Template

    var selectedPromptTemplate: PromptTemplate = .chatML

    // MARK: - Backend Registry

    private var backendFactories: [BackendFactory] = []
    private var cloudBackendFactories: [CloudBackendFactory] = []
    private var supportedLocalModelTypes: Set<ModelType> = []
    private var supportedCloudProviders: Set<APIProvider> = []

    // MARK: - Load Request Token State

    private struct LoadRequestToken: Hashable, Comparable, Sendable {
        let rawValue: UInt64
        static let zero = Self(rawValue: 0)
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private enum LoadPhase: Equatable {
        case idle
        case loading(request: LoadRequestToken)
        case loaded(request: LoadRequestToken)
    }

    private struct LoadRequestMetadata {
        let source: String
        let target: String
        let backend: String
        let startedAtUptime: TimeInterval
    }

    private var nextLoadRequestToken: LoadRequestToken = .zero
    private var latestRequestedLoadToken: LoadRequestToken?
    private var invalidatedThroughToken: LoadRequestToken = .zero
    private var loadPhase: LoadPhase = .idle
    private var loadRequestMetadataByToken: [LoadRequestToken: LoadRequestMetadata] = [:]

    // MARK: - Initializers

    nonisolated init() {}

    #if DEBUG
    init(backend: any InferenceBackend, name: String = "Mock") {
        self.backend = backend
        self.isModelLoaded = true
        self.activeBackendName = name
        let request = LoadRequestToken(rawValue: 1)
        self.nextLoadRequestToken = request
        self.latestRequestedLoadToken = request
        self.loadPhase = .loaded(request: request)
        self.loadRequestMetadataByToken[request] = LoadRequestMetadata(
            source: "debug",
            target: name,
            backend: name,
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
    }
    #endif

    // MARK: - Backend Registration

    func registerBackendFactory(_ factory: @escaping BackendFactory) {
        backendFactories.append(factory)
    }

    func registerCloudBackendFactory(_ factory: @escaping CloudBackendFactory) {
        cloudBackendFactories.append(factory)
    }

    func declareSupport(for modelType: ModelType) {
        supportedLocalModelTypes.insert(modelType)
    }

    func declareSupport(for provider: APIProvider) {
        supportedCloudProviders.insert(provider)
    }

    // MARK: - Model Loading

    func loadModel(
        from modelInfo: ModelInfo,
        contextSize: Int32 = 2048
    ) async throws {
        unloadModel()

        guard let newBackend = createBackend(for: modelInfo.modelType) else {
            throw InferenceError.inferenceFailure(
                "No registered backend can handle model type \(modelInfo.modelType). "
                + "Register a BackendFactory before loading models."
            )
        }

        // Pre-flight memory check
        if let gate = memoryGate {
            let verdict = gate.check(
                modelFileSize: modelInfo.fileSize,
                strategy: newBackend.capabilities.memoryStrategy
            )
            switch verdict {
            case .allow:
                break
            case .warn(let estimated, let available):
                let estMB = estimated / 1_048_576
                let availMB = available / 1_048_576
                Log.inference.warning("Memory warning: model needs ~\(estMB) MB, \(availMB) MB available")
            case .deny(let estimated, let available):
                switch gate.denyBehavior {
                case .throwError:
                    throw InferenceError.memoryInsufficient(
                        required: estimated, available: available
                    )
                case .warnOnly:
                    let estMB = estimated / 1_048_576
                    let availMB = available / 1_048_576
                    Log.inference.warning("Memory insufficient: model needs ~\(estMB) MB, \(availMB) MB available. Proceeding (may swap).")
                }
            }
        }

        let backendName = backendDisplayName(for: modelInfo.modelType)
        let request = beginLoadRequest(
            source: "local",
            target: modelTypeLogLabel(modelInfo.modelType),
            backend: backendName
        )
        installProgressHandler(on: newBackend, for: request)
        do {
            let url = modelInfo.url
            try await Task.detached(priority: .userInitiated) {
                try await newBackend.loadModel(from: url, contextSize: contextSize)
            }.value
        } catch {
            (newBackend as? LoadProgressReporting)?.setLoadProgressHandler(nil)
            let isStale = finishLoadAttemptWithFailure(request, error: error)
            if isStale {
                newBackend.unloadModel()
            }
            throw error
        }
        (newBackend as? LoadProgressReporting)?.setLoadProgressHandler(nil)

        logLoadEvent("load.complete", request: request)
        guard commitLoadIfCurrent(request: request, backend: newBackend, backendName: backendName) else {
            newBackend.unloadModel()
            logLoadEvent("load.suppress", request: request, reason: "stale-success", clearMetadata: true)
            return
        }
    }

    func loadCloudBackend(from endpoint: APIEndpointRecord) async throws {
        unloadModel()

        guard let url = URL(string: endpoint.baseURL) else {
            throw CloudBackendError.invalidURL(endpoint.baseURL)
        }

        guard let newBackend = createCloudBackend(for: endpoint.provider) else {
            throw InferenceError.inferenceFailure(
                "No registered cloud backend factory can handle provider \(endpoint.provider.rawValue). "
                + "Register a CloudBackendFactory before loading cloud backends."
            )
        }

        switch endpoint.provider {
        case .claude, .openAI, .custom:
            guard let keychainConfigurable = newBackend as? CloudBackendKeychainConfigurable else {
                throw InferenceError.inferenceFailure(
                    "Cloud backend \(type(of: newBackend)) must conform to CloudBackendKeychainConfigurable "
                    + "for provider \(endpoint.provider.rawValue)."
                )
            }
            keychainConfigurable.configure(
                baseURL: url,
                keychainAccount: endpoint.keychainAccount,
                modelName: endpoint.modelName
            )

        case .ollama, .lmStudio:
            guard let urlModelConfigurable = newBackend as? CloudBackendURLModelConfigurable else {
                throw InferenceError.inferenceFailure(
                    "Cloud backend \(type(of: newBackend)) must conform to CloudBackendURLModelConfigurable "
                    + "for provider \(endpoint.provider.rawValue)."
                )
            }
            urlModelConfigurable.configure(baseURL: url, modelName: endpoint.modelName)
        }

        let request = beginLoadRequest(
            source: "cloud",
            target: endpoint.provider.rawValue,
            backend: endpoint.provider.rawValue
        )
        installProgressHandler(on: newBackend, for: request)
        do {
            let backendURL = url
            try await Task.detached(priority: .userInitiated) {
                try await newBackend.loadModel(from: backendURL, contextSize: 0)
            }.value
        } catch {
            (newBackend as? LoadProgressReporting)?.setLoadProgressHandler(nil)
            let isStale = finishLoadAttemptWithFailure(request, error: error)
            if isStale {
                newBackend.unloadModel()
            }
            throw error
        }
        (newBackend as? LoadProgressReporting)?.setLoadProgressHandler(nil)

        logLoadEvent("load.complete", request: request)
        guard commitLoadIfCurrent(
            request: request,
            backend: newBackend,
            backendName: endpoint.provider.rawValue
        ) else {
            newBackend.unloadModel()
            logLoadEvent("load.suppress", request: request, reason: "stale-success", clearMetadata: true)
            return
        }
    }

    /// Unloads the current model and frees all associated memory.
    ///
    /// Does NOT stop generation — that is the facade's responsibility.
    /// The facade calls `stopGeneration()` before delegating here.
    func unloadModel() {
        invalidateOutstandingLoads()
        backend?.unloadModel()
        backend = nil
        isModelLoaded = false
        activeBackendName = nil
    }

    // MARK: - Capability Queries

    var capabilities: BackendCapabilities? {
        backend?.capabilities
    }

    var tokenizer: (any TokenizerProvider)? {
        (backend as? TokenizerVendor)?.tokenizer
    }

    var lastTokenUsage: (promptTokens: Int, completionTokens: Int)? {
        (backend as? TokenUsageProvider)?.lastUsage
    }

    func registeredBackendSnapshot() -> EnabledBackends {
        EnabledBackends(
            localModelTypes: supportedLocalModelTypes,
            cloudProviders: supportedCloudProviders
        )
    }

    func resetConversation() {
        backend?.resetConversation()
    }

    // MARK: - Compatibility

    func compatibility(for modelType: ModelType) -> ModelCompatibilityResult {
        if supportedLocalModelTypes.contains(modelType) {
            return .supported
        }
        return .unsupported(reason: unavailableReasonString(for: modelType))
    }

    func compatibility(for provider: APIProvider) -> ModelCompatibilityResult {
        if supportedCloudProviders.contains(provider) {
            return .supported
        }
        return .unsupported(reason: "No backend registered for \(provider.rawValue). Register a cloud backend factory at startup.")
    }

    // MARK: - Backend Selection (Private)

    private func createBackend(for modelType: ModelType) -> (any InferenceBackend)? {
        for factory in backendFactories {
            if let backend = factory(modelType) {
                return backend
            }
        }
        return nil
    }

    private func createCloudBackend(for provider: APIProvider) -> (any InferenceBackend)? {
        for factory in cloudBackendFactories {
            if let backend = factory(provider) {
                return backend
            }
        }
        return nil
    }

    private func backendDisplayName(for modelType: ModelType) -> String {
        switch modelType {
        case .mlx: "MLX"
        case .gguf: "llama.cpp"
        case .foundation: "Apple"
        }
    }

    // MARK: - Load Token Lifecycle (Private)

    private func beginLoadRequest(
        source: String,
        target: String,
        backend: String
    ) -> LoadRequestToken {
        let request = LoadRequestToken(rawValue: nextLoadRequestToken.rawValue + 1)
        nextLoadRequestToken = request
        latestRequestedLoadToken = request
        loadPhase = .loading(request: request)
        modelLoadProgress = 0.0
        loadRequestMetadataByToken[request] = LoadRequestMetadata(
            source: source,
            target: target,
            backend: backend,
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        logLoadEvent("load.start", request: request)
        return request
    }

    @discardableResult
    private func finishLoadAttemptWithFailure(_ request: LoadRequestToken, error: any Error) -> Bool {
        guard case .loading(let activeRequest) = loadPhase, activeRequest == request else {
            logLoadEvent("load.suppress", request: request, reason: "stale-failure", clearMetadata: true)
            return true
        }
        loadPhase = .idle
        modelLoadProgress = nil
        logLoadEvent(
            "load.failed",
            request: request,
            reason: String(reflecting: type(of: error)),
            clearMetadata: true
        )
        return false
    }

    private func invalidateOutstandingLoads() {
        if case .loading(let activeRequest) = loadPhase {
            logLoadEvent("load.cancel", request: activeRequest, reason: "unload")
        }
        if let latestRequestedLoadToken {
            invalidatedThroughToken = max(invalidatedThroughToken, latestRequestedLoadToken)
        }
        loadPhase = .idle
        modelLoadProgress = nil
    }

    private func canCommitLoad(_ request: LoadRequestToken) -> Bool {
        guard request > invalidatedThroughToken else { return false }
        guard latestRequestedLoadToken == request else { return false }
        guard case .loading(let activeRequest) = loadPhase, activeRequest == request else { return false }
        return true
    }

    @discardableResult
    private func commitLoadIfCurrent(
        request: LoadRequestToken,
        backend newBackend: any InferenceBackend,
        backendName: String
    ) -> Bool {
        guard canCommitLoad(request) else { return false }
        backend = newBackend
        isModelLoaded = true
        modelLoadProgress = nil
        activeBackendName = backendName
        loadPhase = .loaded(request: request)
        logLoadEvent("load.commit", request: request, clearMetadata: true)
        return true
    }

    private func installProgressHandler(
        on newBackend: any InferenceBackend,
        for request: LoadRequestToken
    ) {
        guard let reporting = newBackend as? LoadProgressReporting else { return }
        reporting.setLoadProgressHandler { [weak self] progress in
            await MainActor.run { [weak self] in
                self?.applyLoadProgress(progress, for: request)
            }
        }
    }

    private func applyLoadProgress(_ progress: Double, for request: LoadRequestToken) {
        guard case .loading(let activeRequest) = loadPhase, activeRequest == request else { return }
        modelLoadProgress = max(0.0, min(1.0, progress))
    }

    private func modelTypeLogLabel(_ modelType: ModelType) -> String {
        switch modelType {
        case .mlx: "mlx"
        case .gguf: "gguf"
        case .foundation: "foundation"
        }
    }

    private func logLoadEvent(
        _ event: String,
        request: LoadRequestToken,
        reason: String? = nil,
        clearMetadata: Bool = false
    ) {
        let metadata = loadRequestMetadataByToken[request]
        let latencyMs = metadata.map {
            max(0, Int((ProcessInfo.processInfo.systemUptime - $0.startedAtUptime) * 1_000))
        }

        var message = "event=\(event) req=\(request.rawValue)"
        if let metadata {
            message += " source=\(metadata.source) target=\(metadata.target) backend=\(metadata.backend)"
        }
        if let latencyMs {
            message += " latency_ms=\(latencyMs)"
        }
        if let reason {
            message += " reason=\(reason)"
        }

        if event == "load.failed" {
            Log.inference.error("\(message, privacy: .public)")
        } else {
            Log.inference.info("\(message, privacy: .public)")
        }

        if clearMetadata {
            loadRequestMetadataByToken.removeValue(forKey: request)
        }
    }

    private func unavailableReasonString(for modelType: ModelType) -> String {
        switch modelType {
        case .gguf:
            return "GGUF models require the llama.cpp backend. Build with the Llama Swift package dependency to enable it."
        case .mlx:
            return "MLX models require Apple Silicon and the MLX backend. Build with the MLX Swift package dependency to enable it."
        case .foundation:
            return "Apple Foundation Models require iOS 26 / macOS 26 or later."
        }
    }
}
