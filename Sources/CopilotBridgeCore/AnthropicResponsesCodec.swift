import Foundation

/// Translates Anthropic Messages payloads to and from the non-streaming OpenAI Responses API.
///
/// This codec deliberately does not share the Chat Completions translation path: Responses uses
/// flat function tools and standalone function call input/output items.
public enum AnthropicResponsesCodec {
  private static let supportedRequestFields: Set<String> = [
    "cache_control", "context_management", "max_tokens", "messages", "metadata", "model",
    "output_config", "output_format", "service_tier", "stop_sequences", "stream", "system",
    "temperature", "thinking", "tool_choice", "tools", "top_k", "top_p",
  ]

  public static func toOpenAI(
    _ request: [String: Any], resolvedModel: String? = nil
  ) throws -> [String: Any] {
    try requireOnlyKeys(request, allowed: supportedRequestFields, field: "Anthropic 请求")

    let requestedModel = try nonemptyString(request["model"], field: "model")
    guard let sourceMessages = request["messages"] as? [[String: Any]] else {
      throw BridgeError.invalidRequest("Anthropic 请求缺少 messages 数组。")
    }
    guard let maxTokens = exactPositiveInteger(request["max_tokens"]) else {
      throw BridgeError.invalidRequest("Anthropic Messages 请求必须提供正整数 max_tokens。")
    }

    try validateIgnoredTopLevelFields(request)
    let stream = try validatedBool(request["stream"], defaultValue: false, field: "stream")
    let temperature = try validatedNumber(request["temperature"], field: "temperature")
    let topP = try validatedNumber(request["top_p"], field: "top_p")
    try validateStopSequences(request["stop_sequences"])
    try validateThinking(request["thinking"])
    try validateContextManagement(request["context_management"])

    var output: [String: Any] = [
      "input": try translatedMessages(sourceMessages),
      "max_output_tokens": maxTokens,
      "model": resolvedModel ?? requestedModel,
      "store": false,
      "stream": stream,
    ]

    if let instructions = try translatedSystem(optionalValue(request["system"])) {
      output["instructions"] = instructions
    }
    if let temperature { output["temperature"] = temperature }
    if let topP { output["top_p"] = topP }
    if let user = try translatedMetadata(optionalValue(request["metadata"])) {
      output["user"] = user
    }
    if let tools = try translatedTools(optionalValue(request["tools"])), !tools.isEmpty {
      output["tools"] = tools
    }
    try translateToolChoice(optionalValue(request["tool_choice"]), into: &output)
    if let text = try translatedOutputText(
      outputConfig: optionalValue(request["output_config"]),
      legacyFormat: optionalValue(request["output_format"]))
    {
      output["text"] = text
    }

    guard JSONSerialization.isValidJSONObject(output) else {
      throw BridgeError.invalidRequest("Anthropic 请求包含无法编码的 JSON 值。")
    }
    return output
  }

  public static func fromOpenAI(
    _ response: [String: Any], requestedModel: String
  ) throws -> [String: Any] {
    guard !requestedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BridgeError.protocolFailure("缺少原始 Anthropic 模型名。")
    }
    guard response["object"] as? String == "response" else {
      throw BridgeError.protocolFailure("Copilot 返回的 Responses 对象类型无效。")
    }
    let responseID: String
    do {
      responseID = try nonemptyString(response["id"], field: "response.id")
    } catch {
      throw BridgeError.protocolFailure("Copilot 返回的 Responses 对象缺少 id。")
    }
    guard let status = response["status"] as? String else {
      throw BridgeError.protocolFailure("Copilot 返回的 Responses 对象缺少 status。")
    }

    switch status {
    case "completed", "incomplete":
      if let error = response["error"], !(error is NSNull) {
        throw BridgeError.protocolFailure("Copilot 返回了终态响应与非空 error。")
      }
    case "failed":
      throw BridgeError.protocolFailure(responseFailureMessage(response["error"]))
    case "in_progress", "queued", "cancelled":
      throw BridgeError.protocolFailure("Copilot 返回了非终态 Responses 响应：\(status)。")
    default:
      throw BridgeError.protocolFailure("Copilot 返回了未知 Responses status：\(status)。")
    }

    guard let items = response["output"] as? [[String: Any]] else {
      throw BridgeError.protocolFailure("Copilot Responses 响应缺少 output 数组。")
    }

    var content: [[String: Any]] = []
    var sawFunctionCall = false
    var sawRefusal = false
    for item in items {
      guard let type = item["type"] as? String else {
        throw BridgeError.protocolFailure("Copilot Responses output item 缺少 type。")
      }
      switch type {
      case "message":
        let translated = try translatedOutputMessage(item, overallStatus: status)
        content.append(contentsOf: translated.blocks)
        sawRefusal = sawRefusal || translated.sawRefusal
      case "function_call":
        content.append(try translatedFunctionCall(item))
        sawFunctionCall = true
      case "reasoning":
        if let data = try ResponsesReasoningEnvelope.encode(item) {
          content.append(["type": "redacted_thinking", "data": data])
        }
      default:
        throw BridgeError.protocolFailure(
          "Copilot Responses output 包含无法转换的 \(type) item。")
      }
    }

    let usage = try translatedUsage(response["usage"])
    let stopReason: String
    if sawFunctionCall {
      stopReason = "tool_use"
    } else if status == "incomplete" {
      stopReason = try incompleteStopReason(response["incomplete_details"])
    } else if sawRefusal {
      stopReason = "refusal"
    } else {
      stopReason = "end_turn"
    }

    let responseModel: String
    if let rawModel = response["model"] {
      do {
        responseModel = try nonemptyString(rawModel, field: "response.model")
      } catch {
        throw BridgeError.protocolFailure("Copilot Responses 响应的 model 无效。")
      }
    } else {
      responseModel = requestedModel
    }

