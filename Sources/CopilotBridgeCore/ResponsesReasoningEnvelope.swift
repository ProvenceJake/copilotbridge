import Foundation

/// Bridge-owned opaque state, not an Anthropic signature. Never decrypt or log its contents.
/// A client that echoes this redacted_thinking block lets stateless Responses retain reasoning.
enum ResponsesReasoningEnvelope {
  static let prefix = "copilotbridge.responses.reasoning.v1:"
  static let maximumBytes = 8 * 1_024 * 1_024

  static func validate(_ item: [String: Any], allowedStatuses: Set<String>) throws {
    guard item["type"] as? String == "reasoning",
      let id = item["id"] as? String, !id.isEmpty
    else {
      throw BridgeError.protocolFailure("Responses reasoning type/id 无效。")
    }
    if let status = item["status"], !(status is NSNull) {
      guard let status = status as? String, allowedStatuses.contains(status) else {
        throw BridgeError.protocolFailure("Responses reasoning.status 无效。")
      }
    }
    for key in ["summary", "content"] {
      if let value = item[key], !(value is NSNull) {
        guard let parts = value as? [Any], parts.isEmpty else {
          throw BridgeError.protocolFailure("Responses reasoning.\(key) 非空，暂不支持转换。")
        }
      }
    }
    if let value = item["encrypted_content"], !(value is NSNull), !(value is String) {
      throw BridgeError.protocolFailure("Responses reasoning.encrypted_content 必须是字符串。")
    }
  }

  static func encode(_ item: [String: Any]) throws -> String? {
    try validate(item, allowedStatuses: ["completed", "incomplete"])
    guard let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty else {
      return nil
    }
    guard encrypted.utf8.count <= maximumBytes else {
      throw BridgeError.protocolFailure("Responses reasoning 超过字节上限。")
    }
    // Only replay Responses input fields. Optional output status is not required for reasoning.
    let payload: [String: Any] = [
      "id": item["id"]!, "type": "reasoning", "summary": [], "encrypted_content": encrypted,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    guard data.count <= maximumBytes else {
      throw BridgeError.protocolFailure("Responses reasoning 超过字节上限。")
    }
    return prefix + data.base64EncodedString()
  }

  static func decode(_ value: String) throws -> [String: Any]? {
    guard value.hasPrefix(prefix) else { return nil }
    let encoded = value.dropFirst(prefix.count)
    guard encoded.utf8.count <= (maximumBytes + 2) / 3 * 4,
      let data = Data(base64Encoded: String(encoded)), data.count <= maximumBytes,
      let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      Set(item.keys) == ["id", "type", "summary", "encrypted_content"],
      let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty
    else {
      throw BridgeError.invalidRequest("CopilotBridge Responses 推理状态无效。")
    }
    do {
      try validate(item, allowedStatuses: [])
    } catch {
      throw BridgeError.invalidRequest("CopilotBridge Responses 推理状态无效。")
    }
    return item
  }
}
