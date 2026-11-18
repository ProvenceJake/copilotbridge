import Foundation

enum CopilotEndpointPolicy {
  static func validatedAPIEndpoint(_ value: Any?) throws -> URL? {
    guard let value else { return nil }
    guard let raw = value as? String, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty,
      !raw.contains("%"),
      !raw.contains("\\"),
      !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      var components = URLComponents(string: raw),
      components.scheme?.lowercased() == "https",
      let rawHost = components.host,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.port == nil || components.port == 443,
      components.path.isEmpty || components.path == "/"
    else {
      throw BridgeError.protocolFailure("Copilot token 响应包含不安全的 API endpoint。")
    }

    let host = rawHost.lowercased()
    guard isAllowedHost(host) else {
      throw BridgeError.protocolFailure("Copilot token 响应包含未获准的 API endpoint。")
    }

    components.scheme = "https"
    components.host = host
    components.path = ""
    guard let url = components.url, url.host?.lowercased() == host else {
      throw BridgeError.protocolFailure("Copilot token 响应包含无效的 API endpoint。")
    }
    return url
  }

  private static func isAllowedHost(_ host: String) -> Bool {
    guard validDNSName(host) else { return false }
    if host == "copilot-proxy.githubusercontent.com" { return true }
    if host.hasSuffix(".githubcopilot.com") && host != "githubcopilot.com" { return true }

    let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count == 4, labels[2] == "ghe", labels[3] == "com" else { return false }
    return labels[0] == "copilot-api" || labels[0] == "copilot-proxy"
  }

  private static func validDNSName(_ host: String) -> Bool {
    guard !host.isEmpty, host.count <= 253, !host.hasPrefix("."), !host.hasSuffix(".") else {
      return false
    }
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-" else {
        return false
      }
      return label.utf8.allSatisfy {
        ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
      }
    }
  }
}

final class RejectRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  static let shared = RejectRedirectsDelegate()

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
