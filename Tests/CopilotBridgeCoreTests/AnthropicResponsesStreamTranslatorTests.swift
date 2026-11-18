import XCTest

@testable import CopilotBridgeCore

final class AnthropicResponsesStreamTranslatorTests: XCTestCase {
  func testCopilotResponseIDReplacementKeepsOneDownstreamMessage() throws {
    var stream = Harness()
    var bytes = try stream.created()
    var progress = Self.response(status: "in_progress")
    progress["id"] = "resp_provider_after_provisional_id"
    bytes.append(try stream.send("response.in_progress", ["response": progress]))
    bytes.append(
      try stream.send(
        "response.output_item.added",
        ["item": messageItem(status: "in_progress", content: []), "output_index": 0]))
    bytes.append(
      try stream.send("response.content_part.added", contentFields(part: outputText(""))))
    bytes.append(
      try stream.send("response.output_text.delta", contentFields(extra: ["delta": "OK"])))
    bytes.append(
      try stream.send("response.output_text.done", contentFields(extra: ["text": "OK"])))
    bytes.append(
      try stream.send("response.content_part.done", contentFields(part: outputText("OK"))))
    let finalMessage = messageItem(status: "completed", content: [outputText("OK")])
    bytes.append(
      try stream.send(
        "response.output_item.done", ["item": finalMessage, "output_index": 0]))
    var completed = Self.response(
      status: "completed", output: [finalMessage], usage: basicUsage(input: 11, output: 5))
    completed["id"] = progress["id"]
    bytes.append(try stream.send("response.completed", ["response": completed]))
    try stream.translator.finish()

    let events = try decodedEvents(bytes)
    XCTAssertEqual(events.filter { $0.name == "message_start" }.count, 1)
    XCTAssertEqual(events.first?.object.path("message", "id") as? String, "msg_resp_stream_1")
    XCTAssertEqual(
      events.first { $0.name == "content_block_delta" }?.object.path("delta", "text") as? String,
      "OK")
    XCTAssertEqual(events.last?.name, "message_stop")
    XCTAssertFalse(stream.translator.sawFailure)
  }

  func testReplacedResponseIDDoesNotHideUpstreamFailureOrInvalidStatus() throws {
    var failed = Harness()
    _ = try failed.created()
    var response = Self.response(
      status: "failed", error: ["code": "server_error", "message": "upstream failure"])
    response["id"] = "resp_provider_failure"
    let event = try onlyEvent(failed.send("response.failed", ["response": response]))
    XCTAssertEqual(event.object.path("error", "message") as? String, "upstream failure")
    XCTAssertTrue(failed.translator.sawFailure)
    try failed.translator.finish()

    var invalid = Harness()
    _ = try invalid.created()
    var invalidResponse = Self.response(status: "in_progress")
    invalidResponse["id"] = "resp_provider_invalid"
    XCTAssertThrowsError(try invalid.send("response.completed", ["response": invalidResponse]))
  }

  func testTextIsForwardedIncrementallyWithCreatedIdentityAndTerminalUsage() throws {
    try assertTextStream(replacesTransportIDs: false)
  }

  func testCopilotTextItemIDsMayChangeOnEveryEventAndTerminalSnapshot() throws {
    try assertTextStream(replacesTransportIDs: true)
  }

