import Foundation

/// Detects the best `PromptTemplate` for a model based on GGUF metadata.
///
/// Uses a cascading strategy:
/// 1. If a Jinja chat template string is present, pattern-match on template tokens.
/// 2. If architecture is known (e.g. "llama", "phi"), map it to a template.
/// 3. If only the model name is available, use keyword heuristics.
/// 4. Falls back to ChatML (the most widely compatible format).
struct PromptTemplateDetector {

    /// Detects the best prompt template from GGUF metadata.
    ///
    /// Tries chat template first (most reliable), then architecture, then model name.
    /// Returns `.chatML` as a safe default if nothing matches.
    static func detect(from metadata: GGUFMetadata) -> PromptTemplate {
        // 1. Try chat template string first (most reliable)
        if let chatTemplate = metadata.chatTemplate {
            return detect(fromChatTemplate: chatTemplate)
        }
        // 2. Try architecture
        if let arch = metadata.generalArchitecture {
            return detect(fromArchitecture: arch)
        }
        // 3. Try model name
        if let name = metadata.generalName {
            return detect(fromFileName: name)
        }
        return .chatML // default
    }

    /// Detects a prompt template from a Jinja chat template string.
    ///
    /// Looks for unique token markers that identify each format. Order matters:
    /// more specific patterns (ChatML, Llama 3, Gemma) are checked before broader
    /// ones (Mistral `[INST]`, Alpaca `### Instruction`).
    static func detect(fromChatTemplate template: String) -> PromptTemplate {
        if template.contains("<|im_start|>") { return .chatML }
        if template.contains("<|start_header_id|>") { return .llama3 }
        if template.contains("<start_of_turn>") { return .gemma }
        if template.contains("<|user|>") && template.contains("<|assistant|>") { return .phi }
        if template.contains("[INST]") { return .mistral }
        if template.contains("### Instruction") { return .alpaca }
        return .chatML
    }

    /// Detects a prompt template from the GGUF `general.architecture` field.
    ///
    /// Maps known architecture identifiers to their canonical prompt formats.
    static func detect(fromArchitecture arch: String) -> PromptTemplate {
        switch arch.lowercased() {
        case "mistral": return .mistral
        case "gemma", "gemma2": return .gemma
        case "phi", "phi3": return .phi
        // "llama" is too broad — many models (SmolLM2, TinyLlama, etc.) use the
        // LLaMA architecture but train with ChatML. Fall through to chatML default.
        default: return .chatML
        }
    }

    /// Heuristic detection from a filename or model name string.
    ///
    /// Least reliable strategy -- only used as a last resort when neither a chat
    /// template nor architecture string is available.
    static func detect(fromFileName name: String) -> PromptTemplate {
        let lower = name.lowercased()
        if lower.contains("llama") { return .llama3 }
        if lower.contains("mistral") { return .mistral }
        if lower.contains("gemma") { return .gemma }
        if lower.contains("phi") { return .phi }
        if lower.contains("alpaca") { return .alpaca }
        return .chatML
    }
}
