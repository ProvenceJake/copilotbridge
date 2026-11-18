import Foundation

public enum AnthropicCodec {
  private static let unsupportedTopLevelFields = [
    "container", "inference_geo", "mcp_servers", "user_profile_id", "workspace_id",
  ]

  public static func toOpenAI(
    _ request: [String: Any], resolvedModel: String? = nil
  ) throws -> [String: Any] {
    guard let model = request["model"] as? String, !model.isEmpty else {
      throw BridgeError.invalidRequest("Anthropic 请求缺少 model。")
    }
    guard let sourceMessages = request["messages"] as? [[String: Any]] else {
      throw BridgeError.invalidRequest("Anthropic 请求缺少 messages 数组。")
    }

    try rejectUnsupportedTopLevelFields(in: request)
    try validateIgnoredTopLevelFields(in: request)
    let stream = try validatedStream(request["stream"])
    let stopSequences = try validatedStopSequences(request["stop_sequences"])
    let metadata = try validatedMetadata(request["metadata"])
    let tools = try translatedTools(request["tools"])
    let thinking = try validatedThinking(request["thinking"])
    let responseFormat = try translatedOutputFormat(
      outputConfig: request["output_config"], legacyFormat: request["output_format"])
    try validateContextManagement(request["context_management"])

    var messages: [[String: Any]] = []
    let systemParts: [String] = try systemText(request["system"])
    if !systemParts.isEmpty {
      messages.append(["role": "system", "content": systemParts.joined(separator: "\n\n")])
    }

    for message in sourceMessages {
      guard let role = message["role"] as? String else {
        throw BridgeError.invalidRequest("Anthropic message 缺少 role。")
      }
      switch role {
      case "user":
        messages.append(contentsOf: try userMessages(from: message["content"]))
      case "assistant":
        messages.append(try assistantMessage(from: message["content"]))
      case "system":
        let parts = try systemText(message["content"])
        if !parts.isEmpty {
          messages.append(["role": "system", "content": parts.joined(separator: "\n\n")])
        }
      default:
        throw BridgeError.invalidRequest("不支持 Anthropic role：\(role)")
      }
    }

    var output: [String: Any] = [
      "model": model,
      "messages": messages,
      "stream": stream,
    ]
    if let rawMaxTokens = optionalValue(request["max_tokens"]) {
      guard let maxTokens = exactPositiveInteger(rawMaxTokens) else {
        throw BridgeError.invalidRequest("Anthropic max_tokens 必须是正整数。")
      }
      output["max_tokens"] = maxTokens
    }
    copy("temperature", from: request, to: &output)
    copy("top_p", from: request, to: &output)
    if isClaudeModel(resolvedModel ?? model), let thinking { output["thinking"] = thinking }
    if let stopSequences, !stopSequences.isEmpty { output["stop"] = stopSequences }
    if let userID = metadata?["user_id"] as? String {
      output["user"] = AnthropicMetadataUserIdentifier.upstreamValue(for: userID)
    }

    if let tools, !tools.isEmpty { output["tools"] = tools }
    if let responseFormat { output["response_format"] = responseFormat }

    if let rawChoice = optionalValue(request["tool_choice"]) {
      guard let choice = rawChoice as? [String: Any], let type = choice["type"] as? String else {
        throw BridgeError.invalidRequest("Anthropic tool_choice 必须是带 type 的对象。")
      }
      if let rawDisableParallel = optionalValue(choice["disable_parallel_tool_use"]) {
        guard let disableParallel = exactBool(rawDisableParallel) else {
          throw BridgeError.invalidRequest("tool_choice.disable_parallel_tool_use 必须是布尔值。")
        }
        output["parallel_tool_calls"] = !disableParallel
      }
      switch type {
      case "auto": output["tool_choice"] = "auto"
      case "any": output["tool_choice"] = "required"
      case "none": output["tool_choice"] = "none"
      case "tool":
        guard let name = choice["name"] as? String else {
          throw BridgeError.invalidRequest("tool_choice.type=tool 时必须提供 name。")
        }
        output["tool_choice"] = ["type": "function", "function": ["name": name]]
      default:
        throw BridgeError.invalidRequest("不支持 tool_choice.type：\(type)")
      }
    }
    guard JSONSerialization.isValidJSONObject(output) else {
      throw BridgeError.invalidRequest("Anthropic 请求包含无法编码的 JSON 值。")
    }
    return output
  }

