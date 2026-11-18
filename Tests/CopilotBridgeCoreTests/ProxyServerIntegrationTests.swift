import Darwin
import Foundation
import XCTest

@testable import CopilotBridgeCore

final class ProxyServerIntegrationTests: XCTestCase {
  func testRejectsNonPositiveResourceLimitsBeforeBinding() async throws {
    let server = ProxyServer(
      configuration: BridgeConfiguration(
        port: 41_141,
        localAPIKey: "resource-limit-test",
        maximumSSEEventBytes: 0
      ))

    do {
      try await server.start()
      XCTFail("Expected a non-positive resource limit to be rejected")
    } catch let error as BridgeError {
      XCTAssertEqual(error, .invalidConfiguration("所有请求与响应读取限额都必须大于 0。"))
    }
  }

  func testResponsesAndAnthropicProtocolsEndToEndAgainstMockUpstream() async throws {
    let localKey = "integration-test-protocol-key"
    let upstreamToken = "integration-test-upstream-token"
    let responseStreamChunks = [
      Data("event: response.created\r".utf8),
      Data(
        "\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_mock\",\"status\":\"in_progress\"}}\r\n\r"
          .utf8),
      Data(
        "\nevent: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}\n"
          .utf8),
      Data(
        "\nevent: response.completed\r\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_mock\",\"status\":\"completed\"}}\r\n\r"
          .utf8),
      Data("\n".utf8),
    ]
    let responseStreamPayload = responseStreamChunks.reduce(into: Data()) { $0.append($1) }
    let anthropicResponsesStreamEvents: [(name: String, json: String)] = [
      (
        "response.created",
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_copilot_provisional","object":"response","model":"claude-responses-only-mock","status":"in_progress","output":[]}}"#
      ),
      (
        "response.in_progress",
        #"{"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_anthropic_stream","object":"response","model":"claude-responses-only-mock","status":"in_progress","output":[]}}"#
      ),
      (
        "response.output_item.added",
        #"{"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"id":"msg_responses_stream","type":"message","status":"in_progress","role":"assistant","content":[]}}"#
      ),
      (
        "response.content_part.added",
        #"{"type":"response.content_part.added","sequence_number":3,"item_id":"msg_responses_stream","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]}}"#
      ),
      (
        "response.output_text.delta",
        #"{"type":"response.output_text.delta","sequence_number":4,"item_id":"msg_responses_stream","output_index":0,"content_index":0,"delta":"Responses ","logprobs":[]}"#
      ),
      (
        "response.output_text.delta",
        #"{"type":"response.output_text.delta","sequence_number":5,"item_id":"msg_responses_stream","output_index":0,"content_index":0,"delta":"fallback OK","logprobs":[]}"#
      ),
      (
        "response.output_text.done",
        #"{"type":"response.output_text.done","sequence_number":6,"item_id":"msg_responses_stream","output_index":0,"content_index":0,"text":"Responses fallback OK","logprobs":[]}"#
      ),
      (
        "response.content_part.done",
        #"{"type":"response.content_part.done","sequence_number":7,"item_id":"msg_responses_stream","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Responses fallback OK","annotations":[],"logprobs":[]}}"#
      ),
      (
        "response.output_item.done",
        #"{"type":"response.output_item.done","sequence_number":8,"output_index":0,"item":{"id":"msg_responses_stream","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Responses fallback OK","annotations":[],"logprobs":[]}]}}"#
      ),
      (
        "response.completed",
        #"{"type":"response.completed","sequence_number":9,"response":{"id":"resp_anthropic_stream","object":"response","model":"claude-responses-only-mock","status":"completed","output":[{"id":"msg_responses_stream","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Responses fallback OK","annotations":[],"logprobs":[]}]}],"usage":{"input_tokens":5,"output_tokens":3,"total_tokens":8,"input_tokens_details":{"cached_tokens":0},"output_tokens_details":{"reasoning_tokens":0}}}}"#
      ),
    ]
    let anthropicResponsesStreamPayload = anthropicResponsesStreamEvents.enumerated().map {
      index, event in
      // Real Copilot streams can regenerate transport item IDs on every event.
      let json = event.json.replacingOccurrences(
        of: "msg_responses_stream", with: "msg_copilot_event_\(index)")
      return Data("event: \(event.name)\r\ndata: \(json)\r\n\r\n".utf8)
    }
    let anthropicResponsesStreamWithoutUsagePayload =
      Array(anthropicResponsesStreamPayload.dropLast()) + [
        Data(
          ("event: response.completed\r\ndata: "
            + #"{"type":"response.completed","sequence_number":9,"response":{"id":"resp_anthropic_stream","object":"response","model":"claude-responses-only-mock","status":"completed","output":[{"id":"msg_responses_stream","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Responses fallback OK","annotations":[],"logprobs":[]}]}],"usage":null}}"#
            + "\r\n\r\n").utf8)
      ]
    let nativeMessageStreamPayload = Data(
      [
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_native_stream\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-native-mock\",\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":4,\"output_tokens\":0}}}\n\n",
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Native stream OK\"}}\n\n",
        "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":3}}\n\n",
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
      ].joined().utf8)
    let recorder = RequestRecorder()
    var upstreamServer: LocalHTTPServer?
    var upstreamPort = 0

    for _ in 0..<20 {
      let port = Int.random(in: 40_000...49_999)
      let server = LocalHTTPServer(
        configuration: BridgeConfiguration(port: port, localAPIKey: "unused")
      ) { request, responder in
        await recorder.record(request)
        guard request.headers.first(name: "Authorization") == "Bearer \(upstreamToken)" else {
          await responder.sendJSON(
            status: 401,
            object: ["error": ["type": "authentication_error", "message": "bad token"]])
          return
        }

        switch (request.method, request.path) {
        case (.GET, "/models"):
          await responder.sendJSON(
            status: 200,
            object: [
              "object": "list",
              "data": [
                [
                  "id": "gpt-mock",
                  "object": "copilot-model",
                  "created": 1_700_000_000,
                  "owned_by": "legacy-owner",
                  "vendor": "OpenAI",
                  "preview": true,
                  "capabilities": ["type": "chat"],
                ],
                ["id": "claude-sonnet-mock", "object": "model"],
                [
                  "id": "claude-responses-only-mock",
                  "object": "model",
                  "supported_endpoints": ["/responses"],
                ],
                [
                  "id": "claude-native-mock",
                  "object": "model",
                  "supported_endpoints": ["/v1/messages"],
                ],
              ],
            ])
        case (.POST, "/responses"):
          let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
          if body?["model"] as? String == "claude-responses-only-mock" {
            if body?["stream"] as? Bool == true {
              try? await responder.startStream()
              let chunks =
                body?["user"] as? String == "stream-no-usage"
                ? anthropicResponsesStreamWithoutUsagePayload : anthropicResponsesStreamPayload
              for chunk in chunks {
                try? await responder.writeStream(chunk)
              }
              try? await responder.finish()
              return
            }
            await responder.sendJSON(
              status: 200,
              object: [
                "error": NSNull(),
                "id": "resp_anthropic_fallback",
                "model": "claude-responses-only-mock",
                "object": "response",
                "output": [
                  [
                    "content": [
                      ["annotations": [], "text": "Responses fallback OK", "type": "output_text"]
                    ],
                    "id": "msg_responses_fallback",
                    "role": "assistant",
                    "status": "completed",
                    "type": "message",
                  ]
                ],
                "status": "completed",
                "usage": ["input_tokens": 5, "output_tokens": 3, "total_tokens": 8],
              ])
          } else if body?["stream"] as? Bool == true {
            try? await responder.startStream()
            if body?["input"] as? String == "oversized-event" {
              try? await responder.writeStream(
                Data(
                  "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\","
                    .utf8
                ))
              try? await responder.writeStream(
                Data(
                  "data: \"delta\":\"\(String(repeating: "X", count: 1_200))\"}\n\n".utf8
                ))
              try? await responder.finish()
              return
            }
            if body?["input"] as? String == "unterminated-event" {
              try? await responder.writeStream(
                Data(
                  "data: {\"type\":\"response.output_text.delta\",\"delta\":\"PARTIAL_SENTINEL\"}\n"
                    .utf8))
              try? await responder.finish()
              return
            }
            for chunk in responseStreamChunks {
              try? await responder.writeStream(chunk)
            }
            try? await responder.finish()
          } else {
            await responder.sendJSON(
              status: 200,
              object: [
                "id": "resp_mock",
                "object": "response",
                "status": "completed",
                "model": "gpt-mock",
                "output": [],
              ])
          }
        case (.POST, "/v1/messages"):
          let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
          if body?["stream"] as? Bool == true {
            try? await responder.startStream()
            try? await responder.writeStream(nativeMessageStreamPayload)
            try? await responder.finish()
          } else {
            await responder.sendJSON(
              status: 200,
              object: [
                "content": [["text": "Native nonstream OK", "type": "text"]],
                "id": "msg_native_nonstream",
                "model": "claude-native-mock",
                "role": "assistant",
                "stop_reason": "end_turn",
                "stop_sequence": NSNull(),
                "type": "message",
                "usage": ["input_tokens": 4, "output_tokens": 3],
              ])
          }
        case (.POST, "/chat/completions"):
          let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
          if body?["stream"] as? Bool == true {
            try? await responder.startStream()
            if body?["user"] as? String == "stream-error" {
              try? await responder.writeStream(
                Data(
                  "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}\n\n"
                    .utf8))
              try? await responder.finish()
              return
            }
            try? await responder.writeStream(
              Data(
                "data: {\"id\":\"chatcmpl_mock\",\"object\":\"chat.completion.chunk\",\"model\":\"claude-sonnet-mock\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"OK\"},\"finish_reason\":null}]}\n\n"
                  .utf8))
            try? await responder.writeStream(
              Data(
                "data: {\"id\":\"chatcmpl_mock\",\"object\":\"chat.completion.chunk\",\"model\":\"claude-sonnet-mock\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1,\"total_tokens\":4}}\n\n"
                  .utf8))
            try? await responder.writeStream(Data("data: [DONE]\n\n".utf8))
            try? await responder.finish()
          } else {
            await responder.sendJSON(
              status: 200,
              object: [
                "id": "chatcmpl_mock",
                "object": "chat.completion",
                "created": 1,
                "model": "claude-sonnet-mock",
                "choices": [
                  [
                    "index": 0,
                    "message": ["role": "assistant", "content": "OK"],
                    "finish_reason": "stop",
                  ]
                ],
                "usage": ["prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4],
              ])
          }
        default:
          await responder.sendJSON(
            status: 404, object: ["error": ["type": "not_found", "message": request.path]])
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
    let upstream = try XCTUnwrap(upstreamServer, "Could not bind a mock upstream port")

    let initialToken = CopilotAccessToken(
      value: upstreamToken, expiresAt: Date().addingTimeInterval(3_600), apiEndpoint: nil)
    let tokenManager = CopilotTokenManager(initialToken: initialToken)
    var bridgeServer: ProxyServer?
    var bridgePort = 0
    for _ in 0..<20 {
      let port = Int.random(in: 50_000...59_999)
      let configuration = BridgeConfiguration(
        port: port,
        localAPIKey: localKey,
        maximumSSEEventBytes: 1_024,
        upstreamBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(upstreamPort)")),
        modelAliases: [
          "claude-code-alias": "gpt-mock",
          "team-claude-alias": "claude-sonnet-mock",
        ]
      )
      let server = ProxyServer(configuration: configuration, tokenManager: tokenManager)
      do {
        try await server.start()
        bridgeServer = server
        bridgePort = port
        break
      } catch {
        continue
      }
    }
    let bridge = try XCTUnwrap(bridgeServer, "Could not bind a bridge port")

    do {
      let invalidStream = try await Self.request(
        path: "/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-responses-only-mock",
          "max_tokens": 64,
          "stream": "true",
          "messages": [["role": "user", "content": "invalid stream type"]],
        ])
      XCTAssertEqual(invalidStream.status, 400)
      let requestsAfterInvalidStream = await recorder.snapshot()
      XCTAssertTrue(
        requestsAfterInvalidStream.isEmpty,
        "Malformed Anthropic envelopes must fail before model-catalog network access")

      let models = try await Self.request(
        path: "/v1/models", port: bridgePort, bearer: localKey)
      XCTAssertEqual(models.status, 200)
      let modelsJSON = try Self.jsonObject(models.data)
      XCTAssertEqual(modelsJSON["object"] as? String, "list")
      let openAIModels = try XCTUnwrap(modelsJSON["data"] as? [[String: Any]])
      let openAIGPTModel = try XCTUnwrap(
        openAIModels.first(where: { $0["id"] as? String == "gpt-mock" }))
      XCTAssertEqual(openAIGPTModel["object"] as? String, "model")
      XCTAssertEqual(openAIGPTModel["created"] as? Int, 1_700_000_000)
      XCTAssertEqual(openAIGPTModel["owned_by"] as? String, "OpenAI")
      XCTAssertEqual(openAIGPTModel["preview"] as? Bool, true)

      let codexModels = try await Self.request(
        path: "/v1/models?client_version=0.153.4", port: bridgePort, bearer: localKey)
      XCTAssertEqual(codexModels.status, 200)
      let codexModelsJSON = try Self.jsonObject(codexModels.data)
      XCTAssertNil(codexModelsJSON["data"])
      let codexModel = try XCTUnwrap(
        (codexModelsJSON["models"] as? [[String: Any]])?.first)
      XCTAssertEqual(codexModel["slug"] as? String, "gpt-mock")

      let directModels = try await Self.request(
        path: "/models/", port: bridgePort, bearer: localKey)
      XCTAssertEqual(directModels.status, 200)
      XCTAssertEqual(try Self.jsonObject(directModels.data)["object"] as? String, "list")

      let openAIModel = try await Self.request(
        path: "/v1/models/gpt-mock", port: bridgePort, bearer: localKey)
      XCTAssertEqual(openAIModel.status, 200)
      let openAIModelJSON = try Self.jsonObject(openAIModel.data)
      XCTAssertEqual(openAIModelJSON["id"] as? String, "gpt-mock")
      XCTAssertEqual(openAIModelJSON["object"] as? String, "model")
      XCTAssertEqual(openAIModelJSON["created"] as? Int, 1_700_000_000)
      XCTAssertEqual(openAIModelJSON["owned_by"] as? String, "OpenAI")

      let anthropicModel = try await Self.request(
        path: "/anthropic/v1/models/claude-sonnet-mock",
        port: bridgePort,
        bearer: localKey)
      XCTAssertEqual(anthropicModel.status, 200)
      let anthropicModelJSON = try Self.jsonObject(anthropicModel.data)
      XCTAssertEqual(anthropicModelJSON["id"] as? String, "claude-sonnet-mock")
      XCTAssertEqual(anthropicModelJSON["type"] as? String, "model")

      let preflight = try await Self.request(
        path: "/v1/chat/completions",
        port: bridgePort,
        method: "OPTIONS",
        headers: [
          "Origin": "https://example.test",
          "Access-Control-Request-Headers": "api-key, anthropic-version",
          "Access-Control-Request-Method": "POST",
        ])
      XCTAssertEqual(preflight.status, 204)
      let allowedHeaders = try Self.commaSeparatedHeader(
        "Access-Control-Allow-Headers", response: preflight.response)
      XCTAssertTrue(allowedHeaders.isSuperset(of: ["api-key", "anthropic-version"]))
      let allowedMethods = try Self.commaSeparatedHeader(
        "Access-Control-Allow-Methods", response: preflight.response)
      XCTAssertTrue(allowedMethods.isSuperset(of: ["get", "head"]))
      let exposedHeaders = try Self.commaSeparatedHeader(
        "Access-Control-Expose-Headers", response: preflight.response)
      XCTAssertTrue(exposedHeaders.contains("request-id"))

      let unauthorizedAnthropic = try await Self.request(
        path: "/anthropic/v1/messages", port: bridgePort, method: "POST")
      XCTAssertEqual(unauthorizedAnthropic.status, 401)
      let unauthorizedRequestID = try XCTUnwrap(
        unauthorizedAnthropic.response?.value(forHTTPHeaderField: "request-id"))
      XCTAssertEqual(
        try Self.jsonObject(unauthorizedAnthropic.data)["request_id"] as? String,
        unauthorizedRequestID)

      let invalidAnthropic = try await Self.request(
        path: "/anthropic/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: ["model": "claude-sonnet-mock", "messages": []])
      XCTAssertEqual(invalidAnthropic.status, 400)
      let invalidRequestID = try XCTUnwrap(
        invalidAnthropic.response?.value(forHTTPHeaderField: "request-id"))
      XCTAssertEqual(
        try Self.jsonObject(invalidAnthropic.data)["request_id"] as? String,
        invalidRequestID)

      let directChat = try await Self.request(
        path: "/chat/completions",
        port: bridgePort,
        method: "POST",
        bearer: localKey,
        json: [
          "model": "gpt-mock",
          "messages": [["role": "user", "content": "direct nonstream"]],
        ])
      XCTAssertEqual(directChat.status, 200)
      XCTAssertEqual(try Self.jsonObject(directChat.data)["object"] as? String, "chat.completion")

      let directChatStream = try await Self.request(
        path: "/chat/completions/",
        port: bridgePort,
        method: "POST",
        bearer: localKey,
        json: [
          "model": "gpt-mock",
          "stream": true,
          "messages": [["role": "user", "content": "direct stream"]],
        ])
      XCTAssertEqual(directChatStream.status, 200)
      XCTAssertTrue(String(decoding: directChatStream.data, as: UTF8.self).contains("data: [DONE]"))

      let azureChat = try await Self.request(
        path: "/openai/deployments/gpt-mock/chat/completions?api-version=2024-10-21",
        port: bridgePort,
        method: "POST",
        headers: ["api-key": localKey],
        json: ["messages": [["role": "user", "content": "azure"]]])
      XCTAssertEqual(azureChat.status, 200)
      let recordedAzureBody = await recorder.lastBody(for: "/chat/completions")
      let azureUpstreamData = try XCTUnwrap(recordedAzureBody)
      XCTAssertEqual(try Self.jsonObject(azureUpstreamData)["model"] as? String, "gpt-mock")

      let response = try await Self.request(
        path: "/v1/responses",
        port: bridgePort,
        method: "POST",
        bearer: localKey,
        json: ["model": "gpt-mock", "input": "hello"])
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(try Self.jsonObject(response.data)["status"] as? String, "completed")

      let responseStream = try await Self.request(
        path: "/v1/responses",
        port: bridgePort,
        method: "POST",
        bearer: localKey,
        json: ["model": "gpt-mock", "input": "hello", "stream": true])
      XCTAssertEqual(responseStream.status, 200)
      XCTAssertEqual(responseStream.data, responseStreamPayload)

      let directResponse = try await Self.request(
        path: "/responses/",
        port: bridgePort,
        method: "POST",
        headers: ["x-goog-api-key": localKey],
        json: ["model": "gpt-mock", "input": "google-compatible authentication"])
      XCTAssertEqual(directResponse.status, 200)
      XCTAssertEqual(try Self.jsonObject(directResponse.data)["status"] as? String, "completed")

      for input in ["oversized-event", "unterminated-event"] {
        let failedStream = try await Self.request(
          path: "/v1/responses",
          port: bridgePort,
          method: "POST",
          bearer: localKey,
          json: ["model": "gpt-mock", "input": input, "stream": true])
        XCTAssertEqual(failedStream.status, 200)
        let events = try Self.sseJSONEvents(failedStream.data)
        XCTAssertEqual(events.count, 1, String(decoding: failedStream.data, as: UTF8.self))
        XCTAssertEqual(events.first?.name, "error")
        XCTAssertEqual(events.first?.object["type"] as? String, "error")
        XCTAssertFalse(
          String(decoding: failedStream.data, as: UTF8.self).contains("PARTIAL_SENTINEL"))
        XCTAssertFalse(String(decoding: failedStream.data, as: UTF8.self).contains("XXXXX"))
      }

      let responsesFallback = try await Self.request(
        path: "/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-responses-only-mock",
          "max_tokens": 64,
          "stream": NSNull(),
          "messages": [
            ["role": "user", "content": "previous question"],
            ["role": "assistant", "content": "previous answer"],
            ["role": "user", "content": "responses fallback"],
          ],
        ])
      XCTAssertEqual(responsesFallback.status, 200)
      let responsesFallbackJSON = try Self.jsonObject(responsesFallback.data)
      XCTAssertEqual(responsesFallbackJSON["type"] as? String, "message")
      XCTAssertEqual(responsesFallbackJSON["model"] as? String, "claude-responses-only-mock")
      XCTAssertEqual(
        ((responsesFallbackJSON["content"] as? [[String: Any]])?.first)?["text"] as? String,
        "Responses fallback OK")
      let recordedResponsesFallbackBody = await recorder.lastBody(for: "/responses")
      let responsesFallbackUpstreamData = try XCTUnwrap(recordedResponsesFallbackBody)
      let responsesFallbackUpstream = try Self.jsonObject(responsesFallbackUpstreamData)
      XCTAssertEqual(responsesFallbackUpstream["model"] as? String, "claude-responses-only-mock")
      XCTAssertEqual(responsesFallbackUpstream["stream"] as? Bool, false)
      XCTAssertEqual(responsesFallbackUpstream["store"] as? Bool, false)
      XCTAssertEqual(responsesFallbackUpstream["max_output_tokens"] as? Int, 64)
      let responsesFallbackInput = try XCTUnwrap(
        responsesFallbackUpstream["input"] as? [[String: Any]])
      let assistantHistory = try XCTUnwrap(
        responsesFallbackInput.first { $0["role"] as? String == "assistant" })
      XCTAssertEqual(
        ((assistantHistory["content"] as? [[String: Any]])?.first)?["type"] as? String,
        "output_text")

      let oversizedMetadataUserID = String(repeating: "u", count: 150)
      let responsesWithOversizedUser = try await Self.request(
        path: "/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-responses-only-mock",
          "max_tokens": 64,
          "metadata": ["user_id": oversizedMetadataUserID],
          "messages": [["role": "user", "content": "oversized metadata user"]],
        ])
      XCTAssertEqual(responsesWithOversizedUser.status, 200)
      let rawRecordedOversizedUserBody = await recorder.lastBody(for: "/responses")
      let recordedOversizedUserBody = try XCTUnwrap(rawRecordedOversizedUserBody)
      let oversizedUserUpstream = try Self.jsonObject(recordedOversizedUserBody)
      let normalizedUserID = try XCTUnwrap(oversizedUserUpstream["user"] as? String)
      XCTAssertEqual(normalizedUserID.utf8.count, 64)
      XCTAssertEqual(
        normalizedUserID,
        AnthropicMetadataUserIdentifier.upstreamValue(for: oversizedMetadataUserID))
      XCTAssertNotEqual(normalizedUserID, oversizedMetadataUserID)

      let responsesInlineSystems = try await Self.request(
        path: "/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-responses-only-mock",
          "max_tokens": 64,
          "system": "RESPONSES_TOP_SYSTEM",
          "messages": [
            ["role": "user", "content": "RESPONSES_USER"],
            [
              "role": "system",
              "content": [
                ["type": "text", "text": "RESPONSES_INLINE_BLOCK_A"],
                ["type": "text", "text": "RESPONSES_INLINE_BLOCK_B"],
              ],
            ],
            [
              "role": "assistant",
              "content": [
                [
                  "type": "tool_use",
                  "id": "call_inline_system",
                  "name": "lookup",
                  "input": ["query": "compatibility"],
                ]
              ],
            ],
            [
              "role": "user",
              "content": [
                [
                  "type": "tool_result",
                  "tool_use_id": "call_inline_system",
                  "content": "TOOL_RESULT",
                ]
              ],
            ],
            ["role": "system", "content": "RESPONSES_INLINE_STRING"],
            [
              "role": "system",
              "content": [["type": "text", "text": "RESPONSES_CONSECUTIVE_SYSTEM"]],
            ],
          ],
        ])
      XCTAssertEqual(responsesInlineSystems.status, 200)
      let recordedResponsesInlineBody = await recorder.lastBody(for: "/responses")
      let responsesInlineUpstream = try Self.jsonObject(
        try XCTUnwrap(recordedResponsesInlineBody))
      XCTAssertEqual(responsesInlineUpstream["instructions"] as? String, "RESPONSES_TOP_SYSTEM")
      let responsesInlineInput = try XCTUnwrap(
        responsesInlineUpstream["input"] as? [[String: Any]])
      XCTAssertEqual(
        responsesInlineInput.map { $0["type"] as? String },
        ["message", "message", "function_call", "function_call_output", "message", "message"])
      XCTAssertEqual(
        responsesInlineInput.compactMap { $0["role"] as? String },
        ["user", "system", "system", "system"])
      let responsesSystemMessages = responsesInlineInput.filter {
        $0["role"] as? String == "system"
      }
      XCTAssertEqual(responsesSystemMessages.count, 3)
      XCTAssertEqual(
        (responsesSystemMessages[0]["content"] as? [[String: Any]])?.map {
          $0["type"] as? String
        },
        ["input_text", "input_text"])
      XCTAssertEqual(
        (responsesSystemMessages[0]["content"] as? [[String: Any]])?.compactMap {
          $0["text"] as? String
        },
        ["RESPONSES_INLINE_BLOCK_A", "RESPONSES_INLINE_BLOCK_B"])
      XCTAssertEqual(responsesInlineInput[2]["call_id"] as? String, "call_inline_system")
      XCTAssertEqual(responsesInlineInput[3]["call_id"] as? String, "call_inline_system")

      let responsesFallbackStream = try await Self.request(
        path: "/anthropic/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-responses-only-mock",
          "max_tokens": 64,
          "stream": true,
          "messages": [["role": "user", "content": "responses fallback stream"]],
        ])
      XCTAssertEqual(responsesFallbackStream.status, 200)
      let responsesFallbackEvents = try Self.sseJSONEvents(responsesFallbackStream.data)
      XCTAssertEqual(responsesFallbackEvents.first?.name, "message_start")
      XCTAssertEqual(
        (responsesFallbackEvents.first?.object["message"] as? [String: Any])?["id"] as? String,
        "msg_resp_copilot_provisional")
      XCTAssertFalse(responsesFallbackEvents.contains { $0.name == "error" })
      XCTAssertTrue(
        responsesFallbackEvents.contains {
          $0.name == "content_block_delta"
            && ($0.object["delta"] as? [String: Any])?["text"] as? String
              == "Responses "
        })
      XCTAssertTrue(
        responsesFallbackEvents.contains {
          $0.name == "content_block_delta"
            && ($0.object["delta"] as? [String: Any])?["text"] as? String
              == "fallback OK"
        })
      XCTAssertEqual(responsesFallbackEvents.last?.name, "message_stop")
      let recordedIncrementalStreamBody = await recorder.lastBody(for: "/responses")
      let incrementalStreamUpstreamData = try XCTUnwrap(recordedIncrementalStreamBody)
      XCTAssertEqual(
        try Self.jsonObject(incrementalStreamUpstreamData)["stream"] as? Bool,
        true,
        "Anthropic streaming compatibility must preserve incremental Responses delivery")

      let responsesStreamWithoutUsage = try await Self.request(
        path: "/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-responses-only-mock",
          "max_tokens": 64,
          "metadata": ["user_id": "stream-no-usage"],
          "stream": true,
          "messages": [["role": "user", "content": "stream without usage"]],
        ])
      XCTAssertEqual(responsesStreamWithoutUsage.status, 200)
      let noUsageEvents = try Self.sseJSONEvents(responsesStreamWithoutUsage.data)
      XCTAssertEqual(noUsageEvents.last?.name, "message_stop")
      let noUsageDelta = try XCTUnwrap(noUsageEvents.first { $0.name == "message_delta" })
      let noUsage = try XCTUnwrap(noUsageDelta.object["usage"] as? [String: Any])
      XCTAssertEqual(noUsage["input_tokens"] as? Int, 0)
      XCTAssertEqual(noUsage["output_tokens"] as? Int, 0)

      let nativeHeaders = [
        "X-API-Key": localKey,
        "Anthropic-Version": "2023-06-01",
        "Anthropic-Beta": "prompt-caching-2024-07-31",
      ]
      let nativeNonstreamBody: [String: Any] = [
        "model": "claude-native-mock",
        "max_tokens": 96,
        "metadata": ["user_id": oversizedMetadataUserID],
        "system": "Keep this native body unchanged.",
        "messages": [["role": "user", "content": "native nonstream"]],
      ]
      let nativeMessage = try await Self.request(
        path: "/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: nativeHeaders,
        json: nativeNonstreamBody)
      XCTAssertEqual(nativeMessage.status, 200)
      XCTAssertEqual(
        try Self.jsonObject(nativeMessage.data)["id"] as? String, "msg_native_nonstream")
      let recordedNativeNonstreamBody = await recorder.lastBody(for: "/v1/messages")
      let nativeNonstreamUpstreamData = try XCTUnwrap(recordedNativeNonstreamBody)
      let nativeNonstreamUpstream = try Self.jsonObject(nativeNonstreamUpstreamData)
      XCTAssertEqual(
        try Self.canonicalJSON(nativeNonstreamUpstream),
        try Self.canonicalJSON(nativeNonstreamBody))
      let nativeNonstreamMetadata = try XCTUnwrap(
        nativeNonstreamUpstream["metadata"] as? [String: Any])
      XCTAssertEqual(
        nativeNonstreamMetadata["user_id"] as? String,
        oversizedMetadataUserID,
        "Native Anthropic routing must not apply OpenAI's 64-byte user limit")
      let recordedNativeNonstreamHeaders = await recorder.lastHeaders(for: "/v1/messages")
      let nativeNonstreamUpstreamHeaders = try XCTUnwrap(recordedNativeNonstreamHeaders)
      XCTAssertEqual(nativeNonstreamUpstreamHeaders["authorization"], "Bearer \(upstreamToken)")
      XCTAssertEqual(nativeNonstreamUpstreamHeaders["anthropic-version"], "2023-06-01")
      XCTAssertEqual(
        nativeNonstreamUpstreamHeaders["anthropic-beta"], "prompt-caching-2024-07-31")
      XCTAssertEqual(nativeNonstreamUpstreamHeaders["x-initiator"], "user")

      let nativeInlineSystemBody: [String: Any] = [
        "model": "claude-native-mock",
        "max_tokens": 96,
        "system": "NATIVE_TOP_SYSTEM",
        "messages": [
          ["role": "user", "content": "NATIVE_USER"],
          ["role": "system", "content": "NATIVE_INLINE_STRING"],
          [
            "role": "system",
            "content": [
              [
                "type": "text",
                "text": "NATIVE_INLINE_BLOCK",
                "cache_control": ["type": "ephemeral"],
              ]
            ],
          ],
          ["role": "assistant", "content": "NATIVE_ASSISTANT"],
        ],
      ]
      let nativeInlineSystem = try await Self.request(
        path: "/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: nativeHeaders,
        json: nativeInlineSystemBody)
      XCTAssertEqual(nativeInlineSystem.status, 200)
      let rawRecordedNativeInlineData = await recorder.lastBody(for: "/v1/messages")
      let recordedNativeInlineData = try XCTUnwrap(rawRecordedNativeInlineData)
      let recordedNativeInline = try Self.jsonObject(recordedNativeInlineData)
      XCTAssertEqual(
        try Self.canonicalJSON(recordedNativeInline),
        try Self.canonicalJSON(nativeInlineSystemBody),
        "Native Anthropic routing must preserve supported mid-conversation system messages")

      var nativeStreamBody = nativeNonstreamBody
      nativeStreamBody["metadata"] = ["user_id": "native-stream"]
      nativeStreamBody["messages"] = [["role": "user", "content": "native stream"]]
      nativeStreamBody["stream"] = true
      let nativeMessageStream = try await Self.request(
        path: "/anthropic/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: nativeHeaders,
        json: nativeStreamBody)
      XCTAssertEqual(nativeMessageStream.status, 200)
      let nativeEvents = try Self.sseJSONEvents(nativeMessageStream.data)
      let nativeStreamText = String(decoding: nativeMessageStream.data, as: UTF8.self)
      XCTAssertEqual(nativeEvents.first?.name, "message_start", nativeStreamText)
      XCTAssertTrue(
        nativeEvents.contains {
          $0.name == "content_block_delta"
            && ($0.object["delta"] as? [String: Any])?["text"] as? String
              == "Native stream OK"
        }, nativeStreamText)
      XCTAssertEqual(nativeEvents.last?.name, "message_stop", nativeStreamText)
      let recordedNativeStreamBody = await recorder.lastBody(for: "/v1/messages")
      let nativeStreamUpstreamData = try XCTUnwrap(recordedNativeStreamBody)
      XCTAssertEqual(
        try Self.canonicalJSON(try Self.jsonObject(nativeStreamUpstreamData)),
        try Self.canonicalJSON(nativeStreamBody))
      let recordedNativeStreamHeaders = await recorder.lastHeaders(for: "/v1/messages")
      let nativeStreamUpstreamHeaders = try XCTUnwrap(recordedNativeStreamHeaders)
      XCTAssertEqual(nativeStreamUpstreamHeaders["anthropic-version"], "2023-06-01")
      XCTAssertEqual(
        nativeStreamUpstreamHeaders["anthropic-beta"], "prompt-caching-2024-07-31")

      let message = try await Self.request(
        path: "/anthropic/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-sonnet-mock",
          "max_tokens": 32,
          "messages": [["role": "user", "content": "hello"]],
        ])
      XCTAssertEqual(message.status, 200)
      let messageJSON = try Self.jsonObject(message.data)
      XCTAssertEqual(messageJSON["type"] as? String, "message")
      XCTAssertEqual(messageJSON["stop_reason"] as? String, "end_turn")

      let chatInlineSystems = try await Self.request(
        path: "/anthropic/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-sonnet-mock",
          "max_tokens": 32,
          "system": "CHAT_TOP_SYSTEM",
          "messages": [
            ["role": "user", "content": "CHAT_USER"],
            ["role": "system", "content": "CHAT_INLINE_STRING"],
            [
              "role": "system",
              "content": [
                ["type": "text", "text": "CHAT_INLINE_BLOCK_A"],
                ["type": "text", "text": "CHAT_INLINE_BLOCK_B"],
              ],
            ],
            ["role": "assistant", "content": "CHAT_ASSISTANT"],
          ],
        ])
      XCTAssertEqual(chatInlineSystems.status, 200)
      let rawRecordedChatInlineData = await recorder.lastBody(for: "/chat/completions")
      let recordedChatInlineData = try XCTUnwrap(rawRecordedChatInlineData)
      let recordedChatInline = try Self.jsonObject(recordedChatInlineData)
      let recordedChatMessages = try XCTUnwrap(
        recordedChatInline["messages"] as? [[String: Any]])
      XCTAssertEqual(
        recordedChatMessages.map { $0["role"] as? String },
        ["system", "user", "system", "system", "assistant"])
      XCTAssertEqual(
        recordedChatMessages.map { $0["content"] as? String },
        [
          "CHAT_TOP_SYSTEM", "CHAT_USER", "CHAT_INLINE_STRING",
          "CHAT_INLINE_BLOCK_A\n\nCHAT_INLINE_BLOCK_B", "CHAT_ASSISTANT",
        ])

      let messageStream = try await Self.request(
        path: "/anthropic/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-sonnet-mock",
          "max_tokens": 32,
          "stream": true,
          "messages": [["role": "user", "content": "hello"]],
        ])
      XCTAssertEqual(messageStream.status, 200)
      let anthropicEvents = String(decoding: messageStream.data, as: UTF8.self)
      XCTAssertTrue(anthropicEvents.contains("event: message_start"), anthropicEvents)
      XCTAssertTrue(anthropicEvents.contains("event: content_block_delta"), anthropicEvents)
      XCTAssertTrue(anthropicEvents.contains("event: message_stop"), anthropicEvents)
      XCTAssertFalse(anthropicEvents.contains("event: error"), anthropicEvents)

      let capturedShape = try await Self.request(
        path: "/v1/messages?beta=true",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-code-alias",
          "max_tokens": 32_000,
          "stream": true,
          "thinking": ["type": "adaptive", "display": "omitted"],
          "output_config": ["effort": "high"],
          "context_management": [
            "edits": [
              ["type": "clear_thinking_20251015", "keep": "all"]
            ]
          ],
          "metadata": ["user_id": "fixture-user"],
          "system": [["type": "text", "text": "SYSTEM_SENTINEL"]],
          "messages": [
            ["role": "user", "content": [["type": "text", "text": "USER_SENTINEL"]]]
          ],
          "tools": [
            [
              "name": "lookup",
              "description": "fixture",
              "input_schema": ["type": "object", "properties": [:]],
            ]
          ],
        ])
      XCTAssertEqual(capturedShape.status, 200)
      let lastChatBody = await recorder.lastBody(for: "/chat/completions")
      let capturedUpstreamData = try XCTUnwrap(lastChatBody)
      let capturedUpstream = try Self.jsonObject(capturedUpstreamData)
      XCTAssertEqual(capturedUpstream["model"] as? String, "gpt-mock")
      XCTAssertEqual(capturedUpstream["max_tokens"] as? Int, 32_000)
      XCTAssertNil(capturedUpstream["thinking"])
      XCTAssertNil(capturedUpstream["output_config"])
      XCTAssertNil(capturedUpstream["context_management"])
      XCTAssertNil(capturedUpstream["reasoning_effort"])

      let claudeAliasShape = try await Self.request(
        path: "/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "team-claude-alias",
          "max_tokens": 1_024,
          "thinking": ["type": "adaptive"],
          "messages": [["role": "user", "content": "hello"]],
        ])
      XCTAssertEqual(claudeAliasShape.status, 200)
      let lastClaudeAliasBody = await recorder.lastBody(for: "/chat/completions")
      let claudeAliasBody = try XCTUnwrap(lastClaudeAliasBody)
      let claudeAliasUpstream = try Self.jsonObject(claudeAliasBody)
      XCTAssertEqual(claudeAliasUpstream["model"] as? String, "claude-sonnet-mock")
      XCTAssertEqual(
        (claudeAliasUpstream["thinking"] as? [String: String])?["type"], "adaptive")

      let streamError = try await Self.request(
        path: "/anthropic/v1/messages",
        port: bridgePort,
        method: "POST",
        headers: ["X-API-Key": localKey, "Anthropic-Version": "2023-06-01"],
        json: [
          "model": "claude-sonnet-mock",
          "max_tokens": 32,
          "stream": true,
          "metadata": ["user_id": "stream-error"],
          "messages": [["role": "user", "content": "trigger"]],
        ])
      XCTAssertEqual(streamError.status, 200)
      let streamErrorEvents = try Self.sseJSONEvents(streamError.data)
      XCTAssertTrue(streamErrorEvents.contains { $0.name == "message_start" })
      let errorEvent = try XCTUnwrap(streamErrorEvents.first { $0.name == "error" })
      let nestedError = try XCTUnwrap(errorEvent.object["error"] as? [String: Any])
      XCTAssertEqual(nestedError["type"] as? String, "overloaded_error")
      XCTAssertEqual(nestedError["message"] as? String, "busy")
      XCTAssertFalse(streamErrorEvents.contains { $0.name == "message_stop" })

      let snapshot = await recorder.snapshot()
      XCTAssertEqual(snapshot["/models", default: 0], 1)
      XCTAssertEqual(snapshot["/responses"], 10)
      XCTAssertEqual(snapshot["/v1/messages"], 3)
      XCTAssertEqual(snapshot["/chat/completions"], 9)
    } catch {
      await bridge.stop()
      await upstream.stop()
      throw error
    }
    await bridge.stop()
    await upstream.stop()
  }

  func testIPv6LoopbackHealthAndEndpointFormatting() async throws {
    let key = "integration-test-ipv6-key"
    var runningServer: ProxyServer?
    var selectedPort = 0

    for _ in 0..<20 {
      let port = Int.random(in: 40_000...59_999)
      let configuration = BridgeConfiguration(host: "::1", port: port, localAPIKey: key)
      XCTAssertEqual(configuration.endpoint.absoluteString, "http://[::1]:\(port)/v1")
      let server = ProxyServer(configuration: configuration)
      do {
        try await server.start()
        runningServer = server
        selectedPort = port
        break
      } catch {
        continue
      }
    }
    let server = try XCTUnwrap(runningServer, "Could not bind an IPv6 loopback port")

    do {
      let health = try await Self.request(path: "/healthz", host: "::1", port: selectedPort)
      XCTAssertEqual(health.status, 200)
      XCTAssertTrue(String(decoding: health.data, as: UTF8.self).contains("\"ok\":true"))
    } catch {
      await server.stop()
      throw error
    }
    await server.stop()
  }

  func testConcurrentStartsAreIdempotent() async throws {
    let port = Int.random(in: 40_000...59_999)
    let server = ProxyServer(
      configuration: BridgeConfiguration(port: port, localAPIKey: "concurrent-start-key"))

    async let first: Void = server.start()
    async let second: Void = server.start()
    _ = try await (first, second)

    let health = try await Self.request(path: "/healthz", port: port)
    XCTAssertEqual(health.status, 200)
    await server.stop()

    let replacement = ProxyServer(
      configuration: BridgeConfiguration(port: port, localAPIKey: "replacement-key"))
    try await replacement.start()
    await replacement.stop()
  }

  func testLoopbackHealthAndLocalAuthentication() async throws {
    let key = "integration-test-local-key"
    var runningServer: ProxyServer?
    var selectedPort = 0

    for _ in 0..<20 {
      let port = Int.random(in: 40_000...59_999)
      let server = ProxyServer(configuration: BridgeConfiguration(port: port, localAPIKey: key))
      do {
        try await server.start()
        runningServer = server
        selectedPort = port
        break
      } catch {
        continue
      }
    }
    let server = try XCTUnwrap(runningServer, "Could not find a free loopback port")

    do {
      for path in ["/health", "/healthz"] {
        let health = try await Self.request(path: path, port: selectedPort)
        XCTAssertEqual(health.status, 200, "path=\(path)")
        let healthObject = try Self.jsonObject(health.data)
        XCTAssertEqual(healthObject["version"] as? String, BridgeVersion.current)
        XCTAssertEqual(
          health.response?.value(forHTTPHeaderField: "Server"), BridgeVersion.userAgent)
        XCTAssertTrue(
          String(decoding: health.data, as: UTF8.self).contains("\"ok\":true"),
          "path=\(path)")
        XCTAssertEqual(
          health.response?.value(forHTTPHeaderField: "Connection"), "keep-alive",
          "path=\(path)")

        let nonGetHealth = try await Self.request(
          path: path, port: selectedPort, method: "POST")
        XCTAssertEqual(nonGetHealth.status, 401, "path=\(path)")

        let authorizedNonGetHealth = try await Self.request(
          path: path, port: selectedPort, method: "POST", bearer: key)
        XCTAssertEqual(authorizedNonGetHealth.status, 404, "path=\(path)")
      }

      let warmup = try await Self.request(
        path: "/anthropic/api/hello", port: selectedPort, method: "HEAD")
      XCTAssertEqual(warmup.status, 204)
      XCTAssertTrue(warmup.data.isEmpty)

      let unauthorized = try await Self.request(path: "/", port: selectedPort)
      XCTAssertEqual(unauthorized.status, 401)

      for path in [
        "/anthropic/v1/messages", "/v1/messages?beta=true", "/anthropic/v1/models",
        "/v1/messages/count_tokens",
      ] {
        let response = try await Self.request(path: path, port: selectedPort)
        XCTAssertEqual(response.status, 401, "path=\(path)")
        let object = try Self.jsonObject(response.data)
        XCTAssertEqual(object["type"] as? String, "error", "path=\(path)")
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["type"] as? String, "authentication_error", "path=\(path)")
        XCTAssertNil(error["param"], "path=\(path)")
        XCTAssertNil(error["code"], "path=\(path)")
      }

      let unauthorizedOpenAI = try await Self.request(
        path: "/v1/chat/completions", port: selectedPort)
      XCTAssertEqual(unauthorizedOpenAI.status, 401)
      let unauthorizedOpenAIJSON = try Self.jsonObject(unauthorizedOpenAI.data)
      XCTAssertNil(unauthorizedOpenAIJSON["type"])
      let openAIError = try XCTUnwrap(unauthorizedOpenAIJSON["error"] as? [String: Any])
      XCTAssertNotNil(openAIError["param"])
      XCTAssertNotNil(openAIError["code"])

      let invalidAnthropic = try await Self.request(
        path: "/v1/messages",
        port: selectedPort,
        method: "POST",
        bearer: key,
        json: ["model": "gpt-4o", "messages": []])
      XCTAssertEqual(invalidAnthropic.status, 400)
      let invalidAnthropicJSON = try Self.jsonObject(invalidAnthropic.data)
      XCTAssertEqual(invalidAnthropicJSON["type"] as? String, "error")
      let invalidAnthropicError = try XCTUnwrap(
        invalidAnthropicJSON["error"] as? [String: Any])
      XCTAssertEqual(invalidAnthropicError["type"] as? String, "invalid_request_error")

      let missingAnthropicRoute = try await Self.request(
        path: "/anthropic/v1/not-real", port: selectedPort, bearer: key)
      XCTAssertEqual(missingAnthropicRoute.status, 404)
      let missingAnthropicJSON = try Self.jsonObject(missingAnthropicRoute.data)
      XCTAssertEqual(missingAnthropicJSON["type"] as? String, "error")
      let missingAnthropicError = try XCTUnwrap(
        missingAnthropicJSON["error"] as? [String: Any])
      XCTAssertEqual(missingAnthropicError["type"] as? String, "not_found_error")

      let authorized = try await Self.request(path: "/", port: selectedPort, bearer: key)
      XCTAssertEqual(authorized.status, 200)
      XCTAssertTrue(String(decoding: authorized.data, as: UTF8.self).contains("CopilotBridge"))
    } catch {
      await server.stop()
      throw error
    }
    await server.stop()
  }

  func testBridgeEventsRedactClientInputAndBoundClientErrorMessages() async throws {
    let key = "integration-test-log-redaction-key"
    let sentinel = "CLIENT_SECRET_SENTINEL_" + String(repeating: "🔐", count: 2_000)
    let recorder = BridgeEventRecorder()
    var runningServer: ProxyServer?
    var selectedPort = 0

    for _ in 0..<20 {
      let port = Int.random(in: 40_000...59_999)
      let server = ProxyServer(
        configuration: BridgeConfiguration(
          port: port,
          localAPIKey: key,
          modelAliases: ["log-redaction-alias": "gpt-4o"]
        ),
        onEvent: { recorder.record($0) }
      )
      do {
        try await server.start()
        runningServer = server
        selectedPort = port
        break
      } catch {
        continue
      }
    }
    let server = try XCTUnwrap(runningServer, "Could not find a free loopback port")

    do {
      let response = try await Self.request(
        path: "/v1/messages",
        port: selectedPort,
        method: "POST",
        bearer: key,
        json: [
          "model": "log-redaction-alias",
          "max_tokens": 1,
          "messages": [["role": sentinel, "content": "private request content"]],
        ])
      XCTAssertEqual(response.status, 400)
      let object = try Self.jsonObject(response.data)
      let error = try XCTUnwrap(object["error"] as? [String: Any])
      let clientMessage = try XCTUnwrap(error["message"] as? String)
      XCTAssertLessThanOrEqual(clientMessage.utf8.count, 1_024)

      let invalidToolInput = try await Self.request(
        path: "/v1/messages",
        port: selectedPort,
        method: "POST",
        bearer: key,
        json: [
          "model": "log-redaction-alias",
          "max_tokens": 1,
          "messages": [
            [
              "role": "assistant",
              "content": [
                [
                  "type": "tool_use",
                  "id": "tool_1",
                  "name": "lookup",
                  "input": "TOOL_INPUT_SENTINEL",
                ]
              ],
            ]
          ],
        ])
      XCTAssertEqual(invalidToolInput.status, 400)
      XCTAssertEqual(
        ((try Self.jsonObject(invalidToolInput.data)["error"] as? [String: Any])?["type"]
          as? String),
        "invalid_request_error")
      let healthAfterMalformedInput = try await Self.request(path: "/healthz", port: selectedPort)
      XCTAssertEqual(healthAfterMalformedInput.status, 200)

      let events = recorder.snapshot()
      let eventDescriptions = events.map(Self.eventDescription)
      XCTAssertTrue(eventDescriptions.contains("请求被拒绝：格式或参数无效。"))
      XCTAssertFalse(eventDescriptions.joined(separator: "\n").contains("CLIENT_SECRET_SENTINEL_"))
      XCTAssertFalse(eventDescriptions.joined(separator: "\n").contains("TOOL_INPUT_SENTINEL"))
      XCTAssertTrue(eventDescriptions.allSatisfy { $0.utf8.count <= 1_024 })
    } catch {
      await server.stop()
      throw error
    }
    await server.stop()
  }

  func testHTTP11PipelinedHealthRequestsCompleteInOrder() async throws {
    let key = "integration-test-pipeline-key"
    var runningServer: ProxyServer?
    var selectedPort = 0

    for _ in 0..<20 {
      let port = Int.random(in: 40_000...59_999)
      let server = ProxyServer(configuration: BridgeConfiguration(port: port, localAPIKey: key))
      do {
        try await server.start()
        runningServer = server
        selectedPort = port
        break
      } catch {
        continue
      }
    }
    let server = try XCTUnwrap(runningServer, "Could not find a free loopback port")

    do {
      let port = selectedPort
      let response = try await Task.detached { @Sendable in
        try Self.sendPipelinedHealthRequests(port)
      }
      .value
      XCTAssertEqual(response.components(separatedBy: "HTTP/1.1 200 OK").count - 1, 2)
      XCTAssertTrue(response.contains("Connection: keep-alive"))
      XCTAssertTrue(response.contains("Connection: close"))
    } catch {
      await server.stop()
      throw error
    }
    await server.stop()
  }

  func testServerStopCancelsAndDrainsInFlightRequest() async throws {
    let started = expectation(description: "request handler started")
    let cancelled = expectation(description: "request handler cancelled")
    var runningServer: LocalHTTPServer?
    var selectedPort = 0

    for _ in 0..<20 {
      let port = Int.random(in: 40_000...59_999)
      let server = LocalHTTPServer(
        configuration: BridgeConfiguration(port: port, localAPIKey: "unused")
      ) { _, responder in
        started.fulfill()
        do {
          try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
          cancelled.fulfill()
        } catch {
          XCTFail("Unexpected sleep failure: \(error)")
        }
        try? await responder.finish()
      }
      do {
        try await server.start()
        runningServer = server
        selectedPort = port
        break
      } catch {
        continue
      }
    }
    let server = try XCTUnwrap(runningServer, "Could not find a free loopback port")
    let port = selectedPort
    let requestTask = Task { @Sendable in try? await Self.request(path: "/slow", port: port) }

    await fulfillment(of: [started], timeout: 3)
    await server.stop()
    await fulfillment(of: [cancelled], timeout: 3)
    requestTask.cancel()
  }

  private static func request(
    path: String, host: String = "127.0.0.1", port: Int, method: String = "GET",
    bearer: String? = nil, headers: [String: String] = [:], json: [String: Any]? = nil
  ) async throws -> (
    status: Int, data: Data, response: HTTPURLResponse?
  ) {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host.contains(":") ? "[\(host)]" : host
    components.port = port
    let relative = try XCTUnwrap(URLComponents(string: path))
    components.path = relative.path
    components.percentEncodedQuery = relative.percentEncodedQuery
    var request = URLRequest(url: try XCTUnwrap(components.url))
    request.httpMethod = method
    request.timeoutInterval = 3
    if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if let json {
      request.httpBody = try JSONSerialization.data(withJSONObject: json)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as? HTTPURLResponse
    return (http?.statusCode ?? 0, data, http)
  }

  private static func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private static func canonicalJSON(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private static func commaSeparatedHeader(
    _ name: String, response: HTTPURLResponse?
  ) throws -> Set<String> {
    let value = try XCTUnwrap(response?.value(forHTTPHeaderField: name))
    return Set(
      value.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      })
  }

  private static func sseJSONEvents(_ data: Data) throws -> [(name: String?, object: [String: Any])]
  {
    var decoder = SSEDecoder()
    var events: [(name: String?, object: [String: Any])] = []
    for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
      if let event = try decoder.feed(line: line) {
        events.append((event.name, try jsonObject(Data(event.data.utf8))))
      }
    }
    if let event = decoder.finish() {
      events.append((event.name, try jsonObject(Data(event.data.utf8))))
    }
    return events
  }

  private static func eventDescription(_ event: BridgeEvent) -> String {
    switch event {
    case .info(let message), .warning(let message), .error(let message):
      return message
    case .request(let method, let path, let status, let milliseconds):
      return "\(method) \(path) \(status) \(milliseconds)"
    }
  }

  private static func sendPipelinedHealthRequests(_ port: Int) throws -> String {
    let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
    defer { Darwin.close(fileDescriptor) }

    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    guard
      setsockopt(
        fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
        socklen_t(MemoryLayout<timeval>.size)) == 0
    else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connectionResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connectionResult == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
    }

    let request =
      "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n"
      + "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    let sent = request.withCString {
      send(fileDescriptor, $0, request.utf8.count, 0)
    }
    guard sent == request.utf8.count else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = recv(fileDescriptor, &buffer, buffer.count, 0)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      data.append(buffer, count: count)
    }
    return String(decoding: data, as: UTF8.self)
  }
}

private actor RequestRecorder {
  private var counts: [String: Int] = [:]
  private var bodies: [String: [Data]] = [:]
  private var headers: [String: [[String: String]]] = [:]

  func record(_ request: BridgeHTTPRequest) {
    counts[request.path, default: 0] += 1
    if !request.body.isEmpty {
      bodies[request.path, default: []].append(request.body)
    }
    var headerSnapshot: [String: String] = [:]
    for name in ["Authorization", "Anthropic-Version", "Anthropic-Beta", "X-Initiator"] {
      if let value = request.headers.first(name: name) {
        headerSnapshot[name.lowercased()] = value
      }
    }
    headers[request.path, default: []].append(headerSnapshot)
  }

  func snapshot() -> [String: Int] { counts }

  func lastBody(for path: String) -> Data? { bodies[path]?.last }

  func lastHeaders(for path: String) -> [String: String]? { headers[path]?.last }
}

private final class BridgeEventRecorder: @unchecked Sendable {
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
