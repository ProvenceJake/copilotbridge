import Foundation

enum SafeUpstreamErrorDiagnostic {
  /// Only fixed categories are logged; error descriptions can contain model output or secrets.
  static func streamFailureSummary(
    error: any Error, upstreamPath: String, localRequestID: String
  ) -> String {
    let origin: String
    let reason: String
    if case .protocolFailure(let message) = error as? BridgeError {
      origin = "代理流式校验"
      let categories: [([String], String)] = [
        (["response id/model/status", "object/model/status", "response.id"], "响应状态或标识"),
        (["sequence_number"], "事件序号"),
        (["usage", "token 计数"], "用量字段"),
        (["arguments", "function_call"], "工具调用参数或事件顺序"),
        (["reasoning"], "推理事件"),
        (["超过", "上限"], "响应大小限制"),
        (["JSON", "SSE 数据"], "响应格式"),
        (["结束", "终止", "终态", "完成前"], "流提前结束或事件顺序"),
        (["item", "content", "delta"], "内容坐标或增量一致性"),
      ]
      reason = categories.first { $0.0.contains(where: message.contains) }?.1 ?? "协议兼容"
    } else if let urlError = error as? URLError {
      origin = "上游连接"
      reason = "URLSession \(urlError.code.rawValue)"
    } else {
      origin = "上游流或传输"
      reason = "流式请求失败"
    }
    let path =
      ["responses", "chat/completions", "v1/messages"].contains(upstreamPath)
      ? upstreamPath : "unknown"
    let requestID = safeRequestID(localRequestID) ?? "unknown"
    return "流式失败（来源=\(origin)；原因=\(reason)；upstream=/\(path)；request=\(requestID)）。"
  }

  static func summary(
    status: Int,
    data: Data,
    headers: [String: String],
    localRequestID: String
  ) -> String {
    let payload = parsedPayload(data)
    var details: [String] = []

    if let type = safeErrorIdentifier(payload.type) {
      details.append("type=\(type)")
    }
    if let code = safeErrorIdentifier(payload.code) {
      details.append("code=\(code)")
    }
    if let parameter = safeParameter(payload.parameter) {
      details.append("param=\(parameter)")
    }
    if let category = category(for: payload.message) {
      details.append("原因类别=\(category)")
    }
    if let upstreamRequestID = safeRequestID(headers["x-request-id"] ?? headers["request-id"]) {
      details.append("upstream-request=\(upstreamRequestID)")
    }
    if let requestID = safeRequestID(localRequestID) {
      details.append("request=\(requestID)")
    }

    guard !details.isEmpty else {
      return "Copilot 上游请求失败（HTTP \(status)）。"
    }
    return "Copilot 上游请求失败（HTTP \(status)；\(details.joined(separator: "；"))）。"
  }

  private static func parsedPayload(_ data: Data) -> Payload {
    guard data.count <= 64 * 1_024,
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return Payload()
    }
    let nested = root["error"] as? [String: Any]
    return Payload(
      type: nested?["type"] as? String ?? root["type"] as? String,
      code: nested?["code"] as? String ?? root["code"] as? String,
      parameter: nested?["param"] as? String ?? root["param"] as? String,
      message: nested?["message"] as? String
        ?? root["message"] as? String
        ?? root["error_description"] as? String
    )
  }

  private static func safeErrorIdentifier(_ value: String?) -> String? {
    guard let value, (1...64).contains(value.utf8.count), value == value.lowercased(),
      value.unicodeScalars.allSatisfy({ scalar in
        isASCIILetterOrDigit(scalar) || "._-".unicodeScalars.contains(scalar)
      })
    else {
      return nil
    }
    let semanticMarkers = [
      "error", "invalid", "unsupported", "missing", "required", "not_found", "rate_limit",
      "context_length", "model", "content", "quota", "billing", "authentication",
      "permission", "timeout", "overloaded",
    ]
    guard semanticMarkers.contains(where: value.contains), !looksSensitive(value) else {
      return nil
    }
    return value
  }

  private static func safeParameter(_ value: String?) -> String? {
    guard let value, (1...96).contains(value.utf8.count),
      value.unicodeScalars.allSatisfy({ scalar in
        isASCIILetterOrDigit(scalar) || "._-[]".unicodeScalars.contains(scalar)
      }),
      !looksSensitive(value)
    else {
      return nil
    }
    let root = value.split(whereSeparator: { $0 == "." || $0 == "[" }).first.map(String.init)
    let knownRoots: Set<String> = [
      "content", "frequency_penalty", "input", "max_completion_tokens", "max_tokens",
      "messages", "metadata", "model", "n", "output_config", "presence_penalty",
      "reasoning_effort", "response_format", "seed", "stop", "stream", "system",
      "temperature", "thinking", "tool_choice", "tools", "top_p", "user",
    ]
    guard let root, knownRoots.contains(root) else { return nil }
    return value
  }

  private static func safeRequestID(_ value: String?) -> String? {
    guard let value, (1...128).contains(value.utf8.count),
      value.unicodeScalars.allSatisfy({ scalar in
        isASCIILetterOrDigit(scalar) || "._:/-".unicodeScalars.contains(scalar)
      }),
      !looksSensitive(value)
    else {
      return nil
    }
    return value
  }

  private static func category(for message: String?) -> String? {
    guard let message else { return nil }
    let normalized = String(message.prefix(4_096)).lowercased()
    let categories: [([String], String)] = [
      (["max_tokens", "max tokens", "maximum tokens"], "max_tokens 参数"),
      (["context length", "context_length", "too many tokens", "too long"], "上下文长度"),
      (["response_format", "json schema", "json_schema"], "结构化输出参数"),
      (["tool", "function"], "工具调用参数"),
      (["image", "vision"], "图像输入"),
      (["temperature", "top_p", "top p", "stop sequence"], "采样参数"),
      (["stream"], "流式参数"),
      (["role", "messages", "message content", "content block"], "消息或角色格式"),
      (["model"], "模型或模型能力"),
      (["rate limit", "quota"], "速率或额度"),
      (["authentication", "unauthorized", "access token"], "上游认证"),
    ]
    return categories.first(where: { needles, _ in
      needles.contains(where: normalized.contains)
    })?.1
  }

  private static func looksSensitive(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    let markers = [
      "authorization", "bearer", "api_key", "api-key", "secret", "password", "github_pat_",
      "ghp_", "gho_", "ghu_", "ghs_", "sk-", "xox",
    ]
    return markers.contains(where: lowercased.contains)
  }

  private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 48...57, 65...90, 97...122: return true
    default: return false
    }
  }

  private struct Payload {
    var type: String?
    var code: String?
    var parameter: String?
    var message: String?
  }
}
