import XCTest

@testable import CopilotBridgeCore

final class AnthropicNativeStreamValidatorTests: XCTestCase {
  func testAcceptsStandardSequenceAndPreservesForwardedFramesByteForByte() throws {
    let messageStart = frame("message_start", #"{"type":"message_start","message":{}}"#)
    let ping = frame("ping", #"{"type":"ping"}"#, newline: "\n")
    let blockStart = frame(
      "content_block_start",
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
    let blockDelta = frame(
      "content_block_delta",
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"#)
    let blockStop = frame("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
    let messageDelta = frame(
      "message_delta",
      #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#)
    let messageStop = frame("message_stop", #"{"type":"message_stop"}"#)
    let done = Data("data: [DONE]\r\n\r\n".utf8)
    let source =
      Data(": keep-alive\r\n\r\n".utf8) + messageStart + ping + blockStart + blockDelta
      + blockStop + messageDelta + messageStop + done
    let expected =
      Data(": keep-alive\r\n\r\n".utf8) + messageStart + ping + blockStart
      + blockDelta + blockStop + messageDelta + messageStop

    var parser = SSELineParser()
    var frames = SSEFrameBuffer(maximumEventBytes: 1_024 * 1_024, maximumLineBytes: 1_024 * 1_024)
    var validator = AnthropicNativeStreamValidator()
    var output = Data()

    for line in try parser.feed(source) {
      guard let completed = try frames.feed(line: line) else { continue }
      if try validator.observe(completed.event) == .forward {
        output.append(completed.bytes)
      }
    }
    if let trailing = parser.finish(), let completed = try frames.feed(line: trailing),
      try validator.observe(completed.event) == .forward
    {
      output.append(completed.bytes)
    }
    try frames.finish()
    try validator.validateEndOfStream()

    XCTAssertEqual(output, expected)
    XCTAssertTrue(validator.sawTerminal)
    XCTAssertFalse(validator.sawFailure)
  }

  func testErrorIsForwardedAsTerminalFailure() throws {
    var validator = AnthropicNativeStreamValidator()

    XCTAssertEqual(
      try validator.observe(
        .init(
          name: "error",
          data: #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#)),
      .forward)
    XCTAssertNoThrow(try validator.validateEndOfStream())
    XCTAssertTrue(validator.sawTerminal)
    XCTAssertTrue(validator.sawFailure)
  }

  func testAllowsKeepalivesAndDiscardsDoneAfterTerminal() throws {
    var validator = AnthropicNativeStreamValidator()
    try validator.observe(.init(name: "message_stop", data: #"{"type":"message_stop"}"#))

    XCTAssertEqual(try validator.observe(nil), .forward)
    XCTAssertEqual(try validator.observe(.init(name: "ping", data: "")), .forward)
    XCTAssertEqual(
      try validator.observe(.init(name: "ping", data: #"{"type":"ping"}"#)), .forward)
    XCTAssertEqual(try validator.observe(.init(name: nil, data: "[DONE]")), .discard)
    XCTAssertNoThrow(try validator.validateEndOfStream())
  }

  func testRejectsMalformedJSONObjectsAndInvalidTypes() throws {
    let invalidEvents: [SSEDecoder.Event] = [
      .init(name: "message_start", data: "not-json"),
      .init(name: "message_start", data: "[]"),
      .init(name: "message_start", data: ""),
      .init(name: "message_start", data: #"{"type":1}"#),
      .init(name: "ping", data: "not-json"),
    ]

    for event in invalidEvents {
      var validator = AnthropicNativeStreamValidator()
      XCTAssertThrowsError(try validator.observe(event), "event=\(event.name ?? "nil")")
    }
  }

  func testRejectsMismatchedNamedEventAndPayloadType() throws {
    var validator = AnthropicNativeStreamValidator()
    XCTAssertThrowsError(
      try validator.observe(
        .init(name: "ping", data: #"{"type":"message_stop"}"#)))
  }

  func testRejectsBusinessEventAfterTerminalButStillAllowsTransportNoise() throws {
    var validator = AnthropicNativeStreamValidator()
    try validator.observe(.init(name: nil, data: #"{"type":"message_stop"}"#))
    XCTAssertEqual(try validator.observe(.init(name: nil, data: "[DONE]")), .discard)
    XCTAssertEqual(try validator.observe(nil), .forward)

    XCTAssertThrowsError(
      try validator.observe(
        .init(
          name: "content_block_delta",
          data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"late"}}"#
        )))
  }

  func testRequiresNativeTerminalAndDoneDoesNotCount() throws {
    var validator = AnthropicNativeStreamValidator()
    try validator.observe(
      .init(name: "message_start", data: #"{"type":"message_start","message":{}}"#))
    XCTAssertEqual(try validator.observe(.init(name: nil, data: "[DONE]")), .discard)

    XCTAssertThrowsError(try validator.validateEndOfStream()) { error in
      XCTAssertEqual(
        error as? BridgeError,
        .protocolFailure(
          "Copilot 上游 Anthropic Messages 流在 message_stop 或 error 事件前结束。"))
    }
  }

  private func frame(_ name: String, _ data: String, newline: String = "\r\n") -> Data {
    Data("event: \(name)\(newline)data: \(data)\(newline)\(newline)".utf8)
  }
}
