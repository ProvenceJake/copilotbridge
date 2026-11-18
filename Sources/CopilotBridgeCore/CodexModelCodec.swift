import Foundation

enum CodexModelCodec {
  static func translate(_ source: [String: Any]) throws -> [String: Any] {
    guard let sourceModels = source["data"] as? [[String: Any]] else {
      throw BridgeError.protocolFailure("Copilot 模型目录缺少 data 数组。")
    }

    let eligibleModels = try sourceModels.compactMap {
      model -> (model: [String: Any], id: String)? in
      guard let id = nonemptyString(model["id"]) else {
        throw BridgeError.protocolFailure("Copilot 模型目录包含缺少 id 的条目。")
      }
      if let modelPickerEnabled = model["model_picker_enabled"] as? Bool,
        !modelPickerEnabled
      {
        return nil
      }
      let capabilities = model["capabilities"] as? [String: Any]
      if let type = nonemptyString(capabilities?["type"]), type != "chat" {
        return nil
      }
      return (model, id)
    }

    let models = eligibleModels.enumerated().map { index, candidate -> [String: Any] in
      let model = candidate.model
      let id = candidate.id

      let capabilities = model["capabilities"] as? [String: Any]
      let supports = capabilities?["supports"] as? [String: Any]
      let limits = capabilities?["limits"] as? [String: Any]
      let reasoningEfforts = reasoningEfforts(model: model, supports: supports)
      let defaultReasoningEffort = defaultReasoningEffort(
        model: model, supported: reasoningEfforts)
      let supportsVision = boolean(supports?["vision"])
      let contextWindow = positiveInteger(
        limits?["max_prompt_tokens"] ?? limits?["maxPromptTokens"]
          ?? model["max_input_tokens"] ?? limits?["max_context_window_tokens"]
          ?? limits?["maxContextWindowTokens"])

      let reasoningLevels = reasoningEfforts.map {
        ["effort": $0, "description": reasoningDescription($0)]
      }

      var result: [String: Any] = [
        "slug": id,
        "display_name": nonemptyString(model["name"]) ?? id,
        "description": "Available through this GitHub Copilot account",
        "default_reasoning_level": defaultReasoningEffort ?? NSNull(),
        "supported_reasoning_levels": reasoningLevels,
        "shell_type": "unified_exec",
        "visibility": "list",
        "supported_in_api": true,
        "priority": index + 1,
        "availability_nux": NSNull(),
        "upgrade": NSNull(),
        "base_instructions":
          "You are a coding agent. Follow the user's instructions and use the provided tools responsibly.",
        "support_verbosity": false,
        "default_verbosity": NSNull(),
        "apply_patch_tool_type": "freeform",
        "supports_reasoning_summary_parameter": false,
        "default_reasoning_summary": "none",
        "truncation_policy": ["mode": "tokens", "limit": 10_000],
        "supports_image_detail_original": false,
        "experimental_supported_tools": [],
        "input_modalities": supportsVision ? ["text", "image"] : ["text"],
      ]
      if let contextWindow {
        result["context_window"] = contextWindow
        result["max_context_window"] = contextWindow
      }
      return result
    }

    return ["models": models]
  }

  private static func positiveInteger(_ value: Any?) -> Int? {
    if value is Bool { return nil }
    let integer = AnthropicCodec.integer(value)
    return integer > 0 ? integer : nil
  }

  private static func boolean(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return false
  }

  private static func reasoningEfforts(
    model: [String: Any], supports: [String: Any]?
  ) -> [String] {
    let candidates: [Any?] = [
      model["supportedReasoningEfforts"],
      model["supported_reasoning_efforts"],
      supports?["reasoning_effort"],
      supports?["reasoningEffort"],
    ]
    for candidate in candidates {
      if let values = candidate as? [String] {
        var seen = Set<String>()
        let normalized = values.compactMap { value -> String? in
          let effort = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          guard !effort.isEmpty, seen.insert(effort).inserted else { return nil }
          return effort
        }
        if !normalized.isEmpty { return normalized }
      }
    }

    let supportsReasoning = candidates.contains { boolean($0) }
    return supportsReasoning ? ["low", "medium", "high"] : []
  }

  private static func defaultReasoningEffort(
    model: [String: Any], supported: [String]
  ) -> String? {
    guard !supported.isEmpty else { return nil }
    let preferred = nonemptyString(
      model["defaultReasoningEffort"] ?? model["default_reasoning_effort"]
    )?.lowercased()
    if let preferred, supported.contains(preferred) { return preferred }
    if supported.contains("medium") { return "medium" }
    return supported[0]
  }

  private static func reasoningDescription(_ effort: String) -> String {
    switch effort {
    case "none": return "No additional reasoning"
    case "minimal": return "Minimal reasoning for the fastest responses"
    case "low": return "Faster responses with lighter reasoning"
    case "medium": return "Balanced speed and reasoning depth"
    case "high": return "Greater reasoning depth for complex tasks"
    case "xhigh": return "Extended reasoning for demanding tasks"
    case "max": return "Maximum available reasoning depth"
    case "ultra": return "Ultra reasoning depth"
    case "persistent": return "Persistent reasoning mode"
    default: return "Model-defined reasoning level"
    }
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    guard let value = value as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return value
  }
}
