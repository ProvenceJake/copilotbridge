import Foundation

/// Validates an Anthropic Messages SSE stream without rewriting its frames.
/// Callers can forward the original frame bytes when this returns `.forward`.
struct AnthropicNativeStreamValidator {
  enum Action: Equatable {
    case forward
    case discard
  }

  private static let knownEventTypes: Set<String> = [
    "message_start",
    "content_block_start",
    "content_block_delta",
    "content_block_stop",
    "message_delta",
    "message_stop",
    "ping",
    "error",
  ]

  private(set) var sawFailure = false
  private(set) var sawTerminal = false

  /// `nil` represents a comment or an empty SSE frame. These keep-alives are
  /// intentionally passed through, including after the terminal event.
  @discardableResult
  mutating func observe(_ event: SSEDecoder.Event?) throws -> Action {
    guard let event else { return .forward }

    // Copilot can append the OpenAI sentinel to an otherwise native Anthropic
    // stream. It is transport noise here and must never replace message_stop.
    if event.data == "[DONE]" { return .discard }

    // Some proxies emit an empty named ping instead of Anthropic's JSON ping.
    if event.name == "ping", event.data.isEmpty { return .forward }

    let object = try decodeObject(event.data)
    let payloadType = try eventType(in: object)
    try validateEventName(event.name, matches: payloadType)

    let semanticType = payloadType ?? event.name
    if semanticType == "ping" { return .forward }

    guard !sawTerminal else {
      throw BridgeError.protocolFailure(
        "Copilot 上游在 Anthropic 终止事件后继续发送 SSE 业务数据。")
    }

    if semanticType == "error" || object["error"] != nil {
      sawFailure = true
      sawTerminal = true
    } else if semanticType == "message_stop" {
      sawTerminal = true
    }
    return .forward
  }

  func validateEndOfStream() throws {
    guard sawTerminal else {
      throw BridgeError.protocolFailure(
        "Copilot 上游 Anthropic Messages 流在 message_stop 或 error 事件前结束。")
    }
  }

  private func decodeObject(_ value: String) throws -> [String: Any] {
    guard !value.isEmpty, let data = value.data(using: .utf8) else {
      throw BridgeError.protocolFailure("Copilot 上游 Anthropic SSE data 不是有效 JSON 对象。")
    }
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BridgeError.protocolFailure(
          "Copilot 上游 Anthropic SSE data 必须是 JSON 对象。")
      }
      return object
    } catch let error as BridgeError {
      throw error
    } catch {
      throw BridgeError.protocolFailure("Copilot 上游 Anthropic SSE data 不是有效 JSON。")
    }
  }

  private func eventType(in object: [String: Any]) throws -> String? {
    guard let value = object["type"] else { return nil }
    guard let type = value as? String, !type.isEmpty else {
      throw BridgeError.protocolFailure("Copilot 上游 Anthropic SSE type 必须是非空字符串。")
    }
    return type
  }

  private func validateEventName(_ name: String?, matches payloadType: String?) throws {
    guard let name, Self.knownEventTypes.contains(name), let payloadType,
      name != payloadType
    else { return }
    throw BridgeError.protocolFailure(
      "Copilot 上游 Anthropic SSE event 与 data.type 不匹配。")
  }
}
