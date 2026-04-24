import Foundation

/// Prompt template formats for models that require explicit chat formatting.
///
/// GGUF models loaded via llama.cpp do not apply their own chat templates,
/// so the caller must wrap messages in the format the model was trained on.
/// MLX and Foundation backends handle formatting internally and ignore these.
public enum PromptTemplate: String, CaseIterable, Sendable, Identifiable {
    case chatML = "ChatML"
    case llama3 = "Llama 3"
    case mistral = "Mistral"
    case alpaca = "Alpaca"
    case gemma = "Gemma"
    case gemma4 = "Gemma 4"
    case phi = "Phi"

    public var id: String { rawValue }

    /// Special tokens for each template format. User content containing these
    /// tokens is sanitised before interpolation to prevent prompt injection.
    private var specialTokens: [String] {
        switch self {
        case .chatML:
            return ["<|im_start|>", "<|im_end|>"]
        case .llama3:
            return ["<|begin_of_text|>", "<|start_header_id|>", "<|end_header_id|>", "<|eot_id|>"]
        case .mistral:
            return ["[INST]", "[/INST]", "</s>"]
        case .alpaca:
            return ["### Instruction:", "### Input:", "### Response:"]
        case .gemma:
            return ["<start_of_turn>", "<end_of_turn>"]
        case .gemma4:
            return ["<|turn>", "<|end_of_turn>"]
        case .phi:
            return ["<|system|>", "<|user|>", "<|assistant|>", "<|end|>"]
        }
    }

