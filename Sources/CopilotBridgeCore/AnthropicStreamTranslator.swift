import Foundation

final class AnthropicStreamTranslator {
  private struct ToolState {
    var id: String
    var name: String
    var arguments: String
  }

  private let requestedModel: String
  private let maximumAccumulatedFieldBytes: Int
  private let maximumToolCalls: Int
  private let messageID = "msg_\(AnthropicCodec.shortID())"
  private var model: String
  private var nextBlockIndex = 0
  private var thinkingIndex: Int?
  private var thinkingOpen = false
  private var thinkingSignature = ""
  private var textIndex: Int?
  private var textOpen = false
  private var tools: [Int: ToolState] = [:]
  private var finishReason: String?
  private var inputTokens = 0
  private var outputTokens = 0
  private var accumulatedReasoningOpaqueBytes = 0
  private var accumulatedToolStateBytes = 0

  init(
    requestedModel: String,
    maximumAccumulatedFieldBytes: Int = 8 * 1_024 * 1_024,
    maximumToolCalls: Int = 256
  ) {
    self.requestedModel = requestedModel
    self.model = requestedModel
    self.maximumAccumulatedFieldBytes = max(1, maximumAccumulatedFieldBytes)
    self.maximumToolCalls = max(1, maximumToolCalls)
  }

  func start() -> Data {
    event(
      "message_start",
      [
        "type": "message_start",
        "message": [
          "id": messageID,
          "type": "message",
          "role": "assistant",
          "model": requestedModel,
          "content": [],
          "stop_reason": NSNull(),
          "stop_sequence": NSNull(),
          "usage": ["input_tokens": 0, "output_tokens": 0],
        ],
      ])
  }

  func consume(_ chunk: [String: Any]) throws -> Data {
    var output = Data()
    if let model = chunk["model"] as? String { self.model = model }
    if let usage = chunk["usage"] as? [String: Any] {
      inputTokens = AnthropicCodec.integer(usage["prompt_tokens"])
      outputTokens = AnthropicCodec.integer(usage["completion_tokens"])
    }
    guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return output }
    let delta = choice["delta"] as? [String: Any] ?? [:]

    if let reasoning = delta["reasoning_text"] as? String, !reasoning.isEmpty {
      if !thinkingOpen {
        closeText(into: &output)
        thinkingIndex = nextBlockIndex
        nextBlockIndex += 1
        thinkingOpen = true
        output += event(
          "content_block_start",
          [
            "type": "content_block_start",
            "index": thinkingIndex!,
            "content_block": ["type": "thinking", "thinking": "", "signature": ""],
          ])
      }
      output += event(
        "content_block_delta",
        [
          "type": "content_block_delta",
          "index": thinkingIndex!,
          "delta": ["type": "thinking_delta", "thinking": reasoning],
        ])
    }
    if let signature = delta["reasoning_opaque"] as? String, !signature.isEmpty {
      if !thinkingOpen { closeText(into: &output) }
      try appendBounded(
        signature, to: &thinkingSignature, accumulatedBytes: &accumulatedReasoningOpaqueBytes,
        field: "reasoning_opaque")
    }

    var textFragments: [String] = []
    if let content = delta["content"] as? String, !content.isEmpty {
      textFragments.append(content)
    }
    if let refusal = delta["refusal"] as? String, !refusal.isEmpty {
      textFragments.append(refusal)
    }
    for text in textFragments {
      closeThinking(into: &output)
      if !textOpen {
        textIndex = nextBlockIndex
        nextBlockIndex += 1
        textOpen = true
        output += event(
          "content_block_start",
          [
            "type": "content_block_start",
            "index": textIndex!,
            "content_block": ["type": "text", "text": ""],
          ])
      }
      output += event(
        "content_block_delta",
        [
          "type": "content_block_delta",
          "index": textIndex!,
          "delta": ["type": "text_delta", "text": text],
        ])
    }

