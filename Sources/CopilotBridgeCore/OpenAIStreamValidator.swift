import Foundation

struct OpenAIStreamValidator {
  enum Kind: Equatable {
    case chatCompletions
    case responses
  }

  private let kind: Kind
  private(set) var sawFailure = false
  private(set) var sawTerminal = false

  init(kind: Kind) {
    self.kind = kind
  }

  mutating func observe(_ event: SSEDecoder.Event) throws {
    guard !sawTerminal else {
      throw BridgeError.protocolFailure("Copilot 上游在终止事件后继续发送 SSE 数据。")
    }
    if event.name == "error" {
      try validateJSONIfPresent(event.data)
      sawFailure = true
      sawTerminal = true
      return
    }

    if kind == .chatCompletions, event.data == "[DONE]" {
      sawTerminal = true
      return
    }

    if event.data.isEmpty, event.name == "ping" {
      return
    }
    guard let data = event.data.data(using: .utf8) else {
      throw BridgeError.protocolFailure("Copilot 上游返回了无效的 SSE 文本。")
    }
    let object: [String: Any]
    do {
      guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BridgeError.protocolFailure("Copilot 上游 SSE data 必须是 JSON 对象。")
      }
      object = decoded
    } catch let error as BridgeError {
      throw error
    } catch {
      throw BridgeError.protocolFailure("Copilot 上游 SSE data 不是有效 JSON。")
    }
    let type = object["type"] as? String ?? event.name
    if type == "error" || object["error"] != nil {
      sawFailure = true
      sawTerminal = true
      return
    }
    guard kind == .responses else { return }
    switch type {
    case "response.completed", "response.incomplete":
      sawTerminal = true
    case "response.failed":
      sawFailure = true
      sawTerminal = true
    default:
      break
    }
  }

  func validateEndOfStream() throws {
    guard sawTerminal else {
      let protocolName = kind == .responses ? "Responses" : "Chat Completions"
      throw BridgeError.protocolFailure("Copilot 上游 \(protocolName) 流在终止事件前结束。")
    }
  }

  private func validateJSONIfPresent(_ value: String) throws {
    guard !value.isEmpty else { return }
    guard let data = value.data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil
    else {
      throw BridgeError.protocolFailure("Copilot 上游 error 事件不是有效 JSON 对象。")
    }
  }
}
