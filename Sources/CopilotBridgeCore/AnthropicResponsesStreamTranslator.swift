import CryptoKit
import Foundation

/// Incrementally translates OpenAI Responses SSE events into Anthropic Messages SSE events.
///
/// The translator is intentionally stateful and fail-closed. Feed one decoded JSON object per
/// Responses SSE event to `consume(eventName:object:)`, then call `finish()` at transport EOF.
/// A new instance is required for every upstream response stream.
final class AnthropicResponsesStreamTranslator {
  private enum Lifecycle {
    case waitingForResponse
    case active
    case terminal
  }

  private enum ContentKind: String {
    case outputText = "output_text"
    case refusal
  }

  private struct ContentPartState {
    let kind: ContentKind
    let blockIndex: Int
    var value = ""
    var digest: IncrementalFieldDigest? = IncrementalFieldDigest()
    var finalSummary: FieldSummary?
    var valueDone = false
    var partDone = false
  }

  private struct MessageState {
    var phase: String?
    var nextContentIndex = 0
    var parts: [Int: ContentPartState] = [:]
    var done = false
    var finalStatus: String?
  }

  private struct FunctionCallState {
    let callID: String
    let name: String
    let blockIndex: Int
    var arguments = ""
    var argumentsDigest: IncrementalFieldDigest? = IncrementalFieldDigest()
    var finalArgumentsSummary: FieldSummary?
    var argumentsDone = false
    var done = false
  }

  /// A deterministic, fixed-size summary of an incrementally received UTF-8 field.
  ///
  /// Swift's `Hashable` intentionally uses a per-process random seed, so it cannot be used to
  /// verify the repeated final Responses object. SHA-256 keeps this state bounded and does not
  /// retain the original text after `value`/`arguments` is released.
  private struct FieldSummary {
    let byteCount: Int
    let digest: Data

    func matches(_ value: String) -> Bool {
      let data = Data(value.utf8)
      guard data.count == byteCount else { return false }
      var candidate = SHA256()
      candidate.update(data: data)
      return digest == Data(candidate.finalize())
    }
  }

  private struct IncrementalFieldDigest {
    private var byteCount = 0
    private var hasher = SHA256()

    mutating func append(_ fragment: String) {
      let data = Data(fragment.utf8)
      byteCount += data.count
      hasher.update(data: data)
    }

    func finalized() -> FieldSummary {
      let actual = hasher
      return FieldSummary(byteCount: byteCount, digest: Data(actual.finalize()))
    }
  }

  private struct ReasoningState {
    var done = false
    var finalStatus: String?
  }

  private enum ItemState {
    case message(MessageState)
    case functionCall(FunctionCallState)
    case reasoning(ReasoningState)

    var type: String {
      switch self {
      case .message: return "message"
      case .functionCall: return "function_call"
      case .reasoning: return "reasoning"
      }
    }

    var isDone: Bool {
      switch self {
      case .message(let state): return state.done
      case .functionCall(let state): return state.done
      case .reasoning(let state): return state.done
      }
    }

    var finalStatus: String? {
      switch self {
      case .message(let state): return state.finalStatus
      case .functionCall(let state): return state.done ? "completed" : nil
      case .reasoning(let state): return state.finalStatus
      }
    }
  }

  private struct Usage {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    var anthropicObject: [String: Any] {
      var result: [String: Any] = [
        "input_tokens": inputTokens,
        "output_tokens": outputTokens,
      ]
      if let cacheReadInputTokens {
        result["cache_read_input_tokens"] = cacheReadInputTokens
      }
      if let cacheCreationInputTokens {
        result["cache_creation_input_tokens"] = cacheCreationInputTokens
      }
      return result
    }
  }

  private let requestedModel: String
  private let maximumAccumulatedFieldBytes: Int
  private let maximumOutputItems: Int
  private let maximumContentPartsPerMessage: Int

  private var lifecycle = Lifecycle.waitingForResponse
  private var responseID: String?
  private var responseModel: String?
  private var lastSequenceNumber: Int?
  private var sawInProgress = false
  private var nextOutputIndex = 0
  private var nextBlockIndex = 0
  private var items: [Int: ItemState] = [:]
  private var accumulatedFieldBytes = 0
  private var sawFunctionCall = false
  private var sawRefusal = false

  private(set) var sawFailure = false
  private(set) var sawTerminal = false

  init(
    requestedModel: String,
    maximumAccumulatedFieldBytes: Int = 8 * 1_024 * 1_024,
    maximumOutputItems: Int = 256,
    maximumContentPartsPerMessage: Int = 256
  ) {
    self.requestedModel = requestedModel
    self.maximumAccumulatedFieldBytes = max(1, maximumAccumulatedFieldBytes)
    self.maximumOutputItems = max(1, maximumOutputItems)
    self.maximumContentPartsPerMessage = max(1, maximumContentPartsPerMessage)
  }

