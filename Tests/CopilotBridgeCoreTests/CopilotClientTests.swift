import Foundation
import XCTest

@testable import CopilotBridgeCore

final class CopilotClientTests: XCTestCase {
  func testUpstreamBaseURLJoinsEndpointOnceWithAndWithoutTrailingSlash() async throws {
    var upstream: LocalHTTPServer?
    var port = 0
    for _ in 0..<20 {
      port = Int.random(in: 40_000...49_999)
      let candidate = LocalHTTPServer(
        configuration: BridgeConfiguration(port: port, localAPIKey: "unused")
      ) { request, responder in
        await responder.sendJSON(status: 200, object: ["path": request.path])
      }
      do {
        try await candidate.start()
        upstream = candidate
        break
      } catch { continue }
    }
    let server = try XCTUnwrap(upstream)
    do {
      for suffix in ["", "/", "/v1", "/v1/"] {
        let client = CopilotClient(
          configuration: BridgeConfiguration(
            localAPIKey: "unused",
            upstreamBaseURL: URL(string: "http://127.0.0.1:\(port)\(suffix)")!),
          tokens: CopilotTokenManager(
            initialToken: CopilotAccessToken(
              value: "mock-token", expiresAt: Date().addingTimeInterval(600), apiEndpoint: nil)))
        let expected = suffix.hasPrefix("/v1") ? "/v1/models" : "/models"
        let response = try await client.data(path: "/models/", method: "GET")
        let object = try XCTUnwrap(
          JSONSerialization.jsonObject(with: response.data) as? [String: String])
        XCTAssertEqual(object["path"], expected)
        let stream = try await client.stream(path: "/models/", json: [:])
        var data = Data()
        for try await byte in stream.bytes { data.append(byte) }
        let streamed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(streamed["path"], expected)
      }
    } catch {
      await server.stop()
      throw error
    }
    await server.stop()
  }

