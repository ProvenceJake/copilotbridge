import XCTest

@testable import CopilotBridgeCore

final class CodexModelCodecTests: XCTestCase {
  func testBuildsCurrentCodexModelsResponse() throws {
    let source: [String: Any] = [
      "object": "list",
      "data": [
        [
          "id": "gpt-test",
          "name": "GPT Test",
          "capabilities": [
            "supports": ["reasoning_effort": true, "vision": true],
            "limits": ["max_prompt_tokens": 200_000],
          ],
        ]
      ],
    ]

    let output = try CodexModelCodec.translate(source)
    let models = try XCTUnwrap(output["models"] as? [[String: Any]])
    XCTAssertNil(output["data"])
    XCTAssertEqual(models.count, 1)
    let model = models[0]
    XCTAssertEqual(model["slug"] as? String, "gpt-test")
    XCTAssertEqual(model["display_name"] as? String, "GPT Test")
    XCTAssertEqual(model["default_reasoning_level"] as? String, "medium")
    XCTAssertEqual((model["supported_reasoning_levels"] as? [[String: Any]])?.count, 3)
    XCTAssertEqual(model["shell_type"] as? String, "unified_exec")
    XCTAssertEqual(model["visibility"] as? String, "list")
    XCTAssertEqual(model["supported_in_api"] as? Bool, true)
    XCTAssertEqual(model["context_window"] as? Int, 200_000)
    XCTAssertEqual(model["max_context_window"] as? Int, 200_000)
    XCTAssertEqual(model["input_modalities"] as? [String], ["text", "image"])
    XCTAssertNotNil(model["base_instructions"] as? String)
    XCTAssertEqual(model["apply_patch_tool_type"] as? String, "freeform")
  }

  func testUsesConservativeDefaultsWhenCapabilitiesAreUnknown() throws {
    let output = try CodexModelCodec.translate(["data": [["id": "claude-test"]]])
    let model = try XCTUnwrap((output["models"] as? [[String: Any]])?.first)

    XCTAssertTrue(model["default_reasoning_level"] is NSNull)
    XCTAssertEqual((model["supported_reasoning_levels"] as? [[String: Any]])?.count, 0)
    XCTAssertEqual(model["input_modalities"] as? [String], ["text"])
    XCTAssertNil(model["context_window"])
    XCTAssertEqual(model["supports_reasoning_summary_parameter"] as? Bool, false)
    XCTAssertEqual(model["default_reasoning_summary"] as? String, "none")
  }

  func testPreservesRealCopilotReasoningLevelsAndUsesPromptLimit() throws {
    let output = try CodexModelCodec.translate([
      "data": [
        [
          "id": "gpt-reasoning",
          "defaultReasoningEffort": "high",
          "capabilities": [
            "type": "chat",
            "supports": [
              "reasoning_effort": ["none", "low", "medium", "high", "xhigh", "max"],
              "reasoningEffort": true,
            ],
            "limits": [
              "max_context_window_tokens": 328_000,
              "max_prompt_tokens": 200_000,
            ],
          ],
        ]
      ]
    ])
    let model = try XCTUnwrap((output["models"] as? [[String: Any]])?.first)
    let levels = try XCTUnwrap(model["supported_reasoning_levels"] as? [[String: Any]])

    XCTAssertEqual(
      levels.compactMap { $0["effort"] as? String },
      [
        "none", "low", "medium", "high", "xhigh", "max",
      ])
    XCTAssertEqual(model["default_reasoning_level"] as? String, "high")
    XCTAssertEqual(model["context_window"] as? Int, 200_000)
    XCTAssertEqual(model["max_context_window"] as? Int, 200_000)
  }

  func testOmitsHiddenAndNonChatModelsFromCodexPicker() throws {
    let output = try CodexModelCodec.translate([
      "data": [
        [
          "id": "visible-chat",
          "model_picker_enabled": true,
          "capabilities": ["type": "chat"],
        ],
        [
          "id": "internal-chat",
          "model_picker_enabled": false,
          "capabilities": ["type": "chat"],
        ],
        [
          "id": "embedding-model",
          "model_picker_enabled": true,
          "capabilities": ["type": "embeddings"],
        ],
      ]
    ])
    let models = try XCTUnwrap(output["models"] as? [[String: Any]])

    XCTAssertEqual(models.compactMap { $0["slug"] as? String }, ["visible-chat"])
  }

  func testRejectsMalformedSourceCatalog() {
    XCTAssertThrowsError(try CodexModelCodec.translate(["object": "list"]))
    XCTAssertThrowsError(try CodexModelCodec.translate(["data": [["name": "missing id"]]]))
  }
}