  /// Consumes one parsed Responses SSE event and returns zero or more Anthropic SSE frames.
  func consume(eventName: String?, object: [String: Any]) throws -> Data {
    guard lifecycle != .terminal else {
      throw protocolFailure("Copilot Responses 流在终止事件后继续发送业务数据。")
    }

    let type = try requiredNonemptyString(object["type"], field: "event.type")
    if let eventName, !eventName.isEmpty, eventName != type {
      throw protocolFailure("Copilot Responses SSE event 与 data.type 不匹配。")
    }
    try observeSequenceNumber(object["sequence_number"], eventType: type)

    switch type {
    case "response.created":
      return try consumeResponseCreated(object)
    case "response.in_progress":
      return try consumeResponseInProgress(object)
    case "response.output_item.added":
      return try consumeOutputItemAdded(object)
    case "response.output_item.done":
      return try consumeOutputItemDone(object)
    case "response.content_part.added":
      return try consumeContentPartAdded(object)
    case "response.content_part.done":
      return try consumeContentPartDone(object)
    case "response.output_text.delta":
      return try consumeTextDelta(object, expectedKind: .outputText)
    case "response.output_text.done":
      return try consumeTextDone(object, expectedKind: .outputText)
    case "response.refusal.delta":
      return try consumeTextDelta(object, expectedKind: .refusal)
    case "response.refusal.done":
      return try consumeTextDone(object, expectedKind: .refusal)
    case "response.function_call_arguments.delta":
      return try consumeFunctionArgumentsDelta(object)
    case "response.function_call_arguments.done":
      return try consumeFunctionArgumentsDone(object)
    case "response.completed":
      return try consumeSuccessfulTerminal(object, status: "completed")
    case "response.incomplete":
      return try consumeSuccessfulTerminal(object, status: "incomplete")
    case "response.failed":
      return try consumeResponseFailed(object)
    case "error":
      return try consumeError(object)
    default:
      throw protocolFailure("Copilot Responses 流包含无法转换的事件：\(type)。")
    }
  }

  /// Validates that the transport ended only after a Responses terminal event.
  func finish() throws {
    guard sawTerminal, lifecycle == .terminal else {
      throw protocolFailure("Copilot Responses 流在 completed、incomplete、failed 或 error 前结束。")
    }
  }

  func error(_ message: String, type: String = "api_error") -> Data {
    (try? Self.event("error", ["error": ["message": message, "type": type], "type": "error"]))
      ?? Data()
  }

  func ping() -> Data {
    (try? Self.event("ping", ["type": "ping"])) ?? Data()
  }

  private func consumeResponseCreated(_ event: [String: Any]) throws -> Data {
    guard lifecycle == .waitingForResponse, responseID == nil else {
      throw protocolFailure("Copilot Responses 流重复发送 response.created。")
    }
    let response = try responseObject(in: event)
    guard response["object"] as? String == "response",
      response["status"] as? String == "in_progress"
    else {
      throw protocolFailure("response.created 包含无效的 Responses 对象。")
    }
    try requireNullIfPresent(response["error"], field: "response.error")
    try requireNullIfPresent(response["incomplete_details"], field: "response.incomplete_details")
    try requireEmptyOutputIfPresent(response["output"], field: "response.output")
    try requireNullIfPresent(response["usage"], field: "response.usage")

    let id = try requiredNonemptyString(response["id"], field: "response.id")
    let model = try requiredNonemptyString(response["model"], field: "response.model")
    try reserve(id.utf8.count, field: "response.id")
    try reserve(model.utf8.count, field: "response.model")
    responseID = id
    responseModel = model
    lifecycle = .active

    let messageID = id.hasPrefix("msg_") ? id : "msg_\(id)"
    return try Self.event(
      "message_start",
      [
        "message": [
          "content": [],
          "id": messageID,
          "model": model,
          "role": "assistant",
          "stop_reason": NSNull(),
          "stop_sequence": NSNull(),
          "type": "message",
          "usage": ["input_tokens": 0, "output_tokens": 0],
        ],
        "type": "message_start",
      ])
  }

  private func consumeResponseInProgress(_ event: [String: Any]) throws -> Data {
    try requireActive("response.in_progress")
    guard !sawInProgress, items.isEmpty else {
      throw protocolFailure("response.in_progress 重复或出现在 output item 之后。")
    }
    let response = try responseObject(in: event)
    try validateResponseSnapshot(response, expectedStatus: "in_progress")
    try requireNullIfPresent(response["error"], field: "response.error")
    try requireNullIfPresent(response["incomplete_details"], field: "response.incomplete_details")
    try requireEmptyOutputIfPresent(response["output"], field: "response.output")
    try requireNullIfPresent(response["usage"], field: "response.usage")
    sawInProgress = true
    return Data()
  }