  public static func fromOpenAI(_ response: [String: Any], requestedModel: String) throws
    -> [String: Any]
  {
    guard let first = (response["choices"] as? [[String: Any]])?.first,
      let message = first["message"] as? [String: Any],
      let reason = first["finish_reason"] as? String,
      ["stop", "length", "tool_calls", "content_filter", "refusal"].contains(reason)
    else {
      throw BridgeError.protocolFailure("Copilot 返回了不完整或无法识别的 Chat 响应。")
    }
    var content: [[String: Any]] = []

    let thinking = message["reasoning_text"] as? String
    let opaque = message["reasoning_opaque"] as? String
    if let thinking, !thinking.isEmpty {
      var block: [String: Any] = ["type": "thinking", "thinking": thinking]
      if let opaque, !opaque.isEmpty {
        block["signature"] = opaque
      }
      content.append(block)
    } else if let opaque, !opaque.isEmpty {
      content.append(["type": "redacted_thinking", "data": opaque])
    }
    if let text = message["content"] as? String, !text.isEmpty {
      content.append(["type": "text", "text": text])
    }
    if let refusal = message["refusal"] as? String, !refusal.isEmpty {
      content.append(["type": "text", "text": refusal])
    }
    let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
    guard (reason == "tool_calls") == !toolCalls.isEmpty else {
      throw BridgeError.protocolFailure("Copilot 返回了未完成的工具调用，已拒绝下发执行。")
    }
    for call in toolCalls {
      let function = call["function"] as? [String: Any] ?? [:]
      guard let id = call["id"] as? String, !id.isEmpty,
        let name = function["name"] as? String, !name.isEmpty,
        let raw = function["arguments"] as? String,
        let input = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
      else {
        throw BridgeError.protocolFailure("Copilot 返回了无效的工具调用参数，已拒绝下发执行。")
      }
      content.append([
        "type": "tool_use",
        "id": id,
        "name": name,
        "input": input,
      ])
    }

    let usage = response["usage"] as? [String: Any] ?? [:]
    let mappedStopReason: Any = stopReason(reason) ?? NSNull()
    return [
      "id": "msg_\(response["id"] as? String ?? shortID())",
      "type": "message",
      "role": "assistant",
      "model": response["model"] as? String ?? requestedModel,
      "content": content,
      "stop_reason": mappedStopReason,
      "stop_sequence": NSNull(),
      "usage": [
        "input_tokens": integer(usage["prompt_tokens"]),
        "output_tokens": integer(usage["completion_tokens"]),
      ],
    ]
  }

  public static func estimatedInputTokens(_ request: [String: Any]) throws -> Int {
    let converted = try toOpenAI(request)
    var estimate = 0
    for key in ["messages", "tools"] {
      guard let value = converted[key] else { continue }
      guard JSONSerialization.isValidJSONObject(value) else {
        throw BridgeError.invalidRequest("Anthropic 请求包含无法编码的 JSON 值。")
      }
      let data = try JSONSerialization.data(withJSONObject: value)
      estimate += conservativeTokenEstimate(String(decoding: data, as: UTF8.self))
    }
    return max(1, estimate)
  }

  private static func systemText(_ value: Any?) throws -> [String] {
    if value == nil || value is NSNull { return [] }
    if let text = value as? String, !text.isEmpty { return [text] }
    guard let blocks = value as? [[String: Any]] else {
      throw BridgeError.invalidRequest("Anthropic system 必须是字符串或 text block 数组。")
    }
    return try blocks.map { block in
      guard block["type"] as? String == "text", let text = block["text"] as? String else {
        throw BridgeError.invalidRequest("Anthropic system 只支持带 text 的 text block。")
      }
      return text
    }
  }

  private static func plainText(_ value: Any?) throws -> [String] {
    if let text = value as? String { return [text] }
    guard let blocks = value as? [[String: Any]] else {
      throw BridgeError.invalidRequest("tool_result content 必须是字符串或 block 数组。")
    }
    return try blocks.compactMap { block in
      switch block["type"] as? String {
      case "text", "thinking": return block["text"] as? String ?? block["thinking"] as? String
      case "tool_result":
        if let text = block["content"] as? String { return text }
        if let nested = block["content"] as? [[String: Any]] {
          return try plainText(nested).joined(separator: "\n")
        }
        throw BridgeError.invalidRequest("嵌套 tool_result 缺少可读 content。")
      case let type?:
        throw BridgeError.invalidRequest("tool_result content 不支持 \(type) block。")
      case nil:
        throw BridgeError.invalidRequest("tool_result content block 缺少 type。")
      }
    }
  }

