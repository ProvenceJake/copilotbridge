import XCTest

@testable import CopilotBridgeCore

final class AnthropicMetadataUserIdentifierTests: XCTestCase {
  func testOneHundredFiftyCharacterIDIsBoundedASCIIAndSharedByTranslatedPaths() throws {
    let sourceUserID = String(repeating: "u", count: 150)
    XCTAssertEqual(sourceUserID.count, 150)

    let chat = try AnthropicCodec.toOpenAI([
      "messages": [] as [[String: Any]],
      "metadata": ["user_id": sourceUserID],
      "model": "chat-model",
    ])
    let responses = try AnthropicResponsesCodec.toOpenAI([
      "max_tokens": 1,
      "messages": [] as [[String: Any]],
      "metadata": ["user_id": sourceUserID],
      "model": "responses-model",
    ])

    let chatUser = try XCTUnwrap(chat["user"] as? String)
    let responsesUser = try XCTUnwrap(responses["user"] as? String)
    XCTAssertEqual(chatUser, responsesUser)
    XCTAssertEqual(chatUser.utf8.count, 64)
    XCTAssertTrue(
      chatUser.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      })
    XCTAssertNotEqual(chatUser, String(sourceUserID.prefix(64)))
  }

  func testBoundaryUsesUTF8ByteLength() {
    let sixtyFourByteID = String(repeating: "a", count: 64)
    let sixtyFiveByteID = sixtyFourByteID + "b"
    let shortUnicodeID = "用户🌍"

    XCTAssertEqual(
      AnthropicMetadataUserIdentifier.upstreamValue(for: sixtyFourByteID), sixtyFourByteID)
    XCTAssertEqual(
      AnthropicMetadataUserIdentifier.upstreamValue(for: shortUnicodeID), shortUnicodeID)
    XCTAssertEqual(
      AnthropicMetadataUserIdentifier.upstreamValue(for: sixtyFiveByteID).utf8.count, 64)
    XCTAssertNotEqual(
      AnthropicMetadataUserIdentifier.upstreamValue(for: sixtyFiveByteID),
      String(sixtyFiveByteID.prefix(64)))
  }

  func testOversizedUnicodeIDHasStableDomainSeparatedDigest() {
    let sourceUserID = String(repeating: "你好🌍", count: 7)
    XCTAssertEqual(sourceUserID.count, 21)
    XCTAssertEqual(sourceUserID.utf8.count, 70)
    let first = AnthropicMetadataUserIdentifier.upstreamValue(for: sourceUserID)
    let second = AnthropicMetadataUserIdentifier.upstreamValue(for: sourceUserID)

    XCTAssertEqual(first, second)
    XCTAssertEqual(first, "9e5f688ee42233a922b3f4880a57a7a9dd63bddd19d95d4d899dbc40f93204e1")
  }

  func testIDsThatWouldCollideWhenTruncatedRemainDistinct() {
    let commonPrefix = String(repeating: "a", count: 64)
    let firstSource = commonPrefix + "-first"
    let secondSource = commonPrefix + "-second"
    XCTAssertEqual(String(firstSource.prefix(64)), String(secondSource.prefix(64)))

    XCTAssertNotEqual(
      AnthropicMetadataUserIdentifier.upstreamValue(for: firstSource),
      AnthropicMetadataUserIdentifier.upstreamValue(for: secondSource))
  }
}
