import XCTest

@testable import CopilotBridgeCore

final class AnthropicStreamTranslatorTests: XCTestCase {
  func testTextStreamHasValidEventOrder() throws {
    let translator = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    var bytes = Data()
    bytes.append(translator.start())
    bytes.append(
      try translator.consume([
        "id": "chatcmpl_1",
        "model": "claude-sonnet-4.6",
        "choices": [["index": 0, "delta": ["content": "Hello"], "finish_reason": NSNull()]],
      ]))
    bytes.append(
      try translator.consume([
        "id": "chatcmpl_1",
        "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]],
        "usage": ["prompt_tokens": 4, "completion_tokens": 2],
      ]))
    bytes.append(try translator.end())
    let text = String(decoding: bytes, as: UTF8.self)

    assertOrder(
      [
        "event: message_start", "event: content_block_start", "event: content_block_delta",
        "event: content_block_stop", "event: message_delta", "event: message_stop",
      ],
      in: text
    )
    XCTAssertTrue(text.contains("Hello"))
    XCTAssertTrue(text.contains("end_turn"))
  }

  func testToolArgumentsAreBufferedIntoOneSequentialBlock() throws {
    let translator = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    var bytes = translator.start()
    bytes.append(
      try translator.consume([
        "choices": [
          [
            "index": 0,
            "delta": [
              "tool_calls": [
                [
                  "index": 0,
                  "id": "call_1",
                  "function": ["name": "lookup", "arguments": "{\"q\":"],
                ]
              ]
            ],
            "finish_reason": NSNull(),
          ]
        ]
      ]))
    bytes.append(
      try translator.consume([
        "choices": [
          [
            "index": 0,
            "delta": ["tool_calls": [["index": 0, "function": ["arguments": "\"swift\"}"]]]],
            "finish_reason": "tool_calls",
          ]
        ]
      ]))
    bytes.append(try translator.end())
    let text = String(decoding: bytes, as: UTF8.self)

    XCTAssertTrue(text.contains("tool_use"))
    XCTAssertTrue(text.contains("input_json_delta"))
    XCTAssertTrue(text.contains(#"{\"q\":\"swift\"}"#))
    XCTAssertTrue(text.contains(#""stop_reason":"tool_use""#))
  }

  func testToolArgumentsPreserveManyFragmentsAtAccumulationLimit() throws {
    let id = "call_fragmented"
    let name = "lookup"
    let opening = #"{"value":""#
    let fragment = String(repeating: "x", count: 1_024)
    let fragmentCount = 512
    let closing = #""}"#
    let arguments =
      opening + String(repeating: "x", count: fragment.count * fragmentCount) + closing
    let maximumBytes = id.utf8.count + name.utf8.count + arguments.utf8.count
    let translator = AnthropicStreamTranslator(
      requestedModel: "claude-sonnet-4.6",
      maximumAccumulatedFieldBytes: maximumBytes)

    _ = try translator.consume([
      "choices": [
        [
          "index": 0,
          "delta": [
            "tool_calls": [
              [
                "index": 0,
                "id": id,
                "function": ["name": name, "arguments": opening],
              ]
            ]
          ],
          "finish_reason": NSNull(),
        ]
      ]
    ])
    for _ in 0..<fragmentCount {
      _ = try translator.consume([
        "choices": [
          [
            "index": 0,
            "delta": ["tool_calls": [["index": 0, "function": ["arguments": fragment]]]],
            "finish_reason": NSNull(),
          ]
        ]
      ])
    }
    _ = try translator.consume([
      "choices": [
        [
          "index": 0,
          "delta": ["tool_calls": [["index": 0, "function": ["arguments": closing]]]],
          "finish_reason": "tool_calls",
        ]
      ]
    ])

    let events = try decodedEvents(try translator.end())
    let partialJSON = events.compactMap { event -> String? in
      guard event.name == "content_block_delta",
        let delta = event.object["delta"] as? [String: Any],
        delta["type"] as? String == "input_json_delta"
      else {
        return nil
      }
      return delta["partial_json"] as? String
    }
    XCTAssertEqual(partialJSON, [arguments])
  }

  func testRejectsToolCallCutOffByLengthLimit() throws {
    let translator = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    _ = try translator.consume([
      "choices": [
        [
          "index": 0,
          "delta": [
            "tool_calls": [
              [
                "index": 0,
                "id": "call_1",
                "function": ["name": "shell", "arguments": "{\"command\":"],
              ]
            ]
          ],
          "finish_reason": "length",
        ]
      ]
    ])
    XCTAssertThrowsError(try translator.end())
  }

  func testRejectsStreamWithoutTerminalFinishReason() throws {
    let translator = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    _ = try translator.consume([
      "choices": [["index": 0, "delta": ["content": "partial"], "finish_reason": NSNull()]]
    ])
    XCTAssertThrowsError(try translator.end())
  }

  func testRejectsToolFinishReasonWithoutToolCall() throws {
    let translator = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    _ = try translator.consume([
      "choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]
    ])
    XCTAssertThrowsError(try translator.end())
  }

  func testRefusalDeltaIsPreservedAsText() throws {
    let translator = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    var bytes = translator.start()
    bytes.append(
      try translator.consume([
        "choices": [
          ["index": 0, "delta": ["refusal": "I cannot do that."], "finish_reason": "refusal"]
        ]
      ]))
    bytes.append(try translator.end())
    let text = String(decoding: bytes, as: UTF8.self)

    XCTAssertTrue(text.contains("I cannot do that."))
    XCTAssertTrue(text.contains(#""stop_reason":"refusal""#))
  }

  func testSignatureOnlyStreamBecomesOneRedactedThinkingBlockBeforeText() throws {
    let translator = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    var bytes = translator.start()
    bytes.append(
      try translator.consume([
        "choices": [
          ["index": 0, "delta": ["reasoning_opaque": "sig-"], "finish_reason": NSNull()]
        ]
      ]))
    bytes.append(
      try translator.consume([
        "choices": [
          ["index": 0, "delta": ["reasoning_opaque": "part"], "finish_reason": NSNull()]
        ]
      ]))
    bytes.append(
      try translator.consume([
        "choices": [
          ["index": 0, "delta": ["content": "answer"], "finish_reason": "stop"]
        ]
      ]))
    bytes.append(try translator.end())

    let events = try decodedEvents(bytes)
    let starts = events.filter { $0.name == "content_block_start" }
    XCTAssertEqual(starts.count, 2)
    XCTAssertEqual(starts[0].object["index"] as? Int, 0)
    let redacted = try XCTUnwrap(starts[0].object["content_block"] as? [String: Any])
    XCTAssertEqual(redacted["type"] as? String, "redacted_thinking")
    XCTAssertEqual(redacted["data"] as? String, "sig-part")
    XCTAssertEqual(starts[1].object["index"] as? Int, 1)
    let textBlock = try XCTUnwrap(starts[1].object["content_block"] as? [String: Any])
    XCTAssertEqual(textBlock["type"] as? String, "text")

    let deltaTypes = events.compactMap { event in
      (event.object["delta"] as? [String: Any])?["type"] as? String
    }
    XCTAssertFalse(deltaTypes.contains("thinking_delta"))
    XCTAssertFalse(deltaTypes.contains("signature_delta"))
  }

  func testSignatureOnlyStreamIsFlushedAtEndWithoutText() throws {
    let translator = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    var bytes = try translator.consume([
      "choices": [
        ["index": 0, "delta": ["reasoning_opaque": "opaque"], "finish_reason": "stop"]
      ]
    ])
    bytes.append(try translator.end())

    let starts = try decodedEvents(bytes).filter { $0.name == "content_block_start" }
    XCTAssertEqual(starts.count, 1)
    let block = try XCTUnwrap(starts[0].object["content_block"] as? [String: Any])
    XCTAssertEqual(block["type"] as? String, "redacted_thinking")
    XCTAssertEqual(block["data"] as? String, "opaque")
  }

  func testThinkingStreamKeepsOpaqueAsSignatureDelta() throws {
    let translator = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    var bytes = try translator.consume([
      "choices": [
        [
          "index": 0,
          "delta": ["reasoning_text": "thought", "reasoning_opaque": "signature"],
          "finish_reason": "stop",
        ]
      ]
    ])
    bytes.append(try translator.end())

    let events = try decodedEvents(bytes)
    let deltaTypes = events.compactMap { event in
      (event.object["delta"] as? [String: Any])?["type"] as? String
    }
    XCTAssertEqual(deltaTypes, ["thinking_delta", "signature_delta"])
  }

  func testRejectsUnboundedOpaqueAndToolArgumentAccumulation() throws {
    let opaqueTranslator = AnthropicStreamTranslator(
      requestedModel: "claude-sonnet-4.6", maximumAccumulatedFieldBytes: 4)
    _ = try opaqueTranslator.consume([
      "choices": [
        ["index": 0, "delta": ["reasoning_opaque": "1234"], "finish_reason": NSNull()]
      ]
    ])
    XCTAssertThrowsError(
      try opaqueTranslator.consume([
        "choices": [
          ["index": 0, "delta": ["reasoning_opaque": "5"], "finish_reason": NSNull()]
        ]
      ]))

    let toolTranslator = AnthropicStreamTranslator(
      requestedModel: "claude-sonnet-4.6", maximumAccumulatedFieldBytes: 14)
    _ = try toolTranslator.consume([
      "choices": [
        [
          "index": 0,
          "delta": [
            "tool_calls": [
              ["index": 0, "id": "call_1", "function": ["name": "tool", "arguments": "1234"]]
            ]
          ],
          "finish_reason": NSNull(),
        ]
      ]
    ])
    XCTAssertThrowsError(
      try toolTranslator.consume([
        "choices": [
          [
            "index": 0,
            "delta": ["tool_calls": [["index": 0, "function": ["arguments": "5"]]]],
            "finish_reason": NSNull(),
          ]
        ]
      ]))
  }

  func testRejectsToolIndexFloodMetadataOverflowAndIdentityRewrite() throws {
    let indexLimited = AnthropicStreamTranslator(
      requestedModel: "claude-sonnet-4.6",
      maximumAccumulatedFieldBytes: 1_024,
      maximumToolCalls: 2)
    for index in 0..<2 {
      _ = try indexLimited.consume([
        "choices": [
          [
            "index": 0,
            "delta": [
              "tool_calls": [
                [
                  "index": index,
                  "id": "call_\(index)",
                  "function": ["name": "tool_\(index)", "arguments": ""],
                ]
              ]
            ],
            "finish_reason": NSNull(),
          ]
        ]
      ])
    }
    XCTAssertThrowsError(
      try indexLimited.consume([
        "choices": [
          [
            "index": 0,
            "delta": [
              "tool_calls": [
                ["index": 2, "id": "call_2", "function": ["name": "tool_2"]]
              ]
            ],
            "finish_reason": NSNull(),
          ]
        ]
      ]))

    let metadataLimited = AnthropicStreamTranslator(
      requestedModel: "claude-sonnet-4.6", maximumAccumulatedFieldBytes: 8)
    XCTAssertThrowsError(
      try metadataLimited.consume([
        "choices": [
          [
            "index": 0,
            "delta": [
              "tool_calls": [
                ["index": 0, "id": "id", "function": ["name": "1234567"]]
              ]
            ],
            "finish_reason": NSNull(),
          ]
        ]
      ]))

    let stableIdentity = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    _ = try stableIdentity.consume([
      "choices": [
        [
          "index": 0,
          "delta": [
            "tool_calls": [
              ["index": 0, "id": "call_a", "function": ["name": "lookup"]]
            ]
          ],
          "finish_reason": NSNull(),
        ]
      ]
    ])
    XCTAssertThrowsError(
      try stableIdentity.consume([
        "choices": [
          [
            "index": 0,
            "delta": ["tool_calls": [["index": 0, "id": "call_b"]]],
            "finish_reason": NSNull(),
          ]
        ]
      ]))
  }

  func testPingProducesAnthropicKeepAliveEvent() {
    let translator = AnthropicStreamTranslator(requestedModel: "claude-sonnet-4.6")
    let text = String(decoding: translator.ping(), as: UTF8.self)

    XCTAssertTrue(text.contains("event: ping"))
    XCTAssertTrue(text.contains(#""type":"ping""#))
  }

  private func decodedEvents(_ data: Data) throws -> [(name: String?, object: [String: Any])] {
    var decoder = SSEDecoder()
    var decoded: [(name: String?, object: [String: Any])] = []
    for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
      if let event = try decoder.feed(line: line) {
        let object = try XCTUnwrap(
          try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any])
        decoded.append((event.name, object))
      }
    }
    if let event = decoder.finish() {
      let object = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any])
      decoded.append((event.name, object))
    }
    return decoded
  }

  private func assertOrder(
    _ needles: [String], in haystack: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    var lowerBound = haystack.startIndex
    for needle in needles {
      guard let range = haystack.range(of: needle, range: lowerBound..<haystack.endIndex) else {
        XCTFail("Missing or out-of-order: \(needle)", file: file, line: line)
        return
      }
      lowerBound = range.upperBound
    }
  }
}
