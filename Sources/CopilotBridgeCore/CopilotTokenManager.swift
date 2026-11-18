import Foundation

public struct CopilotAccessToken: Sendable, Equatable {
  public let value: String
  public let expiresAt: Date
  public let apiEndpoint: URL?
  public let quotaSnapshot: CopilotQuotaSnapshot?
  public let refreshedAt: Date?

  public init(
    value: String,
    expiresAt: Date,
    apiEndpoint: URL?,
    quotaSnapshot: CopilotQuotaSnapshot? = nil,
    refreshedAt: Date? = nil
  ) {
    self.value = value
    self.expiresAt = expiresAt
    self.apiEndpoint = apiEndpoint
    self.quotaSnapshot = quotaSnapshot
    self.refreshedAt = refreshedAt
  }
}

public actor CopilotTokenManager {
  private var cached: CopilotAccessToken?
  private var refreshGeneration: UInt64 = 0
  private var refreshOperation = SharedOperation<CopilotAccessToken>()
  private let oauthTokenLoader: @Sendable () throws -> String?
  private let exchangeToken: @Sendable (String) async throws -> CopilotAccessToken

  public init(
    session: URLSession = .shared,
    userAgent: String = "GitHubCopilotChat/0.22.4",
    editorVersion: String = "vscode/1.95.0",
    editorPluginVersion: String = "copilot-chat/0.22.4"
  ) {
    oauthTokenLoader = {
      try KeychainStore.read(account: KeychainStore.githubOAuthAccount)
    }
    exchangeToken = { oauthToken in
      try await Self.exchange(
        oauthToken: oauthToken,
        session: session,
        userAgent: userAgent,
        editorVersion: editorVersion,
        editorPluginVersion: editorPluginVersion
      )
    }
  }

  init(
    initialToken: CopilotAccessToken,
    session: URLSession = .shared,
    userAgent: String = "GitHubCopilotChat/0.22.4",
    editorVersion: String = "vscode/1.95.0",
    editorPluginVersion: String = "copilot-chat/0.22.4"
  ) {
    cached = initialToken
    oauthTokenLoader = {
      try KeychainStore.read(account: KeychainStore.githubOAuthAccount)
    }
    exchangeToken = { oauthToken in
      try await Self.exchange(
        oauthToken: oauthToken,
        session: session,
        userAgent: userAgent,
        editorVersion: editorVersion,
        editorPluginVersion: editorPluginVersion
      )
    }
  }

  init(
    oauthTokenLoader: @escaping @Sendable () throws -> String?,
    exchangeToken: @escaping @Sendable (String) async throws -> CopilotAccessToken
  ) {
    self.oauthTokenLoader = oauthTokenLoader
    self.exchangeToken = exchangeToken
  }

  public func accessToken(forceRefresh: Bool = false) async throws -> CopilotAccessToken {
    if !forceRefresh,
      let cached,
      cached.expiresAt.timeIntervalSinceNow > 90
    {
      return cached
    }
    let generation = refreshGeneration
    let refreshOperation = self.refreshOperation
    let oauthTokenLoader = self.oauthTokenLoader
    let exchangeToken = self.exchangeToken
    let result = try await refreshOperation.value {
      guard let oauthToken = try oauthTokenLoader(), !oauthToken.isEmpty else {
        throw BridgeError.missingGitHubToken
      }
      return try await exchangeToken(oauthToken)
    }
    guard refreshGeneration == generation else { throw CancellationError() }
    cached = result
    return result
  }

  public func invalidate(rejectedToken: String? = nil) async {
    if let rejectedToken, cached?.value != rejectedToken { return }
    refreshGeneration &+= 1
    cached = nil
    let invalidatedOperation = refreshOperation
    refreshOperation = SharedOperation()
    await invalidatedOperation.invalidate()
  }

  public func verify() async throws -> Date {
    try await accessToken(forceRefresh: true).expiresAt
  }

  func activeRefreshWaiterCount() async -> Int {
    await refreshOperation.waiterCount()
  }

  private static func exchange(
    oauthToken: String,
    session: URLSession,
    userAgent: String,
    editorVersion: String,
    editorPluginVersion: String
  ) async throws -> CopilotAccessToken {

    var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/v2/token")!)
    request.httpMethod = "GET"
    request.setValue("token \(oauthToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(editorVersion, forHTTPHeaderField: "Editor-Version")
    request.setValue(editorPluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")

    let (bytes, response) = try await session.bytes(
      for: request, delegate: RejectRedirectsDelegate.shared)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw BridgeError.upstream(status: status, message: "Copilot token exchange 失败。")
    }
    let data = try await CopilotClient.collect(bytes, response: http, limit: 1_048_576)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let token = json["token"] as? String,
      !token.isEmpty
    else {
      throw BridgeError.protocolFailure("Copilot token 响应缺少 token。")
    }

    let expiresAt: Date
    if let timestamp = json["expires_at"] as? TimeInterval {
      expiresAt = Date(timeIntervalSince1970: timestamp)
    } else if let timestamp = json["expires_at"] as? Int {
      expiresAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
    } else {
      expiresAt = Date().addingTimeInterval(25 * 60)
    }

    let endpointContainer = json["endpoints"] as? [String: Any]
    if json["endpoints"] != nil, endpointContainer == nil {
      throw BridgeError.protocolFailure("Copilot token 响应的 endpoints 格式无效。")
    }
    let endpoint = try CopilotEndpointPolicy.validatedAPIEndpoint(endpointContainer?["api"])
    let quotaSnapshot = (try? CopilotAccountService.parseQuota(data)).flatMap {
      $0.entries.isEmpty ? nil : $0
    }
    let result = CopilotAccessToken(
      value: token,
      expiresAt: expiresAt,
      apiEndpoint: endpoint,
      quotaSnapshot: quotaSnapshot,
      refreshedAt: .now
    )
    return result
  }
}
