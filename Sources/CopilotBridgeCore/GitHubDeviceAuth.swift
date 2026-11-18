import Foundation

public struct DeviceAuthorization: Sendable, Equatable {
  public let deviceCode: String
  public let userCode: String
  public let verificationURL: URL
  public let expiresIn: Int
  public let interval: Int

  public init(
    deviceCode: String, userCode: String, verificationURL: URL, expiresIn: Int, interval: Int
  ) {
    self.deviceCode = deviceCode
    self.userCode = userCode
    self.verificationURL = verificationURL
    self.expiresIn = expiresIn
    self.interval = interval
  }
}

struct GitHubAuthRetryPolicy: Sendable {
  let requestCodeMaximumAttempts: Int
  let requestCodeBaseDelay: TimeInterval
  let requestCodeRetryBudget: TimeInterval
  let maximumPollBackoff: TimeInterval

  static let live = GitHubAuthRetryPolicy(
    requestCodeMaximumAttempts: 4,
    requestCodeBaseDelay: 0.5,
    requestCodeRetryBudget: 30,
    maximumPollBackoff: 60)
}

struct GitHubAuthTiming: Sendable {
  let monotonicNow: @Sendable () -> TimeInterval
  let wallNow: @Sendable () -> Date
  let sleep: @Sendable (TimeInterval) async throws -> Void

  static let live = GitHubAuthTiming(
    monotonicNow: { ProcessInfo.processInfo.systemUptime },
    wallNow: { Date() },
    sleep: { delay in
      try await Task.sleep(for: .seconds(delay))
    })
}