  private func consumeOutputItemAdded(_ event: [String: Any]) throws -> Data {
    try requireActive("response.output_item.added")
    let outputIndex = try outputIndex(in: event)
    guard outputIndex == nextOutputIndex, outputIndex < maximumOutputItems,
      items[outputIndex] == nil
    else {
      throw protocolFailure("Responses output_item.added 的 output_index 不连续或超过限制。")
    }
    guard let item = event["item"] as? [String: Any] else {
      throw protocolFailure("Responses output_item.added 缺少 item 对象。")
    }
    let type = try requiredNonemptyString(item["type"], field: "item.type")
    _ = try requiredNonemptyString(item["id"], field: "item.id")

    let state: ItemState
    var output = Data()
    switch type {
    case "message":
      guard item["status"] as? String == "in_progress",
        item["role"] as? String == "assistant"
      else {
        throw protocolFailure("Responses message item 必须以 assistant/in_progress 状态开始。")
      }
      try requireEmptyArray(item["content"], field: "message.content")
      let phase = try validatedPhase(item["phase"], field: "message.phase")
      state = .message(MessageState(phase: phase))
    case "function_call":
      guard item["status"] as? String == "in_progress" else {
        throw protocolFailure("Responses function_call item 必须以 in_progress 状态开始。")
      }
      let callID = try requiredNonemptyString(item["call_id"], field: "function_call.call_id")
      let name = try requiredNonemptyString(item["name"], field: "function_call.name")
      let arguments = try requiredString(item["arguments"], field: "function_call.arguments")
      guard arguments.isEmpty else {
        throw protocolFailure("Responses function_call 必须在空 arguments 上开始增量流。")
      }
      try rejectUnsupportedFunctionMetadata(item)
      try reserve(callID.utf8.count, field: "function_call.call_id")
      try reserve(name.utf8.count, field: "function_call.name")
      let blockIndex = nextBlockIndex
      nextBlockIndex += 1
      state = .functionCall(
        FunctionCallState(callID: callID, name: name, blockIndex: blockIndex))
      sawFunctionCall = true
      output = try Self.event(
        "content_block_start",
        [
          "content_block": [
            "id": callID,
            "input": [:],
            "name": name,
            "type": "tool_use",
          ],
          "index": blockIndex,
          "type": "content_block_start",
        ])
    case "reasoning":
      try validateReasoning(item, allowedStatuses: ["in_progress"], field: "reasoning")
      state = .reasoning(ReasoningState())
    default:
      throw protocolFailure("Responses output item \(type) 无法无损转换。")
    }

    items[outputIndex] = state
    nextOutputIndex += 1
    return output
  }

  private func consumeContentPartAdded(_ event: [String: Any]) throws -> Data {
    try requireActive("response.content_part.added")
    let (outputIndex, contentIndex) = try contentCoordinates(in: event)
    guard case .message(var message) = try item(at: outputIndex),
      !message.done,
      contentIndex == message.nextContentIndex,
      contentIndex < maximumContentPartsPerMessage
    else {
      throw protocolFailure("Responses content_part.added 的 item 或 content_index 无效。")
    }
    guard let part = event["part"] as? [String: Any] else {
      throw protocolFailure("Responses content_part.added 缺少 part 对象。")
    }
    let kind = try contentKind(in: part)
    try validatePart(part, kind: kind, expectedValue: "", field: "part")

    let blockIndex = nextBlockIndex
    nextBlockIndex += 1
    message.parts[contentIndex] = ContentPartState(kind: kind, blockIndex: blockIndex)
    message.nextContentIndex += 1
    items[outputIndex] = .message(message)
    if kind == .refusal { sawRefusal = true }

    return try Self.event(
      "content_block_start",
      [
        "content_block": ["text": "", "type": "text"],
        "index": blockIndex,
        "type": "content_block_start",
      ])
  }

  private func consumeTextDelta(_ event: [String: Any], expectedKind: ContentKind) throws
    -> Data
  {
    try requireActive(event["type"] as? String ?? "text delta")
    let (outputIndex, contentIndex) = try contentCoordinates(in: event)
    guard case .message(var message) = try item(at: outputIndex),
      var part = message.parts[contentIndex], part.kind == expectedKind,
      !part.valueDone, !part.partDone
    else {
      throw protocolFailure("Responses 文本 delta 没有对应的开放 content part。")
    }
    if expectedKind == .outputText {
      try requireEmptyArrayIfPresent(event["logprobs"], field: "output_text.delta.logprobs")
    }
    let fragment = try requiredString(event["delta"], field: "event.delta")
    try appendBounded(fragment, to: &part.value, field: "content delta")
    guard var digest = part.digest else {
      throw protocolFailure("Responses 文本 delta 出现在内容摘要完成之后。")
    }
    digest.append(fragment)
    part.digest = digest
    message.parts[contentIndex] = part
    items[outputIndex] = .message(message)

    return try Self.event(
      "content_block_delta",
      [
        "delta": ["text": fragment, "type": "text_delta"],
        "index": part.blockIndex,
        "type": "content_block_delta",
      ])
  }

  private func consumeTextDone(_ event: [String: Any], expectedKind: ContentKind) throws
    -> Data
  {
    try requireActive(event["type"] as? String ?? "text done")
    let (outputIndex, contentIndex) = try contentCoordinates(in: event)
    guard case .message(var message) = try item(at: outputIndex),
      var part = message.parts[contentIndex], part.kind == expectedKind,
      !part.valueDone, !part.partDone
    else {
      throw protocolFailure("Responses 文本 done 没有对应的开放 content part。")
    }
    if expectedKind == .outputText {
      try requireEmptyArrayIfPresent(event["logprobs"], field: "output_text.done.logprobs")
    }
    let field = expectedKind == .outputText ? "text" : "refusal"
    let finalValue = try requiredString(event[field], field: "event.\(field)")
    guard finalValue == part.value else {
      throw protocolFailure("Responses \(field) done 与已接收的 delta 不一致。")
    }
    part.valueDone = true
    message.parts[contentIndex] = part
    items[outputIndex] = .message(message)
    return Data()
  }

