import Foundation
import BaseChatCore
import BaseChatInference

// MARK: - ChatViewModel + Model Loading

// Two-tier load coordination:
// - ChatViewModel (this layer) owns UI task lifecycle via `latestLoadIntentGeneration` —
//   superseded async tasks are cancelled before they reach InferenceService.
// - InferenceService owns backend state correctness via monotonic LoadRequestToken —
//   any stale completion that does reach the service layer is suppressed there.
// Together they provide defense-in-depth: this layer avoids redundant load attempts;
// InferenceService provides the hard correctness guarantee.

extension ChatViewModel {

    /// Coordinates loading for the currently selected model/endpoint.
    ///
    /// Newest selection always wins; any older in-flight coordinated load intent is
    /// cancelled and invalidated.
    public func dispatchSelectedLoad() {
        let generation = nextLoadIntentGeneration(cancelInFlightTask: true)
        guard let intent = currentLoadIntent else { return }

        coordinatedLoadTask = Task { [weak self] in
            await self?.performLoad(intent, generation: generation)
        }
    }

    /// Manually unloads the active backend and invalidates any pending coordinated load.
    public func unloadModel() {
        invalidatePendingLoadIntent(resetActivityPhase: true)
        inferenceService.unloadModel()
        // Token counts are keyed by message UUID, which is reused across sessions.
        // Dropping them here prevents counts computed with the previous model's
        // tokenizer from being returned after a subsequent model swap.
        invalidateTokenCaches()
    }

    /// Loads the currently selected local model into the inference backend.
    ///
    /// Does nothing if a load is already in progress. Sets `isLoading` for the duration
    /// and writes to `errorMessage` on failure. Auto-detects the GGUF prompt template
    /// from model metadata before loading.
    ///
    /// - Note: Prefer `dispatchSelectedLoad()` for UI-driven loads — it coordinates
    ///   intent and cancels superseded requests.
    public func loadSelectedModel() async {
        guard !isLoading else { return }

        guard let model = selectedModel else {
            activeError = ChatError(kind: .configuration, message: "No model selected.", recovery: .selectModel)
            return
        }

        await loadLocalModel(model, generation: nil)
    }

    /// Loads a cloud API endpoint for the active session.
    ///
    /// - Note: Prefer `dispatchSelectedLoad()` for UI-driven loads — it coordinates
    ///   intent and cancels superseded requests.
    public func loadCloudEndpoint(_ endpoint: APIEndpoint) async {
        await loadCloudEndpointInternal(endpoint, generation: nil)
    }

    private var currentLoadIntent: LoadIntent? {
        if let endpoint = selectedEndpoint {
            return .cloudEndpoint(endpoint)
        }
        if let model = selectedModel {
            return .localModel(model)
        }
        return nil
    }

    @discardableResult
    private func nextLoadIntentGeneration(cancelInFlightTask: Bool) -> UInt64 {
        latestLoadIntentGeneration &+= 1
        if cancelInFlightTask {
            coordinatedLoadTask?.cancel()
            coordinatedLoadTask = nil
        }
        return latestLoadIntentGeneration
    }

    private func invalidatePendingLoadIntent(resetActivityPhase: Bool = false) {
        _ = nextLoadIntentGeneration(cancelInFlightTask: true)
        if resetActivityPhase, isLoading {
            transitionPhase(to: .idle)
        }
    }

    private func isCurrentLoadIntentGeneration(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return generation == latestLoadIntentGeneration
    }

    private func beginLoadUIState(generation: UInt64?) -> Bool {
        guard isCurrentLoadIntentGeneration(generation) else { return false }
        errorMessage = nil
        lastProgressTransitionInstant = nil
        transitionPhase(to: .modelLoading(progress: inferenceService.modelLoadProgress))
        return true
    }

    /// Mirrors `inferenceService.modelLoadProgress` into ``activityPhase`` for
    /// the duration of a model load. Polls instead of using
    /// `withObservationTracking` so cancellation is reliable — observation
    /// continuations don't resume on `Task.cancel()`, which makes them
    /// deadlock-prone for a long-running mirror like this.
    ///
    /// The bridge only writes when the load generation is still current AND
    /// `activityPhase` is still `.modelLoading`, so any late wake-up after
    /// `endLoadUIState` has flipped the phase to `.idle` is a no-op.
    private func observeModelLoadProgress(generation: UInt64?) async {
        while !Task.isCancelled {
            applyModelLoadProgress(generation: generation)
            do {
                try await Task.sleep(for: progressBridgePollInterval)
            } catch {
                // Sleep throws on cancel; one final apply ensures the latest
                // value is published before the bridge exits.
                applyModelLoadProgress(generation: generation)
                return
            }
        }
    }

    private func applyModelLoadProgress(generation: UInt64?) {
        guard isCurrentLoadIntentGeneration(generation) else { return }
        guard case .modelLoading(let current) = activityPhase else { return }
        let snapshot = inferenceService.modelLoadProgress
        guard current != snapshot else { return }

        // Terminal progress (>= 1.0) and the first emission after a new load
        // cycle bypass the throttle so the progress UI feels immediate at the
        // start and lands cleanly at 100% before the phase flips to .idle.
        let isTerminal = (snapshot ?? 0.0) >= 1.0
        let now = ContinuousClock.now
        if let last = lastProgressTransitionInstant,
           !isTerminal,
           now - last < progressBridgeMinTransitionInterval {
            return
        }

        if transitionPhase(to: .modelLoading(progress: snapshot)) {
            lastProgressTransitionInstant = now
        }
    }

