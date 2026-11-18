import Foundation
import XCTest

@testable import CopilotBridgeCore

final class CopilotAccountServiceTests: XCTestCase {
  func testParsesOnlySelectableChatModelsAndRuntimeMetadata() throws {
    let data = try json([
      "data": [
        [
          "id": "gpt-visible",
          "name": "GPT Visible",
          "vendor": ["name": "OpenAI"],
          "model_picker_enabled": true,
          "supported_endpoints": ["chat", "responses", "chat"],
          "capabilities": [
            "type": "chat",
            "supports": [
              "vision": true,
              "tool_calls": true,
              "reasoning_effort": ["low", "high"],
            ],
            "limits": [
              "max_prompt_tokens": 200_000,
              "max_output_tokens": 64_000,
            ],
          ],
          "billing": ["is_premium": true, "multiplier": 1.5],
          "preview": true,
        ],
        ["id": "picker-hidden", "model_picker_enabled": false],
        [
          "id": "picker-field-omitted",
          "supported_endpoints": ["responses"],
        ],
        ["id": "policy-disabled", "policy": ["state": "disabled"]],
        ["id": "embedding", "capabilities": ["type": "embeddings"]],
      ]
    ])

    let models = try CopilotAccountService.parseModels(data)

    XCTAssertEqual(models.count, 2)
    let model = try XCTUnwrap(models.first { $0.id == "gpt-visible" })
    XCTAssertEqual(model.id, "gpt-visible")
    XCTAssertEqual(model.displayName, "GPT Visible")
    XCTAssertEqual(model.vendor, "OpenAI")
    XCTAssertEqual(model.type, "chat")
    XCTAssertEqual(model.capabilities, [.vision, .tools, .reasoning])
    XCTAssertEqual(model.supportedEndpoints, ["chat", "responses"])
    XCTAssertEqual(model.maximumPromptTokens, 200_000)
    XCTAssertEqual(model.maximumOutputTokens, 64_000)
    XCTAssertEqual(model.billingMultiplier, 1.5)
    XCTAssertEqual(model.isPremium, true)
    XCTAssertEqual(model.isPreview, true)
    XCTAssertNotNil(models.first { $0.id == "picker-field-omitted" })
  }

  func testParsesLegacyRequestQuotaAndComputedUsage() throws {
    let data = try json([
      "login": "octocat",
      "copilot_plan": "individual_pro",
      "access_type_sku": "copilot_pro",
      "quota_reset_date_utc": "2026-10-01T00:00:00.000Z",
      "quota_snapshots": [
        "premium_interactions": [
          "entitlement": 300,
          "remaining": 225,
          "percent_remaining": 12,
          "token_based_billing": false,
          "overage_permitted": true,
        ],
        "chat": ["unlimited": true],
      ],
    ])

    let quota = try CopilotAccountService.parseQuota(data)

    XCTAssertEqual(quota.accountName, "octocat")
    XCTAssertEqual(quota.planName, "individual_pro")
    XCTAssertEqual(quota.sku, "copilot_pro")
    XCTAssertNotNil(quota.resetAt)
    XCTAssertFalse(quota.hasExactAICreditData)
    XCTAssertEqual(quota.entries.map(\.id), ["premium_interactions", "chat"])
    let premium = try XCTUnwrap(quota.entries.first)
    XCTAssertEqual(premium.unit, .requests)
    XCTAssertEqual(premium.entitlement, 300)
    XCTAssertEqual(premium.remaining, 225)
    XCTAssertEqual(premium.used, 75)
    XCTAssertEqual(
      premium.percentRemaining, 75, "Known totals take precedence over stale percentages")
    XCTAssertEqual(premium.overagePermitted, true)
    XCTAssertTrue(quota.entries[1].unlimited)
  }

  func testLabelsOnlyExplicitCreditValuesAsAICredits() throws {
    let data = try json([
      "quota_snapshots": [
        "premium_interactions": [
          "entitlement": 50,
          "credits_used": 12.5,
          "remaining": 37.5,
          "token_based_billing": true,
        ],
        "another_bucket": [
          "entitlement": 100,
          "remaining": 90,
        ],
      ]
    ])

    let quota = try CopilotAccountService.parseQuota(data)

    XCTAssertTrue(quota.hasExactAICreditData)
    XCTAssertEqual(quota.entries.first { $0.id == "premium_interactions" }?.unit, .aiCredits)
    XCTAssertEqual(quota.entries.first { $0.id == "premium_interactions" }?.used, 12.5)
    XCTAssertEqual(quota.entries.first { $0.id == "another_bucket" }?.unit, .unspecified)
  }

  func testKeepsCurrentAICreditsSeparateFromLegacyPremiumRequests() throws {
    let data = try json([
      "token_based_billing": true,
      "quota_snapshots": [
        "premium_interactions": [
          "entitlement": 300,
          "remaining": 200,
          "token_based_billing": false,
        ],
        "premium_models": [
          "entitlement": 1_000,
          "remaining": 750,
          "has_quota": true,
          "quota_reset_at": 1_798_761_600,
        ],
        "chat": ["entitlement": 50, "remaining": 40],
      ],
    ])

    let quota = try CopilotAccountService.parseQuota(data)

    XCTAssertEqual(
      quota.entries.first { $0.id == "premium_interactions" }?.unit,
      .requests)
    let credits = try XCTUnwrap(quota.entries.first { $0.id == "premium_models" })
    XCTAssertEqual(credits.unit, .aiCredits)
    XCTAssertEqual(credits.hasQuota, true)
    XCTAssertNotNil(credits.resetAt)
    XCTAssertEqual(quota.entries.first { $0.id == "chat" }?.unit, .requests)
  }

