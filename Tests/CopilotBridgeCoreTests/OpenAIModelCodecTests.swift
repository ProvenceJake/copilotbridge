import XCTest

@testable import CopilotBridgeCore

final class OpenAIModelCodecTests: XCTestCase {
  func testNormalizesStandardFieldsAndPreservesCompatibilityMetadata() throws {
    let translated = try OpenAIModelCodec.translate([
      "data": [
        [
          "id": " gpt-test ",
          "object": "copilot_model",
          "created": 1_700_000_000,
          "owned_by": "legacy-owner",
          "vendor": "OpenAI",
          "name": "GPT Test",
          "preview": true,
          "capabilities": ["type": "chat"],
        ],
        [
          "id": "claude-test",
          "created": 42.0,
          "owned_by": "legacy-owner",
          "vendor": ["name": "Anthropic", "id": "anthropic"],
          "capabilities": ["type": " chat_completion "],
        ],
        ["id": "fallback-owner"],
      ]
    ])

    XCTAssertEqual(translated["object"] as? String, "list")
    let models = try XCTUnwrap(translated["data"] as? [[String: Any]])
    XCTAssertEqual(models.count, 3)

    XCTAssertEqual(models[0]["id"] as? String, "gpt-test")
    XCTAssertEqual(models[0]["object"] as? String, "model")
    XCTAssertEqual(models[0]["created"] as? Int, 1_700_000_000)
    XCTAssertEqual(models[0]["owned_by"] as? String, "OpenAI")
    XCTAssertEqual(models[0]["name"] as? String, "GPT Test")
    XCTAssertEqual(models[0]["preview"] as? Bool, true)
    XCTAssertNotNil(models[0]["capabilities"])

    XCTAssertEqual(models[1]["object"] as? String, "model")
    XCTAssertEqual(models[1]["created"] as? Int, 42)
    XCTAssertEqual(models[1]["owned_by"] as? String, "Anthropic")
    XCTAssertNotNil(models[1]["vendor"])

    XCTAssertEqual(models[2]["object"] as? String, "model")
    XCTAssertEqual(models[2]["created"] as? Int, 0)
    XCTAssertEqual(models[2]["owned_by"] as? String, "github-copilot")
  }

  func testCreatedRequiresAnExactNonnegativeInteger() throws {
    let translated = try OpenAIModelCodec.translate([
      "data": [
        ["id": "zero", "created": 0],
        ["id": "integral-double", "created": 12.0],
        ["id": "negative", "created": -1],
        ["id": "fractional", "created": 1.5],
        ["id": "boolean", "created": true],
        ["id": "string", "created": "12"],
        ["id": "non-finite", "created": Double.infinity],
        ["id": "overflow", "created": NSNumber(value: UInt64.max)],
      ]
    ])
    let models = try XCTUnwrap(translated["data"] as? [[String: Any]])

    XCTAssertEqual(
      models.compactMap { $0["created"] as? Int },
      [0, 12, 0, 0, 0, 0, 0, 0])
  }

  func testFiltersExplicitlyHiddenNonChatAndUnavailableModels() throws {
    let translated = try OpenAIModelCodec.translate([
      "data": [
        ["id": "metadata-missing"],
        ["id": "snake-hidden", "model_picker_enabled": false],
        ["id": "camel-hidden", "modelPickerEnabled": false],
        ["id": "embedding", "capabilities": ["type": "embeddings"]],
        ["id": "completion", "capabilities": ["type": "completion"]],
        ["id": "blocked", "policy": "BLOCKED"],
        ["id": "disabled", "status": " disabled "],
        ["id": "denied", "policy": ["state": "denied"]],
        ["id": "unavailable", "policy": ["status": "unavailable"]],
        [
          "id": "chat",
          "modelPickerEnabled": true,
          "capabilities": ["type": "CHAT"],
          "policy": ["state": "enabled"],
          "status": "available",
        ],
        ["id": "chat-completion", "capabilities": ["type": "chat_completion"]],
      ]
    ])
    let models = try XCTUnwrap(translated["data"] as? [[String: Any]])

    XCTAssertEqual(
      models.compactMap { $0["id"] as? String },
      ["metadata-missing", "chat", "chat-completion"])
  }

  func testRejectsMalformedCatalogAndEntriesWithoutAnID() {
    XCTAssertThrowsError(try OpenAIModelCodec.translate([:])) { error in
      XCTAssertEqual(
        error as? BridgeError,
        .protocolFailure("无法读取 Copilot 模型列表。"))
    }
    for source: [String: Any] in [
      ["data": [["name": "missing-id"]]],
      ["data": [["id": "  "]]],
      ["data": ["not-an-object"]],
    ] {
      XCTAssertThrowsError(try OpenAIModelCodec.translate(source)) { error in
        XCTAssertEqual(
          error as? BridgeError,
          .protocolFailure("Copilot 模型目录包含缺少 id 的条目。"))
      }
    }
  }
}