  private func assertTextStream(replacesTransportIDs: Bool) throws {
    var stream = Harness(replacesTransportIDs: replacesTransportIDs)
    var bytes = try stream.created()
    bytes.append(try stream.inProgress())
    bytes.append(
      try stream.send(
        "response.output_item.added",
        ["item": messageItem(status: "in_progress", content: []), "output_index": 0]))
    bytes.append(
      try stream.send(
        "response.content_part.added",
        contentFields(part: outputText(""))))

    let firstDelta = try stream.send(
      "response.output_text.delta", contentFields(extra: ["delta": "Hel", "logprobs": []]))
    XCTAssertEqual(try onlyEvent(firstDelta).name, "content_block_delta")
    XCTAssertEqual(
      try onlyEvent(firstDelta).object.path("delta", "text") as? String,
      "Hel")
    bytes.append(firstDelta)
    bytes.append(
      try stream.send(
        "response.output_text.delta", contentFields(extra: ["delta": "lo"])))
    bytes.append(
      try stream.send(
        "response.output_text.done",
        contentFields(extra: ["logprobs": [], "text": "Hello"])))
    bytes.append(
      try stream.send(
        "response.content_part.done",
        contentFields(part: outputText("Hello"))))

    let finalMessage = messageItem(status: "completed", content: [outputText("Hello")])
    bytes.append(
      try stream.send(
        "response.output_item.done", ["item": finalMessage, "output_index": 0]))
    bytes.append(
      try stream.terminal(
        "completed",
        output: [finalMessage],
        usage: [
          "input_tokens": 12,
          "input_tokens_details": ["cache_write_tokens": 1, "cached_tokens": 4],
          "output_tokens": 3,
          "output_tokens_details": ["reasoning_tokens": 1],
          "total_tokens": 15,
        ]))
    try stream.translator.finish()

    let events = try decodedEvents(bytes)
    XCTAssertEqual(
      events.map(\.name),
      [
        "message_start", "content_block_start", "content_block_delta",
        "content_block_delta", "content_block_stop", "message_delta", "message_stop",
      ])
    let message = try XCTUnwrap(events[0].object["message"] as? [String: Any])
    XCTAssertEqual(message["id"] as? String, "msg_resp_stream_1")
    XCTAssertEqual(message["model"] as? String, Harness.model)
    XCTAssertEqual(events[2].object.path("delta", "text") as? String, "Hel")
    XCTAssertEqual(events[3].object.path("delta", "text") as? String, "lo")
    XCTAssertEqual(events[5].object.path("delta", "stop_reason") as? String, "end_turn")
    let usage = try XCTUnwrap(events[5].object["usage"] as? [String: Any])
    XCTAssertEqual(usage["input_tokens"] as? Int, 12)
    XCTAssertEqual(usage["output_tokens"] as? Int, 3)
    XCTAssertEqual(usage["cache_read_input_tokens"] as? Int, 4)
    XCTAssertEqual(usage["cache_creation_input_tokens"] as? Int, 1)
  }

  func testFunctionArgumentsAreForwardedAsTheyArrive() throws {
    try assertFunctionStream(replacesTransportIDs: false)
  }

  func testCopilotToolItemIDsMayChangeWhileCallIDAndArgumentsStayStable() throws {
    try assertFunctionStream(replacesTransportIDs: true)
  }

