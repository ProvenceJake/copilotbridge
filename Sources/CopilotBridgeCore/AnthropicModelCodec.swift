import Foundation

enum AnthropicModelCodec {
  private static let blockedPolicyStates: Set<String> = [
    "blocked", "denied", "disabled", "unavailable",
  ]

  static func translate(_ source: [String: Any]) throws -> [String: Any] {
    guard let sourceModels = source["data"] as? [[String: Any]] else {
      throw BridgeError.protocolFailure("Copilot 模型目录缺少 data 数组。")
    }

    let formatter = ISO8601DateFormatter()
    let models = try sourceModels.compactMap { model -> [String: Any]? in
      guard let id = nonemptyString(model["id"]) else {
        throw BridgeError.protocolFailure("Copilot 模型目录包含缺少 id 的条目。")
      }

      let capabilities = model["capabilities"] as? [String: Any]
      let modelPickerEnabled = boolean(
        firstValue(
          in: model,
          keys: ["model_picker_enabled", "modelPickerEnabled", "picker_enabled", "pickerEnabled"]))
      guard modelPickerEnabled != false else { return nil }

      let modelType =
        nonemptyString(
          firstValue(in: capabilities, keys: ["type", "model_type", "modelType"]))
        ?? nonemptyString(firstValue(in: model, keys: ["type", "model_type", "modelType"]))
      if let modelType,
        !["chat", "chat_completion"].contains(modelType.lowercased())
      {
        return nil
      }

      if let policyState = policyState(model), blockedPolicyStates.contains(policyState) {
        return nil
      }

      let limits = capabilities?["limits"] as? [String: Any]
      let maxInputTokens = positiveInteger(
        firstValue(
          in: limits,
          keys: ["max_prompt_tokens", "maxPromptTokens", "max_input_tokens", "maxInputTokens"])
          ?? firstValue(in: model, keys: ["max_input_tokens", "maxInputTokens"]))
      let maxOutputTokens = positiveInteger(
        firstValue(
          in: limits,
          keys: [
            "max_output_tokens", "maxOutputTokens", "maximum_output_tokens",
            "maximumOutputTokens",
          ])
          ?? firstValue(
            in: model,
            keys: [
              "max_output_tokens", "maxOutputTokens", "maximum_output_tokens",
              "maximumOutputTokens", "max_tokens", "maxTokens",
            ]))

      var result: [String: Any] = [
        "id": id,
        "type": "model",
        "display_name": nonemptyString(model["name"]) ?? id,
        "created_at": createdAt(model, formatter: formatter),
        "capabilities": NSNull(),
        "max_input_tokens": maxInputTokens ?? NSNull(),
        "max_tokens": maxOutputTokens ?? NSNull(),
        "is_family_default": false,
        "description": "Available through this GitHub Copilot account",
      ]

      if let familyTier = familyTier(for: id) {
        result["anthropic_family_tier"] = familyTier
      }
      return result
    }

    return [
      "data": models,
      "first_id": models.first?["id"] ?? NSNull(),
      "last_id": models.last?["id"] ?? NSNull(),
      "has_more": false,
    ]
  }

  private static func createdAt(_ model: [String: Any], formatter: ISO8601DateFormatter) -> String {
    if let value = nonemptyString(model["created_at"]),
      let date = formatter.date(from: value)
    {
      return formatter.string(from: date)
    }
    let created = positiveInteger(model["created"])
    guard let created else { return "1970-01-01T00:00:00Z" }
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(created)))
  }

  private static func positiveInteger(_ value: Any?) -> Int? {
    AnthropicCodec.exactPositiveInteger(value)
  }

  private static func policyState(_ model: [String: Any]) -> String? {
    let policy = model["policy"] as? [String: Any]
    let candidates: [Any?] = [
      firstValue(in: policy, keys: ["state", "policy_state", "policyState", "status"]),
      firstValue(
        in: model,
        keys: ["policy_state", "policyState", "policy_status", "policyStatus"]),
      model["policy"] as? String,
    ]
    for candidate in candidates {
      if let state = nonemptyString(candidate) { return state.lowercased() }
    }
    return nil
  }

  private static func firstValue(in dictionary: [String: Any]?, keys: [String]) -> Any? {
    guard let dictionary else { return nil }
    for key in keys where dictionary[key] != nil {
      return dictionary[key]
    }
    return nil
  }

  private static func boolean(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? String {
      switch value.lowercased() {
      case "true", "yes", "1": return true
      case "false", "no", "0": return false
      default: return nil
      }
    }
    return nil
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func familyTier(for id: String) -> String? {
    let lowercasedID = id.lowercased()
    if lowercasedID.contains("sonnet") { return "sonnet" }
    if lowercasedID.contains("opus") { return "opus" }
    if lowercasedID.contains("haiku") { return "haiku" }
    return nil
  }
}