    return [
      "content": content,
      "id": responseID.hasPrefix("msg_") ? responseID : "msg_\(responseID)",
      "model": responseModel,
      "role": "assistant",
      "stop_reason": stopReason,
      "stop_sequence": NSNull(),
      "type": "message",
      "usage": usage,
    ]
  }

  /// Encodes a complete Anthropic message as a standards-shaped SSE sequence.
  ///
  /// The proxy's live Responses path uses `AnthropicResponsesStreamTranslator`; this helper is for
  /// callers that already have a complete message object.
  public static func encodeSSE(message: [String: Any]) throws -> Data {
    guard message["type"] as? String == "message", message["role"] as? String == "assistant"
    else {
      throw BridgeError.protocolFailure("SSE 编码需要完整的 Anthropic assistant message。")
    }
    let id = try protocolNonemptyString(message["id"], field: "message.id")
    let model = try protocolNonemptyString(message["model"], field: "message.model")
    guard let blocks = message["content"] as? [[String: Any]] else {
      throw BridgeError.protocolFailure("Anthropic message.content 必须是 block 数组。")
    }
    guard let stopReason = message["stop_reason"] as? String,
      ["end_turn", "max_tokens", "pause_turn", "refusal", "tool_use"].contains(stopReason)
    else {
      throw BridgeError.protocolFailure("Anthropic message.stop_reason 无效。")
    }
    if let stopSequence = message["stop_sequence"], !(stopSequence is NSNull),
      !(stopSequence is String)
    {
      throw BridgeError.protocolFailure("Anthropic message.stop_sequence 必须是字符串或 null。")
    }
    guard let usage = message["usage"] as? [String: Any],
      let inputTokens = exactNonnegativeInteger(usage["input_tokens"]),
      let outputTokens = exactNonnegativeInteger(usage["output_tokens"])
    else {
      throw BridgeError.protocolFailure("Anthropic message.usage 缺少有效 token 计数。")
    }
    let hasToolUse = blocks.contains { $0["type"] as? String == "tool_use" }
    guard (stopReason == "tool_use") == hasToolUse else {
      throw BridgeError.protocolFailure("Anthropic message.stop_reason 与 tool_use content 不一致。")
    }

    var startUsage: [String: Any] = ["input_tokens": inputTokens, "output_tokens": 0]
    for key in ["cache_creation_input_tokens", "cache_read_input_tokens"] {
      if let rawValue = usage[key] {
        guard let value = exactNonnegativeInteger(rawValue) else {
          throw BridgeError.protocolFailure("Anthropic message.usage.\(key) 无效。")
        }
        startUsage[key] = value
      }
    }

    var output = try sseEvent(
      "message_start",
      [
        "message": [
          "content": [],
          "id": id,
          "model": model,
          "role": "assistant",
          "stop_reason": NSNull(),
          "stop_sequence": NSNull(),
          "type": "message",
          "usage": startUsage,
        ],
        "type": "message_start",
      ])

    for (index, block) in blocks.enumerated() {
      let type = try protocolNonemptyString(block["type"], field: "content[\(index)].type")
      switch type {
      case "text":
        let text = try protocolString(block["text"], field: "content[\(index)].text")
        output += try sseEvent(
          "content_block_start",
          [
            "content_block": ["text": "", "type": "text"],
            "index": index,
            "type": "content_block_start",
          ])
        if !text.isEmpty {
          output += try sseEvent(
            "content_block_delta",
            [
              "delta": ["text": text, "type": "text_delta"],
              "index": index,
              "type": "content_block_delta",
            ])
        }
      case "thinking":
        let thinking = try protocolString(
          block["thinking"], field: "content[\(index)].thinking")
        output += try sseEvent(
          "content_block_start",
          [
            "content_block": ["signature": "", "thinking": "", "type": "thinking"],
            "index": index,
            "type": "content_block_start",
          ])
        if !thinking.isEmpty {
          output += try sseEvent(
            "content_block_delta",
            [
              "delta": ["thinking": thinking, "type": "thinking_delta"],
              "index": index,
              "type": "content_block_delta",
            ])
        }
        if let rawSignature = block["signature"] {
          let signature = try protocolString(
            rawSignature, field: "content[\(index)].signature")
          if !signature.isEmpty {
            output += try sseEvent(
              "content_block_delta",
              [
                "delta": ["signature": signature, "type": "signature_delta"],
                "index": index,
                "type": "content_block_delta",
              ])
          }
        }
      case "redacted_thinking":
        let data = try protocolNonemptyString(block["data"], field: "content[\(index)].data")
        output += try sseEvent(
          "content_block_start",
          [
            "content_block": ["data": data, "type": "redacted_thinking"],
            "index": index,
            "type": "content_block_start",
          ])
      case "tool_use":
        let callID = try protocolNonemptyString(block["id"], field: "content[\(index)].id")
        let name = try protocolNonemptyString(block["name"], field: "content[\(index)].name")
        guard let input = block["input"] as? [String: Any],
          JSONSerialization.isValidJSONObject(input)
        else {
          throw BridgeError.protocolFailure("Anthropic tool_use.input 必须是有效 JSON 对象。")
        }
        let inputData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let partialJSON = String(decoding: inputData, as: UTF8.self)
        output += try sseEvent(
          "content_block_start",
          [
            "content_block": ["id": callID, "input": [:], "name": name, "type": "tool_use"],
            "index": index,
            "type": "content_block_start",
          ])
        output += try sseEvent(
          "content_block_delta",
          [
            "delta": ["partial_json": partialJSON, "type": "input_json_delta"],
            "index": index,
            "type": "content_block_delta",
          ])
      default:
        throw BridgeError.protocolFailure("Anthropic message 包含不支持的 \(type) block。")
      }
      output += try sseEvent(
        "content_block_stop", ["index": index, "type": "content_block_stop"])
    }

    let stopSequence: Any = message["stop_sequence"] ?? NSNull()
    output += try sseEvent(
      "message_delta",
      [
        "delta": ["stop_reason": stopReason, "stop_sequence": stopSequence],
        "type": "message_delta",
        "usage": ["output_tokens": outputTokens],
      ])
    output += try sseEvent("message_stop", ["type": "message_stop"])
    return output
  }

  private static func translatedMessages(_ messages: [[String: Any]]) throws -> [[String: Any]] {
    var output: [[String: Any]] = []
    for (index, message) in messages.enumerated() {
      try requireOnlyKeys(message, allowed: ["content", "role"], field: "messages[\(index)]")
      let role = try nonemptyString(message["role"], field: "messages[\(index)].role")
      switch role {
      case "user":
        try appendUserContent(message["content"], messageIndex: index, to: &output)
      case "assistant":
        try appendAssistantContent(message["content"], messageIndex: index, to: &output)
      case "system":
        try appendSystemContent(message["content"], messageIndex: index, to: &output)
      default:
        throw BridgeError.invalidRequest("Anthropic messages[\(index)] 不支持 role \(role)。")
      }
    }
    return output
  }

  private static func appendSystemContent(
    _ value: Any?, messageIndex: Int, to output: inout [[String: Any]]
  ) throws {
    if let text = value as? String {
      appendMessage(role: "system", parts: [["text": text, "type": "input_text"]], to: &output)
      return
    }
    guard let blocks = value as? [[String: Any]], !blocks.isEmpty else {
      throw BridgeError.invalidRequest(
        "Anthropic messages[\(messageIndex)].content 必须是字符串或非空 block 数组。")
    }

    let parts = try blocks.enumerated().map { blockIndex, block -> [String: Any] in
      let field = "messages[\(messageIndex)].content[\(blockIndex)]"
      try requireOnlyKeys(block, allowed: ["cache_control", "text", "type"], field: field)
      let type = try nonemptyString(block["type"], field: "\(field).type")
      guard type == "text" else {
        throw BridgeError.invalidRequest("Anthropic system content 不支持 \(type) block。")
      }
      try validateCacheControl(block["cache_control"], field: "\(field).cache_control")
      return [
        "text": try string(block["text"], field: "\(field).text"),
        "type": "input_text",
      ]
    }
    appendMessage(role: "system", parts: parts, to: &output)
  }

  private static func appendUserContent(
    _ value: Any?, messageIndex: Int, to output: inout [[String: Any]]
  ) throws {
    if let text = value as? String {
      appendMessage(role: "user", parts: [["text": text, "type": "input_text"]], to: &output)
      return
    }
    guard let blocks = value as? [[String: Any]], !blocks.isEmpty else {
      throw BridgeError.invalidRequest(
        "Anthropic messages[\(messageIndex)].content 必须是字符串或非空 block 数组。")
    }

    var parts: [[String: Any]] = []
    for (blockIndex, block) in blocks.enumerated() {
      let field = "messages[\(messageIndex)].content[\(blockIndex)]"
      let type = try nonemptyString(block["type"], field: "\(field).type")
      switch type {
      case "text":
        try requireOnlyKeys(block, allowed: ["cache_control", "text", "type"], field: field)
        try validateCacheControl(block["cache_control"], field: "\(field).cache_control")
        let text = try string(block["text"], field: "\(field).text")
        parts.append(["text": text, "type": "input_text"])
      case "image":
        try requireOnlyKeys(block, allowed: ["cache_control", "source", "type"], field: field)
        try validateCacheControl(block["cache_control"], field: "\(field).cache_control")
        parts.append(try translatedImage(block["source"], field: "\(field).source"))
      case "tool_result":
        appendMessage(role: "user", parts: parts, to: &output)
        parts.removeAll(keepingCapacity: true)
        output.append(try translatedToolResult(block, field: field))
      default:
        throw BridgeError.invalidRequest("Anthropic user content 不支持 \(type) block。")
      }
    }
    appendMessage(role: "user", parts: parts, to: &output)
  }

  private static func appendAssistantContent(
    _ value: Any?, messageIndex: Int, to output: inout [[String: Any]]
  ) throws {
    if let text = value as? String {
      appendMessage(
        role: "assistant", parts: [["text": text, "type": "output_text"]], to: &output)
      return
    }
    guard let blocks = value as? [[String: Any]], !blocks.isEmpty else {
      throw BridgeError.invalidRequest(
        "Anthropic messages[\(messageIndex)].content 必须是字符串或非空 block 数组。")
    }

    var parts: [[String: Any]] = []
    var emittedItem = false
    for (blockIndex, block) in blocks.enumerated() {
      let field = "messages[\(messageIndex)].content[\(blockIndex)]"
      let type = try nonemptyString(block["type"], field: "\(field).type")
      switch type {
      case "text":
        try requireOnlyKeys(block, allowed: ["cache_control", "text", "type"], field: field)
        try validateCacheControl(block["cache_control"], field: "\(field).cache_control")
        let text = try string(block["text"], field: "\(field).text")
        parts.append(["text": text, "type": "output_text"])
      case "tool_use":
        if !parts.isEmpty {
          appendMessage(role: "assistant", parts: parts, to: &output)
          emittedItem = true
          parts.removeAll(keepingCapacity: true)
        }
        output.append(try translatedToolUse(block, field: field))
        emittedItem = true
      case "thinking":
        try validateThinkingBlock(block, field: field)
      case "redacted_thinking":
        try validateRedactedThinkingBlock(block, field: field)
        if let data = block["data"] as? String,
          let reasoning = try ResponsesReasoningEnvelope.decode(data)
        {
          appendMessage(role: "assistant", parts: parts, to: &output)
          parts.removeAll(keepingCapacity: true)
          output.append(reasoning)
          emittedItem = true
        }
      default:
        throw BridgeError.invalidRequest("Anthropic assistant content 不支持 \(type) block。")
      }
    }
    if !parts.isEmpty {
      appendMessage(role: "assistant", parts: parts, to: &output)
      emittedItem = true
    }
    guard emittedItem else {
      throw BridgeError.invalidRequest(
        "Anthropic assistant message 仅含无法作为 Responses 历史转发的 thinking block。")
    }
  }

  private static func appendMessage(
    role: String, parts: [[String: Any]], to output: inout [[String: Any]]
  ) {
    guard !parts.isEmpty else { return }
    output.append(["content": parts, "role": role, "type": "message"])
  }

  private static func translatedToolUse(_ block: [String: Any], field: String) throws
    -> [String: Any]
  {
    try requireOnlyKeys(
      block, allowed: ["cache_control", "id", "input", "name", "type"], field: field)
    try validateCacheControl(block["cache_control"], field: "\(field).cache_control")
    let id = try nonemptyString(block["id"], field: "\(field).id")
    let name = try nonemptyString(block["name"], field: "\(field).name")
    let input: [String: Any]
    if block["input"] == nil {
      input = [:]
    } else if let object = block["input"] as? [String: Any],
      JSONSerialization.isValidJSONObject(object)
    {
      input = object
    } else {
      throw BridgeError.invalidRequest("\(field).input 必须是有效 JSON 对象。")
    }
    let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
    return [
      "arguments": String(decoding: data, as: UTF8.self),
      "call_id": id,
      "name": name,
      "type": "function_call",
    ]
  }

  private static func translatedToolResult(_ block: [String: Any], field: String) throws
    -> [String: Any]
  {
    try requireOnlyKeys(
      block,
      allowed: ["cache_control", "content", "is_error", "tool_use_id", "type"],
      field: field)
    try validateCacheControl(block["cache_control"], field: "\(field).cache_control")
    let callID = try nonemptyString(block["tool_use_id"], field: "\(field).tool_use_id")
    let isError = try validatedBool(
      block["is_error"], defaultValue: false, field: "\(field).is_error")

    let translatedOutput: Any
    if let text = block["content"] as? String {
      translatedOutput = isError ? "ERROR: \(text)" : text
    } else if let blocks = block["content"] as? [[String: Any]], !blocks.isEmpty {
      var parts: [[String: Any]] = []
      if isError { parts.append(["text": "ERROR", "type": "input_text"]) }
      for (index, nested) in blocks.enumerated() {
        let nestedField = "\(field).content[\(index)]"
        let type = try nonemptyString(nested["type"], field: "\(nestedField).type")
        switch type {
        case "text":
          try requireOnlyKeys(
            nested, allowed: ["cache_control", "text", "type"], field: nestedField)
          try validateCacheControl(
            nested["cache_control"], field: "\(nestedField).cache_control")
          parts.append([
            "text": try string(nested["text"], field: "\(nestedField).text"),
            "type": "input_text",
          ])
        case "image":
          try requireOnlyKeys(
            nested, allowed: ["cache_control", "source", "type"], field: nestedField)
          try validateCacheControl(
            nested["cache_control"], field: "\(nestedField).cache_control")
          parts.append(try translatedImage(nested["source"], field: "\(nestedField).source"))
        default:
          throw BridgeError.invalidRequest("tool_result content 不支持 \(type) block。")
        }
      }
      translatedOutput = parts
    } else {
      throw BridgeError.invalidRequest("\(field).content 必须是字符串或非空 block 数组。")
    }

    return [
      "call_id": callID,
      "output": translatedOutput,
      "type": "function_call_output",
    ]
  }

  private static func translatedImage(_ value: Any?, field: String) throws -> [String: Any] {
    guard let source = value as? [String: Any] else {
      throw BridgeError.invalidRequest("\(field) 必须是对象。")
    }
    let type = try nonemptyString(source["type"], field: "\(field).type")
    let imageURL: String
    switch type {
    case "url":
      try requireOnlyKeys(source, allowed: ["type", "url"], field: field)
      let rawURL = try nonemptyString(source["url"], field: "\(field).url")
      guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(),
        ["http", "https"].contains(scheme), url.host != nil
      else {
        throw BridgeError.invalidRequest("\(field).url 必须是 HTTP(S) URL。")
      }
      imageURL = rawURL
    case "base64":
      try requireOnlyKeys(source, allowed: ["data", "media_type", "type"], field: field)
      let mediaType = try nonemptyString(source["media_type"], field: "\(field).media_type")
      guard ["image/gif", "image/jpeg", "image/png", "image/webp"].contains(mediaType) else {
        throw BridgeError.invalidRequest("\(field).media_type 不受支持。")
      }
      let data = try nonemptyString(source["data"], field: "\(field).data")
      guard Data(base64Encoded: data) != nil else {
        throw BridgeError.invalidRequest("\(field).data 不是有效 base64。")
      }
      imageURL = "data:\(mediaType);base64,\(data)"
    default:
      throw BridgeError.invalidRequest("\(field).type 不支持 \(type)。")
    }
    return ["detail": "auto", "image_url": imageURL, "type": "input_image"]
  }

  private static func translatedSystem(_ value: Any?) throws -> String? {
    guard let value else { return nil }
    if let text = value as? String { return text }
    guard let blocks = value as? [[String: Any]], !blocks.isEmpty else {
      throw BridgeError.invalidRequest("Anthropic system 必须是字符串或非空 text block 数组。")
    }
    return try blocks.enumerated().map { index, block in
      let field = "system[\(index)]"
      try requireOnlyKeys(block, allowed: ["cache_control", "text", "type"], field: field)
      guard block["type"] as? String == "text" else {
        throw BridgeError.invalidRequest("\(field) 仅支持 text block。")
      }
      try validateCacheControl(block["cache_control"], field: "\(field).cache_control")
      return try string(block["text"], field: "\(field).text")
    }.joined(separator: "\n\n")
  }

  private static func translatedMetadata(_ value: Any?) throws -> String? {
    guard let value else { return nil }
    guard let metadata = value as? [String: Any] else {
      throw BridgeError.invalidRequest("Anthropic metadata 必须是对象。")
    }
    try requireOnlyKeys(metadata, allowed: ["user_id"], field: "metadata")
    guard let rawUserID = optionalValue(metadata["user_id"]) else { return nil }
    let userID = try nonemptyString(rawUserID, field: "metadata.user_id")
    return AnthropicMetadataUserIdentifier.upstreamValue(for: userID)
  }

  private static func translatedTools(_ value: Any?) throws -> [[String: Any]]? {
    guard let value else { return nil }
    guard let tools = value as? [[String: Any]] else {
      throw BridgeError.invalidRequest("Anthropic tools 必须是对象数组。")
    }
    return try tools.enumerated().compactMap { index, tool -> [String: Any]? in
      let field = "tools[\(index)]"
      try requireOnlyKeys(
        tool,
        allowed: [
          "allowed_callers", "cache_control", "defer_loading", "description",
          "eager_input_streaming", "input_examples", "input_schema", "name", "strict", "type",
        ],
        field: field)
      let rawType = optionalValue(tool["type"])
      let type: String?
      if let rawType {
        guard let value = rawType as? String else {
          throw BridgeError.invalidRequest("\(field).type 必须是字符串。")
        }
        type = value
      } else {
        type = nil
      }
      let isToolSearchMetadata = type?.hasPrefix("tool_search_tool_") == true
      guard type == nil || type == "custom" || isToolSearchMetadata else {
        throw BridgeError.invalidRequest("\(field).type 仅支持 custom。")
      }
      try validateCacheControl(tool["cache_control"], field: "\(field).cache_control")
      for key in ["defer_loading", "eager_input_streaming"] {
        if let value = optionalValue(tool[key]), exactBool(value) == nil {
          throw BridgeError.invalidRequest("\(field).\(key) 必须是布尔值。")
        }
      }
      if let examples = optionalValue(tool["input_examples"]) {
        guard let examples = examples as? [[String: Any]],
          JSONSerialization.isValidJSONObject(examples)
        else {
          throw BridgeError.invalidRequest("\(field).input_examples 必须是 JSON 对象数组。")
        }
      }
      if let callers = optionalValue(tool["allowed_callers"]) {
        guard let callers = callers as? [String], callers.contains("direct") else {
          throw BridgeError.invalidRequest("\(field).allowed_callers 必须包含 direct。")
        }
      }
      if isToolSearchMetadata { return nil }
      let name = try nonemptyString(tool["name"], field: "\(field).name")
      guard let schema = tool["input_schema"] as? [String: Any],
        JSONSerialization.isValidJSONObject(schema)
      else {
        throw BridgeError.invalidRequest("\(field).input_schema 必须是有效 JSON 对象。")
      }
      var translated: [String: Any] = [
        "name": name,
        "parameters": schema,
        "type": "function",
      ]
      if let rawDescription = optionalValue(tool["description"]) {
        translated["description"] = try string(rawDescription, field: "\(field).description")
      }
      if let rawStrict = optionalValue(tool["strict"]) {
        guard let strict = exactBool(rawStrict) else {
          throw BridgeError.invalidRequest("\(field).strict 必须是布尔值。")
        }
        translated["strict"] = strict
      }
      return translated
    }
  }

  private static func translateToolChoice(_ value: Any?, into output: inout [String: Any]) throws {
    guard let value else { return }
    guard let choice = value as? [String: Any] else {
      throw BridgeError.invalidRequest("Anthropic tool_choice 必须是对象。")
    }
    try requireOnlyKeys(
      choice, allowed: ["disable_parallel_tool_use", "name", "type"], field: "tool_choice")
    let type = try nonemptyString(choice["type"], field: "tool_choice.type")
    if let rawDisable = optionalValue(choice["disable_parallel_tool_use"]) {
      guard let disable = exactBool(rawDisable) else {
        throw BridgeError.invalidRequest("tool_choice.disable_parallel_tool_use 必须是布尔值。")
      }
      output["parallel_tool_calls"] = !disable
    }
    switch type {
    case "auto": output["tool_choice"] = "auto"
    case "any": output["tool_choice"] = "required"
    case "none": output["tool_choice"] = "none"
    case "tool":
      output["tool_choice"] = [
        "name": try nonemptyString(choice["name"], field: "tool_choice.name"),
        "type": "function",
      ]
    default:
      throw BridgeError.invalidRequest("不支持 tool_choice.type：\(type)")
    }
  }

  private static func translatedOutputText(outputConfig: Any?, legacyFormat: Any?) throws
    -> [String: Any]?
  {
    let outputConfig = optionalValue(outputConfig)
    let legacyFormat = optionalValue(legacyFormat)
    if outputConfig != nil, legacyFormat != nil {
      throw BridgeError.invalidRequest("output_config.format 与 output_format 不能同时提供。")
    }

    var rawFormat = legacyFormat
    if let outputConfig {
      guard let object = outputConfig as? [String: Any] else {
        throw BridgeError.invalidRequest("Anthropic output_config 必须是对象。")
      }
      try requireOnlyKeys(object, allowed: ["effort", "format"], field: "output_config")
      if let rawEffort = optionalValue(object["effort"]) {
        guard let effort = rawEffort as? String,
          ["low", "medium", "high", "xhigh", "max"].contains(effort)
        else {
          throw BridgeError.invalidRequest("output_config.effort 不受支持。")
        }
      }
      rawFormat = optionalValue(object["format"])
      guard optionalValue(object["effort"]) != nil || rawFormat != nil else {
        throw BridgeError.invalidRequest("output_config 必须提供 effort 或 format。")
      }
    }
    guard let rawFormat else { return nil }
    guard let format = rawFormat as? [String: Any] else {
      throw BridgeError.invalidRequest("Anthropic output format 必须是对象。")
    }
    try requireOnlyKeys(format, allowed: ["schema", "type"], field: "output_config.format")
    guard format["type"] as? String == "json_schema",
      let schema = format["schema"] as? [String: Any],
      JSONSerialization.isValidJSONObject(schema)
    else {
      throw BridgeError.invalidRequest(
        "output_config.format 仅支持带有效 schema 的 json_schema。")
    }
    return [
      "format": [
        "name": "anthropic_output",
        "schema": schema,
        "strict": true,
        "type": "json_schema",
      ]
    ]
  }

  private static func translatedOutputMessage(
    _ item: [String: Any], overallStatus: String
  ) throws -> (blocks: [[String: Any]], sawRefusal: Bool) {
    guard item["role"] as? String == "assistant" else {
      throw BridgeError.protocolFailure("Responses message output 的 role 必须是 assistant。")
    }
    guard let itemStatus = item["status"] as? String,
      itemStatus == "completed" || (overallStatus == "incomplete" && itemStatus == "incomplete")
    else {
      throw BridgeError.protocolFailure("Responses message output 尚未完成。")
    }
    guard let parts = item["content"] as? [[String: Any]] else {
      throw BridgeError.protocolFailure("Responses message output 缺少 content 数组。")
    }
    if let phase = item["phase"] as? String,
      !["commentary", "final_answer"].contains(phase)
    {
      throw BridgeError.protocolFailure("Responses message output 的 phase 无效。")
    } else if item["phase"] != nil, !(item["phase"] is String) {
      throw BridgeError.protocolFailure("Responses message output 的 phase 必须是字符串。")
    }

    var blocks: [[String: Any]] = []
    var sawRefusal = false
    for part in parts {
      switch part["type"] as? String {
      case "output_text":
        guard let text = part["text"] as? String else {
          throw BridgeError.protocolFailure("Responses output_text 缺少 text。")
        }
        if let annotations = part["annotations"] {
          guard let array = annotations as? [Any], array.isEmpty else {
            throw BridgeError.protocolFailure("Responses output_text 的非空 annotations 无法无损转换。")
          }
        }
        if let logprobs = part["logprobs"], !(logprobs is [Any]) {
          throw BridgeError.protocolFailure("Responses output_text.logprobs 必须是数组。")
        }
        blocks.append(["text": text, "type": "text"])
      case "refusal":
        guard let refusal = part["refusal"] as? String else {
          throw BridgeError.protocolFailure("Responses refusal 缺少文本。")
        }
        blocks.append(["text": refusal, "type": "text"])
        sawRefusal = true
      case let type?:
        throw BridgeError.protocolFailure("Responses message 包含不支持的 \(type) content。")
      case nil:
        throw BridgeError.protocolFailure("Responses message content 缺少 type。")
      }
    }
    return (blocks, sawRefusal)
  }

  private static func translatedFunctionCall(_ item: [String: Any]) throws -> [String: Any] {
    if let status = item["status"] as? String, status != "completed" {
      throw BridgeError.protocolFailure("Responses function_call 尚未完成，已拒绝下发执行。")
    } else if item["status"] != nil, !(item["status"] is String) {
      throw BridgeError.protocolFailure("Responses function_call.status 必须是字符串。")
    }
    for unsupported in ["async", "caller", "namespace"] where item[unsupported] != nil {
      throw BridgeError.protocolFailure(
        "Responses function_call.\(unsupported) 无法转换为 Anthropic tool_use。")
    }
    guard let callID = item["call_id"] as? String, !callID.isEmpty,
      let name = item["name"] as? String, !name.isEmpty,
      let arguments = item["arguments"] as? String,
      let data = arguments.data(using: .utf8),
      let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw BridgeError.protocolFailure("Responses function_call 包含无效的函数名、ID 或 JSON 参数。")
    }
    return [
      "id": callID,
      "input": input,
      "name": name,
      "type": "tool_use",
    ]
  }

  private static func translatedUsage(_ value: Any?) throws -> [String: Any] {
    guard let usage = value as? [String: Any],
      let inputTokens = exactNonnegativeInteger(usage["input_tokens"]),
      let outputTokens = exactNonnegativeInteger(usage["output_tokens"])
    else {
      throw BridgeError.protocolFailure("Copilot Responses 响应缺少有效 usage token 计数。")
    }
    if let total = usage["total_tokens"], exactNonnegativeInteger(total) == nil {
      throw BridgeError.protocolFailure("Copilot Responses usage.total_tokens 无效。")
    }

    var translated: [String: Any] = [
      "input_tokens": inputTokens,
      "output_tokens": outputTokens,
    ]
    if let details = usage["input_tokens_details"] {
      guard let details = details as? [String: Any] else {
        throw BridgeError.protocolFailure("Responses usage.input_tokens_details 必须是对象。")
      }
      if let cached = details["cached_tokens"] {
        guard let cached = exactNonnegativeInteger(cached) else {
          throw BridgeError.protocolFailure(
            "Responses usage.input_tokens_details.cached_tokens 无效。")
        }
        translated["cache_read_input_tokens"] = cached
      }
      if let written = details["cache_write_tokens"] {
        guard let written = exactNonnegativeInteger(written) else {
          throw BridgeError.protocolFailure(
            "Responses usage.input_tokens_details.cache_write_tokens 无效。")
        }
        translated["cache_creation_input_tokens"] = written
      }
    }
    return translated
  }

  private static func incompleteStopReason(_ value: Any?) throws -> String {
    guard let details = value as? [String: Any], let reason = details["reason"] as? String else {
      throw BridgeError.protocolFailure("Incomplete Responses 响应缺少 incomplete_details.reason。")
    }
    switch reason {
    case "max_output_tokens": return "max_tokens"
    case "content_filter": return "refusal"
    case "max_messages", "steered": return "pause_turn"
    default:
      throw BridgeError.protocolFailure("Responses incomplete_details.reason 不受支持：\(reason)。")
    }
  }

  private static func validateStopSequences(_ value: Any?) throws {
    guard let value = optionalValue(value) else { return }
    guard let sequences = value as? [String] else {
      throw BridgeError.invalidRequest("Anthropic stop_sequences 必须是字符串数组。")
    }
    guard sequences.isEmpty else {
      throw BridgeError.invalidRequest("Responses API 没有 stop_sequences 的无损对应字段。")
    }
  }

  private static func validateThinking(_ value: Any?) throws {
    guard let value = optionalValue(value) else { return }
    guard let object = value as? [String: Any], let type = object["type"] as? String else {
      throw BridgeError.invalidRequest("Anthropic thinking 必须是带 type 的对象。")
    }
    switch type {
    case "adaptive":
      try requireOnlyKeys(
        object, allowed: ["block_binding", "display", "type"], field: "thinking")
      try validateThinkingDisplay(object["display"])
    case "enabled":
      try requireOnlyKeys(
        object, allowed: ["block_binding", "budget_tokens", "display", "type"],
        field: "thinking")
      guard exactPositiveInteger(object["budget_tokens"]) != nil else {
        throw BridgeError.invalidRequest("thinking.budget_tokens 必须是正整数。")
      }
      try validateThinkingDisplay(object["display"])
    case "disabled":
      try requireOnlyKeys(object, allowed: ["type"], field: "thinking")
    default:
      throw BridgeError.invalidRequest("不支持 thinking.type：\(type)")
    }
    try validateThinkingBlockBinding(object["block_binding"])
  }

  private static func validateThinkingDisplay(_ value: Any?) throws {
    guard let value = optionalValue(value) else { return }
    guard let display = value as? String,
      ["omitted", "summarized", "updates"].contains(display)
    else {
      throw BridgeError.invalidRequest("不支持 thinking.display。")
    }
  }

  private static func validateThinkingBlockBinding(_ value: Any?) throws {
    guard let value = optionalValue(value) else { return }
    guard let object = value as? [String: Any] else {
      throw BridgeError.invalidRequest("thinking.block_binding 必须是对象。")
    }
    try requireOnlyKeys(
      object, allowed: ["prefix_mismatch_behavior"], field: "thinking.block_binding")
    guard let rawBehavior = optionalValue(object["prefix_mismatch_behavior"]) else { return }
    guard let behavior = rawBehavior as? String, ["drop_block", "error"].contains(behavior) else {
      throw BridgeError.invalidRequest(
        "thinking.block_binding.prefix_mismatch_behavior 仅支持 error 或 drop_block。")
    }
  }

  private static func validateThinkingBlock(_ block: [String: Any], field: String) throws {
    try requireOnlyKeys(
      block, allowed: ["cache_control", "signature", "thinking", "type"], field: field)
    try validateCacheControl(block["cache_control"], field: "\(field).cache_control")
    _ = try string(block["thinking"], field: "\(field).thinking")
    if let signature = block["signature"] { _ = try string(signature, field: "\(field).signature") }
  }

  private static func validateRedactedThinkingBlock(_ block: [String: Any], field: String) throws {
    try requireOnlyKeys(block, allowed: ["cache_control", "data", "type"], field: field)
    try validateCacheControl(block["cache_control"], field: "\(field).cache_control")
    _ = try nonemptyString(block["data"], field: "\(field).data")
  }

  private static func validateContextManagement(_ value: Any?) throws {
    guard let value = optionalValue(value) else { return }
    guard let object = value as? [String: Any] else {
      throw BridgeError.invalidRequest("Anthropic context_management 必须是对象。")
    }
    try requireOnlyKeys(object, allowed: ["edits"], field: "context_management")
    guard let rawEdits = optionalValue(object["edits"]) else { return }
    guard let edits = rawEdits as? [[String: Any]] else {
      throw BridgeError.invalidRequest("context_management.edits 必须是对象数组。")
    }
    for (index, edit) in edits.enumerated() {
      let field = "context_management.edits[\(index)]"
      guard let type = edit["type"] as? String else {
        throw BridgeError.invalidRequest("\(field) 缺少 type。")
      }
      switch type {
      case "clear_thinking_20251015":
        try requireOnlyKeys(edit, allowed: ["keep", "type"], field: field)
        guard edit["keep"] as? String == "all" else {
          throw BridgeError.invalidRequest("\(field) 仅支持 keep=all。")
        }
      case "clear_tool_uses_20250919":
        try validateClearToolUses(edit, field: field)
      default:
        throw BridgeError.invalidRequest("\(field) 的类型 \(type) 无法无损转换。")
      }
    }
  }

  private static func validateClearToolUses(_ edit: [String: Any], field: String) throws {
    try requireOnlyKeys(
      edit,
      allowed: [
        "clear_at_least", "clear_tool_inputs", "exclude_tools", "keep", "trigger", "type",
      ], field: field)
    if let trigger = optionalValue(edit["trigger"]) {
      try validateCountCondition(
        trigger, allowedTypes: ["input_tokens", "tool_uses"], field: "\(field).trigger")
    }
    if let keep = optionalValue(edit["keep"]) {
      try validateCountCondition(keep, allowedTypes: ["tool_uses"], field: "\(field).keep")
    }
    if let clearAtLeast = optionalValue(edit["clear_at_least"]) {
      try validateCountCondition(
        clearAtLeast, allowedTypes: ["input_tokens"], field: "\(field).clear_at_least")
    }
    if let clearToolInputs = optionalValue(edit["clear_tool_inputs"]),
      exactBool(clearToolInputs) == nil && !(clearToolInputs is [String])
    {
      throw BridgeError.invalidRequest("\(field).clear_tool_inputs 必须是布尔值或字符串数组。")
    }
    if let excludeTools = optionalValue(edit["exclude_tools"]), !(excludeTools is [String]) {
      throw BridgeError.invalidRequest("\(field).exclude_tools 必须是字符串数组。")
    }
  }

  private static func validateCountCondition(
    _ value: Any, allowedTypes: Set<String>, field: String
  ) throws {
    guard let object = value as? [String: Any] else {
      throw BridgeError.invalidRequest("\(field) 必须是对象。")
    }
    try requireOnlyKeys(object, allowed: ["type", "value"], field: field)
    guard let type = object["type"] as? String, allowedTypes.contains(type),
      exactNonnegativeInteger(object["value"]) != nil
    else {
      throw BridgeError.invalidRequest("\(field) 包含无效的 type 或 value。")
    }
  }

  private static func validateIgnoredTopLevelFields(_ request: [String: Any]) throws {
    try validateCacheControl(request["cache_control"], field: "cache_control")
    if let rawTier = optionalValue(request["service_tier"]) {
      guard let tier = rawTier as? String, ["auto", "standard_only"].contains(tier) else {
        throw BridgeError.invalidRequest("Anthropic service_tier 仅支持 auto 或 standard_only。")
      }
    }
    if let rawTopK = optionalValue(request["top_k"]),
      exactNonnegativeInteger(rawTopK) == nil
    {
      throw BridgeError.invalidRequest("Anthropic top_k 必须是非负整数。")
    }
  }

  private static func validateCacheControl(_ value: Any?, field: String) throws {
    guard let value = optionalValue(value) else { return }
    guard let object = value as? [String: Any] else {
      throw BridgeError.invalidRequest("\(field) 必须是对象。")
    }
    try requireOnlyKeys(object, allowed: ["ttl", "type"], field: field)
    guard object["type"] as? String == "ephemeral" else {
      throw BridgeError.invalidRequest("\(field).type 仅支持 ephemeral。")
    }
    if let rawTTL = optionalValue(object["ttl"]) {
      guard let ttl = rawTTL as? String, ["5m", "1h"].contains(ttl) else {
        throw BridgeError.invalidRequest("\(field).ttl 仅支持 5m 或 1h。")
      }
    }
  }

  private static func validatedBool(_ value: Any?, defaultValue: Bool, field: String) throws
    -> Bool
  {
    guard let value = optionalValue(value) else { return defaultValue }
    guard let result = exactBool(value) else {
      throw BridgeError.invalidRequest("Anthropic \(field) 必须是布尔值。")
    }
    return result
  }

  private static func validatedNumber(_ value: Any?, field: String) throws -> Double? {
    guard let value = optionalValue(value) else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      throw BridgeError.invalidRequest("Anthropic \(field) 必须是 0...1 的数字。")
    }
    let result = number.doubleValue
    guard result.isFinite, (0...1).contains(result) else {
      throw BridgeError.invalidRequest("Anthropic \(field) 必须是 0...1 的数字。")
    }
    return result
  }

  private static func exactBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return nil
    }
    return number.boolValue
  }

  private static func exactPositiveInteger(_ value: Any?) -> Int? {
    guard let value = exactNonnegativeInteger(value), value > 0 else { return nil }
    return value
  }

  private static func exactNonnegativeInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
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

  private static func string(_ value: Any?, field: String) throws -> String {
    guard let value = value as? String else {
      throw BridgeError.invalidRequest("\(field) 必须是字符串。")
    }
    return value
  }

  private static func nonemptyString(_ value: Any?, field: String) throws -> String {
    let result = try string(value, field: field)
    guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BridgeError.invalidRequest("\(field) 不能为空。")
    }
    return result
  }

  private static func requireOnlyKeys(
    _ object: [String: Any], allowed: Set<String>, field: String
  ) throws {
    guard Set(object.keys).isSubset(of: allowed) else {
      throw BridgeError.invalidRequest("\(field) 包含不受支持的字段。")
    }
  }

  private static func responseFailureMessage(_ value: Any?) -> String {
    if let object = value as? [String: Any], let message = object["message"] as? String,
      !message.isEmpty
    {
      return "Copilot Responses 执行失败：\(message)"
    }
    return "Copilot Responses 执行失败。"
  }

  private static func protocolString(_ value: Any?, field: String) throws -> String {
    guard let value = value as? String else {
      throw BridgeError.protocolFailure("\(field) 必须是字符串。")
    }
    return value
  }

  private static func protocolNonemptyString(_ value: Any?, field: String) throws -> String {
    let result = try protocolString(value, field: field)
    guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BridgeError.protocolFailure("\(field) 不能为空。")
    }
    return result
  }

  private static func sseEvent(_ name: String, _ object: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw BridgeError.protocolFailure("Anthropic SSE 事件包含无法编码的 JSON 值。")
    }
    let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    var output = Data("event: \(name)\ndata: ".utf8)
    output.append(payload)
    output.append(Data("\n\n".utf8))
    return output
  }

  private static func optionalValue(_ value: Any?) -> Any? {
    guard let value, !(value is NSNull) else { return nil }
    return value
  }
}