    /// Strips special tokens from user-controlled text to prevent prompt injection.
    private func sanitize(_ text: String) -> String {
        var result = text
        for token in specialTokens {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result
    }

    /// Thinking markers for this template, or nil if the template does not emit reasoning blocks.
    public var thinkingMarkers: ThinkingMarkers? {
        switch self {
        case .chatML:  return .qwen3   // Qwen3, DeepSeek-R1 use ChatML format with <think> tags
        case .gemma4:  return .gemma4  // Gemma 4 thinking fine-tunes wrap CoT in <|turn>think\n
        default:       return nil
        }
    }

    /// Formats an array of messages into a single prompt string.
    ///
    /// - Parameters:
    ///   - messages: Ordered (role, content) pairs. Roles are "user", "assistant", "system".
    ///   - systemPrompt: An optional system-level instruction prepended before messages.
    /// - Returns: A formatted prompt string ready for the model.
    public func format(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        switch self {
        case .chatML:
            return formatChatML(messages: messages, systemPrompt: systemPrompt)
        case .llama3:
            return formatLlama3(messages: messages, systemPrompt: systemPrompt)
        case .mistral:
            return formatMistral(messages: messages, systemPrompt: systemPrompt)
        case .alpaca:
            return formatAlpaca(messages: messages, systemPrompt: systemPrompt)
        case .gemma:
            return formatGemma(messages: messages, systemPrompt: systemPrompt)
        case .gemma4:
            return formatGemma4(messages: messages, systemPrompt: systemPrompt)
        case .phi:
            return formatPhi(messages: messages, systemPrompt: systemPrompt)
        }
    }

    // MARK: - ChatML

    /// ```
    /// <|im_start|>system
    /// {system}<|im_end|>
    /// <|im_start|>user
    /// {content}<|im_end|>
    /// <|im_start|>assistant
    /// ```
    private func formatChatML(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        if let systemPrompt, !systemPrompt.isEmpty {
            result += "<|im_start|>system\n\(sanitize(systemPrompt))<|im_end|>\n"
        }

        for message in messages {
            result += "<|im_start|>\(message.role)\n\(sanitize(message.content))<|im_end|>\n"
        }

        result += "<|im_start|>assistant\n"
        Log.prompt.debug("Formatted \(messages.count) messages with ChatML template")
        return result
    }

    // MARK: - Llama 3

    /// ```
    /// <|begin_of_text|><|start_header_id|>system<|end_header_id|>
    /// {system}<|eot_id|><|start_header_id|>user<|end_header_id|>
    /// {content}<|eot_id|><|start_header_id|>assistant<|end_header_id|>
    /// ```
    private func formatLlama3(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = "<|begin_of_text|>"

        if let systemPrompt, !systemPrompt.isEmpty {
            result += "<|start_header_id|>system<|end_header_id|>\n\n\(sanitize(systemPrompt))<|eot_id|>"
        }

        for message in messages {
            result += "<|start_header_id|>\(message.role)<|end_header_id|>\n\n\(sanitize(message.content))<|eot_id|>"
        }

        result += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        Log.prompt.debug("Formatted \(messages.count) messages with Llama 3 template")
        return result
    }

    // MARK: - Mistral

    /// ```
    /// [INST] {system}
    /// {content} [/INST]
    /// ```
    /// Multi-turn uses alternating `[INST]...[/INST]` and plain text.
    private func formatMistral(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        // Mistral v0.1/v0.2 style: system prompt is prepended to the first user message.
        var systemPrefix = ""
        if let systemPrompt, !systemPrompt.isEmpty {
            systemPrefix = sanitize(systemPrompt) + "\n\n"
        }

        var isFirstUser = true
        for message in messages {
            switch message.role {
            case "user":
                let content = isFirstUser ? systemPrefix + sanitize(message.content) : sanitize(message.content)
                result += "[INST] \(content) [/INST]"
                isFirstUser = false
            case "assistant":
                result += " \(sanitize(message.content))</s>"
            default:
                break  // System messages handled via systemPrefix
            }
        }

        Log.prompt.debug("Formatted \(messages.count) messages with Mistral template")
        return result
    }

    // MARK: - Alpaca

    /// ```
    /// ### Instruction:
    /// {system}
    ///
    /// ### Input:
    /// {content}
    ///
    /// ### Response:
    /// ```
    /// Only uses the last user message (Alpaca is single-turn by design).
    private func formatAlpaca(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        if let systemPrompt, !systemPrompt.isEmpty {
            result += "### Instruction:\n\(sanitize(systemPrompt))\n\n"
        } else {
            result += "### Instruction:\nYou are a helpful assistant.\n\n"
        }

        // Alpaca is single-turn; use the last user message as input.
        if let lastUser = messages.last(where: { $0.role == "user" }) {
            result += "### Input:\n\(sanitize(lastUser.content))\n\n"
        }

        result += "### Response:\n"
        Log.prompt.debug("Formatted with Alpaca template (single-turn)")
        return result
    }

    // MARK: - Gemma

    /// ```
    /// <start_of_turn>user
    /// {system}
    ///
    /// {content}<end_of_turn>
    /// <start_of_turn>model
    /// ```
    private func formatGemma(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        // Gemma prepends system prompt to first user message.
        var systemPrefix = ""
        if let systemPrompt, !systemPrompt.isEmpty {
            systemPrefix = sanitize(systemPrompt) + "\n\n"
        }

        var isFirstUser = true
        for message in messages {
            switch message.role {
            case "user":
                let content = isFirstUser ? systemPrefix + sanitize(message.content) : sanitize(message.content)
                result += "<start_of_turn>user\n\(content)<end_of_turn>\n"
                isFirstUser = false
            case "assistant":
                result += "<start_of_turn>model\n\(sanitize(message.content))<end_of_turn>\n"
            default:
                break
            }
        }

        result += "<start_of_turn>model\n"
        Log.prompt.debug("Formatted \(messages.count) messages with Gemma template")
        return result
    }

    // MARK: - Gemma 4

    /// ```
    /// <|turn>system
    /// {system}<|end_of_turn>       ← emitted only when systemPrompt is non-empty
    /// <|turn>user
    /// {content}<|end_of_turn>
    /// <|turn>model
    /// {content}<|end_of_turn>
    /// <|turn>model                 ← generation prompt (no closing delimiter)
    /// ```
    ///
    /// Unlike Gemma 1/2/3 (which prepend the system prompt to the first user turn),
    /// Gemma 4 uses an explicit `<|turn>system` turn.
    private func formatGemma4(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        if let systemPrompt, !systemPrompt.isEmpty {
            result += "<|turn>system\n\(sanitize(systemPrompt))<|end_of_turn>\n"
        }

        for message in messages {
            switch message.role {
            case "user":
                result += "<|turn>user\n\(sanitize(message.content))<|end_of_turn>\n"
            case "assistant":
                result += "<|turn>model\n\(sanitize(message.content))<|end_of_turn>\n"
            default:
                break
            }
        }

        result += "<|turn>model\n"
        Log.prompt.debug("Formatted \(messages.count) messages with Gemma 4 template")
        return result
    }

    // MARK: - Phi

    /// ```
    /// <|system|>
    /// {system}<|end|>
    /// <|user|>
    /// {content}<|end|>
    /// <|assistant|>
    /// ```
    private func formatPhi(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        if let systemPrompt, !systemPrompt.isEmpty {
            result += "<|system|>\n\(sanitize(systemPrompt))<|end|>\n"
        }

        for message in messages {
            switch message.role {
            case "user":
                result += "<|user|>\n\(sanitize(message.content))<|end|>\n"
            case "assistant":
                result += "<|assistant|>\n\(sanitize(message.content))<|end|>\n"
            case "system":
                result += "<|system|>\n\(sanitize(message.content))<|end|>\n"
            default:
                break
            }
        }

        result += "<|assistant|>\n"
        Log.prompt.debug("Formatted \(messages.count) messages with Phi template")
        return result
    }
}