  func testExplicitRequestFieldsOverrideTokenBasedAccountMode() throws {
    let data = try json([
      "tokenBasedBilling": true,
      "quotas": [
        "premium_models": [
          "entitlementRequests": 100,
          "usedRequests": 25,
          "remainingPercentage": 75,
        ]
      ],
    ])

    let quota = try CopilotAccountService.parseQuota(data)
    let entry = try XCTUnwrap(quota.entries.first)

    XCTAssertEqual(entry.unit, .requests)
    XCTAssertEqual(entry.entitlement, 100)
    XCTAssertEqual(entry.used, 25)
    XCTAssertEqual(entry.percentRemaining, 75)
    XCTAssertFalse(quota.hasExactAICreditData)
  }

  func testParsesOfficialSDKQuotaFlagsAndResetDate() throws {
    let data = try json([
      "resetDate": "2026-10-01T00:00:00Z",
      "quotas": [
        "premium_interactions": [
          "isUnlimitedEntitlement": true,
          "usageAllowedWithExhaustedQuota": true,
          "resetDate": "2026-10-02T00:00:00Z",
        ]
      ],
    ])

    let quota = try CopilotAccountService.parseQuota(data)
    let entry = try XCTUnwrap(quota.entries.first)

    XCTAssertNotNil(quota.resetAt)
    XCTAssertTrue(entry.unlimited)
    XCTAssertEqual(entry.overagePermitted, true)
    XCTAssertNotNil(entry.resetAt)
  }

  func testParsesFreeLimitedBucketsWithoutInventingMissingValues() throws {
    let data = try json([
      "limited_user_quotas": ["chat": 40, "completions": 900],
      "monthly_quotas": ["chat": 50],
      "limited_user_reset_date": "2026-10-01",
    ])

    let quota = try CopilotAccountService.parseQuota(data)

    XCTAssertEqual(quota.entries.map(\.id), ["chat", "completions"])
    let chat = try XCTUnwrap(quota.entries.first { $0.id == "chat" })
    XCTAssertEqual(chat.entitlement, 50)
    XCTAssertEqual(chat.used, 10)
    XCTAssertEqual(chat.remaining, 40)
    XCTAssertEqual(chat.percentRemaining, 80)
    let completions = try XCTUnwrap(quota.entries.first { $0.id == "completions" })
    XCTAssertNil(completions.entitlement)
    XCTAssertNil(completions.used)
    XCTAssertEqual(completions.remaining, 900)
    XCTAssertNil(completions.percentRemaining)
  }

  func testQuotaRequestUsesOAuthHeaderWithoutQueryCredentials() {
    let request = CopilotAccountService.makeQuotaRequest(
      oauthToken: "secret-oauth-token",
      userAgent: "test-agent",
      editorVersion: "test-editor",
      editorPluginVersion: "test-plugin"
    )

    XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/copilot_internal/user")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token secret-oauth-token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2025-04-01")
    XCTAssertFalse(request.url?.absoluteString.contains("secret-oauth-token") == true)
  }

  func testStaleTokenSnapshotForcesOneFreshExchangeThenUsesRecentSnapshot() async throws {
    let sequence = QuotaTokenSequence()
    let manager = CopilotTokenManager(
      oauthTokenLoader: { "oauth-token" },
      exchangeToken: { _ in await sequence.next() })
    let service = CopilotAccountService(tokenManager: manager)

    let firstRead = try await service.fetchQuota()
    let secondRead = try await service.fetchQuota()
    let forcedRead = try await service.fetchQuota(forceRefresh: true)

    XCTAssertEqual(firstRead.entries.first?.remaining, 80)
    XCTAssertEqual(secondRead.entries.first?.remaining, 80)
    XCTAssertEqual(forcedRead.entries.first?.remaining, 80)
    let calls = await sequence.calls
    XCTAssertEqual(
      calls, 3,
      "A stale snapshot refreshes once, a recent automatic read reuses it, and a manual refresh forces another exchange"
    )
  }

  func testRejectsMalformedCatalogAndQuotaRoots() throws {
    XCTAssertThrowsError(try CopilotAccountService.parseModels(try json(["object": "list"])))
    XCTAssertThrowsError(
      try CopilotAccountService.parseModels(try json(["data": [["name": "no id"]]])))
    XCTAssertThrowsError(try CopilotAccountService.parseQuota(try json(["not", "an", "object"])))
  }

  private func json(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
  }
}

private actor QuotaTokenSequence {
  private(set) var calls = 0

  func next() -> CopilotAccessToken {
    calls += 1
    let isFirst = calls == 1
    return CopilotAccessToken(
      value: "short-token-\(calls)",
      expiresAt: Date().addingTimeInterval(1_800),
      apiEndpoint: nil,
      quotaSnapshot: CopilotQuotaSnapshot(
        entries: [
          CopilotQuotaEntry(
            id: "premium_models",
            unit: .aiCredits,
            entitlement: 100,
            remaining: isFirst ? 90 : 80)
        ]),
      refreshedAt: Date().addingTimeInterval(isFirst ? -120 : 0)
    )
  }
}