  private static func userMessages(from value: Any?) throws -> [[String: Any]] {
    if let text = value as? String { return [["role": "user", "content": text]] }
    guard let blocks = value as? [[String: Any]] else {
      throw BridgeError.invalidRequest("Anthropic user content 必须是字符串或数组。")
    }
    var toolMessages: [[String: Any]] = []
    var parts: [[String: Any]] = []
    var textOnly: [String] = []
    var hasNonText = false

    for block in blocks {
      guard let type = block["type"] as? String else {
        throw BridgeError.invalidRequest("Anthropic user content block 缺少 type。")
      }
      switch type {
      case "text":
        let text = block["text"] as? String ?? ""
        textOnly.append(text)
        parts.append(["type": "text", "text": text])
      case "image":
        guard let source = block["source"] as? [String: Any],
          let sourceType = source["type"] as? String
        else {
          throw BridgeError.invalidRequest("Anthropic image 缺少 source。")
        }
        let url: String
        if sourceType == "url", let remote = source["url"] as? String {
          url = remote
        } else if sourceType == "base64", let data = source["data"] as? String {
          url = "data:\(source["media_type"] as? String ?? "image/png");base64,\(data)"
        } else {
          throw BridgeError.invalidRequest("不支持的 Anthropic image source。")
        }
        hasNonText = true
        parts.append(["type": "image_url", "image_url": ["url": url]])
      case "tool_result":
        guard let callID = block["tool_use_id"] as? String else {
          throw BridgeError.invalidRequest("tool_result 缺少 tool_use_id。")
        }
        let content: String
        if let text = block["content"] as? String {
          content = text
        } else if let nested = block["content"] as? [[String: Any]] {
          content = try plainText(nested).joined(separator: "\n")
        } else {
          throw BridgeError.invalidRequest("tool_result 缺少可读 content。")
        }
        toolMessages.append([
          "role": "tool",
          "tool_call_id": callID,
          "content": (block["is_error"] as? Bool == true ? "ERROR: " : "") + content,
        ])
      default:
        throw BridgeError.invalidRequest("user content 不支持 \(type) block。")
      }
    }
    if !parts.isEmpty {
      let content: Any = hasNonText ? parts : textOnly.joined(separator: "\n")
      toolMessages.append(["role": "user", "content": content])
    }
    return toolMessages
  }

  private static func assistantMessage(from value: Any?) throws -> [String: Any] {
    if let text = value as? String { return ["role": "assistant", "content": text] }
    guard let blocks = value as? [[String: Any]] else {
      throw BridgeError.invalidRequest("Anthropic assistant content 必须是字符串或数组。")
    }
    var text: [String] = []
    var toolCalls: [[String: Any]] = []
    var reasoning: [String] = []
    var signatures: [String] = []

    for block in blocks {
      switch block["type"] as? String {
      case "text": text.append(block["text"] as? String ?? "")
      case "thinking":
        guard let thinking = block["thinking"] as? String else {
          throw BridgeError.invalidRequest("thinking block 缺少 thinking 文本。")
        }
        reasoning.append(thinking)
        if let rawSignature = block["signature"] {
          guard let signature = rawSignature as? String else {
            throw BridgeError.invalidRequest("thinking.signature 必须是字符串。")
          }
          signatures.append(signature)
        }
      case "redacted_thinking":
        guard let data = block["data"] as? String else {
          throw BridgeError.invalidRequest("redacted_thinking block 缺少 data。")
        }
        signatures.append(data)
      case "tool_use":
        guard let id = block["id"] as? String, let name = block["name"] as? String else {
          throw BridgeError.invalidRequest("tool_use 缺少 id 或 name。")
        }
        let input: [String: Any]
        if block["input"] == nil {
          input = [:]
        } else {
          guard let object = block["input"] as? [String: Any],
            JSONSerialization.isValidJSONObject(object)
          else {
            throw BridgeError.invalidRequest("tool_use.input 必须是 JSON 对象。")
          }
          input = object
        }
        let data = try JSONSerialization.data(withJSONObject: input)
        toolCalls.append([
          "id": id,
          "type": "function",
          "function": ["name": name, "arguments": String(decoding: data, as: UTF8.self)],
        ])
      case let type?: throw BridgeError.invalidRequest("assistant content 不支持 \(type) block。")
      case nil: throw BridgeError.invalidRequest("Anthropic assistant content block 缺少 type。")
      }
    }
    guard signatures.count <= 1 else {
      throw BridgeError.invalidRequest(
        "单个 Chat assistant message 无法无损表示多个 Anthropic thinking 签名。")
    }
    let content: Any = text.isEmpty ? NSNull() : text.joined(separator: "\n")
    var message: [String: Any] = ["role": "assistant", "content": content]
    if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
    if !reasoning.isEmpty { message["reasoning_text"] = reasoning.joined() }
    if let signature = signatures.first { message["reasoning_opaque"] = signature }
    return message
  }