    private func endLoadUIState(generation: UInt64?) {
        guard isCurrentLoadIntentGeneration(generation) else { return }
        lastProgressTransitionInstant = nil
        if case .modelLoading = activityPhase {
            transitionPhase(to: .idle)
        }
    }

    private func setLoadErrorIfCurrent(_ message: String, generation: UInt64?) {
        guard isCurrentLoadIntentGeneration(generation) else { return }
        errorMessage = message
    }

    private func performLoad(_ intent: LoadIntent, generation: UInt64?) async {
        switch intent {
        case .localModel(let model):
            await loadLocalModel(model, generation: generation)
        case .cloudEndpoint(let endpoint):
            await loadCloudEndpointInternal(endpoint, generation: generation)
        }
    }

    private func loadLocalModel(_ model: ModelInfo, generation: UInt64?) async {
        guard isCurrentLoadIntentGeneration(generation) else { return }

        // Stage 2: unified load plan. `ModelLoadPlan` fuses the legacy
        // `DeviceCapabilityService.canLoadModel(...)` fit check and the
        // `DeviceCapabilityService.safeContextSize(...)` context clamp into a single
        // decision so backends see a consistent verdict + context pair. The
        // legacy helpers are still in place for Stage 5 removal — the UI no
        // longer calls them.
        let requestedContext = model.detectedContextLength ?? 8_192
        let plan: ModelLoadPlan
        switch model.modelType {
        case .foundation:
            // Foundation models are system-managed: no weight or KV math applies.
            plan = ModelLoadPlan.systemManaged(requestedContextSize: requestedContext)
        case .gguf:
            plan = ModelLoadPlan.compute(
                for: model,
                requestedContextSize: requestedContext,
                strategy: .mappable,
                environment: loadPlanEnvironment
            )
        case .mlx:
            plan = ModelLoadPlan.compute(
                for: model,
                requestedContextSize: requestedContext,
                strategy: .resident,
                environment: loadPlanEnvironment
            )
        }

        switch plan.verdict {
        case .deny:
            setLoadErrorIfCurrent(
                loadPlanDenyMessage(for: plan, model: model),
                generation: generation
            )
            return
        case .warn:
            Log.inference.warning(
                "Proceeding with tight-fit model load: \(model.name) — \(String(describing: plan.reasons))"
            )
        case .allow:
            break
        }

        // Auto-detect prompt template from GGUF metadata before loading.
        if let detected = model.detectedPromptTemplate,
           isCurrentLoadIntentGeneration(generation) {
            selectedPromptTemplate = detected
            Log.inference.info("Auto-detected prompt template: \(detected.rawValue)")
        }

        guard beginLoadUIState(generation: generation) else { return }
        let bridge = Task { @MainActor [weak self] in
            await self?.observeModelLoadProgress(generation: generation)
        }
        defer {
            bridge.cancel()
            endLoadUIState(generation: generation)
        }

        do {
            try await inferenceService.loadModel(
                from: model,
                contextSize: Int32(plan.effectiveContextSize)
            )
        } catch is CancellationError {
            return
        } catch {
            setLoadErrorIfCurrent("Failed to load model: \(error.localizedDescription)", generation: generation)
        }
    }

    /// Translates a denied plan's primary `Reason` into a user-visible message.
    ///
    /// Picks the first `.insufficientResident` or `.insufficientKVCache` as the
    /// primary reason; clamp reasons (info-only) are not surfaced. Falls back to
    /// the legacy shape when no primary reason is present.
    private func loadPlanDenyMessage(for plan: ModelLoadPlan, model: ModelInfo) -> String {
        let primary = plan.reasons.first { reason in
            switch reason {
            case .insufficientResident, .insufficientKVCache: return true
            default: return false
            }
        }
        switch primary {
        case .insufficientResident(let required, let available):
            return "This model (\(Self.formatBytes(required))) is too large for available memory (\(Self.formatBytes(available))). Try a smaller quantisation."
        case .insufficientKVCache(let required, let available):
            return "Model weights fit, but the requested context window doesn't (\(Self.formatBytes(required)) needed vs \(Self.formatBytes(available)) available). Try reducing the context size or closing other apps."
        default:
            return "This model (\(model.fileSizeFormatted)) may be too large for this device. Try a smaller quantisation."
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func loadCloudEndpointInternal(_ endpoint: APIEndpoint, generation: UInt64?) async {
        guard beginLoadUIState(generation: generation) else { return }
        let bridge = Task { @MainActor [weak self] in
            await self?.observeModelLoadProgress(generation: generation)
        }
        defer {
            bridge.cancel()
            endLoadUIState(generation: generation)
        }

        do {
            try await inferenceService.loadCloudBackend(from: endpoint)
        } catch is CancellationError {
            return
        } catch {
            setLoadErrorIfCurrent("Failed to connect: \(error.localizedDescription)", generation: generation)
        }
    }
}
