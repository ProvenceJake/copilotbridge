import Foundation
import XCTest

@testable import CopilotBridgeCore

/// Opt-in smoke coverage for the complete local bridge -> Copilot data path.
///
/// Normal `swift test` runs skip this suite. A maintainer can exchange a fresh,
/// short-lived Copilot token outside the test process and provide it through the
/// environment. The test never prints credentials or response bodies.
final class LiveUpstreamTests: XCTestCase {
  /// Opt-in check for the real GitHub device-code endpoint. It deliberately
  /// stops before browser authorization and never prints either returned code.
  func testLiveGitHubDeviceCodeRequest() async throws {
    guard ProcessInfo.processInfo.environment["COPILOT_BRIDGE_RUN_LIVE_OAUTH_TESTS"] == "1"
    else {
      throw XCTSkip(
        "Set COPILOT_BRIDGE_RUN_LIVE_OAUTH_TESTS=1 to test GitHub device-code acquisition.")
    }

    let authorization = try await GitHubDeviceAuth(
      userAgent: "\(BridgeVersion.userAgent) live-auth-smoke"
    ).requestCode()
    XCTAssertFalse(authorization.deviceCode.isEmpty)
    XCTAssertFalse(authorization.userCode.isEmpty)
    XCTAssertEqual(authorization.verificationURL.host, "github.com")
    XCTAssertGreaterThan(authorization.expiresIn, 0)
    XCTAssertGreaterThan(authorization.interval, 0)
  }

  func testLiveModelsResponsesAndAnthropicStream() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["COPILOT_BRIDGE_RUN_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set COPILOT_BRIDGE_RUN_LIVE_TESTS=1 to run live Copilot smoke tests.")
    }
    guard
      let accessToken = environment["COPILOT_BRIDGE_LIVE_ACCESS_TOKEN"],
      !accessToken.isEmpty,
      let endpointValue = environment["COPILOT_BRIDGE_LIVE_API_ENDPOINT"]
    else {
      XCTFail("Live tests require a short-lived token and its API endpoint.")
      return
    }
    let endpoint = try XCTUnwrap(try CopilotEndpointPolicy.validatedAPIEndpoint(endpointValue))

    let responsesModel = environment["COPILOT_BRIDGE_LIVE_RESPONSES_MODEL"] ?? "gpt-5.6-luna"
    let chatModel = environment["COPILOT_BRIDGE_LIVE_CHAT_MODEL"] ?? "gpt-4o"
    let localKey = "copilotbridge-live-smoke-local-key"
    let manager = CopilotTokenManager(
      initialToken: CopilotAccessToken(
        value: accessToken,
        expiresAt: Date().addingTimeInterval(10 * 60),
        apiEndpoint: endpoint
      ))

    var runningServer: ProxyServer?
    var selectedPort = 0
    for _ in 0..<20 {
      let port = Int.random(in: 50_000...59_999)
      let candidate = ProxyServer(
        configuration: BridgeConfiguration(port: port, localAPIKey: localKey),
        tokenManager: manager
      )
      do {
        try await candidate.start()
        runningServer = candidate
        selectedPort = port
        break
      } catch {
        continue
      }
    }
    let server = try XCTUnwrap(runningServer, "Could not find a free live-test port")

    do {
      let catalog = try await Self.request(
        path: "/v1/models?client_version=0.153.4",
        port: selectedPort,
        bearer: localKey
      )
      XCTAssertEqual(catalog.status, 200)
      let catalogObject = try Self.jsonObject(catalog.data)
      XCTAssertFalse((catalogObject["models"] as? [[String: Any]])?.isEmpty ?? true)

      let responses = try await Self.request(
        path: "/v1/responses",
        port: selectedPort,
        method: "POST",
        bearer: localKey,
        json: [
          "model": responsesModel,
          "input": "Reply with exactly LIVE_RESPONSES_OK.",
          "max_output_tokens": 32,
          "stream": false,
        ])
      XCTAssertEqual(responses.status, 200)
      let responseObject = try Self.jsonObject(responses.data)
      XCTAssertEqual(responseObject["object"] as? String, "response")
      XCTAssertEqual(responseObject["status"] as? String, "completed")

      let anthropic = try await Self.request(
        path: "/anthropic/v1/messages",
        port: selectedPort,
        method: "POST",
        bearer: localKey,
        json: [
          "model": chatModel,
          "max_tokens": 32,
          "stream": true,
          "messages": [["role": "user", "content": "Reply with exactly LIVE_CLAUDE_OK."]],
        ])
      XCTAssertEqual(anthropic.status, 200)
      let events = String(decoding: anthropic.data, as: UTF8.self)
      XCTAssertTrue(events.contains("event: message_start"))
      XCTAssertTrue(events.contains("event: message_stop"))
      XCTAssertFalse(events.contains("event: error"))
    } catch {
      await server.stop()
      throw error
    }
    await server.stop()
  }

  private static func request(
    path: String,
    port: Int,
    method: String = "GET",
    bearer: String,
    json: [String: Any]? = nil
  ) async throws -> (status: Int, data: Data) {
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = port
    let relative = try XCTUnwrap(URLComponents(string: path))
    components.path = relative.path
    components.percentEncodedQuery = relative.percentEncodedQuery

    var request = URLRequest(url: try XCTUnwrap(components.url))
    request.httpMethod = method
    request.timeoutInterval = 90
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    if let json {
      request.httpBody = try JSONSerialization.data(withJSONObject: json)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
  }

  private static func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
