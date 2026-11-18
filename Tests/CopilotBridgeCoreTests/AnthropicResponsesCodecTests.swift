import Foundation
import XCTest

@testable import CopilotBridgeCore

final class AnthropicResponsesCodecTests: XCTestCase {
  func testMapsSystemTextImageAndSamplingFieldsToResponses() throws {
    let output = try AnthropicResponsesCodec.toOpenAI(
      [
        "max_tokens": 512,
        "messages": [
          [
            "content": [
              ["text": "describe", "type": "text"],
              [
                "source": [
                  "data": "aGVsbG8=", "media_type": "image/png", "type": "base64",
                ],
                "type": "image",
              ],
              [
                "source": ["type": "url", "url": "https://example.com/image.webp"],
                "type": "image",
              ],
            ],
            "role": "user",
          ]
        ],
        "metadata": ["user_id": "client-user"],
        "model": "requested-model",
        "stream": true,
        "system": [
          ["text": "first", "type": "text"],
          [
            "cache_control": ["ttl": "5m", "type": "ephemeral"],
            "text": "second",
            "type": "text",
          ],
        ],
        "temperature": 0.25,
        "top_p": 0.9,
      ],
      resolvedModel: "resolved-model")

    XCTAssertEqual(output["model"] as? String, "resolved-model")
    XCTAssertEqual(output["max_output_tokens"] as? Int, 512)
    XCTAssertEqual(output["store"] as? Bool, false)
    XCTAssertEqual(output["stream"] as? Bool, true)
    XCTAssertEqual(output["instructions"] as? String, "first\n\nsecond")
    XCTAssertEqual(output["temperature"] as? Double, 0.25)
    XCTAssertEqual(output["top_p"] as? Double, 0.9)
    XCTAssertEqual(output["user"] as? String, "client-user")

    let input = try XCTUnwrap(output["input"] as? [[String: Any]])
    XCTAssertEqual(input.count, 1)
    XCTAssertEqual(input[0]["type"] as? String, "message")
    XCTAssertEqual(input[0]["role"] as? String, "user")
    let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
    XCTAssertEqual(
      content.map { $0["type"] as? String }, ["input_text", "input_image", "input_image"])
    XCTAssertEqual(content[1]["image_url"] as? String, "data:image/png;base64,aGVsbG8=")
    XCTAssertEqual(content[2]["image_url"] as? String, "https://example.com/image.webp")
    XCTAssertEqual(content[1]["detail"] as? String, "auto")
  }