  static func exactPositiveInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
      return nil
    }
    let double = number.doubleValue
    guard double.isFinite, double > 0, double.rounded(.towardZero) == double else { return nil }
    if CFNumberIsFloatType(number) { return Int(exactly: double) }
    guard number.compare(NSNumber(value: Int.max)) != .orderedDescending else { return nil }
    let integer = number.int64Value
    guard integer > 0, number.compare(NSNumber(value: integer)) == .orderedSame else { return nil }
    return Int(integer)
  }

  static func exactNonnegativeInteger(_ value: Any?) -> Int? {
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

  private static func exactBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
      return nil
    }
    return number.boolValue
  }

  private static func rejectUnsupportedTopLevelFields(in request: [String: Any]) throws {
    guard
      let field = unsupportedTopLevelFields.first(where: {
        optionalValue(request[$0]) != nil
      })
    else { return }
    throw BridgeError.invalidRequest("Anthropic 字段 \(field) 无法无损转换。")
  }

  private static func validateIgnoredTopLevelFields(in request: [String: Any]) throws {
    try validateCacheControl(request["cache_control"], field: "cache_control")

    if let rawServiceTier = optionalValue(request["service_tier"]) {
      guard let serviceTier = rawServiceTier as? String,
        ["auto", "standard_only"].contains(serviceTier)
      else {
        throw BridgeError.invalidRequest(
          "Anthropic service_tier 仅支持 auto 或 standard_only。")
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
    try requireOnlyKeys(object, allowed: ["type", "ttl"], field: field)
    guard object["type"] as? String == "ephemeral" else {
      throw BridgeError.invalidRequest("\(field).type 仅支持 ephemeral。")
    }
    if let rawTTL = optionalValue(object["ttl"]) {
      guard let ttl = rawTTL as? String, ["5m", "1h"].contains(ttl) else {
        throw BridgeError.invalidRequest("\(field).ttl 仅支持 5m 或 1h。")
      }
    }
  }

  private static func validatedStream(_ value: Any?) throws -> Bool {
    guard let value = optionalValue(value) else { return false }
    guard let stream = exactBool(value) else {
      throw BridgeError.invalidRequest("Anthropic stream 必须是布尔值。")
    }
    return stream
  }

  private static func validatedStopSequences(_ value: Any?) throws -> [String]? {
    guard let value = optionalValue(value) else { return nil }
    guard let stopSequences = value as? [String] else {
      throw BridgeError.invalidRequest("Anthropic stop_sequences 必须是字符串数组。")
    }
    return stopSequences
  }

  private static func validatedMetadata(_ value: Any?) throws -> [String: Any]? {
    guard let value = optionalValue(value) else { return nil }
    guard let metadata = value as? [String: Any] else {
      throw BridgeError.invalidRequest("Anthropic metadata 必须是对象。")
    }
    if let userID = optionalValue(metadata["user_id"]), !(userID is String) {
      throw BridgeError.invalidRequest("metadata.user_id 必须是字符串。")
    }
    return metadata
  }

  private static func translatedTools(_ value: Any?) throws -> [[String: Any]]? {
    guard let value = optionalValue(value) else { return nil }
    guard let tools = value as? [[String: Any]] else {
      throw BridgeError.invalidRequest("Anthropic tools 必须是对象数组。")
    }
    return try tools.compactMap { tool in
      var isToolSearchMetadata = false
      if let rawType = optionalValue(tool["type"]) {
        guard let type = rawType as? String else {
          throw BridgeError.invalidRequest("Anthropic tool.type 必须是字符串。")
        }
        isToolSearchMetadata = type.hasPrefix("tool_search_tool_")
        guard type == "custom" || isToolSearchMetadata else {
          throw BridgeError.invalidRequest("Anthropic tool.type 仅支持 custom。")
        }
      }

      for field in ["defer_loading", "eager_input_streaming"] {
        if let rawValue = optionalValue(tool[field]), exactBool(rawValue) == nil {
          throw BridgeError.invalidRequest("Anthropic tool.\(field) 必须是布尔值。")
        }
      }
      if let rawExamples = optionalValue(tool["input_examples"]) {
        guard let examples = rawExamples as? [[String: Any]],
          JSONSerialization.isValidJSONObject(examples)
        else {
          throw BridgeError.invalidRequest("Anthropic tool.input_examples 必须是 JSON 对象数组。")
        }
      }
      if let rawCallers = optionalValue(tool["allowed_callers"]) {
        guard let callers = rawCallers as? [String], callers.contains("direct") else {
          throw BridgeError.invalidRequest(
            "Anthropic tool.allowed_callers 必须包含 direct。")
        }
      }
      if isToolSearchMetadata { return nil }

      guard let name = tool["name"] as? String,
        let schema = tool["input_schema"] as? [String: Any]
      else {
        throw BridgeError.invalidRequest("Anthropic tool 缺少 name 或 input_schema。")
      }
      var function: [String: Any] = ["name": name, "parameters": schema]
      if let description = tool["description"] as? String {
        function["description"] = description
      }
      if let rawStrict = optionalValue(tool["strict"]) {
        guard let strict = exactBool(rawStrict) else {
          throw BridgeError.invalidRequest("Anthropic tool.strict 必须是布尔值。")
        }
        function["strict"] = strict
      }
      return ["type": "function", "function": function]
    }
  }

  private static func validatedThinking(_ value: Any?) throws -> [String: Any]? {
    guard let value = optionalValue(value) else { return nil }
    guard let object = value as? [String: Any], let type = object["type"] as? String else {
      throw BridgeError.invalidRequest("Anthropic thinking 必须是带 type 的对象。")
    }

    switch type {
    case "adaptive":
      try requireOnlyKeys(
        object, allowed: ["type", "display", "block_binding"], field: "thinking")
      try validateThinkingDisplay(object["display"])
    case "enabled":
      try requireOnlyKeys(
        object, allowed: ["type", "budget_tokens", "display", "block_binding"],
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
    return object.filter { key, value in
      key != "block_binding" && !(value is NSNull)
    }
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
    guard let behavior = rawBehavior as? String,
      ["error", "drop_block"].contains(behavior)
    else {
      throw BridgeError.invalidRequest(
        "thinking.block_binding.prefix_mismatch_behavior 仅支持 error 或 drop_block。")
    }
  }

  private static func translatedOutputFormat(outputConfig: Any?, legacyFormat: Any?) throws
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
    try requireOnlyKeys(format, allowed: ["type", "schema"], field: "output_config.format")
    guard format["type"] as? String == "json_schema",
      let schema = format["schema"] as? [String: Any],
      JSONSerialization.isValidJSONObject(schema)
    else {
      throw BridgeError.invalidRequest(
        "output_config.format 仅支持带有效 schema 的 json_schema。")
    }
    return [
      "type": "json_schema",
      "json_schema": [
        "name": "anthropic_output",
        "strict": true,
        "schema": schema,
      ],
    ]
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
        try requireOnlyKeys(edit, allowed: ["type", "keep"], field: field)
        guard edit["keep"] as? String == "all" else {
          throw BridgeError.invalidRequest(
            "\(field) 仅支持 clear_thinking_20251015 + keep=all。")
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
        "type", "trigger", "keep", "clear_at_least", "clear_tool_inputs", "exclude_tools",
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

  private static func requireOnlyKeys(
    _ object: [String: Any], allowed: Set<String>, field: String
  ) throws {
    guard Set(object.keys).isSubset(of: allowed) else {
      throw BridgeError.invalidRequest("\(field) 包含不受支持的字段。")
    }
  }

  static func isClaudeModel(_ model: String) -> Bool {
    let normalized = model.lowercased()
    return normalized.hasPrefix("claude-") || normalized.hasPrefix("anthropic/claude-")
  }

  private static func copy(
    _ key: String, from source: [String: Any], to destination: inout [String: Any]
  ) {
    if let value = optionalValue(source[key]) { destination[key] = value }
  }

  private static func optionalValue(_ value: Any?) -> Any? {
    guard let value, !(value is NSNull) else { return nil }
    return value
  }

  static func stopReason(_ reason: String?) -> String? {
    switch reason {
    case "tool_calls": return "tool_use"
    case "length": return "max_tokens"
    case "content_filter", "refusal": return "refusal"
    case "stop": return "end_turn"
    case .some: return "end_turn"
    case .none: return nil
    }
  }

  static func integer(_ value: Any?) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return 0
  }

  static func shortID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
  }

  private static func conservativeTokenEstimate(_ text: String) -> Int {
    var asciiScalars = 0
    var nonASCIIScalars = 0
    for scalar in text.unicodeScalars {
      if scalar.isASCII {
        asciiScalars += 1
      } else {
        nonASCIIScalars += 1
      }
    }
    return Int(ceil(Double(asciiScalars) / 4.0)) + nonASCIIScalars
  }
}
