import XCTest

@testable import CopilotBridgeCore

final class AnthropicCodecTests: XCTestCase {
  func testTranslatesSystemTextImagesAndTools() throws {
    let source: [String: Any] = [
      "model": "claude-sonnet-4-6-20260301",
      "max_tokens": 1_024,
      "system": [["type": "text", "text": "Be precise."]],
      "messages": [
        [
          "role": "user",
          "content": [
            ["type": "text", "text": "Inspect this"],
            ["type": "image", "source": ["type": "url", "url": "https://example.com/a.png"]],
          ],
        ]
      ],
      "tools": [
        [
          "name": "lookup", "description": "Look up a value",
          "input_schema": ["type": "object", "properties": [:]],
        ]
      ],
      "tool_choice": ["type": "tool", "name": "lookup"],
    ]

    let output = try AnthropicCodec.toOpenAI(source)
    XCTAssertEqual(output["model"] as? String, "claude-sonnet-4-6-20260301")
    let messages = try XCTUnwrap(output["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0]["role"] as? String, "system")
    let userParts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
    XCTAssertEqual(userParts[1]["type"] as? String, "image_url")
    let tools = try XCTUnwrap(output["tools"] as? [[String: Any]])
    let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
    XCTAssertEqual(function["name"] as? String, "lookup")
    let choice = try XCTUnwrap(output["tool_choice"] as? [String: Any])
    XCTAssertEqual(((choice["function"] as? [String: Any])?["name"] as? String), "lookup")
  }

  func testStreamMustBeStrictBooleanWhenPresent() throws {
    let invalidValues: [Any] = [0, 1, "true", [], ["value": true]]
    for value in invalidValues {
      let request: [String: Any] = [
        "model": "gpt-4o", "messages": [], "stream": value,
      ]
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(request), "stream=\(value)")
    }

    for value in [false, true] {
      let output = try AnthropicCodec.toOpenAI([
        "model": "gpt-4o", "messages": [], "stream": value,
      ])
      XCTAssertEqual(output["stream"] as? Bool, value)
    }
    let nullOutput = try AnthropicCodec.toOpenAI([
      "model": "gpt-4o", "messages": [], "stream": NSNull(),
    ])
    XCTAssertEqual(nullOutput["stream"] as? Bool, false)
  }

  func testStopSequencesToolsAndMetadataRejectWrongContainerTypes() throws {
    let invalidFields: [(key: String, value: Any)] = [
      ("stop_sequences", "stop"),
      ("stop_sequences", ["stop", 1] as [Any]),
      ("tools", ["not-an-object"]),
      ("metadata", [] as [Any]),
    ]
    for invalid in invalidFields {
      var request: [String: Any] = ["model": "gpt-4o", "messages": []]
      request[invalid.key] = invalid.value
      XCTAssertThrowsError(
        try AnthropicCodec.toOpenAI(request), "\(invalid.key)=\(invalid.value)")
    }

    let output = try AnthropicCodec.toOpenAI([
      "model": "gpt-4o",
      "messages": [],
      "stop_sequences": [] as [String],
      "tools": [] as [[String: Any]],
      "metadata": [:] as [String: Any],
    ])
    XCTAssertNil(output["stop"])
    XCTAssertNil(output["tools"])
    XCTAssertNil(output["user"])
  }

  func testMetadataUserIDMustBeStringWhenPresent() throws {
    for value in [7, true] as [Any] {
      let request: [String: Any] = [
        "model": "gpt-4o", "messages": [], "metadata": ["user_id": value],
      ]
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(request), "user_id=\(value)")
    }

    let output = try AnthropicCodec.toOpenAI([
      "model": "gpt-4o", "messages": [], "metadata": ["user_id": "user-123"],
    ])
    XCTAssertEqual(output["user"] as? String, "user-123")

    let nullOutput = try AnthropicCodec.toOpenAI([
      "model": "gpt-4o", "messages": [], "metadata": ["user_id": NSNull()],
    ])
    XCTAssertNil(nullOutput["user"])
  }

