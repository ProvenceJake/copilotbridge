import Foundation

enum OpenAIModelCodec {
  private static let supportedCapabilityTypes: Set<String> = ["chat", "chat_completion"]
  private static let unavailableStates: Set<String> = [
    "blocked", "disabled", "denied", "unavailable",
  ]

  static func translate(_ source: [String: Any]) throws -> [String: Any] {
    guard let sourceModels = source["data"] as? [Any] else {
      throw BridgeError.protocolFailure("无法读取 Copilot 模型列表。")
    }

    let models = try sourceModels.compactMap { rawModel -> [String: Any]? in
      guard let model = rawModel as? [String: Any],
        let id = nonemptyString(model["id"])
      else {
        throw BridgeError.protocolFailure("Copilot 模型目录包含缺少 id 的条目。")
      }
      guard isPickerEnabled(model), supportsChat(model), !isUnavailable(model) else {
        return nil
      }

      var result = model
      result["id"] = id
      result["object"] = "model"
      result["created"] = exactNonnegativeInteger(model["created"]) ?? 0
      result["owned_by"] = owner(model)
      return result
    }

    return ["object": "list", "data": models]
  }

  private static func isPickerEnabled(_ model: [String: Any]) -> Bool {
    for key in ["model_picker_enabled", "modelPickerEnabled"] {
      if let enabled = exactBoolean(model[key]), !enabled { return false }
    }
    return true
  }

  private static func supportsChat(_ model: [String: Any]) -> Bool {
    guard let capabilities = model["capabilities"] as? [String: Any],
      let type = nonemptyString(capabilities["type"])?.lowercased()
    else {
      return true
    }
    return supportedCapabilityTypes.contains(type)
  }

  private static func isUnavailable(_ model: [String: Any]) -> Bool {
    let policy = model["policy"] as? [String: Any]
    let status = model["status"] as? [String: Any]
    let candidates: [Any?] = [
      model["policy"],
      model["status"],
      policy?["state"],
      policy?["status"],
      policy?["policy_state"],
      policy?["policyState"],
      status?["state"],
      status?["status"],
      model["policy_state"],
      model["policyState"],
      model["policy_status"],
      model["policyStatus"],
    ]
    return candidates.contains { candidate in
      guard let state = nonemptyString(candidate)?.lowercased() else { return false }
      return unavailableStates.contains(state)
    }
  }

  private static func owner(_ model: [String: Any]) -> String {
    if let vendor = nonemptyString(model["vendor"]) { return vendor }
    if let vendor = model["vendor"] as? [String: Any],
      let name = nonemptyString(vendor["name"])
    {
      return name
    }
    return nonemptyString(model["owned_by"]) ?? "github-copilot"
  }

  private static func exactNonnegativeInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
      return nil
    }
    let double = number.doubleValue
    guard double.isFinite, double >= 0, double.rounded(.towardZero) == double else { return nil }
    if CFNumberIsFloatType(number) { return Int(exactly: double) }
    guard number.compare(NSNumber(value: Int.max)) != .orderedDescending else { return nil }
    let integer = number.int64Value
    guard integer >= 0, number.compare(NSNumber(value: integer)) == .orderedSame else { return nil }
    return Int(integer)
  }

  private static func exactBoolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
      return nil
    }
    return number.boolValue
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
