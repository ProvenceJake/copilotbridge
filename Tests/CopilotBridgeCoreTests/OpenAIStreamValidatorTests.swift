import XCTest

@testable import CopilotBridgeCore

final class OpenAIStreamValidatorTests: XCTestCase {
  func testChatRequiresDoneSentinel() throws {
    var complete = OpenAIStreamValidator(kind: .chatCompletions)
    try complete.observe(.init(name: nil, data: "[DONE]"))
    XCTAssertNoThrow(try complete.validateEndOfStream())

    let truncated = OpenAIStreamValidator(kind: .chatCompletions)
    XCTAssertThrowsError(try truncated.validateEndOfStream())
  }

  func testResponsesRequiresTerminalEvent() throws {
    var complete = OpenAIStreamValidator(kind: .responses)
    try complete.observe(
      .init(name: "response.completed", data: #"{"type":"response.completed"}"#))
    XCTAssertNoThrow(try complete.validateEndOfStream())
    XCTAssertFalse(complete.sawFailure)

    var failed = OpenAIStreamValidator(kind: .responses)
    try failed.observe(.init(name: "response.failed", data: #"{"type":"response.failed"}"#))
    XCTAssertNoThrow(try failed.validateEndOfStream())
    XCTAssertTrue(failed.sawFailure)
  }

  func testErrorEventIsTerminalFailureForBothProtocols() throws {
    for kind in [OpenAIStreamValidator.Kind.chatCompletions, .responses] {
      var validator = OpenAIStreamValidator(kind: kind)
      try validator.observe(.init(name: "error", data: #"{"type":"error"}"#))
      XCTAssertNoThrow(try validator.validateEndOfStream())
      XCTAssertTrue(validator.sawFailure)
    }
  }

  func testRejectsMalformedJSONAndEventsAfterTerminal() throws {
    var malformed = OpenAIStreamValidator(kind: .chatCompletions)
    XCTAssertThrowsError(try malformed.observe(.init(name: nil, data: "not-json")))

    var complete = OpenAIStreamValidator(kind: .responses)
    try complete.observe(
      .init(name: "response.completed", data: #"{"type":"response.completed"}"#))
    XCTAssertThrowsError(
      try complete.observe(
        .init(name: "response.output_text.delta", data: #"{"delta":"late"}"#)))
  }
}