  func testToolStrictMustBeBooleanAndMapsToOpenAIFunction() throws {
    for strict in [false, true] {
      let output = try AnthropicCodec.toOpenAI([
        "model": "gpt-4o",
        "messages": [],
        "tools": [
          [
            "type": "custom",
            "name": "lookup",
            "input_schema": ["type": "object"],
            "strict": strict,
          ]
        ],
      ])
      let function = try XCTUnwrap(
        (output["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
      XCTAssertEqual(function["strict"] as? Bool, strict)
    }

    for value in [0, 1, "true"] as [Any] {
      let request: [String: Any] = [
        "model": "gpt-4o",
        "messages": [],
        "tools": [
          [
            "name": "lookup",
            "input_schema": ["type": "object"],
            "strict": value,
          ]
        ],
      ]
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(request), "strict=\(value)")
    }

    let nullOutput = try AnthropicCodec.toOpenAI([
      "model": "gpt-4o",
      "messages": [],
      "tools": [
        [
          "name": "lookup",
          "input_schema": ["type": "object"],
          "strict": NSNull(),
        ]
      ],
    ])
    let nullFunction = try XCTUnwrap(
      (nullOutput["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
    XCTAssertNil(nullFunction["strict"])
  }

  func testValidatesAndStripsToolCompatibilityHints() throws {
    let output = try AnthropicCodec.toOpenAI([
      "model": "gpt-4o",
      "messages": [],
      "tools": [
        [
          "type": "tool_search_tool_regex_20251119",
          "name": "tool_search_tool_regex",
          "allowed_callers": ["direct"],
        ],
        [
          "type": "custom",
          "name": "lookup",
          "description": "Lookup",
          "input_schema": ["type": "object"],
          "allowed_callers": ["direct", "code_execution_20260120"],
          "defer_loading": true,
          "eager_input_streaming": false,
          "input_examples": [["query": "weather"]],
        ],
        [
          "type": NSNull(),
          "name": "null-hints",
          "description": NSNull(),
          "input_schema": ["type": "object"],
          "allowed_callers": NSNull(),
          "defer_loading": NSNull(),
          "eager_input_streaming": NSNull(),
          "input_examples": NSNull(),
        ],
      ],
    ])
    let tools = try XCTUnwrap(output["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.count, 2)
    for tool in tools {
      let function = try XCTUnwrap(tool["function"] as? [String: Any])
      XCTAssertNil(function["allowed_callers"])
      XCTAssertNil(function["defer_loading"])
      XCTAssertNil(function["eager_input_streaming"])
      XCTAssertNil(function["input_examples"])
    }
  }

  func testRejectsUnsafeOrMalformedToolCompatibilityHintsAndNonCustomTypes() throws {
    let invalidFields: [(String, Any)] = [
      ("allowed_callers", [] as [String]),
      ("allowed_callers", ["code_execution_20260120"]),
      ("allowed_callers", ["direct", 1] as [Any]),
      ("defer_loading", 1),
      ("eager_input_streaming", "true"),
      ("input_examples", ["not-an-object"]),
      ("input_examples", [["invalid": Date()]]),
    ]
    for (field, value) in invalidFields {
      let request: [String: Any] = [
        "model": "gpt-4o",
        "messages": [],
        "tools": [
          [
            "name": "lookup",
            "input_schema": ["type": "object"],
            field: value,
          ]
        ],
      ]
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(request), "field=\(field)")
    }

    for type in ["computer_20241022", "bash_20250124", "custom_v2"] {
      let request: [String: Any] = [
        "model": "gpt-4o",
        "messages": [],
        "tools": [
          [
            "type": type,
            "name": "lookup",
            "input_schema": ["type": "object"],
          ]
        ],
      ]
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(request), "type=\(type)")
    }

    XCTAssertNoThrow(
      try AnthropicCodec.toOpenAI([
        "model": "gpt-4o",
        "messages": [],
        "tools": [
          [
            "name": "legacy",
            "input_schema": ["type": "object"],
          ],
          [
            "type": "custom",
            "name": "typed",
            "input_schema": ["type": "object"],
          ],
        ],
      ]))
  }

  func testNullOptionalFieldsAreTreatedAsAbsent() throws {
    let output = try AnthropicCodec.toOpenAI([
      "model": "gpt-4o",
      "messages": [],
      "max_tokens": NSNull(),
      "system": NSNull(),
      "stream": NSNull(),
      "stop_sequences": NSNull(),
      "metadata": NSNull(),
      "tools": NSNull(),
      "thinking": NSNull(),
      "output_config": NSNull(),
      "output_format": NSNull(),
      "context_management": NSNull(),
      "tool_choice": NSNull(),
      "temperature": NSNull(),
      "top_p": NSNull(),
      "cache_control": NSNull(),
      "service_tier": NSNull(),
      "top_k": NSNull(),
      "container": NSNull(),
      "inference_geo": NSNull(),
      "mcp_servers": NSNull(),
      "user_profile_id": NSNull(),
      "workspace_id": NSNull(),
    ])
    XCTAssertEqual(Set(output.keys), ["messages", "model", "stream"])
    XCTAssertEqual(output["stream"] as? Bool, false)
  }

  func testRejectsUnsupportedTopLevelSemanticsWhenNonNull() {
    let unsupportedFields = [
      "container", "inference_geo", "mcp_servers", "user_profile_id", "workspace_id",
    ]
    for field in unsupportedFields {
      var request: [String: Any] = ["model": "gpt-4o", "messages": []]
      request[field] = "requested"
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(request), "field=\(field)")
    }
  }

  func testValidatesAndStripsTopLevelCompatibilityHints() throws {
    for ttl: Any in [NSNull(), "5m", "1h"] {
      for serviceTier in ["auto", "standard_only"] {
        let output = try AnthropicCodec.toOpenAI([
          "model": "gpt-4o",
          "messages": [],
          "cache_control": ["type": "ephemeral", "ttl": ttl],
          "service_tier": serviceTier,
          "top_k": 0,
        ])
        XCTAssertNil(output["cache_control"])
        XCTAssertNil(output["service_tier"])
        XCTAssertNil(output["top_k"])
      }
    }

    let invalidFields: [(String, Any)] = [
      ("cache_control", "ephemeral"),
      ("cache_control", ["type": "persistent"]),
      ("cache_control", ["type": "ephemeral", "ttl": "1d"]),
      ("cache_control", ["type": "ephemeral", "ttl": "5m", "scope": "global"]),
      ("service_tier", "priority_only"),
      ("service_tier", 1),
      ("top_k", -1),
      ("top_k", 1.5),
      ("top_k", true),
    ]
    for (field, value) in invalidFields {
      var request: [String: Any] = ["model": "gpt-4o", "messages": []]
      request[field] = value
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(request), "field=\(field)")
    }
  }

  func testToolRoundTripAndUsage() throws {
    let openAI: [String: Any] = [
      "id": "chatcmpl_1",
      "model": "claude-sonnet-4.6",
      "choices": [
        [
          "index": 0,
          "message": [
            "role": "assistant",
            "content": NSNull(),
            "tool_calls": [
              [
                "id": "call_123",
                "type": "function",
                "function": ["name": "weather", "arguments": "{\"city\":\"Paris\"}"],
              ]
            ],
          ],
          "finish_reason": "tool_calls",
        ]
      ],
      "usage": ["prompt_tokens": 12, "completion_tokens": 7, "total_tokens": 19],
    ]

    let output = try AnthropicCodec.fromOpenAI(openAI, requestedModel: "claude-sonnet-4.6")
    XCTAssertEqual(output["stop_reason"] as? String, "tool_use")
    let content = try XCTUnwrap(output["content"] as? [[String: Any]])
    XCTAssertEqual(content[0]["type"] as? String, "tool_use")
    XCTAssertEqual((content[0]["input"] as? [String: String])?["city"], "Paris")
    let usage = try XCTUnwrap(output["usage"] as? [String: Int])
    XCTAssertEqual(usage["input_tokens"], 12)
    XCTAssertEqual(usage["output_tokens"], 7)
  }

  func testToolResultsBecomeOpenAIToolMessages() throws {
    let source: [String: Any] = [
      "model": "claude-sonnet-4.6",
      "max_tokens": 100,
      "messages": [
        [
          "role": "assistant",
          "content": [
            ["type": "tool_use", "id": "tool_1", "name": "read", "input": ["path": "a.txt"]]
          ],
        ],
        [
          "role": "user",
          "content": [
            ["type": "tool_result", "tool_use_id": "tool_1", "content": "hello"],
            ["type": "text", "text": "Summarize"],
          ],
        ],
      ],
    ]

    let output = try AnthropicCodec.toOpenAI(source)
    let messages = try XCTUnwrap(output["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["assistant", "tool", "user"])
    XCTAssertEqual(messages[1]["tool_call_id"] as? String, "tool_1")
  }

  func testRejectsNonObjectOrNonJSONToolUseInputBeforeSerialization() {
    let invalidInputs: [Any] = [
      "not-an-object",
      7,
      NSNull(),
      ["not_json": Date()],
    ]
    for input in invalidInputs {
      let source: [String: Any] = [
        "model": "gpt-4o",
        "max_tokens": 1,
        "messages": [
          [
            "role": "assistant",
            "content": [
              ["type": "tool_use", "id": "tool_1", "name": "lookup", "input": input]
            ],
          ]
        ],
      ]

      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(source), "input=\(input)") { error in
        XCTAssertEqual(
          error as? BridgeError,
          .invalidRequest("tool_use.input 必须是 JSON 对象。"))
      }
    }
  }

  func testRejectsOtherNonJSONValuesBeforeEncoding() {
    var invalidTemperature: [String: Any] = [
      "model": "gpt-4o",
      "max_tokens": 1,
      "messages": [],
      "temperature": Date(),
    ]
    XCTAssertThrowsError(try AnthropicCodec.toOpenAI(invalidTemperature))

    invalidTemperature.removeValue(forKey: "temperature")
    invalidTemperature["tools"] = [
      [
        "name": "lookup",
        "input_schema": ["type": "object", "invalid": Double.nan],
      ]
    ]
    XCTAssertThrowsError(try AnthropicCodec.toOpenAI(invalidTemperature))
    XCTAssertThrowsError(try AnthropicCodec.estimatedInputTokens(invalidTemperature))
  }

  func testRejectsUnsupportedBlocks() {
    let source: [String: Any] = [
      "model": "claude-sonnet-4.6",
      "max_tokens": 100,
      "messages": [["role": "user", "content": [["type": "audio", "data": "..."]]]],
    ]
    XCTAssertThrowsError(try AnthropicCodec.toOpenAI(source))
  }

  func testTokenEstimateIsConservativeForUnicodeAndIncludesTools() throws {
    let base: [String: Any] = [
      "model": "claude-sonnet-4.6",
      "messages": [["role": "user", "content": "中文字符测试"]],
    ]
    let baseEstimate = try AnthropicCodec.estimatedInputTokens(base)
    XCTAssertGreaterThanOrEqual(baseEstimate, 6)

    var withTools = base
    withTools["tools"] = [
      [
        "name": "lookup",
        "description": "Look up weather",
        "input_schema": ["type": "object", "properties": ["city": ["type": "string"]]],
      ]
    ]
    XCTAssertGreaterThan(try AnthropicCodec.estimatedInputTokens(withTools), baseEstimate)
  }

  func testRejectsMalformedOrUnknownBlocksInsteadOfDroppingThem() {
    let malformedUser: [String: Any] = [
      "model": "claude-sonnet-4.6",
      "messages": [["role": "user", "content": [["text": "missing type"]]]],
    ]
    let unknownSystem: [String: Any] = [
      "model": "claude-sonnet-4.6",
      "system": [["type": "image", "source": [:]]],
      "messages": [],
    ]
    XCTAssertThrowsError(try AnthropicCodec.toOpenAI(malformedUser))
    XCTAssertThrowsError(try AnthropicCodec.toOpenAI(unknownSystem))
  }

  func testPreservesRefusalAsText() throws {
    let response: [String: Any] = [
      "choices": [
        [
          "message": ["role": "assistant", "content": NSNull(), "refusal": "I cannot do that."],
          "finish_reason": "refusal",
        ]
      ]
    ]
    let output = try AnthropicCodec.fromOpenAI(response, requestedModel: "claude-sonnet-4.6")
    let content = try XCTUnwrap(output["content"] as? [[String: Any]])
    XCTAssertEqual(content.first?["text"] as? String, "I cannot do that.")
    XCTAssertEqual(output["stop_reason"] as? String, "refusal")
  }

  func testRejectsTruncatedToolCallFromUpstream() {
    let response: [String: Any] = [
      "choices": [
        [
          "message": [
            "tool_calls": [
              [
                "id": "call_1",
                "function": ["name": "shell", "arguments": "{\"command\":"],
              ]
            ]
          ],
          "finish_reason": "length",
        ]
      ]
    ]
    XCTAssertThrowsError(try AnthropicCodec.fromOpenAI(response, requestedModel: "claude"))
  }

  func testRejectsIncompleteUpstreamResponse() {
    XCTAssertThrowsError(
      try AnthropicCodec.fromOpenAI(["choices": []], requestedModel: "claude"))
    XCTAssertThrowsError(
      try AnthropicCodec.fromOpenAI(
        ["choices": [["message": ["content": "ok"], "finish_reason": NSNull()]]],
        requestedModel: "claude"))
    XCTAssertThrowsError(
      try AnthropicCodec.fromOpenAI(
        ["choices": [["message": ["content": "ok"], "finish_reason": "tool_calls"]]],
        requestedModel: "claude"))
  }

  func testClaudeCode233CapturedShapeIsAcceptedWithoutLeakingCompatibilityFieldsToGPT() throws {
    let output = try AnthropicCodec.toOpenAI(claudeCode233Fixture())

    XCTAssertEqual(
      Set(output.keys), ["max_tokens", "messages", "model", "stream", "tools", "user"])
    XCTAssertEqual(output["model"] as? String, "gpt-4o")
    XCTAssertEqual(output["max_tokens"] as? Int, 32_000)
    XCTAssertEqual(output["stream"] as? Bool, true)
    XCTAssertEqual(output["user"] as? String, "fixture-user")
    XCTAssertNil(output["thinking"])
    XCTAssertNil(output["output_config"])
    XCTAssertNil(output["context_management"])
    XCTAssertNil(output["reasoning_effort"])

    let messages = try XCTUnwrap(output["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
    XCTAssertEqual(messages[0]["content"] as? String, "SYSTEM_SENTINEL")
    XCTAssertEqual(messages[1]["content"] as? String, "USER_SENTINEL")
    let function = try XCTUnwrap(
      (output["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
    XCTAssertEqual(function["name"] as? String, "lookup")
  }

  func testClaudeCode233ThinkingOnlyPassesToClaudeTargets() throws {
    for model in ["claude-sonnet-4.6", "anthropic/claude-sonnet-4.6", "CLAUDE-SONNET-4.6"] {
      let output = try AnthropicCodec.toOpenAI(claudeCode233Fixture(model: model))
      XCTAssertEqual(
        (output["thinking"] as? [String: String])?["type"], "adaptive", "model=\(model)")
      XCTAssertNil(output["output_config"], "model=\(model)")
      XCTAssertNil(output["context_management"], "model=\(model)")
    }
  }

  func testThinkingBlockBindingIsValidatedAndStripped() throws {
    for behavior: Any in [NSNull(), "error", "drop_block"] {
      let output = try AnthropicCodec.toOpenAI(
        [
          "model": "claude-sonnet-4.6",
          "messages": [],
          "thinking": [
            "type": "adaptive",
            "display": NSNull(),
            "block_binding": ["prefix_mismatch_behavior": behavior],
          ],
        ], resolvedModel: "claude-sonnet-4.6")
      let thinking = try XCTUnwrap(output["thinking"] as? [String: Any])
      XCTAssertEqual(thinking["type"] as? String, "adaptive")
      XCTAssertNil(thinking["display"])
      XCTAssertNil(thinking["block_binding"])
    }

    let invalidBindings: [Any] = [
      "drop_block",
      ["prefix_mismatch_behavior": "ignore"],
      ["prefix_mismatch_behavior": 1],
      ["prefix_mismatch_behavior": "error", "bind_to_end_user": true],
    ]
    for binding in invalidBindings {
      XCTAssertThrowsError(
        try AnthropicCodec.toOpenAI(
          [
            "model": "claude-sonnet-4.6",
            "messages": [],
            "thinking": ["type": "adaptive", "block_binding": binding],
          ], resolvedModel: "claude-sonnet-4.6"))
    }
  }

  func testAcceptsControlledContextManagementShapesAndStripsThem() throws {
    let validValues: [Any] = [
      [:] as [String: Any],
      ["edits": NSNull()],
      ["edits": []],
      [
        "edits": [
          ["type": "clear_thinking_20251015", "keep": "all"],
          ["type": "clear_thinking_20251015", "keep": "all"],
          ["type": "clear_tool_uses_20250919"],
          [
            "type": "clear_tool_uses_20250919",
            "trigger": ["type": "input_tokens", "value": 30_000],
            "keep": ["type": "tool_uses", "value": 3],
            "clear_at_least": ["type": "input_tokens", "value": 5_000],
            "clear_tool_inputs": ["read", "search"],
            "exclude_tools": ["memory"],
          ],
          [
            "type": "clear_tool_uses_20250919",
            "trigger": ["type": "tool_uses", "value": 10],
            "keep": NSNull(),
            "clear_at_least": NSNull(),
            "clear_tool_inputs": true,
            "exclude_tools": NSNull(),
          ],
        ]
      ],
    ]
    for value in validValues {
      let output = try AnthropicCodec.toOpenAI([
        "model": "gpt-4o", "messages": [], "context_management": value,
      ])
      XCTAssertNil(output["context_management"])
    }
  }

  func testRejectsMalformedClaudeCodeCompatibilityFields() {
    let invalidOutputConfigs: [Any] = [
      [:] as [String: Any],
      ["effort": "extreme"],
      ["effort": 1],
      ["effort": "high", "format": "json"],
      "high",
    ]
    for value in invalidOutputConfigs {
      var fixture = claudeCode233Fixture()
      fixture["output_config"] = value
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(fixture), "output_config=\(value)")
    }

    let invalidContextManagement: [Any] = [
      ["edits": "clear"] as [String: Any],
      ["edits": [["type": "clear_thinking_20251015", "keep": 1]]],
      ["edits": [["type": "clear_thinking_20251015", "keep": "all", "clear_at": 1]]],
      ["edits": [["type": "clear_tool_uses_20250919", "clear_at": 1]]],
      ["edits": [["type": "clear_tool_uses_20250919", "clear_at_least": 1]]],
      [
        "edits": [
          [
            "type": "clear_tool_uses_20250919",
            "trigger": ["type": "requests", "value": 1],
          ]
        ]
      ],
      [
        "edits": [
          [
            "type": "clear_tool_uses_20250919",
            "keep": ["type": "tool_uses", "value": 1.5],
          ]
        ]
      ],
      [
        "edits": [
          [
            "type": "clear_tool_uses_20250919",
            "clear_tool_inputs": ["read", 1],
          ]
        ]
      ],
      ["edits": [["type": "compact_20260112"]]],
      "keep-all",
    ]
    for value in invalidContextManagement {
      var fixture = claudeCode233Fixture()
      fixture["context_management"] = value
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(fixture), "context_management=\(value)")
    }
  }

  func testOutputConfigEffortEnumsAreValidatedThenIgnored() throws {
    for effort in ["low", "medium", "high", "xhigh", "max"] {
      var fixture = claudeCode233Fixture()
      fixture["output_config"] = ["effort": effort]
      let output = try AnthropicCodec.toOpenAI(fixture)
      XCTAssertNil(output["output_config"])
      XCTAssertNil(output["reasoning_effort"])
    }
  }

  func testMapsCurrentAndLegacyStructuredOutputFormats() throws {
    let schema: [String: Any] = [
      "type": "object",
      "properties": ["answer": ["type": "string"]],
      "required": ["answer"],
      "additionalProperties": false,
    ]
    for requestFormat in [
      ["output_config": ["format": ["type": "json_schema", "schema": schema]]],
      ["output_format": ["type": "json_schema", "schema": schema]],
    ] {
      var request: [String: Any] = ["model": "gpt-4o", "messages": []]
      request.merge(requestFormat) { _, replacement in replacement }
      let output = try AnthropicCodec.toOpenAI(request)
      let responseFormat = try XCTUnwrap(output["response_format"] as? [String: Any])
      XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
      let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
      XCTAssertEqual(jsonSchema["name"] as? String, "anthropic_output")
      XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
      XCTAssertTrue((jsonSchema["schema"] as? NSDictionary)?.isEqual(to: schema) == true)
    }
  }

  func testRejectsAmbiguousOrMalformedStructuredOutputFormats() {
    let valid: [String: Any] = ["type": "json_schema", "schema": ["type": "object"]]
    let invalidRequests: [[String: Any]] = [
      ["output_config": [:]],
      ["output_config": ["format": "json"]],
      ["output_config": ["format": ["type": "json_object", "schema": [:]]]],
      ["output_config": ["format": ["type": "json_schema"]]],
      ["output_config": ["format": valid], "output_format": valid],
    ]
    for fields in invalidRequests {
      var request: [String: Any] = ["model": "gpt-4o", "messages": []]
      request.merge(fields) { _, replacement in replacement }
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(request))
    }
  }

  func testMaxTokensRequiresAnExactPositiveInteger() throws {
    XCTAssertEqual(AnthropicCodec.exactPositiveInteger(1), 1)
    XCTAssertEqual(AnthropicCodec.exactPositiveInteger(32_000), 32_000)
    XCTAssertEqual(AnthropicCodec.exactPositiveInteger(Int.max), Int.max)
    XCTAssertEqual(AnthropicCodec.exactPositiveInteger(NSNumber(value: 1.0)), 1)

    let invalid: [Any] = [
      true, false, "1", 0, -1, 1.5, Double.nan, Double.infinity,
      -Double.infinity, NSNumber(value: UInt64(Int.max) + 1),
    ]
    XCTAssertNil(AnthropicCodec.exactPositiveInteger(nil))
    for value in invalid {
      XCTAssertNil(AnthropicCodec.exactPositiveInteger(value), "value=\(value)")
      var request: [String: Any] = [
        "model": "gpt-4o", "messages": [], "max_tokens": value,
      ]
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(request))
      request.removeValue(forKey: "max_tokens")
    }

    let nullOutput = try AnthropicCodec.toOpenAI([
      "model": "gpt-4o", "messages": [], "max_tokens": NSNull(),
    ])
    XCTAssertNil(nullOutput["max_tokens"])
  }

  func testPreservesMidConversationSystemOrdering() throws {
    let output = try AnthropicCodec.toOpenAI([
      "model": "gpt-4o",
      "max_tokens": 100,
      "system": [
        ["type": "text", "text": "ROOT-A"],
        ["type": "text", "text": "ROOT-B"],
      ],
      "messages": [
        ["role": "user", "content": "U1"],
        ["role": "assistant", "content": "A1"],
        [
          "role": "system",
          "content": [
            ["type": "text", "text": "MID-A"],
            ["type": "text", "text": "MID-B"],
          ],
        ],
        ["role": "user", "content": "U2"],
      ],
    ])
    let messages = try XCTUnwrap(output["messages"] as? [[String: Any]])

    XCTAssertEqual(
      messages.map { $0["role"] as? String }, ["system", "user", "assistant", "system", "user"])
    XCTAssertEqual(
      messages.map { $0["content"] as? String },
      ["ROOT-A\n\nROOT-B", "U1", "A1", "MID-A\n\nMID-B", "U2"])
  }

  func testMapsDisableParallelToolUseAndRejectsNonBooleanValues() throws {
    for (disable, expected) in [(true, false), (false, true)] {
      let output = try AnthropicCodec.toOpenAI([
        "model": "gpt-4o",
        "max_tokens": 100,
        "messages": [],
        "tool_choice": ["type": "auto", "disable_parallel_tool_use": disable],
      ])
      XCTAssertEqual(output["parallel_tool_calls"] as? Bool, expected)
    }

    for value: Any in [1, "true"] {
      XCTAssertThrowsError(
        try AnthropicCodec.toOpenAI([
          "model": "gpt-4o",
          "max_tokens": 100,
          "messages": [],
          "tool_choice": ["type": "auto", "disable_parallel_tool_use": value],
        ]))
    }
  }

  func testSignatureOnlyNonstreamOutputBecomesRedactedThinking() throws {
    for reasoningText: Any? in [nil, ""] {
      var message: [String: Any] = [
        "role": "assistant", "content": "answer", "reasoning_opaque": "opaque-data",
      ]
      if let reasoningText { message["reasoning_text"] = reasoningText }
      let output = try AnthropicCodec.fromOpenAI(
        ["choices": [["message": message, "finish_reason": "stop"]]],
        requestedModel: "claude-sonnet-4.6")
      let content = try XCTUnwrap(output["content"] as? [[String: Any]])
      XCTAssertEqual(content.map { $0["type"] as? String }, ["redacted_thinking", "text"])
      XCTAssertEqual(content[0]["data"] as? String, "opaque-data")
    }
  }

  func testNonstreamThinkingKeepsOpaqueAsSignature() throws {
    let output = try AnthropicCodec.fromOpenAI(
      [
        "choices": [
          [
            "message": [
              "role": "assistant",
              "content": NSNull(),
              "reasoning_text": "private thought",
              "reasoning_opaque": "opaque-signature",
            ],
            "finish_reason": "stop",
          ]
        ]
      ],
      requestedModel: "claude-sonnet-4.6")
    let block = try XCTUnwrap((output["content"] as? [[String: Any]])?.first)
    XCTAssertEqual(block["type"] as? String, "thinking")
    XCTAssertEqual(block["thinking"] as? String, "private thought")
    XCTAssertEqual(block["signature"] as? String, "opaque-signature")
  }

  func testFailsClosedWhenOneAssistantMessageContainsMultipleOpaqueBlocks() throws {
    let base: [String: Any] = [
      "model": "claude-sonnet-4.6",
      "max_tokens": 100,
    ]
    for blocks in [
      [
        ["type": "thinking", "thinking": "one", "signature": "sig-one"],
        ["type": "thinking", "thinking": "two", "signature": "sig-two"],
      ],
      [
        ["type": "thinking", "thinking": "one", "signature": "sig-one"],
        ["type": "redacted_thinking", "data": "sig-two"],
      ],
    ] {
      var request = base
      request["messages"] = [["role": "assistant", "content": blocks]]
      XCTAssertThrowsError(try AnthropicCodec.toOpenAI(request))
    }

    var request = base
    request["messages"] = [
      [
        "role": "assistant",
        "content": [["type": "thinking", "thinking": "one", "signature": "sig-one"]],
      ],
      ["role": "user", "content": "continue"],
      [
        "role": "assistant",
        "content": [["type": "redacted_thinking", "data": "sig-two"]],
      ],
    ]
    XCTAssertNoThrow(try AnthropicCodec.toOpenAI(request))
  }

  private func claudeCode233Fixture(model: String = "gpt-4o") -> [String: Any] {
    [
      "model": model,
      "max_tokens": 32_000,
      "stream": true,
      "thinking": ["type": "adaptive", "display": "omitted"],
      "output_config": ["effort": "high"],
      "context_management": [
        "edits": [
          ["type": "clear_thinking_20251015", "keep": "all"]
        ]
      ],
      "metadata": ["user_id": "fixture-user"],
      "system": [["type": "text", "text": "SYSTEM_SENTINEL"]],
      "messages": [
        ["role": "user", "content": [["type": "text", "text": "USER_SENTINEL"]]]
      ],
      "tools": [
        [
          "name": "lookup",
          "description": "fixture",
          "input_schema": ["type": "object", "properties": [:]],
        ]
      ],
    ]
  }
}