public actor GitHubDeviceAuth {
  // Public OAuth client ID used by GitHub Copilot Chat in VS Code. It is
  // configurable so a build can use its own device-flow-enabled OAuth app.
  public static let copilotChatClientID = "Iv1.b507a08c87ecfe98"

  private static let maximumResponseBytes = 1_048_576
  private static let maximumExpiresIn = 86_400
  private static let maximumServerInterval = 3_600

  private let session: URLSession
  private let clientID: String
  private let userAgent: String
  private let retryPolicy: GitHubAuthRetryPolicy
  private let timing: GitHubAuthTiming

  public init(
    clientID: String = GitHubDeviceAuth.copilotChatClientID,
    userAgent: String = BridgeVersion.userAgent,
    session: URLSession = .shared
  ) {
    self.clientID = clientID
    self.userAgent = userAgent
    self.session = session
    retryPolicy = .live
    timing = .live
  }

  init(
    clientID: String = GitHubDeviceAuth.copilotChatClientID,
    userAgent: String = BridgeVersion.userAgent,
    session: URLSession,
    retryPolicy: GitHubAuthRetryPolicy,
    timing: GitHubAuthTiming
  ) {
    self.clientID = clientID
    self.userAgent = userAgent
    self.session = session
    self.retryPolicy = retryPolicy
    self.timing = timing
  }

  public func requestCode() async throws -> DeviceAuthorization {
    try Task.checkCancellation()
    let request = try makeRequest(
      url: URL(string: "https://github.com/login/device/code")!,
      fields: [
        ("client_id", clientID),
        ("scope", "read:user"),
      ])
    let retryDeadline = timing.monotonicNow() + max(retryPolicy.requestCodeRetryBudget, 0)
    let maximumAttempts = max(retryPolicy.requestCodeMaximumAttempts, 1)

    for attempt in 1...maximumAttempts {
      try Task.checkCancellation()
      do {
        let (response, data) = try await sendBounded(request)
        if Self.isRetryable(response) {
          guard attempt < maximumAttempts else {
            throw Self.upstreamError(response, operation: "GitHub device/code")
          }
          let delay = max(
            Self.exponentialDelay(base: retryPolicy.requestCodeBaseDelay, exponent: attempt - 1),
            Self.retryAfterDelay(response, now: timing.wallNow()) ?? 0)
          guard canWait(delay, before: retryDeadline) else {
            throw Self.upstreamError(response, operation: "GitHub device/code")
          }
          try await timing.sleep(delay)
          try Task.checkCancellation()
          continue
        }

        try Self.requireSuccess(response, operation: "GitHub device/code")
        let json = try Self.object(data)
        return try Self.authorization(from: json)
      } catch {
        if Self.isCancellation(error) { throw CancellationError() }
        guard Self.isTransientTransport(error), attempt < maximumAttempts else { throw error }
        let delay = Self.exponentialDelay(
          base: retryPolicy.requestCodeBaseDelay, exponent: attempt - 1)
        guard canWait(delay, before: retryDeadline) else { throw error }
        try await timing.sleep(delay)
        try Task.checkCancellation()
      }
    }

    preconditionFailure("GitHub device/code retry loop exhausted unexpectedly")
  }

  public func pollForToken(_ authorization: DeviceAuthorization) async throws -> String {
    try Task.checkCancellation()
    guard authorization.expiresIn > 0, authorization.expiresIn <= Self.maximumExpiresIn,
      authorization.interval > 0,
      authorization.interval <= Self.maximumServerInterval
    else {
      throw BridgeError.protocolFailure("GitHub 设备登录参数无效，请重新登录。")
    }

    let deadline = timing.monotonicNow() + TimeInterval(authorization.expiresIn)
    var protocolInterval = TimeInterval(authorization.interval)
    var nextDelay = protocolInterval
    var consecutiveTransientFailures = 0
    let request = try makeRequest(
      url: URL(string: "https://github.com/login/oauth/access_token")!,
      fields: [
        ("client_id", clientID),
        ("device_code", authorization.deviceCode),
        ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
      ])

    while true {
      try Task.checkCancellation()
      guard canWait(nextDelay, before: deadline) else {
        throw BridgeError.protocolFailure("GitHub 设备登录超时，请重新登录。")
      }
      try await timing.sleep(nextDelay)
      try Task.checkCancellation()

      let response: HTTPURLResponse
      let data: Data
      do {
        (response, data) = try await sendBounded(request)
      } catch {
        if Self.isCancellation(error) { throw CancellationError() }
        guard Self.isTransientTransport(error) else { throw error }
        consecutiveTransientFailures += 1
        nextDelay = Self.pollRetryDelay(
          protocolInterval: protocolInterval,
          failureCount: consecutiveTransientFailures,
          retryAfter: nil,
          maximum: retryPolicy.maximumPollBackoff)
        continue
      }

      if Self.isRetryable(response) {
        consecutiveTransientFailures += 1
        nextDelay = Self.pollRetryDelay(
          protocolInterval: protocolInterval,
          failureCount: consecutiveTransientFailures,
          retryAfter: Self.retryAfterDelay(response, now: timing.wallNow()),
          maximum: retryPolicy.maximumPollBackoff)
        continue
      }

      let json: [String: Any]
      if response.statusCode == 400 {
        guard let parsed = try? Self.object(data) else {
          throw Self.upstreamError(response, operation: "GitHub access_token")
        }
        json = parsed
      } else {
        try Self.requireSuccess(response, operation: "GitHub access_token")
        json = try Self.object(data)
      }
      consecutiveTransientFailures = 0

      if (200..<300).contains(response.statusCode),
        let token = json["access_token"] as? String, !token.isEmpty
      {
        return token
      }

      switch json["error"] as? String {
      case "authorization_pending":
        nextDelay = protocolInterval
      case "slow_down":
        let returnedInterval = try Self.optionalInterval(json["interval"])
        protocolInterval = max(protocolInterval + 5, returnedInterval ?? 0)
        nextDelay = protocolInterval
      case "expired_token":
        throw BridgeError.protocolFailure("GitHub 登录码已过期，请重新登录。")
      case "access_denied":
        throw BridgeError.protocolFailure("GitHub 登录已取消。")
      case "incorrect_client_credentials":
        throw BridgeError.protocolFailure("GitHub OAuth 客户端配置无效。")
      case "incorrect_device_code":
        throw BridgeError.protocolFailure("GitHub 设备登录码无效，请重新登录。")
      case "device_flow_disabled":
        throw BridgeError.protocolFailure("此 GitHub OAuth 应用未启用设备登录。")
      case _?:
        throw BridgeError.protocolFailure("GitHub 登录失败，远端返回了未支持的 OAuth 错误。")
      case nil:
        throw BridgeError.protocolFailure("GitHub 登录返回了无法识别的响应。")
      }
    }
  }

  private func makeRequest(url: URL, fields: [(String, String)]) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = try Self.formBody(fields)
    return request
  }

  private func sendBounded(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
    let (bytes, response) = try await session.bytes(
      for: request, delegate: RejectRedirectsDelegate.shared)
    guard let http = response as? HTTPURLResponse else {
      throw BridgeError.protocolFailure("GitHub 没有返回 HTTP 响应。")
    }
    let data = try await CopilotClient.collect(
      bytes, response: http, limit: Self.maximumResponseBytes)
    return (http, data)
  }

  private func canWait(_ delay: TimeInterval, before deadline: TimeInterval) -> Bool {
    delay.isFinite && delay >= 0 && timing.monotonicNow() + delay < deadline
  }

  private static func authorization(from json: [String: Any]) throws -> DeviceAuthorization {
    guard let deviceCode = json["device_code"] as? String, !deviceCode.isEmpty,
      let userCode = json["user_code"] as? String, !userCode.isEmpty,
      let uri = json["verification_uri"] as? String,
      let url = URL(string: uri),
      url.scheme?.lowercased() == "https",
      url.host?.lowercased() == "github.com",
      url.user == nil,
      url.password == nil,
      let expiresIn = json["expires_in"] as? Int,
      expiresIn > 0,
      expiresIn <= maximumExpiresIn
    else {
      throw BridgeError.protocolFailure("GitHub device/code 响应缺少必要字段。")
    }

    let interval: Int
    if let rawInterval = json["interval"] {
      guard let value = rawInterval as? Int, value > 0, value <= maximumServerInterval else {
        throw BridgeError.protocolFailure("GitHub device/code 响应的轮询间隔无效。")
      }
      interval = value
    } else {
      interval = 5
    }

    return DeviceAuthorization(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationURL: url,
      expiresIn: expiresIn,
      interval: interval)
  }

  private static func optionalInterval(_ raw: Any?) throws -> TimeInterval? {
    guard let raw else { return nil }
    guard let value = raw as? Int, value > 0, value <= maximumServerInterval else {
      throw BridgeError.protocolFailure("GitHub access_token 响应的轮询间隔无效。")
    }
    return TimeInterval(value)
  }

  private static func formBody(_ fields: [(String, String)]) throws -> Data {
    let encoded = fields.map {
      "\(formComponent($0.0))=\(formComponent($0.1))"
    }.joined(separator: "&")
    return Data(encoded.utf8)
  }

  /// HTML form encoding differs from an ordinary URL query: a literal `+`
  /// must be escaped because `+` represents a space to form decoders.
  private static func formComponent(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.utf8.count)
    let hexadecimal = Array("0123456789ABCDEF".utf8)
    for byte in value.utf8 {
      switch byte {
      case 65...90, 97...122, 48...57, 42, 45, 46, 95:
        result.unicodeScalars.append(UnicodeScalar(byte))
      case 32:
        result.append("+")
      default:
        result.append("%")
        result.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte >> 4)]))
        result.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte & 0x0F)]))
      }
    }
    return result
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BridgeError.protocolFailure("远端返回的不是 JSON 对象。")
    }
    return json
  }

  private static func requireSuccess(_ response: HTTPURLResponse, operation: String) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw upstreamError(response, operation: operation)
    }
  }

  private static func upstreamError(_ response: HTTPURLResponse, operation: String) -> BridgeError {
    BridgeError.upstream(status: response.statusCode, message: "\(operation) 失败。")
  }

  private static func isRetryable(_ response: HTTPURLResponse) -> Bool {
    switch response.statusCode {
    case 408, 429, 500, 502, 503, 504:
      return true
    case 403:
      return response.value(forHTTPHeaderField: "Retry-After") != nil
        || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
    default:
      return false
    }
  }

  private static func retryAfterDelay(
    _ response: HTTPURLResponse, now: Date
  ) -> TimeInterval? {
    guard
      let raw = response.value(forHTTPHeaderField: "Retry-After")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else { return nil }

    if raw.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
      guard let seconds = TimeInterval(raw), seconds.isFinite else { return .infinity }
      return seconds
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    guard let date = formatter.date(from: raw) else { return nil }
    return max(0, date.timeIntervalSince(now))
  }

  private static func exponentialDelay(base: TimeInterval, exponent: Int) -> TimeInterval {
    guard base > 0, base.isFinite else { return 0 }
    return base * pow(2, Double(min(max(exponent, 0), 20)))
  }

  private static func pollRetryDelay(
    protocolInterval: TimeInterval,
    failureCount: Int,
    retryAfter: TimeInterval?,
    maximum: TimeInterval
  ) -> TimeInterval {
    let configuredMaximum = max(maximum, protocolInterval)
    let backedOff = min(
      configuredMaximum,
      exponentialDelay(base: protocolInterval, exponent: failureCount))
    return max(protocolInterval, backedOff, retryAfter ?? 0)
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError || Task.isCancelled { return true }
    return urlErrorCode(error) == .cancelled
  }

  private static func isTransientTransport(_ error: Error) -> Bool {
    guard let code = urlErrorCode(error) else { return false }
    switch code {
    case .secureConnectionFailed,
      .timedOut,
      .cannotFindHost,
      .cannotConnectToHost,
      .dnsLookupFailed,
      .networkConnectionLost,
      .notConnectedToInternet,
      .resourceUnavailable:
      return true
    default:
      return false
    }
  }

  private static func urlErrorCode(_ error: Error) -> URLError.Code? {
    if let urlError = error as? URLError { return urlError.code }
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return nil }
    return URLError.Code(rawValue: nsError.code)
  }
}
