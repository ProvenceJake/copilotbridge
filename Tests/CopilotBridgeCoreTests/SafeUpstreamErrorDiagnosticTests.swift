import Foundation
import XCTest

@testable import CopilotBridgeCore

final class SafeUpstreamErrorDiagnosticTests: XCTestCase {
  func testStreamDiagnosticsDistinguishConversionAndNetworkWithoutLoggingPayloads() {
    let protocolSummary = SafeUpstreamErrorDiagnostic.streamFailureSummary(
      error: BridgeError.protocolFailure("Responses sequence_number 无效 PRIVATE_PROMPT_SENTINEL"),
      upstreamPath: "responses", localRequestID: "request-stream-1")
    XCTAssertTrue(protocolSummary.contains("来源=代理流式校验"))
    XCTAssertTrue(protocolSummary.contains("原因=事件序号"))
    XCTAssertTrue(protocolSummary.contains("upstream=/responses"))
    XCTAssertTrue(protocolSummary.contains("request=request-stream-1"))
    XCTAssertFalse(protocolSummary.contains("PRIVATE_PROMPT_SENTINEL"))

    let networkSummary = SafeUpstreamErrorDiagnostic.streamFailureSummary(
      error: URLError(.networkConnectionLost),
      upstreamPath: "chat/completions", localRequestID: "request-stream-2")
    XCTAssertTrue(networkSummary.contains("来源=上游连接"))
    XCTAssertTrue(networkSummary.contains("URLSession -1005"))
  }

  func testProxyRecordsSafeSummaryForAnthropicUpstreamRejection() async throws {
    let localKey = "safe-log-local-key"
    let upstreamToken = "safe-log-upstream-token"
    let privateMessage = "PRIVATE_UPSTREAM_MESSAGE_SENTINEL"
    var upstreamServer: LocalHTTPServer?
    var upstreamPort = 0

    for _ in 0..<20 {
      let port = Int.random(in: 40_000...49_999)
      let server = LocalHTTPServer(
        configuration: BridgeConfiguration(port: port, localAPIKey: "unused")
      ) { request, responder in
        if request.path == "/chat/completions" {
          await responder.sendJSON(
            status: 400,
            object: [
              "error": [
                "type": "invalid_request_error",
                "code": "unsupported_parameter",
                "param": "max_tokens",
                "message": "max_tokens is unsupported: \(privateMessage)",
              ]
            ],
            extraHeaders: [("X-Request-ID", "req_safe_integration")])
        } else {
          await responder.sendJSON(status: 404, object: ["error": "not found"])
        }
      }
      do {
        try await server.start()
        upstreamServer = server
        upstreamPort = port
        break
      } catch {
        continue
      }
    }
    let upstream = try XCTUnwrap(upstreamServer)
    let recorder = SafeDiagnosticEventRecorder()
    let tokenManager = CopilotTokenManager(
      initialToken: CopilotAccessToken(
        value: upstreamToken,
        expiresAt: Date().addingTimeInterval(3_600),
        apiEndpoint: nil))
    var bridgeServer: ProxyServer?
    var bridgePort = 0
    for _ in 0..<20 {
      let port = Int.random(in: 50_000...59_999)
      let server = ProxyServer(
        configuration: BridgeConfiguration(
          port: port,
          localAPIKey: localKey,
          upstreamBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(upstreamPort)"))),
        tokenManager: tokenManager,
        onEvent: { recorder.record($0) })
      do {
        try await server.start()
        bridgeServer = server
        bridgePort = port
        break
      } catch {
        continue
      }
    }
    let bridge = try XCTUnwrap(bridgeServer)

    do {
      var request = URLRequest(
        url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(bridgePort)/v1/messages")))
      request.httpMethod = "POST"
      request.setValue(localKey, forHTTPHeaderField: "X-API-Key")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(
        withJSONObject: [
          "model": "gpt-mock",
          "max_tokens": 32,
          "messages": [["role": "user", "content": "private client body"]],
        ])
      let (_, response) = try await URLSession.shared.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

      let descriptions = recorder.snapshot().compactMap { event -> String? in
        guard case .warning(let message) = event else { return nil }
        return message
      }
      let summary = try XCTUnwrap(descriptions.first(where: { $0.contains("HTTP 400") }))
      XCTAssertTrue(summary.contains("code=unsupported_parameter"))
      XCTAssertTrue(summary.contains("param=max_tokens"))
      XCTAssertTrue(summary.contains("原因类别=max_tokens 参数"))
      XCTAssertTrue(summary.contains("upstream-request=req_safe_integration"))
      XCTAssertFalse(summary.contains(privateMessage))
      XCTAssertFalse(summary.contains("private client body"))
    } catch {
      await bridge.stop()
      await upstream.stop()
      throw error
    }
    await bridge.stop()
    await upstream.stop()
  }

  func testBuildsUsefulSummaryWithoutLoggingUpstreamMessage() throws {
    let secret = "PRIVATE_PROMPT_SENTINEL"
    let data = try JSONSerialization.data(
      withJSONObject: [
        "error": [
          "type": "invalid_request_error",
          "code": "invalid_parameter",
          "param": "max_tokens",
          "message": "max_tokens is not accepted; echoed value: \(secret)",
        ]
      ])

    let summary = SafeUpstreamErrorDiagnostic.summary(
      status: 400,
      data: data,
      headers: ["x-request-id": "req_upstream_123"],
      localRequestID: "b9ce23db-69ea-4548-8f69-d953a32e8bb9")

    XCTAssertTrue(summary.contains("HTTP 400"))
    XCTAssertTrue(summary.contains("type=invalid_request_error"))
    XCTAssertTrue(summary.contains("code=invalid_parameter"))
    XCTAssertTrue(summary.contains("param=max_tokens"))
    XCTAssertTrue(summary.contains("原因类别=max_tokens 参数"))
    XCTAssertTrue(summary.contains("upstream-request=req_upstream_123"))
    XCTAssertTrue(summary.contains("request=b9ce23db-69ea-4548-8f69-d953a32e8bb9"))
    XCTAssertFalse(summary.contains(secret))
    XCTAssertFalse(summary.contains("echoed value"))
  }

  func testRejectsUntrustedMetadataAndOnlyEmitsFixedCategory() throws {
    let secret = "CLIENT_SECRET_SENTINEL"
    let data = try JSONSerialization.data(
      withJSONObject: [
        "error": [
          "type": secret.lowercased(),
          "code": "sk-secret-value",
          "param": "private_prompt",
          "message": "tool input rejected: \(secret)",
        ]
      ])

    let summary = SafeUpstreamErrorDiagnostic.summary(
      status: 400,
      data: data,
      headers: ["request-id": "Bearer-\(secret)"],
      localRequestID: "local-request-1")

    XCTAssertEqual(
      summary,
      "Copilot 上游请求失败（HTTP 400；原因类别=工具调用参数；request=local-request-1）。")
    XCTAssertFalse(summary.lowercased().contains("secret"))
    XCTAssertFalse(summary.contains("private_prompt"))
  }

  func testIgnoresOversizedOrNonJSONBodies() {
    let summary = SafeUpstreamErrorDiagnostic.summary(
      status: 502,
      data: Data(repeating: 65, count: 64 * 1_024 + 1),
      headers: [:],
      localRequestID: "local-request-2")

    XCTAssertEqual(
      summary, "Copilot 上游请求失败（HTTP 502；request=local-request-2）。")
  }
}

private final class SafeDiagnosticEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [BridgeEvent] = []

  func record(_ event: BridgeEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  func snapshot() -> [BridgeEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}
