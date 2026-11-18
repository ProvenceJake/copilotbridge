import Foundation
import XCTest

@testable import CopilotBridgeCore

/// Opt-in: exercises freshly built Core against Copilot through an already authenticated local
/// bridge. This avoids reading the GitHub Keychain credential or restarting the menu-bar app.
final class LiveLocalProxyTests: XCTestCase {
  func testCurrentCoreTextToolsAndReasoningAgainstRunningProxy() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["COPILOT_BRIDGE_RUN_LOCAL_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Opt in with COPILOT_BRIDGE_RUN_LOCAL_LIVE_TESTS=1 and a local proxy key.")
    }
    let key = try XCTUnwrap(environment["COPILOT_BRIDGE_LOCAL_TEST_KEY"])
    let upstream = try XCTUnwrap(URL(string: environment["COPILOT_BRIDGE_LOCAL_TEST_URL"] ?? ""))
    guard upstream.scheme == "http", ["127.0.0.1", "localhost", "[::1]"].contains(upstream.host),
      let upstreamPort = upstream.port, upstream.path.isEmpty || upstream.path == "/", !key.isEmpty
    else {
      throw BridgeError.invalidConfiguration("Live test requires an authenticated loopback proxy.")
    }
    let model = environment["COPILOT_BRIDGE_LOCAL_TEST_MODEL"] ?? "gpt-5.6-sol"
    let localKey = UUID().uuidString
    let tokens = CopilotTokenManager(
      initialToken: CopilotAccessToken(
        value: key, expiresAt: Date().addingTimeInterval(600), apiEndpoint: nil))
    var server: ProxyServer?
    var port = 0
    for _ in 0..<20 {
      port = Int.random(in: 50_000...59_999)
      if port == upstreamPort { continue }
      let candidate = ProxyServer(
        configuration: BridgeConfiguration(
          port: port, localAPIKey: localKey, upstreamBaseURL: upstream), tokenManager: tokens)
      do {
        try await candidate.start()
        server = candidate
        break
      } catch { continue }
    }
    let running = try XCTUnwrap(server)
    do {
      for index in 1...3 {
        _ = try await run(
          "text-\(index)", port: port, key: localKey, model: model,
          fields: [
            "metadata": ["user_id": String(repeating: "u", count: 150)],
            "messages": [["role": "user", "content": "Reply with exactly OK."]],
          ])
      }
      _ = try await run(
        "inline-system", port: port, key: localKey, model: model,
        fields: [
          "messages": [
            ["role": "user", "content": "Say OK."],
            ["role": "assistant", "content": "OK"],
            ["role": "system", "content": "Continue to be concise."],
            ["role": "user", "content": "Reply with exactly OK."],
          ]
        ])
      let tools: [[String: Any]] = [
        [
          "name": "echo", "description": "Echo text.",
          "input_schema": [
            "type": "object", "properties": ["text": ["type": "string"]], "required": ["text"],
            "additionalProperties": false,
          ],
        ]
      ]
      var history: [[String: Any]] = [["role": "user", "content": "Call echo with text OK."]]
      let call = try await run(
        "tool-call", port: port, key: localKey, model: model,
        fields: [
          "messages": history, "tools": tools, "tool_choice": ["type": "tool", "name": "echo"],
        ])
      let tool = try XCTUnwrap(call.first { $0["type"] as? String == "tool_use" })
      let callID = try XCTUnwrap(tool["id"] as? String)
      XCTAssertEqual(tool["name"] as? String, "echo")
      XCTAssertEqual((tool["input"] as? [String: Any])?["text"] as? String, "OK")
      history.append(["role": "assistant", "content": call])
      history.append([
        "role": "user",
        "content": [["type": "tool_result", "tool_use_id": callID, "content": "OK"]],
      ])
      let result = try await run(
        "tool-result", port: port, key: localKey, model: model,
        fields: [
          "messages": history, "tools": tools, "tool_choice": ["type": "none"],
        ])
      history.append(["role": "assistant", "content": result])
      history.append(["role": "user", "content": "Reply with exactly OK."])
      _ = try await run(
        "history-replay", port: port, key: localKey, model: model,
        fields: [
          "messages": history, "tools": tools, "tool_choice": ["type": "none"],
        ])
      // Exercise stateless encrypted reasoning even when the simple tool flow did not emit it.
      let reasoningHistory: [[String: Any]] = [
        [
          "role": "user",
          "content":
            "Compute 127 * 389 carefully, check the arithmetic, and answer with just the number.",
        ]
      ]
      let reasoned = try await run(
        "reasoning", port: port, key: localKey, model: model,
        fields: [
          "messages": reasoningHistory
        ])
      _ = try await run(
        "reasoning-replay", port: port, key: localKey, model: model,
        fields: [
          "messages": reasoningHistory + [
            ["role": "assistant", "content": reasoned],
            ["role": "user", "content": "Add one to the result. Answer with just the number."],
          ]
        ])
    } catch {
      await running.stop()
      throw error
    }
    await running.stop()
  }

  private func run(_ label: String, port: Int, key: String, model: String, fields: [String: Any])
    async throws -> [[String: Any]]
  {
    var body = fields
    body["model"] = model
    body["max_tokens"] = 512
    body["stream"] = true
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 90
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let started = ContinuousClock.now
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      throw BridgeError.protocolFailure("Local live \(label): HTTP \(status)")
    }
    var decoder = SSEDecoder()
    var events: [[String: Any]] = []
    for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
      if let event = try decoder.feed(line: line) {
        events.append(
          try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any])
        )
      }
    }
    guard events.first?["type"] as? String == "message_start",
      events.filter({ $0["type"] as? String == "message_start" }).count == 1,
      events.last?["type"] as? String == "message_stop",
      !events.contains(where: { $0["type"] as? String == "error" })
    else {
      throw BridgeError.protocolFailure("Local live \(label): incomplete or failed SSE stream")
    }
    var blocks: [Int: [String: Any]] = [:]
    var arguments: [Int: String] = [:]
    for event in events {
      guard let index = event["index"] as? Int else { continue }
      if event["type"] as? String == "content_block_start" {
        blocks[index] = event["content_block"] as? [String: Any]
      }
      if let delta = event["delta"] as? [String: Any] {
        if let text = delta["text"] as? String {
          let existing = blocks[index]?["text"] as? String ?? ""
          blocks[index]?["text"] = existing + text
        }
        if let fragment = delta["partial_json"] as? String {
          arguments[index, default: ""] += fragment
        }
      }
    }
    for (index, json) in arguments {
      blocks[index]?["input"] = try JSONSerialization.jsonObject(with: Data(json.utf8))
    }
    let content = blocks.keys.sorted().compactMap { blocks[$0] }
    let stopReason =
      (events.last(where: { $0["type"] as? String == "message_delta" })?["delta"] as? [String: Any])?[
        "stop_reason"] as? String
    XCTAssertEqual(stopReason, label == "tool-call" ? "tool_use" : "end_turn", label)
    let text = content.compactMap { $0["text"] as? String }.joined()
    if label.hasPrefix("text-") || label == "inline-system" || label == "history-replay" {
      XCTAssertTrue(text.contains("OK"), "Missing expected synthetic answer in \(label)")
    } else if label == "reasoning" || label == "reasoning-replay" {
      XCTAssertTrue(
        text.contains(label == "reasoning" ? "49403" : "49404"),
        "Incorrect synthetic arithmetic answer")
    }
    print(
      "Local live \(label): HTTP 200, complete SSE, \(started.duration(to: .now)), blocks=\(content.compactMap { $0["type"] as? String })"
    )
    return content
  }
}