  private func consumeContentPartDone(_ event: [String: Any]) throws -> Data {
    try requireActive("response.content_part.done")
    let (outputIndex, contentIndex) = try contentCoordinates(in: event)
    guard case .message(var message) = try item(at: outputIndex),
      var part = message.parts[contentIndex], part.valueDone, !part.partDone
    else {
      throw protocolFailure("Responses content_part.done 的事件顺序或坐标无效。")
    }
    guard let finalPart = event["part"] as? [String: Any] else {
      throw protocolFailure("Responses content_part.done 缺少 part 对象。")
    }
    try validatePart(finalPart, kind: part.kind, expectedValue: part.value, field: "part")
    part.partDone = true
    message.parts[contentIndex] = part
    items[outputIndex] = .message(message)
    return try Self.event(
      "content_block_stop", ["index": part.blockIndex, "type": "content_block_stop"])
  }

  private func consumeFunctionArgumentsDelta(_ event: [String: Any]) throws -> Data {
    try requireActive("response.function_call_arguments.delta")
    let outputIndex = try outputIndex(in: event)
    _ = try requiredNonemptyString(event["item_id"], field: "event.item_id")
    guard case .functionCall(var function) = try item(at: outputIndex),
      !function.argumentsDone, !function.done
    else {
      throw protocolFailure("Responses function arguments delta 没有对应的开放 function_call。")
    }
    let fragment = try requiredString(event["delta"], field: "event.delta")
    try appendBounded(fragment, to: &function.arguments, field: "function arguments")
    guard var digest = function.argumentsDigest else {
      throw protocolFailure("Responses function arguments delta 出现在参数摘要完成之后。")
    }
    digest.append(fragment)
    function.argumentsDigest = digest
    items[outputIndex] = .functionCall(function)
    return try Self.event(
      "content_block_delta",
      [
        "delta": ["partial_json": fragment, "type": "input_json_delta"],
        "index": function.blockIndex,
        "type": "content_block_delta",
      ])
  }

  private func consumeFunctionArgumentsDone(_ event: [String: Any]) throws -> Data {
    try requireActive("response.function_call_arguments.done")
    let outputIndex = try outputIndex(in: event)
    _ = try requiredNonemptyString(event["item_id"], field: "event.item_id")
    guard case .functionCall(var function) = try item(at: outputIndex),
      !function.argumentsDone, !function.done
    else {
      throw protocolFailure("Responses function arguments done 没有对应的 function_call。")
    }
    let arguments = try requiredString(event["arguments"], field: "event.arguments")
    if let rawName = nonNull(event["name"]),
      try requiredNonemptyString(rawName, field: "event.name") != function.name
    {
      throw protocolFailure("Responses function arguments done 改写了函数名。")
    }
    guard arguments == function.arguments, try Self.isJSONObject(arguments) else {
      throw protocolFailure("Responses function arguments 终值与 delta 不一致或不是 JSON 对象。")
    }
    function.argumentsDone = true
    items[outputIndex] = .functionCall(function)
    return Data()
  }

  private func consumeOutputItemDone(_ event: [String: Any]) throws -> Data {
    try requireActive("response.output_item.done")
    let outputIndex = try outputIndex(in: event)
    guard let finalItem = event["item"] as? [String: Any] else {
      throw protocolFailure("Responses output_item.done 缺少 item 对象。")
    }
    _ = try requiredNonemptyString(finalItem["id"], field: "item.id")
    var state = try item(at: outputIndex)
    guard !state.isDone, finalItem["type"] as? String == state.type else {
      throw protocolFailure("Responses output_item.done 重复或改写了 item 类型。")
    }

    var output = Data()
    switch state {
    case .message(var message):
      let status = try completedItemStatus(finalItem["status"], allowIncomplete: true)
      guard message.parts.values.allSatisfy({ $0.partDone }) else {
        throw protocolFailure("Responses message item 在 content part 完成前结束。")
      }
      try validateFinalMessage(finalItem, state: message)
      if let phase = try validatedPhase(finalItem["phase"], field: "message.phase") {
        if let original = message.phase, original != phase {
          throw protocolFailure("Responses message.phase 在流中被改写。")
        }
        message.phase = phase
      }
      for part in message.parts.values {
        release(part.value.utf8.count)
      }
      message.parts = message.parts.mapValues { part in
        var released = part
        released.finalSummary = released.digest?.finalized()
        released.digest = nil
        released.value = ""
        return released
      }
      message.done = true
      message.finalStatus = status
      state = .message(message)
    case .functionCall(var function):
      _ = try completedItemStatus(finalItem["status"], allowIncomplete: false)
      guard function.argumentsDone else {
        throw protocolFailure("Responses function_call 在 arguments.done 前结束。")
      }
      try validateFinalFunctionCall(finalItem, state: function)
      release(function.arguments.utf8.count)
      function.finalArgumentsSummary = function.argumentsDigest?.finalized()
      function.argumentsDigest = nil
      function.arguments = ""
      function.done = true
      output = try Self.event(
        "content_block_stop",
        ["index": function.blockIndex, "type": "content_block_stop"])
      state = .functionCall(function)
    case .reasoning(var reasoning):
      let status: String?
      if nonNull(finalItem["status"]) != nil {
        status = try completedItemStatus(finalItem["status"], allowIncomplete: true)
      } else {
        status = nil
      }
      try validateReasoning(
        finalItem, allowedStatuses: ["completed", "incomplete"], field: "reasoning")
      if let data = try ResponsesReasoningEnvelope.encode(finalItem) {
        try reserve(data.utf8.count, field: "reasoning state")
        defer { release(data.utf8.count) }
        let blockIndex = nextBlockIndex
        nextBlockIndex += 1
        output = try Self.event(
          "content_block_start",
          [
            "content_block": ["type": "redacted_thinking", "data": data],
            "index": blockIndex, "type": "content_block_start",
          ])
        output.append(
          try Self.event("content_block_stop", ["index": blockIndex, "type": "content_block_stop"]))
      }
      reasoning.done = true
      reasoning.finalStatus = status
      state = .reasoning(reasoning)
    }

    items[outputIndex] = state
    return output
  }