  private func assertFunctionStream(replacesTransportIDs: Bool) throws {
    var stream = Harness(replacesTransportIDs: replacesTransportIDs)
    var bytes = try stream.created()
    let added: [String: Any] = [
      "arguments": "",
      "call_id": "call_weather",
      "id": "fc_1",
      "name": "weather",
      "status": "in_progress",
      "type": "function_call",
    ]
    bytes.append(
      try stream.send(
        "response.output_item.added", ["item": added, "output_index": 0]))
    bytes.append(
      try stream.send(
        "response.function_call_arguments.delta",
        ["delta": #"{"city":""#, "item_id": "fc_1", "output_index": 0]))
    bytes.append(
      try stream.send(
        "response.function_call_arguments.delta",
        ["delta": #"Paris"}"#, "item_id": "fc_1", "output_index": 0]))
    let arguments = #"{"city":"Paris"}"#
    bytes.append(
      try stream.send(
        "response.function_call_arguments.done",
        [
          "arguments": arguments,
          "item_id": "fc_1",
          "name": "weather",
          "output_index": 0,
        ]))
    let done: [String: Any] = [
      "arguments": arguments,
      "call_id": "call_weather",
      "id": "fc_1",
      "name": "weather",
      "status": "completed",
      "type": "function_call",
    ]
    bytes.append(
      try stream.send(
        "response.output_item.done", ["item": done, "output_index": 0]))
    bytes.append(
      try stream.terminal(
        "completed",
        output: [done],
        usage: basicUsage(input: 8, output: 5)))
    try stream.translator.finish()

    let events = try decodedEvents(bytes)
    XCTAssertEqual(
      events.map(\.name),
      [
        "message_start", "content_block_start", "content_block_delta",
        "content_block_delta", "content_block_stop", "message_delta", "message_stop",
      ])
    let block = try XCTUnwrap(events[1].object["content_block"] as? [String: Any])
    XCTAssertEqual(block["type"] as? String, "tool_use")
    XCTAssertEqual(block["id"] as? String, "call_weather")
    XCTAssertEqual(block["name"] as? String, "weather")
    XCTAssertEqual(events[2].object.path("delta", "partial_json") as? String, #"{"city":""#)
    XCTAssertEqual(events[3].object.path("delta", "partial_json") as? String, #"Paris"}"#)
    XCTAssertEqual(events[5].object.path("delta", "stop_reason") as? String, "tool_use")
  }

  func testRefusalAndIncompleteStopReasonsAreMapped() throws {
    var refusal = Harness()
    var refusalBytes = try refusal.created()
    refusalBytes.append(
      try refusal.send(
        "response.output_item.added",
        ["item": messageItem(status: "in_progress", content: []), "output_index": 0]))
    refusalBytes.append(
      try refusal.send(
        "response.content_part.added", contentFields(part: refusalPart(""))))
    refusalBytes.append(
      try refusal.send(
        "response.refusal.delta", contentFields(extra: ["delta": "No."])))
    refusalBytes.append(
      try refusal.send(
        "response.refusal.done", contentFields(extra: ["refusal": "No."])))
    refusalBytes.append(
      try refusal.send(
        "response.content_part.done", contentFields(part: refusalPart("No."))))
    let refusalMessage = messageItem(status: "completed", content: [refusalPart("No.")])
    refusalBytes.append(
      try refusal.send(
        "response.output_item.done", ["item": refusalMessage, "output_index": 0]))
    refusalBytes.append(
      try refusal.terminal(
        "completed", output: [refusalMessage], usage: basicUsage(input: 3, output: 1)))
    XCTAssertEqual(
      try decodedEvents(refusalBytes).dropLast().last?.object.path("delta", "stop_reason")
        as? String,
      "refusal")

    var incomplete = Harness()
    var incompleteBytes = try incomplete.created()
    let partialMessage = messageItem(status: "incomplete", content: [])
    incompleteBytes.append(
      try incomplete.send(
        "response.output_item.added",
        ["item": messageItem(status: "in_progress", content: []), "output_index": 0]))
    incompleteBytes.append(
      try incomplete.send(
        "response.output_item.done", ["item": partialMessage, "output_index": 0]))
    incompleteBytes.append(
      try incomplete.terminal(
        "incomplete",
        output: [partialMessage],
        usage: basicUsage(input: 2, output: 7),
        incompleteDetails: ["reason": "max_output_tokens"]))
    XCTAssertEqual(
      try decodedEvents(incompleteBytes).dropLast().last?.object.path("delta", "stop_reason")
        as? String,
      "max_tokens")
  }

  func testRotatingItemIDsKeepInterleavedToolArgumentsIsolated() throws {
    var stream = Harness(replacesTransportIDs: true)
    var bytes = try stream.created()
    func function(_ index: Int, status: String, arguments: String) -> [String: Any] {
      [
        "id": "fc_\(index)", "type": "function_call", "call_id": "call_\(index)",
        "name": "echo", "status": status, "arguments": arguments,
      ]
    }
    for index in 0...1 {
      bytes.append(
        try stream.send(
          "response.output_item.added",
          ["output_index": index, "item": function(index, status: "in_progress", arguments: "")]))
    }
    for (index, delta) in [(0, #"{"text":""#), (1, #"{"text":"B"}"#), (0, #"A"}"#)] {
      bytes.append(
        try stream.send(
          "response.function_call_arguments.delta",
          ["output_index": index, "item_id": "fc_\(index)", "delta": delta]))
    }
    let arguments = [#"{"text":"A"}"#, #"{"text":"B"}"#]
    // Completion order is allowed to differ from output_index order.
    for index in [1, 0] {
      bytes.append(
        try stream.send(
          "response.function_call_arguments.done",
          ["output_index": index, "item_id": "fc_\(index)", "arguments": arguments[index]]))
      bytes.append(
        try stream.send(
          "response.output_item.done",
          [
            "output_index": index,
            "item": function(index, status: "completed", arguments: arguments[index]),
          ]))
    }
    bytes.append(
      try stream.terminal(
        "completed",
        output: (0...1).map { function($0, status: "completed", arguments: arguments[$0]) },
        usage: basicUsage(input: 1, output: 2)))
    try stream.translator.finish()

    let events = try decodedEvents(bytes)
    let starts = events.filter { $0.name == "content_block_start" }
    XCTAssertEqual(
      starts.map { $0.object.path("content_block", "id") as? String }, ["call_0", "call_1"])
    for index in 0...1 {
      let combined = events.filter {
        $0.name == "content_block_delta" && $0.object["index"] as? Int == index
      }.compactMap { $0.object.path("delta", "partial_json") as? String }.joined()
      XCTAssertEqual(combined, arguments[index])
    }
    XCTAssertEqual(events.last?.name, "message_stop")
  }

  func testRotatingTransportIDsDoNotPermitFunctionCallIDRewrites() throws {
    for rewriteTerminal in [false, true] {
      var stream = Harness(replacesTransportIDs: true)
      _ = try stream.created()
      var function: [String: Any] = [
        "id": "fc_1", "type": "function_call", "call_id": "call_original",
        "name": "echo", "status": "in_progress", "arguments": "",
      ]
      _ = try stream.send("response.output_item.added", ["output_index": 0, "item": function])
      _ = try stream.send(
        "response.function_call_arguments.delta",
        ["output_index": 0, "item_id": "fc_1", "delta": "{}"])
      _ = try stream.send(
        "response.function_call_arguments.done",
        ["output_index": 0, "item_id": "fc_1", "arguments": "{}"])
      function["arguments"] = "{}"
      function["status"] = "completed"
      if rewriteTerminal {
        _ = try stream.send("response.output_item.done", ["output_index": 0, "item": function])
      }
      function["call_id"] = "call_rewritten"
      if rewriteTerminal {
        XCTAssertThrowsError(
          try stream.terminal(
            "completed", output: [function], usage: basicUsage(input: 1, output: 1)))
      } else {
        XCTAssertThrowsError(
          try stream.send("response.output_item.done", ["output_index": 0, "item": function]))
      }
    }
  }

  func testEmptyReasoningItemIsValidatedWithoutCreatingContentBlock() throws {
    var stream = Harness()
    var bytes = try stream.created()
    let added: [String: Any] = [
      "id": "rs_1", "status": "in_progress", "summary": [], "type": "reasoning",
    ]
    bytes.append(
      try stream.send(
        "response.output_item.added", ["item": added, "output_index": 0]))
    let done: [String: Any] = [
      "encrypted_content": "",
      "id": "rs_1",
      "status": "completed",
      "summary": [],
      "type": "reasoning",
    ]
    bytes.append(
      try stream.send(
        "response.output_item.done", ["item": done, "output_index": 0]))
    bytes.append(
      try stream.terminal(
        "completed", output: [done], usage: basicUsage(input: 5, output: 2)))
    try stream.translator.finish()

    XCTAssertEqual(
      try decodedEvents(bytes).map(\.name),
      ["message_start", "message_delta", "message_stop"])
  }

  func testCopilotEncryptedReasoningWithoutStatusIsPreservedAndReplayable() throws {
    var stream = Harness(replacesTransportIDs: true)
    var bytes = try stream.created()
    var reasoning: [String: Any] = [
      "id": "rs", "type": "reasoning", "summary": [], "content": [],
      "encrypted_content": "provisional-ciphertext",
    ]
    bytes.append(
      try stream.send("response.output_item.added", ["output_index": 0, "item": reasoning]))
    reasoning["encrypted_content"] = "done-ciphertext"
    bytes.append(
      try stream.send("response.output_item.done", ["output_index": 0, "item": reasoning]))
    // Copilot may re-encrypt the same state in its terminal snapshot. Do not compare ciphertexts.
    reasoning["encrypted_content"] = "terminal-ciphertext"
    bytes.append(
      try stream.terminal("completed", output: [reasoning], usage: basicUsage(input: 1, output: 2)))
    try stream.translator.finish()
    let events = try decodedEvents(bytes)
    XCTAssertEqual(
      events.map(\.name),
      [
        "message_start", "content_block_start", "content_block_stop", "message_delta",
        "message_stop",
      ])
    let block = try XCTUnwrap(events[1].object["content_block"] as? [String: Any])
    XCTAssertEqual(block["type"] as? String, "redacted_thinking")
    let data = try XCTUnwrap(block["data"] as? String)
    let restored = try XCTUnwrap(ResponsesReasoningEnvelope.decode(data))
    XCTAssertEqual(restored["encrypted_content"] as? String, "done-ciphertext")
  }

  func testEncryptedReasoningRespectsStreamMemoryLimit() throws {
    var stream = Harness(maximumAccumulatedFieldBytes: 100)
    _ = try stream.created()
    let reasoning: [String: Any] = [
      "id": "rs", "type": "reasoning", "summary": [], "encrypted_content": "opaque-test-state",
    ]
    _ = try stream.send("response.output_item.added", ["output_index": 0, "item": reasoning])
    XCTAssertThrowsError(
      try stream.send("response.output_item.done", ["output_index": 0, "item": reasoning]))
  }

  func testResponseFailedAndStandaloneErrorBecomeTerminalAnthropicErrors() throws {
    var failed = Harness()
    var failedBytes = try failed.created()
    failedBytes.append(
      try failed.send(
        "response.failed",
        [
          "response": Self.response(
            status: "failed",
            error: ["code": "server_error", "message": "upstream broke"])
        ]))
    try failed.translator.finish()
    let failedEvent = try decodedEvents(failedBytes).last
    XCTAssertEqual(failedEvent?.name, "error")
    XCTAssertEqual(failedEvent?.object.path("error", "type") as? String, "api_error")
    XCTAssertEqual(failedEvent?.object.path("error", "message") as? String, "upstream broke")
    XCTAssertTrue(failed.translator.sawFailure)

    var standalone = Harness()
    let errorBytes = try standalone.send(
      "error", ["code": NSNull(), "message": "bad gateway", "param": NSNull()])
    try standalone.translator.finish()
    XCTAssertEqual(try onlyEvent(errorBytes).object.path("error", "type") as? String, "api_error")

    var rateLimited = Harness()
    let rateLimitedBytes = try rateLimited.send(
      "error", ["code": "rate_limit_exceeded", "message": "slow down", "param": NSNull()])
    try rateLimited.translator.finish()
    XCTAssertEqual(
      try onlyEvent(rateLimitedBytes).object.path("error", "type") as? String,
      "rate_limit_error")
  }

  func testRejectsUnknownEventsSequenceGapsAndEventsAfterTerminal() throws {
    var unknown = Harness()
    _ = try unknown.created()
    XCTAssertThrowsError(try unknown.send("response.audio.delta", ["delta": "abc"]))

    let sequence = AnthropicResponsesStreamTranslator(requestedModel: "requested")
    XCTAssertThrowsError(
      try sequence.consume(
        eventName: "response.created",
        object: [
          "response": Self.response(status: "in_progress"),
          "sequence_number": 1,
          "type": "response.created",
        ]))

    var terminal = Harness()
    _ = try terminal.created()
    _ = try terminal.terminal(
      "completed", output: [], usage: basicUsage(input: 1, output: 1))
    try terminal.translator.finish()
    XCTAssertThrowsError(
      try terminal.send(
        "response.in_progress", ["response": Self.response(status: "in_progress")]))
  }

  func testRejectsMismatchedCoordinatesAndInvalidEventOrder() throws {
    var stream = Harness()
    _ = try stream.created()
    _ = try stream.send(
      "response.output_item.added",
      ["item": messageItem(status: "in_progress", content: []), "output_index": 0])
    XCTAssertThrowsError(
      try stream.send(
        "response.output_text.delta",
        contentFields(extra: ["delta": "before part"])))

    var coordinates = Harness()
    _ = try coordinates.created()
    _ = try coordinates.send(
      "response.output_item.added",
      ["item": messageItem(status: "in_progress", content: []), "output_index": 0])
    XCTAssertThrowsError(
      try coordinates.send(
        "response.content_part.added",
        [
          "content_index": 1,
          "item_id": "msg_1",
          "output_index": 0,
          "part": outputText(""),
        ]))
  }

  func testRejectsDoneValueRewritesNonemptyAnnotationsAndUnsupportedItems() throws {
    var rewritten = Harness()
    _ = try rewritten.created()
    _ = try rewritten.send(
      "response.output_item.added",
      ["item": messageItem(status: "in_progress", content: []), "output_index": 0])
    _ = try rewritten.send(
      "response.content_part.added", contentFields(part: outputText("")))
    _ = try rewritten.send(
      "response.output_text.delta", contentFields(extra: ["delta": "a"]))
    XCTAssertThrowsError(
      try rewritten.send(
        "response.output_text.done", contentFields(extra: ["text": "b"])))

    var annotations = Harness()
    _ = try annotations.created()
    _ = try annotations.send(
      "response.output_item.added",
      ["item": messageItem(status: "in_progress", content: []), "output_index": 0])
    XCTAssertThrowsError(
      try annotations.send(
        "response.content_part.added",
        contentFields(part: [
          "annotations": [["type": "url_citation"]], "text": "", "type": "output_text",
        ])))

    var unsupported = Harness()
    _ = try unsupported.created()
    XCTAssertThrowsError(
      try unsupported.send(
        "response.output_item.added",
        [
          "item": ["id": "web_1", "status": "in_progress", "type": "web_search_call"],
          "output_index": 0,
        ]))
  }

  func testRejectsInvalidFunctionArgumentsAndAccumulationOverflow() throws {
    var invalid = Harness()
    _ = try invalid.created()
    let added: [String: Any] = [
      "arguments": "", "call_id": "call_1", "id": "fc_1", "name": "tool",
      "status": "in_progress", "type": "function_call",
    ]
    _ = try invalid.send(
      "response.output_item.added", ["item": added, "output_index": 0])
    _ = try invalid.send(
      "response.function_call_arguments.delta",
      ["delta": "[]", "item_id": "fc_1", "output_index": 0])
    XCTAssertThrowsError(
      try invalid.send(
        "response.function_call_arguments.done",
        ["arguments": "[]", "item_id": "fc_1", "output_index": 0]))

    var bounded = Harness(maximumAccumulatedFieldBytes: 64)
    _ = try bounded.created()
    _ = try bounded.send(
      "response.output_item.added",
      ["item": messageItem(status: "in_progress", content: []), "output_index": 0])
    _ = try bounded.send(
      "response.content_part.added", contentFields(part: outputText("")))
    XCTAssertThrowsError(
      try bounded.send(
        "response.output_text.delta",
        contentFields(extra: ["delta": String(repeating: "x", count: 64)])))
  }

  func testRejectsLossyReasoningAndFunctionDoneNameRewrite() throws {
    var reasoning = Harness()
    _ = try reasoning.created()
    _ = try reasoning.send(
      "response.output_item.added",
      [
        "item": [
          "id": "rs_1", "status": "in_progress", "summary": [], "type": "reasoning",
        ],
        "output_index": 0,
      ])
    XCTAssertThrowsError(
      try reasoning.send(
        "response.output_item.done",
        [
          "item": [
            "encrypted_content": "opaque",
            "id": "rs_1",
            "status": "completed",
            "summary": [["type": "summary_text", "text": "unsupported visible summary"]],
            "type": "reasoning",
          ],
          "output_index": 0,
        ]))

    var function = Harness()
    _ = try function.created()
    _ = try function.send(
      "response.output_item.added",
      [
        "item": [
          "arguments": "",
          "call_id": "call_1",
          "id": "fc_1",
          "name": "expected",
          "status": "in_progress",
          "type": "function_call",
        ],
        "output_index": 0,
      ])
    _ = try function.send(
      "response.function_call_arguments.delta",
      ["delta": "{}", "item_id": "fc_1", "output_index": 0])
    XCTAssertThrowsError(
      try function.send(
        "response.function_call_arguments.done",
        [
          "arguments": "{}", "item_id": "fc_1", "name": "rewritten", "output_index": 0,
        ]))
  }

  func testRejectsItemAndContentPartFloodsAndPrematureEOF() throws {
    var itemLimited = Harness(maximumOutputItems: 1)
    _ = try itemLimited.created()
    let firstReasoning: [String: Any] = [
      "id": "r1", "status": "in_progress", "summary": [], "type": "reasoning",
    ]
    _ = try itemLimited.send(
      "response.output_item.added", ["item": firstReasoning, "output_index": 0])
    XCTAssertThrowsError(
      try itemLimited.send(
        "response.output_item.added",
        [
          "item": [
            "id": "r2", "status": "in_progress", "summary": [], "type": "reasoning",
          ],
          "output_index": 1,
        ]))

    var partLimited = Harness(maximumContentPartsPerMessage: 1)
    _ = try partLimited.created()
    _ = try partLimited.send(
      "response.output_item.added",
      ["item": messageItem(status: "in_progress", content: []), "output_index": 0])
    _ = try partLimited.send(
      "response.content_part.added", contentFields(part: outputText("")))
    XCTAssertThrowsError(
      try partLimited.send(
        "response.content_part.added",
        [
          "content_index": 1,
          "item_id": "msg_1",
          "output_index": 0,
          "part": outputText(""),
        ]))

    var partial = Harness()
    _ = try partial.created()
    XCTAssertThrowsError(try partial.translator.finish())
  }

  func testRejectsTerminalOutputOrUsageThatDoesNotMatchStream() throws {
    var outputMismatch = Harness()
    _ = try outputMismatch.created()
    XCTAssertThrowsError(
      try outputMismatch.terminal(
        "completed",
        output: [messageItem(status: "completed", content: [])],
        usage: basicUsage(input: 1, output: 1)))

    var usageMismatch = Harness()
    _ = try usageMismatch.created()
    XCTAssertThrowsError(
      try usageMismatch.terminal(
        "completed",
        output: [],
        usage: ["input_tokens": 2, "output_tokens": 3, "total_tokens": 99]))
  }

  func testRejectsTerminalTextAndFunctionArgumentRewritesAfterStateIsReleased() throws {
    var text = Harness()
    _ = try text.created()
    _ = try text.send(
      "response.output_item.added",
      ["item": messageItem(status: "in_progress", content: []), "output_index": 0])
    _ = try text.send(
      "response.content_part.added", contentFields(part: outputText("")))
    _ = try text.send(
      "response.output_text.delta", contentFields(extra: ["delta": "original"]))
    _ = try text.send(
      "response.output_text.done", contentFields(extra: ["text": "original"]))
    _ = try text.send(
      "response.content_part.done", contentFields(part: outputText("original")))
    let finalText = messageItem(status: "completed", content: [outputText("original")])
    _ = try text.send(
      "response.output_item.done", ["item": finalText, "output_index": 0])
    XCTAssertThrowsError(
      try text.terminal(
        "completed",
        output: [messageItem(status: "completed", content: [outputText("rewritten")])],
        usage: basicUsage(input: 1, output: 1)))

    var function = Harness()
    _ = try function.created()
    let added: [String: Any] = [
      "arguments": "", "call_id": "call_1", "id": "fc_1", "name": "tool",
      "status": "in_progress", "type": "function_call",
    ]
    _ = try function.send(
      "response.output_item.added", ["item": added, "output_index": 0])
    _ = try function.send(
      "response.function_call_arguments.delta",
      ["delta": #"{"safe":true}"#, "item_id": "fc_1", "output_index": 0])
    _ = try function.send(
      "response.function_call_arguments.done",
      ["arguments": #"{"safe":true}"#, "item_id": "fc_1", "output_index": 0])
    let finalFunction: [String: Any] = [
      "arguments": #"{"safe":true}"#,
      "call_id": "call_1",
      "id": "fc_1",
      "name": "tool",
      "status": "completed",
      "type": "function_call",
    ]
    _ = try function.send(
      "response.output_item.done", ["item": finalFunction, "output_index": 0])
    var rewrittenFunction = finalFunction
    rewrittenFunction["arguments"] = #"{"safe":false}"#
    XCTAssertThrowsError(
      try function.terminal(
        "completed",
        output: [rewrittenFunction],
        usage: basicUsage(input: 1, output: 1)))
  }

  func testMissingOrNullTerminalUsageMapsToZero() throws {
    for omitUsage in [false, true] {
      var stream = Harness()
      var bytes = try stream.created()
      var response = Self.response(status: "completed", output: [], usage: NSNull())
      if omitUsage { response.removeValue(forKey: "usage") }
      bytes.append(try stream.send("response.completed", ["response": response]))
      try stream.translator.finish()

      let messageDelta = try XCTUnwrap(
        decodedEvents(bytes).first { $0.name == "message_delta" })
      let usage = try XCTUnwrap(messageDelta.object["usage"] as? [String: Any])
      XCTAssertEqual(usage["input_tokens"] as? Int, 0)
      XCTAssertEqual(usage["output_tokens"] as? Int, 0)
    }
  }

  private struct Harness {
    static let responseID = "resp_stream_1"
    static let model = "claude-sonnet-4.6"

    let translator: AnthropicResponsesStreamTranslator
    let replacesTransportIDs: Bool
    var sequence = 0

    init(
      maximumAccumulatedFieldBytes: Int = 8 * 1_024 * 1_024,
      maximumOutputItems: Int = 256,
      maximumContentPartsPerMessage: Int = 256,
      replacesTransportIDs: Bool = false
    ) {
      self.replacesTransportIDs = replacesTransportIDs
      translator = AnthropicResponsesStreamTranslator(
        requestedModel: "requested-model",
        maximumAccumulatedFieldBytes: maximumAccumulatedFieldBytes,
        maximumOutputItems: maximumOutputItems,
        maximumContentPartsPerMessage: maximumContentPartsPerMessage)
    }

    mutating func created() throws -> Data {
      try send(
        "response.created",
        ["response": AnthropicResponsesStreamTranslatorTests.response(status: "in_progress")])
    }

    mutating func inProgress() throws -> Data {
      try send(
        "response.in_progress",
        ["response": AnthropicResponsesStreamTranslatorTests.response(status: "in_progress")])
    }

    mutating func terminal(
      _ status: String,
      output: [[String: Any]],
      usage: [String: Any],
      incompleteDetails: Any = NSNull()
    ) throws -> Data {
      try send(
        "response.\(status)",
        [
          "response": AnthropicResponsesStreamTranslatorTests.response(
            status: status,
            output: output,
            usage: usage,
            incompleteDetails: incompleteDetails)
        ])
    }

    mutating func send(_ type: String, _ fields: [String: Any]) throws -> Data {
      var object = fields
      if replacesTransportIDs {
        // Copilot reissues item IDs in every event and the final output snapshot, but
        // keeps output_index/content_index and function call_id stable.
        if object["item_id"] != nil { object["item_id"] = "item_event_\(sequence)" }
        if var item = object["item"] as? [String: Any] {
          item["id"] = "item_event_\(sequence)"
          object["item"] = item
        }
        if var response = object["response"] as? [String: Any],
          let output = response["output"] as? [[String: Any]]
        {
          response["output"] = output.enumerated().map { index, value in
            var item = value
            item["id"] = "item_snapshot_\(sequence)_\(index)"
            return item
          }
          object["response"] = response
        }
      }
      object["sequence_number"] = sequence
      object["type"] = type
      sequence += 1
      return try translator.consume(eventName: type, object: object)
    }
  }

  private static func response(
    status: String,
    output: [[String: Any]] = [],
    usage: Any = NSNull(),
    incompleteDetails: Any = NSNull(),
    error: Any = NSNull()
  ) -> [String: Any] {
    [
      "error": error,
      "id": Harness.responseID,
      "incomplete_details": incompleteDetails,
      "model": Harness.model,
      "object": "response",
      "output": output,
      "status": status,
      "usage": usage,
    ]
  }

  private func messageItem(status: String, content: [[String: Any]]) -> [String: Any] {
    [
      "content": content,
      "id": "msg_1",
      "role": "assistant",
      "status": status,
      "type": "message",
    ]
  }

  private func outputText(_ text: String) -> [String: Any] {
    ["annotations": [], "logprobs": [], "text": text, "type": "output_text"]
  }

  private func refusalPart(_ refusal: String) -> [String: Any] {
    ["refusal": refusal, "type": "refusal"]
  }

  private func contentFields(
    part: [String: Any]? = nil, extra: [String: Any] = [:]
  ) -> [String: Any] {
    var fields: [String: Any] = [
      "content_index": 0,
      "item_id": "msg_1",
      "output_index": 0,
    ]
    if let part { fields["part"] = part }
    for (key, value) in extra { fields[key] = value }
    return fields
  }

  private func basicUsage(input: Int, output: Int) -> [String: Any] {
    [
      "input_tokens": input,
      "input_tokens_details": ["cached_tokens": 0],
      "output_tokens": output,
      "output_tokens_details": ["reasoning_tokens": 0],
      "total_tokens": input + output,
    ]
  }

  private func decodedEvents(_ data: Data) throws -> [(name: String?, object: [String: Any])] {
    var decoder = SSEDecoder()
    var result: [(name: String?, object: [String: Any])] = []
    for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
      if let event = try decoder.feed(line: line) {
        result.append((event.name, try decodedObject(event.data)))
      }
    }
    if let event = decoder.finish() {
      result.append((event.name, try decodedObject(event.data)))
    }
    return result
  }

  private func onlyEvent(_ data: Data) throws -> (name: String?, object: [String: Any]) {
    let events = try decodedEvents(data)
    XCTAssertEqual(events.count, 1)
    return try XCTUnwrap(events.first)
  }

  private func decodedObject(_ value: String) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
  }
}

extension Dictionary where Key == String, Value == Any {
  fileprivate func path(_ keys: String...) -> Any? {
    var value: Any = self
    for key in keys {
      guard let object = value as? [String: Any], let next = object[key] else { return nil }
      value = next
    }
    return value
  }
}