  func testAdditionalHeadersWhitelistIsForwardedWithoutReplacingCopilotAuthorization()
    async throws
  {
    let upstreamToken = "copilot-upstream-token"
    var upstream: LocalHTTPServer?
    var upstreamPort = 0

    for _ in 0..<20 {
      let port = Int.random(in: 40_000...49_999)
      let candidate = LocalHTTPServer(
        configuration: BridgeConfiguration(port: port, localAPIKey: "unused")
      ) { request, responder in
        await responder.sendJSON(
          status: 200,
          object: [
            "authorization": request.headers.first(name: "Authorization") ?? "",
            "anthropic-version": request.headers.first(name: "Anthropic-Version") ?? "",
            "anthropic-beta": request.headers.first(name: "Anthropic-Beta") ?? "",
            "x-initiator": request.headers.first(name: "X-Initiator") ?? "",
          ])
      }
      do {
        try await candidate.start()
        upstream = candidate
        upstreamPort = port
        break
      } catch {
        continue
      }
    }

    let server = try XCTUnwrap(upstream, "Could not bind a mock upstream port")
    let client = makeClient(upstreamPort: upstreamPort, token: upstreamToken)
    let response = try await client.data(
      path: "chat/completions",
      json: ["model": "claude-sonnet-mock"],
      additionalHeaders: [
        "anthropic-version": "2023-06-01",
        "AnThRoPiC-BeTa": "prompt-caching-2024-07-31",
        "X-Initiator": "agent",
      ])

    let headers = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: response.data) as? [String: String])
    XCTAssertEqual(headers["authorization"], "Bearer \(upstreamToken)")
    XCTAssertEqual(headers["anthropic-version"], "2023-06-01")
    XCTAssertEqual(headers["anthropic-beta"], "prompt-caching-2024-07-31")
    XCTAssertEqual(headers["x-initiator"], "agent")

    await server.stop()
  }

  func testAdditionalHeadersRejectCredentialsAndHeaderInjection() async throws {
    let client = makeClient(upstreamPort: 49_999, token: "copilot-upstream-token")
    let invalidHeaders: [(String, [String: String], BridgeError)] = [
      (
        "canonical authorization",
        ["Authorization": "Bearer attacker-token"],
        .invalidRequest("不允许向 Copilot 上游转发请求头 Authorization。")
      ),
      (
        "lowercase authorization",
        ["authorization": "Bearer attacker-token"],
        .invalidRequest("不允许向 Copilot 上游转发请求头 authorization。")
      ),
      (
        "CRLF value",
        ["Anthropic-Version": "2023-06-01\r\nAuthorization: Bearer attacker-token"],
        .invalidRequest("上游请求头 Anthropic-Version 的值无效。")
      ),
      (
        "LF value",
        ["Anthropic-Beta": "prompt-caching\nX-Evil: injected"],
        .invalidRequest("上游请求头 Anthropic-Beta 的值无效。")
      ),
      (
        "CRLF name",
        ["Anthropic-Version\r\nX-Evil": "2023-06-01"],
        .invalidRequest(
          "不允许向 Copilot 上游转发请求头 Anthropic-Version\r\nX-Evil。")
      ),
    ]

    for (scenario, additionalHeaders, expectedError) in invalidHeaders {
      do {
        _ = try await client.data(
          path: "chat/completions",
          json: ["model": "claude-sonnet-mock"],
          additionalHeaders: additionalHeaders)
        XCTFail("Expected \(scenario) to be rejected: \(additionalHeaders.keys)")
      } catch let error as BridgeError {
        XCTAssertEqual(error, expectedError)
      } catch {
        XCTFail("Unexpected error for \(scenario): \(error)")
      }
    }
  }

  func testNonStreamingResponseIsRejectedBeforeExceedingConfiguredLimit() async throws {
    let payload = Data(repeating: 0x41, count: 128)
    var upstream: LocalHTTPServer?
    var upstreamPort = 0

    for _ in 0..<20 {
      let port = Int.random(in: 40_000...49_999)
      let candidate = LocalHTTPServer(
        configuration: BridgeConfiguration(port: port, localAPIKey: "unused")
      ) { request, responder in
        if request.path == "/chunked" {
          try? await responder.startStream(contentType: "application/json")
          try? await responder.writeStream(payload)
          try? await responder.finish()
        } else if request.path == "/exact" {
          try? await responder.send(
            status: 200,
            data: Data(payload.prefix(32)),
            contentType: "application/json"
          )
        } else {
          try? await responder.send(
            status: 200,
            data: payload,
            contentType: "application/json"
          )
        }
      }
      do {
        try await candidate.start()
        upstream = candidate
        upstreamPort = port
        break
      } catch {
        continue
      }
    }

    let server = try XCTUnwrap(upstream, "Could not bind a mock upstream port")
    let token = CopilotAccessToken(
      value: "test-token",
      expiresAt: Date().addingTimeInterval(3_600),
      apiEndpoint: nil
    )
    let client = CopilotClient(
      configuration: BridgeConfiguration(
        port: 41_141,
        localAPIKey: "unused",
        maximumUpstreamResponseBytes: 32,
        upstreamBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(upstreamPort)"))
      ),
      tokens: CopilotTokenManager(initialToken: token)
    )

    do {
      _ = try await client.data(path: "models", method: "GET")
      XCTFail("Expected the oversized upstream response to be rejected")
    } catch let error as BridgeError {
      XCTAssertEqual(error, .protocolFailure("上游响应超过读取限额。"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    do {
      _ = try await client.data(path: "chunked", method: "GET")
      XCTFail("Expected the oversized chunked upstream response to be rejected")
    } catch let error as BridgeError {
      XCTAssertEqual(error, .protocolFailure("上游响应超过读取限额。"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let exact = try await client.data(path: "exact", method: "GET")
    XCTAssertEqual(exact.data.count, 32)

    await server.stop()
  }

  private func makeClient(upstreamPort: Int, token: String) -> CopilotClient {
    CopilotClient(
      configuration: BridgeConfiguration(
        port: 41_141,
        localAPIKey: "unused",
        upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!),
      tokens: CopilotTokenManager(
        initialToken: CopilotAccessToken(
          value: token,
          expiresAt: Date().addingTimeInterval(3_600),
          apiEndpoint: nil))
    )
  }
}