  private func consumeSuccessfulTerminal(_ event: [String: Any], status: String) throws -> Data {
    try requireActive("response.\(status)")
    guard items.values.allSatisfy(\.isDone) else {
      throw protocolFailure("Responses 终态事件出现在 output item 完成前。")
    }
    let response = try responseObject(in: event)
    try validateResponseSnapshot(response, expectedStatus: status)
    try requireNullIfPresent(response["error"], field: "response.error")
    guard let output = response["output"] as? [[String: Any]], output.count == items.count else {
      throw protocolFailure("Responses 终态对象的 output 与流事件数量不一致。")
    }
    try validateTerminalOutput(output, overallStatus: status)
    let usage = try translatedUsage(response["usage"])

    let stopReason: String
    if sawFunctionCall {
      stopReason = "tool_use"
    } else if status == "incomplete" {
      stopReason = try incompleteStopReason(response["incomplete_details"])
    } else if sawRefusal {
      try requireNullIfPresent(
        response["incomplete_details"], field: "response.incomplete_details")
      stopReason = "refusal"
    } else {
      try requireNullIfPresent(
        response["incomplete_details"], field: "response.incomplete_details")
      stopReason = "end_turn"
    }
    if status == "completed" {
      try requireNullIfPresent(
        response["incomplete_details"], field: "response.incomplete_details")
    } else if sawFunctionCall {
      _ = try incompleteStopReason(response["incomplete_details"])
    }

    lifecycle = .terminal
    sawTerminal = true
    var result = try Self.event(
      "message_delta",
      [
        "delta": ["stop_reason": stopReason, "stop_sequence": NSNull()],
        "type": "message_delta",
        "usage": usage.anthropicObject,
      ])
    result.append(try Self.event("message_stop", ["type": "message_stop"]))
    return result
  }

  private func consumeResponseFailed(_ event: [String: Any]) throws -> Data {
    try requireActive("response.failed")
    let response = try responseObject(in: event)
    try validateResponseSnapshot(response, expectedStatus: "failed")
    let failure = try failureDetails(response["error"], field: "response.error")
    lifecycle = .terminal
    sawFailure = true
    sawTerminal = true
    return error(failure.message, type: failure.type)
  }

  private func consumeError(_ event: [String: Any]) throws -> Data {
    guard lifecycle == .waitingForResponse || lifecycle == .active else {
      throw protocolFailure("Responses error 出现在终止事件后。")
    }
    let message = try requiredNonemptyString(event["message"], field: "error.message")
    let type: String
    if let rawCode = nonNull(event["code"]) {
      type = anthropicErrorType(
        try requiredNonemptyString(rawCode, field: "error.code"))
    } else {
      type = "api_error"
    }
    if let param = nonNull(event["param"]), !(param is String) {
      throw protocolFailure("Responses error.param 必须是字符串或 null。")
    }
    lifecycle = .terminal
    sawFailure = true
    sawTerminal = true
    return error(message, type: type)
  }

  private func validateFinalMessage(_ item: [String: Any], state: MessageState) throws {
    guard item["role"] as? String == "assistant",
      let content = item["content"] as? [[String: Any]],
      content.count == state.parts.count
    else {
      throw protocolFailure("Responses message.done 的 role 或 content 无效。")
    }
    for (index, finalPart) in content.enumerated() {
      guard let part = state.parts[index], part.partDone else {
        throw protocolFailure("Responses message.done 的 content_index 不连续。")
      }
      try validatePart(finalPart, kind: part.kind, expectedValue: part.value, field: "content")
    }
  }

