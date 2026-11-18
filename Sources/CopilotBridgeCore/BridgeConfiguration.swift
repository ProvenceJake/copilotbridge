import Foundation

public struct BridgeConfiguration: Sendable, Equatable {
  public var host: String
  public var port: Int
  public var localAPIKey: String
  public var maximumRequestBytes: Int
  public var maximumUpstreamResponseBytes: Int
  public var maximumSSELineBytes: Int
  public var maximumSSEEventBytes: Int
  public var upstreamBaseURL: URL
  public var modelAliases: [String: String]
  public var editorVersion: String
  public var editorPluginVersion: String
  public var userAgent: String
  public var integrationID: String

  public init(
    host: String = "127.0.0.1",
    port: Int = 4141,
    localAPIKey: String,
    maximumRequestBytes: Int = 4 * 1_024 * 1_024,
    maximumUpstreamResponseBytes: Int = 32 * 1_024 * 1_024,
    maximumSSELineBytes: Int = 4 * 1_024 * 1_024,
    maximumSSEEventBytes: Int = 8 * 1_024 * 1_024,
    upstreamBaseURL: URL = URL(string: "https://api.githubcopilot.com")!,
    modelAliases: [String: String] = [:],
    editorVersion: String = "vscode/1.95.0",
    editorPluginVersion: String = "copilot-chat/0.22.4",
    userAgent: String = "GitHubCopilotChat/0.22.4",
    integrationID: String = "vscode-chat"
  ) {
    self.host = host
    self.port = port
    self.localAPIKey = localAPIKey
    self.maximumRequestBytes = maximumRequestBytes
    self.maximumUpstreamResponseBytes = maximumUpstreamResponseBytes
    self.maximumSSELineBytes = maximumSSELineBytes
    self.maximumSSEEventBytes = maximumSSEEventBytes
    self.upstreamBaseURL = upstreamBaseURL
    self.modelAliases = modelAliases
    self.editorVersion = editorVersion
    self.editorPluginVersion = editorPluginVersion
    self.userAgent = userAgent
    self.integrationID = integrationID
  }

  public var endpoint: URL {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host.contains(":") ? "[\(host)]" : host
    components.port = port
    components.path = "/v1"
    guard let url = components.url else {
      preconditionFailure("无法从当前本地服务配置生成 endpoint URL。")
    }
    return url
  }
}

public enum BridgeEvent: Sendable, Equatable {
  case info(String)
  case warning(String)
  case error(String)
  case request(method: String, path: String, status: Int, milliseconds: Int)
}

public enum BridgeError: LocalizedError, Equatable {
  case missingGitHubToken
  case invalidConfiguration(String)
  case invalidRequest(String)
  case upstream(status: Int, message: String)
  case protocolFailure(String)

  public var errorDescription: String? {
    switch self {
    case .missingGitHubToken:
      return "尚未登录 GitHub Copilot。"
    case .invalidConfiguration(let message),
      .invalidRequest(let message),
      .protocolFailure(let message):
      return message
    case .upstream(let status, let message):
      return "Copilot 上游返回 HTTP \(status)：\(message)"
    }
  }
}