    for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
      guard let index = AnthropicCodec.exactNonnegativeInteger(call["index"]),
        index < maximumToolCalls
      else {
        throw BridgeError.protocolFailure("Copilot 上游工具调用索引无效或超过限制。")
      }
      if tools[index] == nil, tools.count >= maximumToolCalls {
        throw BridgeError.protocolFailure("Copilot 上游工具调用数量超过限制。")
      }
      var state =
        tools.removeValue(forKey: index)
        ?? ToolState(
          id: "",
          name: "",
          arguments: ""
        )
      defer { tools[index] = state }
      if let id = call["id"] as? String {
        try assignStableBounded(id, to: &state.id, field: "tool_calls.id")
      }
      if let function = call["function"] as? [String: Any] {
        if let name = function["name"] as? String {
          try assignStableBounded(name, to: &state.name, field: "tool_calls.name")
        }
        if let arguments = function["arguments"] as? String {
          try appendBounded(
            arguments, to: &state.arguments, accumulatedBytes: &accumulatedToolStateBytes,
            field: "tool_calls.arguments")
        }
      }
    }

    if let reason = choice["finish_reason"] as? String { finishReason = reason }
    return output
  }

  func end() throws -> Data {
    var output = Data()
    guard let finishReason,
      ["stop", "length", "tool_calls", "content_filter", "refusal"].contains(finishReason)
    else {
      throw BridgeError.protocolFailure("Copilot 上游流缺少有效的结束原因。")
    }
    closeThinking(into: &output)
    closeText(into: &output)

    guard (finishReason == "tool_calls") == !tools.isEmpty else {
      throw BridgeError.protocolFailure("Copilot 返回了未完成的工具调用，已拒绝下发执行。")
    }
    for (_, state) in tools.sorted(by: { $0.key < $1.key }) {
      guard !state.id.isEmpty, !state.name.isEmpty,
        let arguments = state.arguments.data(using: .utf8),
        (try? JSONSerialization.jsonObject(with: arguments)) is [String: Any]
      else {
        throw BridgeError.protocolFailure("Copilot 返回了无效的工具调用参数，已拒绝下发执行。")
      }
      let index = nextBlockIndex
      nextBlockIndex += 1
      output += event(
        "content_block_start",
        [
          "type": "content_block_start",
          "index": index,
          "content_block": [
            "type": "tool_use",
            "id": state.id,
            "name": state.name,
            "input": [:],
          ],
        ])
      if !state.arguments.isEmpty {
        output += event(
          "content_block_delta",
          [
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "input_json_delta", "partial_json": state.arguments],
          ])
      }
      output += event("content_block_stop", ["type": "content_block_stop", "index": index])
    }

    let mappedStopReason: Any = AnthropicCodec.stopReason(finishReason) ?? NSNull()
    output += event(
      "message_delta",
      [
        "type": "message_delta",
        "delta": [
          "stop_reason": mappedStopReason,
          "stop_sequence": NSNull(),
        ],
        "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens],
      ])
    output += event("message_stop", ["type": "message_stop"])
    return output
  }

  func error(_ message: String, type: String = "api_error") -> Data {
    event("error", ["type": "error", "error": ["type": type, "message": message]])
  }

  func ping() -> Data {
    event("ping", ["type": "ping"])
  }

  private func closeThinking(into output: inout Data) {
    if thinkingOpen, let thinkingIndex {
      if !thinkingSignature.isEmpty {
        output += event(
          "content_block_delta",
          [
            "type": "content_block_delta",
            "index": thinkingIndex,
            "delta": ["type": "signature_delta", "signature": thinkingSignature],
          ])
      }
      output += event("content_block_stop", ["type": "content_block_stop", "index": thinkingIndex])
      thinkingOpen = false
      self.thinkingIndex = nil
      thinkingSignature = ""
      return
    }
    guard !thinkingSignature.isEmpty else { return }
    let index = nextBlockIndex
    nextBlockIndex += 1
    output += event(
      "content_block_start",
      [
        "type": "content_block_start",
        "index": index,
        "content_block": ["type": "redacted_thinking", "data": thinkingSignature],
      ])
    output += event("content_block_stop", ["type": "content_block_stop", "index": index])
    thinkingSignature = ""
  }

  private func closeText(into output: inout Data) {
    guard textOpen, let textIndex else { return }
    output += event("content_block_stop", ["type": "content_block_stop", "index": textIndex])
    textOpen = false
    self.textIndex = nil
  }

  private func appendBounded(
    _ fragment: String,
    to destination: inout String,
    accumulatedBytes: inout Int,
    field: String
  ) throws {
    let fragmentBytes = fragment.utf8.count
    guard fragmentBytes <= maximumAccumulatedFieldBytes - accumulatedBytes else {
      throw BridgeError.protocolFailure("Copilot 上游流的 \(field) 超过累计上限。")
    }
    accumulatedBytes += fragmentBytes
    destination += fragment
  }

  private func assignStableBounded(
    _ value: String,
    to destination: inout String,
    field: String
  ) throws {
    guard destination.isEmpty || destination == value else {
      throw BridgeError.protocolFailure("Copilot 上游流在同一工具索引上改写了 \(field)。")
    }
    guard destination.isEmpty else { return }
    try appendBounded(
      value, to: &destination, accumulatedBytes: &accumulatedToolStateBytes, field: field)
  }

  private func event(_ name: String, _ object: [String: Any]) -> Data {
    let payload =
      JSONSerialization.isValidJSONObject(object)
      ? ((try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
      : Data("{}".utf8)
    var result = Data("event: \(name)\ndata: ".utf8)
    result.append(payload)
    result.append(Data("\n\n".utf8))
    return result
  }
}

extension Data {
  fileprivate static func += (left: inout Data, right: Data) {
    left.append(right)
  }
}