  private func validateFinalFunctionCall(
    _ item: [String: Any], state: FunctionCallState
  ) throws {
    try rejectUnsupportedFunctionMetadata(item)
    guard
      try requiredNonemptyString(item["call_id"], field: "function_call.call_id")
        == state.callID,
      try requiredNonemptyString(item["name"], field: "function_call.name") == state.name,
      try requiredString(item["arguments"], field: "function_call.arguments")
        == state.arguments,
      try Self.isJSONObject(state.arguments)
    else {
      throw protocolFailure("Responses function_call.done 改写了身份或 arguments。")
    }
  }

  private func validateTerminalOutput(
    _ output: [[String: Any]], overallStatus: String
  ) throws {
    for (index, item) in output.enumerated() {
      _ = try requiredNonemptyString(item["id"], field: "output.id")
      guard let state = items[index], state.isDone,
        item["type"] as? String == state.type
      else {
        throw protocolFailure("Responses 终态 output 与增量 item 不一致。")
      }
      let expectedStatus = state.finalStatus
      if let expectedStatus, item["status"] as? String != expectedStatus {
        throw protocolFailure("Responses 终态 output 改写了 item.status。")
      }
      if overallStatus == "completed", item["status"] as? String == "incomplete" {
        throw protocolFailure("Completed Responses 包含未完成的 output item。")
      }

      switch state {
      case .message(let message):
        guard item["role"] as? String == "assistant",
          let content = item["content"] as? [[String: Any]],
          content.count == message.parts.count
        else {
          throw protocolFailure("Responses 终态 message content 无效。")
        }
        for (contentIndex, finalPart) in content.enumerated() {
          guard let part = message.parts[contentIndex] else {
            throw protocolFailure("Responses 终态 message content_index 无效。")
          }
          try validatePartShape(finalPart, kind: part.kind, field: "output.content")
          let valueField = part.kind == .outputText ? "text" : "refusal"
          let value = try requiredString(
            finalPart[valueField], field: "output.content.\(valueField)")
          guard part.finalSummary?.matches(value) == true else {
            throw protocolFailure("Responses 终态 message 改写了已流式输出的内容。")
          }
        }
      case .functionCall(let function):
        try rejectUnsupportedFunctionMetadata(item)
        let arguments = try requiredString(item["arguments"], field: "output.arguments")
        guard
          try requiredNonemptyString(item["call_id"], field: "output.call_id")
            == function.callID,
          try requiredNonemptyString(item["name"], field: "output.name") == function.name,
          function.finalArgumentsSummary?.matches(arguments) == true,
          try Self.isJSONObject(arguments)
        else {
          throw protocolFailure("Responses 终态 function_call 无效或改写了已流式输出的参数。")
        }
      case .reasoning:
        try validateReasoning(
          item, allowedStatuses: ["completed", "incomplete"], field: "output.reasoning")
      }
    }
  }

  private func validatePart(
    _ part: [String: Any], kind: ContentKind, expectedValue: String, field: String
  ) throws {
    try validatePartShape(part, kind: kind, field: field)
    let valueField = kind == .outputText ? "text" : "refusal"
    guard try requiredString(part[valueField], field: "\(field).\(valueField)") == expectedValue
    else {
      throw protocolFailure("Responses \(field).\(valueField) 与增量内容不一致。")
    }
  }

  private func validatePartShape(
    _ part: [String: Any], kind: ContentKind, field: String
  ) throws {
    guard part["type"] as? String == kind.rawValue else {
      throw protocolFailure("Responses \(field).type 在流中被改写。")
    }
    switch kind {
    case .outputText:
      _ = try requiredString(part["text"], field: "\(field).text")
      try requireEmptyArrayIfPresent(part["annotations"], field: "\(field).annotations")
      try requireEmptyArrayIfPresent(part["logprobs"], field: "\(field).logprobs")
    case .refusal:
      _ = try requiredString(part["refusal"], field: "\(field).refusal")
    }
  }

  private func validateReasoning(
    _ item: [String: Any], allowedStatuses: Set<String>, field: String
  ) throws {
    try ResponsesReasoningEnvelope.validate(item, allowedStatuses: allowedStatuses)
  }

  private func translatedUsage(_ value: Any?) throws -> Usage {
    guard let value = nonNull(value) else {
      return Usage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadInputTokens: nil,
        cacheCreationInputTokens: nil)
    }
    guard let usage = value as? [String: Any],
      let inputTokens = AnthropicCodec.exactNonnegativeInteger(usage["input_tokens"]),
      let outputTokens = AnthropicCodec.exactNonnegativeInteger(usage["output_tokens"])
    else {
      throw protocolFailure("Responses 终态事件缺少有效 usage token 计数。")
    }
    if let totalValue = nonNull(usage["total_tokens"]) {
      guard let total = AnthropicCodec.exactNonnegativeInteger(totalValue),
        inputTokens <= Int.max - outputTokens, total == inputTokens + outputTokens
      else {
        throw protocolFailure("Responses usage.total_tokens 与 input/output token 不一致。")
      }
    }