  func testMapsAssistantToolUseAndUserToolResultAsStandaloneItems() throws {
    let output = try AnthropicResponsesCodec.toOpenAI([
      "max_tokens": 64,
      "messages": [
        [
          "content": [
            ["text": "I'll check.", "type": "text"],
            [
              "id": "call_weather",
              "input": ["city": "Paris"],
              "name": "weather",
              "type": "tool_use",
            ],
          ],
          "role": "assistant",
        ],
        [
          "content": [
            [
              "content": [
                ["text": "network timeout", "type": "text"],
                [
                  "source": ["type": "url", "url": "https://example.com/error.png"],
                  "type": "image",
                ],
              ],
              "is_error": true,
              "tool_use_id": "call_weather",
              "type": "tool_result",
            ],
            ["text": "Try another source.", "type": "text"],
          ],
          "role": "user",
        ],
      ],
      "model": "gpt-responses",
    ])

    let input = try XCTUnwrap(output["input"] as? [[String: Any]])
    XCTAssertEqual(
      input.map { $0["type"] as? String },
      ["message", "function_call", "function_call_output", "message"])
    XCTAssertEqual(input[0]["role"] as? String, "assistant")
    XCTAssertEqual(
      ((input[0]["content"] as? [[String: Any]])?.first)?["type"] as? String,
      "output_text")
    XCTAssertEqual(input[1]["call_id"] as? String, "call_weather")
    XCTAssertEqual(input[1]["name"] as? String, "weather")
    XCTAssertEqual(input[1]["arguments"] as? String, #"{"city":"Paris"}"#)
    XCTAssertEqual(input[2]["call_id"] as? String, "call_weather")

    let result = try XCTUnwrap(input[2]["output"] as? [[String: Any]])
    XCTAssertEqual(
      result.map { $0["type"] as? String }, ["input_text", "input_text", "input_image"])
    XCTAssertEqual(result[0]["text"] as? String, "ERROR")
    XCTAssertEqual(result[1]["text"] as? String, "network timeout")
    XCTAssertEqual(input[3]["role"] as? String, "user")
  }

  func testMapsFlatFunctionToolsAndResponsesToolChoice() throws {
    let output = try AnthropicResponsesCodec.toOpenAI([
      "max_tokens": 32,
      "messages": [["content": "hello", "role": "user"]],
      "model": "gpt-responses",
      "tool_choice": [
        "disable_parallel_tool_use": true,
        "name": "lookup",
        "type": "tool",
      ],
      "tools": [
        [
          "description": "Look up a value",
          "input_schema": [
            "properties": ["query": ["type": "string"]],
            "required": ["query"],
            "type": "object",
          ],
          "name": "lookup",
          "strict": true,
        ]
      ],
    ])

    let tool = try XCTUnwrap((output["tools"] as? [[String: Any]])?.first)
    XCTAssertEqual(tool["type"] as? String, "function")
    XCTAssertEqual(tool["name"] as? String, "lookup")
    XCTAssertEqual(tool["description"] as? String, "Look up a value")
    XCTAssertEqual(tool["strict"] as? Bool, true)
    XCTAssertNotNil(tool["parameters"] as? [String: Any])
    XCTAssertNil(tool["function"])

    let choice = try XCTUnwrap(output["tool_choice"] as? [String: Any])
    XCTAssertEqual(choice["type"] as? String, "function")
    XCTAssertEqual(choice["name"] as? String, "lookup")
    XCTAssertEqual(output["parallel_tool_calls"] as? Bool, false)

    for (anthropic, responses) in ["auto": "auto", "any": "required", "none": "none"] {
      let mapped = try AnthropicResponsesCodec.toOpenAI([
        "max_tokens": 1,
        "messages": [],
        "model": "gpt-responses",
        "tool_choice": ["type": anthropic],
      ])
      XCTAssertEqual(mapped["tool_choice"] as? String, responses)
    }
  }

  func testMapsCurrentAndLegacyStructuredOutputToResponsesTextFormat() throws {
    let schema: [String: Any] = [
      "additionalProperties": false,
      "properties": ["answer": ["type": "string"]],
      "required": ["answer"],
      "type": "object",
    ]
    let variants: [[String: Any]] = [
      ["output_config": ["effort": "high", "format": ["schema": schema, "type": "json_schema"]]],
      ["output_format": ["schema": schema, "type": "json_schema"]],
    ]
    for fields in variants {
      var request: [String: Any] = ["max_tokens": 100, "messages": [], "model": "gpt"]
      request.merge(fields) { _, replacement in replacement }
      let output = try AnthropicResponsesCodec.toOpenAI(request)
      let text = try XCTUnwrap(output["text"] as? [String: Any])
      let format = try XCTUnwrap(text["format"] as? [String: Any])
      XCTAssertEqual(format["type"] as? String, "json_schema")
      XCTAssertEqual(format["name"] as? String, "anthropic_output")
      XCTAssertEqual(format["strict"] as? Bool, true)
      XCTAssertTrue((format["schema"] as? NSDictionary)?.isEqual(to: schema) == true)
      XCTAssertNil(output["response_format"])
    }
  }

  func testRequestValidationFailsClosed() throws {
    let valid: [String: Any] = ["max_tokens": 1, "messages": [], "model": "gpt"]
    let mutations: [(String, Any)] = [
      ("max_tokens", 0),
      ("stream", 1),
      ("temperature", 1.1),
      ("top_p", Double.nan),
      ("stop_sequences", ["STOP"]),
      ("unknown", true),
      ("metadata", ["user_id": 1]),
      ("tool_choice", ["type": "tool"]),
      ("output_config", [:] as [String: Any]),
    ]
    for (key, value) in mutations {
      var request = valid
      request[key] = value
      XCTAssertThrowsError(try AnthropicResponsesCodec.toOpenAI(request), "\(key)=\(value)")
    }

    for source: [String: Any] in [
      ["type": "url", "url": "file:///tmp/image.png"],
      ["data": "not-base64", "media_type": "image/png", "type": "base64"],
      ["data": "aGVsbG8=", "media_type": "text/plain", "type": "base64"],
    ] {
      var request = valid
      request["messages"] = [
        ["content": [["source": source, "type": "image"]], "role": "user"]
      ]
      XCTAssertThrowsError(try AnthropicResponsesCodec.toOpenAI(request), "source=\(source)")
    }

    var unsupportedRole = valid
    unsupportedRole["messages"] = [["content": "not official", "role": "developer"]]
    XCTAssertThrowsError(try AnthropicResponsesCodec.toOpenAI(unsupportedRole))

    var invalidToolInput = valid
    invalidToolInput["messages"] = [
      [
        "content": [["id": "call", "input": [], "name": "lookup", "type": "tool_use"]],
        "role": "assistant",
      ]
    ]
    XCTAssertThrowsError(try AnthropicResponsesCodec.toOpenAI(invalidToolInput))
  }

  func testPreservesInlineSystemMessagesAtTheirResponsesInputPositions() throws {
    let output = try AnthropicResponsesCodec.toOpenAI([
      "max_tokens": 64,
      "messages": [
        ["content": "U1", "role": "user"],
        ["content": "MID-STRING", "role": "system"],
        ["content": "A1", "role": "assistant"],
        ["content": "U2", "role": "user"],
        [
          "content": [
            ["text": "MID-BLOCK-A", "type": "text"],
            [
              "cache_control": ["type": "ephemeral"],
              "text": "MID-BLOCK-B",
              "type": "text",
            ],
          ],
          "role": "system",
        ],
      ],
      "model": "gpt-responses",
      "system": "ROOT",
    ])

    XCTAssertEqual(output["instructions"] as? String, "ROOT")
    let input = try XCTUnwrap(output["input"] as? [[String: Any]])
    XCTAssertEqual(
      input.map { $0["role"] as? String }, ["user", "system", "assistant", "user", "system"])
    XCTAssertEqual(input.map { $0["type"] as? String }, Array(repeating: "message", count: 5))
    XCTAssertEqual(
      (input[1]["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String },
      ["MID-STRING"])
    XCTAssertEqual(
      (input[4]["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String },
      ["MID-BLOCK-A", "MID-BLOCK-B"])
    XCTAssertEqual(
      (input[4]["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String },
      ["input_text", "input_text"])
  }

  func testTranslatesCompletedResponsesTextFunctionCallsAndUsage() throws {
    let output = try AnthropicResponsesCodec.fromOpenAI(
      [
        "error": NSNull(),
        "id": "resp_123",
        "model": "gpt-responses",
        "object": "response",
        "output": [
          ["id": "rs_1", "status": "completed", "summary": [], "type": "reasoning"],
          [
            "content": [
              ["annotations": [], "text": "Checking.", "type": "output_text"]
            ],
            "id": "msg_1",
            "role": "assistant",
            "status": "completed",
            "type": "message",
          ],
          [
            "arguments": #"{"city":"Paris"}"#,
            "call_id": "call_1",
            "id": "fc_1",
            "name": "weather",
            "status": "completed",
            "type": "function_call",
          ],
        ],
        "status": "completed",
        "usage": [
          "input_tokens": 12,
          "input_tokens_details": ["cache_write_tokens": 2, "cached_tokens": 5],
          "output_tokens": 7,
          "total_tokens": 19,
        ],
      ],
      requestedModel: "client-alias")

    XCTAssertEqual(output["id"] as? String, "msg_resp_123")
    XCTAssertEqual(output["model"] as? String, "gpt-responses")
    XCTAssertEqual(output["stop_reason"] as? String, "tool_use")
    let content = try XCTUnwrap(output["content"] as? [[String: Any]])
    XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "tool_use"])
    XCTAssertEqual(content[0]["text"] as? String, "Checking.")
    XCTAssertEqual(content[1]["id"] as? String, "call_1")
    XCTAssertEqual((content[1]["input"] as? [String: String])?["city"], "Paris")
    let usage = try XCTUnwrap(output["usage"] as? [String: Any])
    XCTAssertEqual(usage["input_tokens"] as? Int, 12)
    XCTAssertEqual(usage["output_tokens"] as? Int, 7)
    XCTAssertEqual(usage["cache_read_input_tokens"] as? Int, 5)
    XCTAssertEqual(usage["cache_creation_input_tokens"] as? Int, 2)
  }

  func testMapsRefusalAndAllSupportedIncompleteReasons() throws {
    let refusal = try AnthropicResponsesCodec.fromOpenAI(
      response(
        output: [
          [
            "content": [["refusal": "Cannot comply.", "type": "refusal"]],
            "id": "msg_1",
            "role": "assistant",
            "status": "completed",
            "type": "message",
          ]
        ]),
      requestedModel: "gpt")
    XCTAssertEqual(refusal["stop_reason"] as? String, "refusal")
    XCTAssertEqual(
      ((refusal["content"] as? [[String: Any]])?.first)?["text"] as? String,
      "Cannot comply.")

    for (reason, expected) in [
      "max_output_tokens": "max_tokens",
      "content_filter": "refusal",
      "max_messages": "pause_turn",
      "steered": "pause_turn",
    ] {
      var source = response(output: [], status: "incomplete")
      source["incomplete_details"] = ["reason": reason]
      let translated = try AnthropicResponsesCodec.fromOpenAI(source, requestedModel: "gpt")
      XCTAssertEqual(translated["stop_reason"] as? String, expected, "reason=\(reason)")
    }
  }

  func testResponseValidationRejectsFailuresPartialCallsAndLossyAnnotations() throws {
    var failed = response(output: [], status: "failed")
    failed["error"] = ["message": "capacity"]
    XCTAssertThrowsError(try AnthropicResponsesCodec.fromOpenAI(failed, requestedModel: "gpt"))

    for status in ["in_progress", "queued", "cancelled", "future"] {
      XCTAssertThrowsError(
        try AnthropicResponsesCodec.fromOpenAI(
          response(output: [], status: status), requestedModel: "gpt"))
    }

    var missingUsage = response(output: [])
    missingUsage.removeValue(forKey: "usage")
    XCTAssertThrowsError(
      try AnthropicResponsesCodec.fromOpenAI(missingUsage, requestedModel: "gpt"))

    let invalidCalls: [[String: Any]] = [
      [
        "arguments": #"{"unterminated":"#,
        "call_id": "call_1",
        "name": "lookup",
        "status": "completed",
        "type": "function_call",
      ],
      [
        "arguments": "{}",
        "call_id": "call_1",
        "name": "lookup",
        "status": "incomplete",
        "type": "function_call",
      ],
    ]
    for call in invalidCalls {
      XCTAssertThrowsError(
        try AnthropicResponsesCodec.fromOpenAI(
          response(output: [call]), requestedModel: "gpt"))
    }

    XCTAssertThrowsError(
      try AnthropicResponsesCodec.fromOpenAI(
        response(output: [
          [
            "content": [
              [
                "annotations": [["title": "source", "type": "url_citation"]],
                "text": "cited",
                "type": "output_text",
              ]
            ],
            "id": "msg_1",
            "role": "assistant",
            "status": "completed",
            "type": "message",
          ]
        ]),
        requestedModel: "gpt"))
  }

  func testEncodesBufferedMessageAsCompleteAnthropicSSESequence() throws {
    let data = try AnthropicResponsesCodec.encodeSSE(message: [
      "content": [
        ["signature": "signed", "thinking": "considering", "type": "thinking"],
        ["text": "answer", "type": "text"],
        ["id": "call_1", "input": ["q": "swift"], "name": "lookup", "type": "tool_use"],
      ],
      "id": "msg_123",
      "model": "gpt-responses",
      "role": "assistant",
      "stop_reason": "tool_use",
      "stop_sequence": NSNull(),
      "type": "message",
      "usage": [
        "cache_read_input_tokens": 3,
        "input_tokens": 10,
        "output_tokens": 6,
      ],
    ])
    let events = try sseEvents(data)

    XCTAssertEqual(
      events.map(\.name),
      [
        "message_start",
        "content_block_start", "content_block_delta", "content_block_delta",
        "content_block_stop",
        "content_block_start", "content_block_delta", "content_block_stop",
        "content_block_start", "content_block_delta", "content_block_stop",
        "message_delta", "message_stop",
      ])
    let deltaTypes = events.compactMap {
      ($0.object["delta"] as? [String: Any])?["type"] as? String
    }
    XCTAssertEqual(
      deltaTypes, ["thinking_delta", "signature_delta", "text_delta", "input_json_delta"])

    let startMessage = try XCTUnwrap(events[0].object["message"] as? [String: Any])
    let startUsage = try XCTUnwrap(startMessage["usage"] as? [String: Any])
    XCTAssertEqual(startUsage["input_tokens"] as? Int, 10)
    XCTAssertEqual(startUsage["output_tokens"] as? Int, 0)
    XCTAssertEqual(startUsage["cache_read_input_tokens"] as? Int, 3)

    let messageDelta = try XCTUnwrap(events[events.count - 2].object["delta"] as? [String: Any])
    XCTAssertEqual(messageDelta["stop_reason"] as? String, "tool_use")
    let finalUsage = try XCTUnwrap(events[events.count - 2].object["usage"] as? [String: Any])
    XCTAssertEqual(finalUsage["output_tokens"] as? Int, 6)
    XCTAssertEqual(
      (events[9].object["delta"] as? [String: Any])?["partial_json"] as? String,
      #"{"q":"swift"}"#)
  }

  func testSSEEncodingSupportsRedactedThinkingAndRejectsMalformedMessages() throws {
    let events = try sseEvents(
      AnthropicResponsesCodec.encodeSSE(message: [
        "content": [["data": "opaque", "type": "redacted_thinking"]],
        "id": "msg_1",
        "model": "gpt",
        "role": "assistant",
        "stop_reason": "end_turn",
        "stop_sequence": NSNull(),
        "type": "message",
        "usage": ["input_tokens": 1, "output_tokens": 1],
      ]))
    let start = try XCTUnwrap(events[1].object["content_block"] as? [String: Any])
    XCTAssertEqual(start["type"] as? String, "redacted_thinking")
    XCTAssertEqual(start["data"] as? String, "opaque")
    XCTAssertFalse(events.contains { $0.name == "content_block_delta" })

    XCTAssertThrowsError(
      try AnthropicResponsesCodec.encodeSSE(message: [
        "content": [["id": "call", "input": [], "name": "tool", "type": "tool_use"]],
        "id": "msg_1",
        "model": "gpt",
        "role": "assistant",
        "stop_reason": "tool_use",
        "type": "message",
        "usage": ["input_tokens": 1, "output_tokens": 1],
      ]))
  }

  private func response(
    output: [[String: Any]], status: String = "completed"
  ) -> [String: Any] {
    [
      "error": NSNull(),
      "id": "resp_test",
      "model": "gpt",
      "object": "response",
      "output": output,
      "status": status,
      "usage": ["input_tokens": 1, "output_tokens": 1, "total_tokens": 2],
    ]
  }

  private struct SSEEvent {
    let name: String
    let object: [String: Any]
  }

  private func sseEvents(_ data: Data) throws -> [SSEEvent] {
    let text = String(decoding: data, as: UTF8.self)
    return try text.split(separator: "\n\n").map { frame in
      let lines = frame.split(separator: "\n", omittingEmptySubsequences: false)
      guard lines.count == 2, lines[0].hasPrefix("event: "), lines[1].hasPrefix("data: ") else {
        throw BridgeError.protocolFailure("Malformed test SSE frame")
      }
      let name = String(lines[0].dropFirst("event: ".count))
      let json = Data(lines[1].dropFirst("data: ".count).utf8)
      guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
        throw BridgeError.protocolFailure("Malformed test SSE JSON")
      }
      return SSEEvent(name: name, object: object)
    }
  }
}
