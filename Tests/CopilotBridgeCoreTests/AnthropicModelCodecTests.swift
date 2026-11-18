import XCTest

@testable import CopilotBridgeCore

final class AnthropicModelCodecTests: XCTestCase {
  func testMapsRequiredModelDiscoveryFieldsAndCopilotLimits() throws {
    let translated = try AnthropicModelCodec.translate([
      "data": [
        [
          "id": "claude-sonnet-4.6",
          "name": "Claude Sonnet 4.6",
          "created": 1_700_000_000,
          "capabilities": [
            "limits": ["max_prompt_tokens": 200_000, "max_output_tokens": 64_000]
          ],
        ]
      ]
    ])

    let model = try XCTUnwrap((translated["data"] as? [[String: Any]])?.first)
    XCTAssertEqual(model["id"] as? String, "claude-sonnet-4.6")
    XCTAssertEqual(model["display_name"] as? String, "Claude Sonnet 4.6")
    XCTAssertEqual(model["created_at"] as? String, "2023-11-14T22:13:20Z")
    XCTAssertTrue(model["capabilities"] is NSNull)
    XCTAssertEqual(model["max_input_tokens"] as? Int, 200_000)
    XCTAssertEqual(model["max_tokens"] as? Int, 64_000)
    XCTAssertEqual(model["anthropic_family_tier"] as? String, "sonnet")
    XCTAssertEqual(model["is_family_default"] as? Bool, false)
    XCTAssertEqual(translated["first_id"] as? String, "claude-sonnet-4.6")
    XCTAssertEqual(translated["last_id"] as? String, "claude-sonnet-4.6")
    XCTAssertEqual(translated["has_more"] as? Bool, false)
  }

  func testUnknownLimitsRemainExplicitlyNull() throws {
    let translated = try AnthropicModelCodec.translate([
      "data": [["id": "gpt-5", "created_at": "2026-01-02T03:04:05Z"]]
    ])
    let model = try XCTUnwrap((translated["data"] as? [[String: Any]])?.first)

    XCTAssertTrue(model["max_input_tokens"] is NSNull)
    XCTAssertTrue(model["max_tokens"] is NSNull)
    XCTAssertNil(model["anthropic_family_tier"])
    XCTAssertEqual(model["created_at"] as? String, "2026-01-02T03:04:05Z")
  }

  func testFiltersUnavailableModelsAndKeepsEntriesWithMissingMetadata() throws {
    let translated = try AnthropicModelCodec.translate([
      "data": [
        ["id": "metadata-missing"],
        ["id": "snake-picker-hidden", "model_picker_enabled": false],
        ["id": "camel-picker-hidden", "modelPickerEnabled": false],
        ["id": "nested-non-chat", "capabilities": ["type": "embedding"]],
        ["id": "camel-non-chat", "modelType": "completion"],
        ["id": "blocked", "policy": ["state": "BLOCKED"]],
        ["id": "disabled", "policy": ["policy_state": "disabled"]],
        ["id": "denied", "policyState": "denied"],
        ["id": "unavailable", "policy_status": "unavailable"],
        [
          "id": "available-chat",
          "modelPickerEnabled": true,
          "capabilities": ["modelType": " Chat "],
          "policy": ["policyState": "enabled"],
        ],
      ]
    ])

    let models = try XCTUnwrap(translated["data"] as? [[String: Any]])
    XCTAssertEqual(
      models.compactMap { $0["id"] as? String }, ["metadata-missing", "available-chat"])
    XCTAssertEqual(translated["first_id"] as? String, "metadata-missing")
    XCTAssertEqual(translated["last_id"] as? String, "available-chat")
  }

  func testKeepsChatCompletionCapabilityType() throws {
    let translated = try AnthropicModelCodec.translate([
      "data": [["id": "compatible-chat", "capabilities": ["type": "chat_completion"]]]
    ])
    XCTAssertEqual(
      (translated["data"] as? [[String: Any]])?.first?["id"] as? String,
      "compatible-chat")
  }

  func testTokenLimitsRejectBooleansAndFractionalNumbersAndAcceptCamelCaseIntegers() throws {
    let translated = try AnthropicModelCodec.translate([
      "data": [
        [
          "id": "invalid-limits",
          "capabilities": [
            "limits": ["max_prompt_tokens": true, "max_output_tokens": 1_024.5]
          ],
        ],
        [
          "id": "camel-limits",
          "capabilities": [
            "limits": ["maxPromptTokens": 200_000, "maxOutputTokens": 64_000]
          ],
        ],
      ]
    ])

    let models = try XCTUnwrap(translated["data"] as? [[String: Any]])
    XCTAssertEqual(models.count, 2)
    XCTAssertTrue(models[0]["max_input_tokens"] is NSNull)
    XCTAssertTrue(models[0]["max_tokens"] is NSNull)
    XCTAssertEqual(models[1]["max_input_tokens"] as? Int, 200_000)
    XCTAssertEqual(models[1]["max_tokens"] as? Int, 64_000)
  }

  func testRejectsMalformedUpstreamCatalog() {
    XCTAssertThrowsError(try AnthropicModelCodec.translate([:]))
    XCTAssertThrowsError(try AnthropicModelCodec.translate(["data": [["name": "missing-id"]]]))
    XCTAssertThrowsError(try AnthropicModelCodec.translate(["data": ["not-an-object"]]))
  }
}
