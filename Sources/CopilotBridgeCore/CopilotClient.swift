import Foundation

struct CopilotDataResponse: Sendable {
  let status: Int
  let headers: [String: String]
  let data: Data
}

struct CopilotStreamResponse {
  let status: Int
  let headers: [String: String]
  let bytes: URLSession.AsyncBytes
}

final class CopilotClient: @unchecked Sendable {
  private let configuration: BridgeConfiguration
  private let tokens: CopilotTokenManager
  private let session: URLSession

  init(
    configuration: BridgeConfiguration,
    tokens: CopilotTokenManager,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.tokens = tokens
    self.session = session
  }

  func data(
    path: String,
    method: String = "POST",
    json: [String: Any]? = nil,
    timeoutInterval: TimeInterval = 600,
    additionalHeaders: [String: String] = [:]
  ) async throws
    -> CopilotDataResponse
  {
    var didRefresh = false
    while true {
      let token = try await tokens.accessToken(forceRefresh: didRefresh)
      let request = try makeRequest(
        path: path,
        method: method,
        json: json,
        stream: false,
        timeoutInterval: timeoutInterval,
        additionalHeaders: additionalHeaders,
        token: token)
      let (bytes, response) = try await session.bytes(
        for: request, delegate: RejectRedirectsDelegate.shared)
      guard let http = response as? HTTPURLResponse else {
        throw BridgeError.protocolFailure("Copilot 上游没有返回 HTTP 响应。")
      }
      if !didRefresh && (http.statusCode == 401 || http.statusCode == 403) {
        didRefresh = true
        await tokens.invalidate(rejectedToken: token.value)
        continue
      }
      let data = try await Self.collect(
        bytes,
        response: http,
        limit: configuration.maximumUpstreamResponseBytes
      )
      return CopilotDataResponse(
        status: http.statusCode,
        headers: Self.normalizedHeaders(http),
        data: data)
    }
  }

  static func collect(
    _ bytes: URLSession.AsyncBytes,
    response: HTTPURLResponse,
    limit: Int
  ) async throws -> Data {
    guard limit > 0 else {
      throw BridgeError.invalidConfiguration("上游响应读取限额必须大于 0。")
    }
    if response.expectedContentLength > Int64(limit) {
      throw BridgeError.protocolFailure("上游响应超过读取限额。")
    }

    var data = Data()
    if response.expectedContentLength > 0 {
      data.reserveCapacity(min(Int(response.expectedContentLength), limit))
    }
    let chunkSize = min(64 * 1_024, limit)
    var chunk: [UInt8] = []
    chunk.reserveCapacity(chunkSize)
    var receivedBytes = 0
    for try await byte in bytes {
      guard receivedBytes < limit else {
        throw BridgeError.protocolFailure("上游响应超过读取限额。")
      }
      receivedBytes += 1
      chunk.append(byte)
      if chunk.count == chunkSize {
        data.append(contentsOf: chunk)
        chunk.removeAll(keepingCapacity: true)
      }
    }
    if !chunk.isEmpty { data.append(contentsOf: chunk) }
    return data
  }

  func stream(
    path: String, json: [String: Any], additionalHeaders: [String: String] = [:]
  ) async throws -> CopilotStreamResponse {
    var didRefresh = false
    while true {
      let token = try await tokens.accessToken(forceRefresh: didRefresh)
      let request = try makeRequest(
        path: path,
        method: "POST",
        json: json,
        stream: true,
        timeoutInterval: 600,
        additionalHeaders: additionalHeaders,
        token: token)
      let (bytes, response) = try await session.bytes(
        for: request, delegate: RejectRedirectsDelegate.shared)
      guard let http = response as? HTTPURLResponse else {
        throw BridgeError.protocolFailure("Copilot 上游没有返回 HTTP 响应。")
      }
      if !didRefresh && (http.statusCode == 401 || http.statusCode == 403) {
        didRefresh = true
        await tokens.invalidate(rejectedToken: token.value)
        continue
      }
      return CopilotStreamResponse(
        status: http.statusCode, headers: Self.normalizedHeaders(http), bytes: bytes)
    }
  }

  private func makeRequest(
    path: String,
    method: String,
    json: [String: Any]?,
    stream: Bool,
    timeoutInterval: TimeInterval,
    additionalHeaders: [String: String],
    token: CopilotAccessToken
  ) throws -> URLRequest {
    let baseURL = token.apiEndpoint ?? configuration.upstreamBaseURL
    // appending a literal "/" before resolving a relative URL produces //models when
    // the configured base already ends with a slash. Append the endpoint only once.
    let url = baseURL.appendingPathComponent(
      path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeoutInterval
    request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
    request.setValue(
      stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(configuration.editorVersion, forHTTPHeaderField: "Editor-Version")
    request.setValue(configuration.editorPluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
    request.setValue(configuration.integrationID, forHTTPHeaderField: "Copilot-Integration-Id")
    request.setValue("conversation-panel", forHTTPHeaderField: "OpenAI-Intent")
    for (name, value) in additionalHeaders {
      let canonicalName: String
      switch name.lowercased() {
      case "anthropic-version": canonicalName = "Anthropic-Version"
      case "anthropic-beta": canonicalName = "Anthropic-Beta"
      case "x-initiator": canonicalName = "X-Initiator"
      default:
        throw BridgeError.invalidRequest("不允许向 Copilot 上游转发请求头 \(name)。")
      }
      guard !value.isEmpty, value.utf8.count <= 8 * 1_024,
        !value.utf8.contains(13), !value.utf8.contains(10)
      else {
        throw BridgeError.invalidRequest("上游请求头 \(canonicalName) 的值无效。")
      }
      request.setValue(value, forHTTPHeaderField: canonicalName)
    }
    if let json {
      do {
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
      } catch {
        throw BridgeError.invalidRequest("请求包含无法编码的 JSON 值。")
      }
    }
    return request
  }

  private static func normalizedHeaders(_ response: HTTPURLResponse) -> [String: String] {
    var result: [String: String] = [:]
    result.reserveCapacity(response.allHeaderFields.count)
    for (name, value) in response.allHeaderFields {
      result[String(describing: name).lowercased()] = String(describing: value)
    }
    return result
  }
}