    var cached: Int?
    var written: Int?
    if let rawDetails = nonNull(usage["input_tokens_details"]) {
      guard let details = rawDetails as? [String: Any] else {
        throw protocolFailure("Responses usage.input_tokens_details 必须是对象。")
      }
      let supported = Set(["cached_tokens", "cache_write_tokens"])
      guard Set(details.keys).isSubset(of: supported) else {
        throw protocolFailure("Responses usage.input_tokens_details 包含无法转换的计数。")
      }
      if let value = nonNull(details["cached_tokens"]) {
        guard let parsed = AnthropicCodec.exactNonnegativeInteger(value), parsed <= inputTokens
        else {
          throw protocolFailure("Responses usage.cached_tokens 无效。")
        }
        cached = parsed
      }
      if let value = nonNull(details["cache_write_tokens"]) {
        guard let parsed = AnthropicCodec.exactNonnegativeInteger(value) else {
          throw protocolFailure("Responses usage.cache_write_tokens 无效。")
        }
        written = parsed
      }
    }
    if let rawDetails = nonNull(usage["output_tokens_details"]) {
      guard let details = rawDetails as? [String: Any],
        Set(details.keys).isSubset(of: ["reasoning_tokens"])
      else {
        throw protocolFailure("Responses usage.output_tokens_details 无效。")
      }
      if let value = nonNull(details["reasoning_tokens"]) {
        guard let reasoning = AnthropicCodec.exactNonnegativeInteger(value),
          reasoning <= outputTokens
        else {
          throw protocolFailure("Responses usage.reasoning_tokens 无效。")
        }
      }
    }
    return Usage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadInputTokens: cached,
      cacheCreationInputTokens: written)
  }

  private func incompleteStopReason(_ value: Any?) throws -> String {
    guard let details = value as? [String: Any],
      let reason = details["reason"] as? String
    else {
      throw protocolFailure("Incomplete Responses 终态缺少 incomplete_details.reason。")
    }
    switch reason {
    case "max_output_tokens": return "max_tokens"
    case "content_filter": return "refusal"
    case "max_messages", "steered": return "pause_turn"
    default:
      throw protocolFailure("Responses incomplete_details.reason 不受支持：\(reason)。")
    }
  }

  private func failureDetails(_ value: Any?, field: String) throws -> (
    type: String, message: String
  ) {
    guard let error = value as? [String: Any] else {
      throw protocolFailure("Responses \(field) 缺少错误对象。")
    }
    let message = try requiredNonemptyString(error["message"], field: "\(field).message")
    let type: String
    if let code = nonNull(error["code"]) {
      type = anthropicErrorType(
        try requiredNonemptyString(code, field: "\(field).code"))
    } else {
      type = "api_error"
    }
    return (type, message)
  }

  private func anthropicErrorType(_ upstreamCode: String) -> String {
    let nativeTypes: Set<String> = [
      "api_error",
      "authentication_error",
      "billing_error",
      "conflict_error",
      "invalid_request_error",
      "not_found_error",
      "overloaded_error",
      "permission_error",
      "rate_limit_error",
      "request_too_large",
      "timeout_error",
    ]
    if nativeTypes.contains(upstreamCode) { return upstreamCode }
    switch upstreamCode {
    case "rate_limit_exceeded": return "rate_limit_error"
    case "insufficient_quota": return "billing_error"
    case "model_not_found": return "not_found_error"
    default: return "api_error"
    }
  }

  private func rejectUnsupportedFunctionMetadata(_ item: [String: Any]) throws {
    for key in ["async", "caller", "namespace"] where nonNull(item[key]) != nil {
      throw protocolFailure("Responses function_call.\(key) 无法转换为 Anthropic tool_use。")
    }
  }

  private func completedItemStatus(_ value: Any?, allowIncomplete: Bool) throws -> String {
    let status = try requiredNonemptyString(value, field: "item.status")
    guard status == "completed" || (allowIncomplete && status == "incomplete") else {
      throw protocolFailure("Responses output item 未进入可接受的终态。")
    }
    return status
  }

  private func validatedPhase(_ value: Any?, field: String) throws -> String? {
    guard let value = nonNull(value) else { return nil }
    let phase = try requiredNonemptyString(value, field: field)
    guard ["commentary", "final_answer"].contains(phase) else {
      throw protocolFailure("Responses \(field) 无效。")
    }
    return phase
  }

  private func contentKind(in part: [String: Any]) throws -> ContentKind {
    let type = try requiredNonemptyString(part["type"], field: "part.type")
    guard let kind = ContentKind(rawValue: type) else {
      throw protocolFailure("Responses content part \(type) 无法转换。")
    }
    return kind
  }

  private func contentCoordinates(in event: [String: Any]) throws -> (
    outputIndex: Int, contentIndex: Int
  ) {
    let outputIndex = try self.outputIndex(in: event)
    guard let contentIndex = AnthropicCodec.exactNonnegativeInteger(event["content_index"]),
      contentIndex < maximumContentPartsPerMessage
    else {
      throw protocolFailure("Responses event.content_index 无效或超过限制。")
    }
    _ = try requiredNonemptyString(event["item_id"], field: "event.item_id")
    return (outputIndex, contentIndex)
  }

  private func outputIndex(in event: [String: Any]) throws -> Int {
    guard let index = AnthropicCodec.exactNonnegativeInteger(event["output_index"]),
      index < maximumOutputItems
    else {
      throw protocolFailure("Responses event.output_index 无效或超过限制。")
    }
    return index
  }

  private func item(at index: Int) throws -> ItemState {
    // Copilot can reissue item.id/item_id on every event, including done snapshots.
    // The stable coordinates within this HTTP stream are output_index/content_index.
    // Function call_id/name and final content still must match the streamed values.
    guard let item = items[index] else {
      throw protocolFailure("Responses output_index 没有对应的已开始 item。")
    }
    return item
  }

  private func responseObject(in event: [String: Any]) throws -> [String: Any] {
    guard let response = event["response"] as? [String: Any] else {
      throw protocolFailure("Responses 状态事件缺少 response 对象。")
    }
    return response
  }

  private func validateResponseSnapshot(
    _ response: [String: Any], expectedStatus: String
  ) throws {
    // Copilot replaces the provisional response.created ID with its provider response ID in
    // later snapshots. This is the same HTTP stream, not a different message. Keep the original
    // downstream message_start ID; output_index/content_index still identify stream content.
    _ = try requiredNonemptyString(response["id"], field: "response.id")
    guard response["object"] as? String == "response",
      try requiredNonemptyString(response["model"], field: "response.model") == responseModel,
      response["status"] as? String == expectedStatus
    else {
      throw protocolFailure("Responses 状态事件的 object/model/status 无效。")
    }
  }

  private func observeSequenceNumber(_ value: Any?, eventType: String) throws {
    guard let number = AnthropicCodec.exactNonnegativeInteger(value) else {
      throw protocolFailure("Responses \(eventType) 缺少有效 sequence_number。")
    }
    if let lastSequenceNumber {
      guard lastSequenceNumber < Int.max, number == lastSequenceNumber + 1 else {
        throw protocolFailure("Responses SSE sequence_number 不连续。")
      }
    } else if number != 0 {
      throw protocolFailure("Responses SSE sequence_number 必须从 0 开始。")
    }
    self.lastSequenceNumber = number
  }

  private func requireActive(_ eventType: String) throws {
    guard lifecycle == .active, responseID != nil, responseModel != nil else {
      throw protocolFailure("Responses \(eventType) 出现在 response.created 之前。")
    }
  }

  private func requireEmptyOutputIfPresent(_ value: Any?, field: String) throws {
    guard let value = nonNull(value) else { return }
    try requireEmptyArray(value, field: field)
  }

  private func requireEmptyArray(_ value: Any?, field: String) throws {
    guard let array = value as? [Any], array.isEmpty else {
      throw protocolFailure("Responses \(field) 必须是空数组。")
    }
  }

  private func requireEmptyArrayIfPresent(_ value: Any?, field: String) throws {
    guard let value = nonNull(value) else { return }
    try requireEmptyArray(value, field: field)
  }

  private func requireNullIfPresent(_ value: Any?, field: String) throws {
    guard value == nil || value is NSNull else {
      throw protocolFailure("Responses \(field) 必须为 null。")
    }
  }

  private func appendBounded(_ fragment: String, to value: inout String, field: String) throws {
    try reserve(fragment.utf8.count, field: field)
    value += fragment
  }

  private func reserve(_ byteCount: Int, field: String) throws {
    guard byteCount >= 0, byteCount <= maximumAccumulatedFieldBytes - accumulatedFieldBytes else {
      throw protocolFailure("Responses 流的 \(field) 超过累计字节上限。")
    }
    accumulatedFieldBytes += byteCount
  }

  private func release(_ byteCount: Int) {
    accumulatedFieldBytes = max(0, accumulatedFieldBytes - byteCount)
  }

  private func requiredNonemptyString(_ value: Any?, field: String) throws -> String {
    let string = try requiredString(value, field: field)
    guard !string.isEmpty else {
      throw protocolFailure("Responses \(field) 必须是非空字符串。")
    }
    return string
  }

  private func requiredString(_ value: Any?, field: String) throws -> String {
    guard let string = value as? String else {
      throw protocolFailure("Responses \(field) 必须是字符串。")
    }
    return string
  }

  private func nonNull(_ value: Any?) -> Any? {
    guard let value, !(value is NSNull) else { return nil }
    return value
  }

  private func protocolFailure(_ message: String) -> BridgeError {
    .protocolFailure(message)
  }

  private static func isJSONObject(_ string: String) throws -> Bool {
    guard let data = string.data(using: .utf8) else { return false }
    do {
      return try JSONSerialization.jsonObject(with: data) is [String: Any]
    } catch {
      return false
    }
  }

  private static func event(_ name: String, _ object: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw BridgeError.protocolFailure("Anthropic SSE 事件包含无法编码的 JSON 值。")
    }
    let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    var result = Data("event: \(name)\ndata: ".utf8)
    result.append(payload)
    result.append(Data("\n\n".utf8))
    return result
  }
}
