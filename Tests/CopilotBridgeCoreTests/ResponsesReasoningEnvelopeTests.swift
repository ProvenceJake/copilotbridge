import Foundation
import XCTest

@testable import CopilotBridgeCore

final class ResponsesReasoningEnvelopeTests: XCTestCase {
  func testNonstreamReasoningRoundTripsInOriginalMessageOrder() throws {
    let reasoning: [String: Any] = [
      "id": "rs_done", "type": "reasoning", "summary": [], "content": [],
      "encrypted_content": "opaque-test-state",
    ]
    let response = try AnthropicResponsesCodec.fromOpenAI(
      [
        "id": "resp_test", "object": "response", "status": "completed", "output": [reasoning],
        "usage": ["input_tokens": 1, "output_tokens": 2],
      ], requestedModel: "gpt-test")
    let blocks = try XCTUnwrap(response["content"] as? [[String: Any]])
    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(blocks[0]["type"] as? String, "redacted_thinking")
    let restored = try AnthropicResponsesCodec.toOpenAI([
      "model": "gpt-test", "max_tokens": 64,
      "messages": [
        [
          "role": "assistant",
          "content": [
            ["type": "text", "text": "before"], blocks[0], ["type": "text", "text": "after"],
          ],
        ]
      ],
    ])
    let input = try XCTUnwrap(restored["input"] as? [[String: Any]])
    XCTAssertEqual(input.map { $0["type"] as? String }, ["message", "reasoning", "message"])
    XCTAssertEqual(input[1]["id"] as? String, "rs_done")
    XCTAssertEqual(input[1]["encrypted_content"] as? String, "opaque-test-state")
    XCTAssertNil(input[1]["status"])
    let sse = String(
      decoding: try AnthropicResponsesCodec.encodeSSE(message: response), as: UTF8.self)
    XCTAssertTrue(sse.contains("redacted_thinking"))
    XCTAssertTrue(sse.contains("message_stop"))
  }

  func testEnvelopeRejectsInvalidPayloadsWithoutIncludingTheirContentsInErrors() throws {
    XCTAssertNil(try ResponsesReasoningEnvelope.decode("native-anthropic-opaque"))
    let invalid: [[String: Any]] = [
      ["id": "rs", "type": "message", "summary": [], "encrypted_content": "private-marker"],
      [
        "id": "rs", "type": "reasoning", "summary": [], "encrypted_content": "private-marker",
        "instructions": "private-marker",
      ],
      ["id": "", "type": "reasoning", "summary": [], "encrypted_content": "private-marker"],
    ]
    let encoded = try invalid.map {
      ResponsesReasoningEnvelope.prefix
        + (try JSONSerialization.data(withJSONObject: $0)).base64EncodedString()
    }
    for value in encoded + [ResponsesReasoningEnvelope.prefix + "invalid-base64"] {
      XCTAssertThrowsError(try ResponsesReasoningEnvelope.decode(value)) { error in
        XCTAssertFalse(error.localizedDescription.contains("private-marker"))
      }
    }
  }

  func testEmptyReasoningStaysEmptyAndOversizedStateIsRejected() throws {
    let empty: [String: Any] = ["id": "rs", "type": "reasoning", "summary": []]
    XCTAssertNil(try ResponsesReasoningEnvelope.encode(empty))
    var huge = empty
    huge["encrypted_content"] = String(
      repeating: "x", count: ResponsesReasoningEnvelope.maximumBytes + 1)
    XCTAssertThrowsError(try ResponsesReasoningEnvelope.encode(huge))
    var invalid = empty
    invalid["status"] = "in_progress"
    XCTAssertThrowsError(try ResponsesReasoningEnvelope.encode(invalid))
  }
}
