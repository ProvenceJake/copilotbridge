import Foundation

public enum CopilotModelCapability: String, Sendable, Hashable {
  case vision
  case tools
  case reasoning
}

public struct CopilotAvailableModel: Identifiable, Sendable, Hashable {
  public let id: String
  public let displayName: String
  public let vendor: String?
  public let type: String?
  public let capabilities: Set<CopilotModelCapability>
  public let supportedEndpoints: [String]
  public let maximumPromptTokens: Int?
  public let maximumOutputTokens: Int?
  public let billingMultiplier: Double?
  public let isPremium: Bool?
  public let isPreview: Bool?
  public let isPickerEnabled: Bool?

  public init(
    id: String,
    displayName: String,
    vendor: String? = nil,
    type: String? = nil,
    capabilities: Set<CopilotModelCapability> = [],
    supportedEndpoints: [String] = [],
    maximumPromptTokens: Int? = nil,
    maximumOutputTokens: Int? = nil,
    billingMultiplier: Double? = nil,
    isPremium: Bool? = nil,
    isPreview: Bool? = nil,
    isPickerEnabled: Bool? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.vendor = vendor
    self.type = type
    self.capabilities = capabilities
    self.supportedEndpoints = supportedEndpoints
    self.maximumPromptTokens = maximumPromptTokens
    self.maximumOutputTokens = maximumOutputTokens
    self.billingMultiplier = billingMultiplier
    self.isPremium = isPremium
    self.isPreview = isPreview
    self.isPickerEnabled = isPickerEnabled
  }
}

public enum CopilotQuotaUnit: String, Sendable, Hashable {
  /// The response explicitly identifies the bucket or account mode as AI Credits.
  case aiCredits
  /// The response explicitly used request-valued fields, or returned a legacy request bucket.
  case requests
  /// GitHub returned a numeric quota but did not state its unit.
  case unspecified
}

public struct CopilotQuotaEntry: Identifiable, Sendable, Hashable {
  public let id: String
  public let unit: CopilotQuotaUnit
  public let entitlement: Double?
  public let used: Double?
  public let remaining: Double?
  public let percentRemaining: Double?
  public let unlimited: Bool
  public let hasQuota: Bool?
  public let overagePermitted: Bool?
  public let resetAt: Date?

  public init(
    id: String,
    unit: CopilotQuotaUnit,
    entitlement: Double? = nil,
    used: Double? = nil,
    remaining: Double? = nil,
    percentRemaining: Double? = nil,
    unlimited: Bool = false,
    hasQuota: Bool? = nil,
    overagePermitted: Bool? = nil,
    resetAt: Date? = nil
  ) {
    self.id = id
    self.unit = unit
    self.entitlement = entitlement
    self.used = used
    self.remaining = remaining
    self.percentRemaining = percentRemaining
    self.unlimited = unlimited
    self.hasQuota = hasQuota
    self.overagePermitted = overagePermitted
    self.resetAt = resetAt
  }
}

public struct CopilotQuotaSnapshot: Sendable, Hashable {
  public let accountName: String?
  public let planName: String?
  public let sku: String?
  public let resetAt: Date?
  public let entries: [CopilotQuotaEntry]

  public init(
    accountName: String? = nil,
    planName: String? = nil,
    sku: String? = nil,
    resetAt: Date? = nil,
    entries: [CopilotQuotaEntry] = []
  ) {
    self.accountName = accountName
    self.planName = planName
    self.sku = sku
    self.resetAt = resetAt
    self.entries = entries
  }

  public var hasExactAICreditData: Bool {
    entries.contains {
      $0.unit == .aiCredits
        && ($0.entitlement != nil || $0.used != nil || $0.remaining != nil
          || $0.percentRemaining != nil || $0.unlimited)
    }
  }
}

/// Loads the live model catalog and account quota without persisting either response.
///
/// Model discovery uses the short-lived Copilot token and the endpoint returned by GitHub.
/// Quota is a best-effort compatibility read from GitHub's Copilot account-status endpoint.
/// Callers must keep quota failures separate from model-discovery failures because GitHub can
/// legitimately authorize one while withholding the other.
public final class CopilotAccountService: @unchecked Sendable {
  private let modelsLoader: @Sendable () async throws -> [CopilotAvailableModel]
  private let quotaLoader: @Sendable (Bool) async throws -> CopilotQuotaSnapshot

  public init(
    tokenManager: CopilotTokenManager,
    session: URLSession = .shared,
    userAgent: String = "GitHubCopilotChat/0.22.4",
    editorVersion: String = "vscode/1.95.0",
    editorPluginVersion: String = "copilot-chat/0.22.4"
  ) {
    let configuration = BridgeConfiguration(
      localAPIKey: "account-read-only",
      maximumUpstreamResponseBytes: 1_048_576,
      editorVersion: editorVersion,
      editorPluginVersion: editorPluginVersion,
      userAgent: userAgent
    )
    let client = CopilotClient(
      configuration: configuration,
      tokens: tokenManager,
      session: session
    )
    modelsLoader = {
      let response = try await client.data(
        path: "models",
        method: "GET",
        timeoutInterval: 30)
      guard (200..<300).contains(response.status) else {
        throw BridgeError.upstream(status: response.status, message: "读取模型目录失败。")
      }
      return try Self.parseModels(response.data)
    }
    quotaLoader = { forceRefresh in
      var accessToken = try await tokenManager.accessToken(forceRefresh: forceRefresh)
      let snapshotAge = accessToken.refreshedAt.map { Date().timeIntervalSince($0) }
      if let quota = accessToken.quotaSnapshot,
        let snapshotAge,
        (0..<60).contains(snapshotAge),
        !quota.entries.isEmpty
      {
        return quota
      }
      if accessToken.refreshedAt == nil || (snapshotAge ?? 60) >= 60 {
        accessToken = try await tokenManager.accessToken(forceRefresh: true)
        if let quota = accessToken.quotaSnapshot, !quota.entries.isEmpty {
          return quota
        }
      }
      let oauthToken = try KeychainStore.read(account: KeychainStore.githubOAuthAccount)
      guard let oauthToken, !oauthToken.isEmpty else {
        throw BridgeError.missingGitHubToken
      }
      return try await Self.loadQuota(
        oauthToken: oauthToken,
        session: session,
        userAgent: userAgent,
        editorVersion: editorVersion,
        editorPluginVersion: editorPluginVersion
      )
    }
  }

  init(
    modelsLoader: @escaping @Sendable () async throws -> [CopilotAvailableModel],
    quotaLoader: @escaping @Sendable () async throws -> CopilotQuotaSnapshot
  ) {
    self.modelsLoader = modelsLoader
    self.quotaLoader = { _ in try await quotaLoader() }
  }

  public func fetchModels() async throws -> [CopilotAvailableModel] {
    try await modelsLoader()
  }

  public func fetchQuota(forceRefresh: Bool = false) async throws -> CopilotQuotaSnapshot {
    try await quotaLoader(forceRefresh)
  }

  static func parseModels(_ data: Data) throws -> [CopilotAvailableModel] {
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawModels = root["data"] as? [Any]
    else {
      throw BridgeError.protocolFailure("Copilot 模型目录格式无效。")
    }

    var seen = Set<String>()
    var sawModelID = false
    var models: [CopilotAvailableModel] = []
    for rawModel in rawModels {
      guard let model = rawModel as? [String: Any],
        let id = nonemptyString(model["id"])
      else { continue }
      sawModelID = true

      let capabilityContainer = dictionary(model["capabilities"])
      let supports = dictionary(capabilityContainer?["supports"])
      let limits = dictionary(capabilityContainer?["limits"])
      let billing = dictionary(model["billing"])
      let pickerEnabled = boolean(
        firstValue(
          in: model,
          keys: ["model_picker_enabled", "modelPickerEnabled", "picker_enabled"]))
      let modelType =
        nonemptyString(capabilityContainer?["type"])
        ?? nonemptyString(model["type"])
      let policyState = nonemptyString(dictionary(model["policy"])?["state"])
      let supportedEndpoints = stringArray(
        firstValue(
          in: model,
          keys: ["supported_endpoints", "supportedEndpoints"])
          ?? firstValue(
            in: capabilityContainer,
            keys: ["supported_endpoints", "supportedEndpoints"]))
      let hasChatEndpoint = supportedEndpoints.contains { endpoint in
        let endpoint = endpoint.lowercased().trimmingCharacters(
          in: CharacterSet(charactersIn: "/"))
        return endpoint == "chat/completions"
          || endpoint == "v1/chat/completions"
          || endpoint == "responses"
          || endpoint == "v1/responses"
          || endpoint == "messages"
          || endpoint == "v1/messages"
      }
      let blockedPolicyStates = ["disabled", "blocked", "denied", "unavailable"]
      guard pickerEnabled != false,
        !blockedPolicyStates.contains(policyState?.lowercased() ?? ""),
        modelType?.lowercased() == "chat" || hasChatEndpoint,
        seen.insert(id).inserted
      else { continue }
      var capabilities = Set<CopilotModelCapability>()
      if supportIsEnabled(supports, keys: ["vision", "image_input", "imageInput"]) {
        capabilities.insert(.vision)
      }
      if supportIsEnabled(
        supports,
        keys: ["tools", "tool_calls", "toolCalls", "function_calling", "functionCalling"])
      {
        capabilities.insert(.tools)
      }
      if supportIsEnabled(
        supports,
        keys: ["reasoning", "reasoning_effort", "reasoningEffort"])
      {
        capabilities.insert(.reasoning)
      }

      let vendor =
        nonemptyString(model["vendor"])
        ?? nonemptyString(dictionary(model["vendor"])?["name"])
      let maximumPromptTokens = integer(
        firstValue(
          in: limits,
          keys: [
            "max_prompt_tokens", "maxPromptTokens", "max_input_tokens", "maxInputTokens",
            "max_context_window_tokens", "maxContextWindowTokens",
          ]))
      let maximumOutputTokens = integer(
        firstValue(
          in: limits,
          keys: ["max_output_tokens", "maxOutputTokens", "maximum_output_tokens"])
          ?? firstValue(
            in: model,
            keys: ["max_output_tokens", "maxOutputTokens", "maximum_output_tokens"]))
      let multiplier = number(
        firstValue(
          in: billing,
          keys: ["multiplier", "premium_multiplier", "premiumMultiplier", "credit_multiplier"])
          ?? firstValue(
            in: model,
            keys: ["billing_multiplier", "billingMultiplier", "premium_multiplier"]))
      let isPremium = boolean(
        firstValue(in: billing, keys: ["is_premium", "isPremium", "premium"])
          ?? firstValue(in: model, keys: ["is_premium", "isPremium"]))

      models.append(
        CopilotAvailableModel(
          id: id,
          displayName: nonemptyString(model["name"])
            ?? nonemptyString(model["display_name"])
            ?? id,
          vendor: vendor,
          type: modelType,
          capabilities: capabilities,
          supportedEndpoints: supportedEndpoints,
          maximumPromptTokens: maximumPromptTokens,
          maximumOutputTokens: maximumOutputTokens,
          billingMultiplier: multiplier,
          isPremium: isPremium,
          isPreview: boolean(
            firstValue(in: model, keys: ["preview", "is_preview", "isPreview"])),
          isPickerEnabled: pickerEnabled
        ))
    }

    if !rawModels.isEmpty, !sawModelID {
      throw BridgeError.protocolFailure("Copilot 模型目录没有有效的模型 ID。")
    }
    return models.sorted {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
  }

  static func parseQuota(_ data: Data) throws -> CopilotQuotaSnapshot {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BridgeError.protocolFailure("GitHub Copilot 额度响应格式无效。")
    }

    var entries: [CopilotQuotaEntry] = []
    let accountTokenBased = boolean(
      firstValue(in: root, keys: ["token_based_billing", "tokenBasedBilling"]))
    if let snapshots = dictionary(
      firstValue(in: root, keys: ["quota_snapshots", "quotaSnapshots", "quotas", "quota"]))
    {
      entries = snapshots.keys.compactMap { key in
        guard let snapshot = dictionary(snapshots[key]) else { return nil }
        return parseQuotaEntry(
          id: key,
          snapshot: snapshot,
          accountTokenBased: accountTokenBased)
      }
    }

    if entries.isEmpty,
      let remainingBuckets = dictionary(
        firstValue(in: root, keys: ["limited_user_quotas", "limitedUserQuotas"]))
    {
      let monthlyBuckets =
        dictionary(
          firstValue(in: root, keys: ["monthly_quotas", "monthlyQuotas"])) ?? [:]
      let keys = Set(remainingBuckets.keys).union(monthlyBuckets.keys)
      entries = keys.compactMap { key in
        let remaining = quotaScalar(remainingBuckets[key])
        let entitlement = quotaScalar(monthlyBuckets[key])
        guard remaining != nil || entitlement != nil else { return nil }
        let used = entitlement.flatMap { total in remaining.map { total - $0 } }
        let percent = percentage(remaining: remaining, entitlement: entitlement, explicit: nil)
        return CopilotQuotaEntry(
          id: key,
          unit: .requests,
          entitlement: entitlement,
          used: used,
          remaining: remaining,
          percentRemaining: percent
        )
      }
    }

    entries.sort { quotaSortKey($0.id) < quotaSortKey($1.id) }
    return CopilotQuotaSnapshot(
      accountName: nonemptyString(firstValue(in: root, keys: ["login", "username"])),
      planName: nonemptyString(
        firstValue(in: root, keys: ["copilot_plan", "copilotPlan", "plan"])),
      sku: nonemptyString(firstValue(in: root, keys: ["access_type_sku", "accessTypeSku", "sku"])),
      resetAt: date(
        firstValue(
          in: root,
          keys: [
            "quota_reset_date_utc", "quotaResetDateUtc", "quota_reset_date",
            "quotaResetDate", "limited_user_reset_date", "limitedUserResetDate", "reset_date",
            "resetDate",
          ])),
      entries: entries
    )
  }

  static func makeQuotaRequest(
    oauthToken: String,
    userAgent: String,
    editorVersion: String,
    editorPluginVersion: String
  ) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("token \(oauthToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2025-04-01", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(editorVersion, forHTTPHeaderField: "Editor-Version")
    request.setValue(editorPluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
    return request
  }

  private static func loadQuota(
    oauthToken: String,
    session: URLSession,
    userAgent: String,
    editorVersion: String,
    editorPluginVersion: String
  ) async throws -> CopilotQuotaSnapshot {
    let request = makeQuotaRequest(
      oauthToken: oauthToken,
      userAgent: userAgent,
      editorVersion: editorVersion,
      editorPluginVersion: editorPluginVersion
    )
    let (bytes, response) = try await session.bytes(
      for: request, delegate: RejectRedirectsDelegate.shared)
    guard let http = response as? HTTPURLResponse else {
      throw BridgeError.protocolFailure("GitHub 没有返回 HTTP 响应。")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw BridgeError.upstream(status: http.statusCode, message: "GitHub 未返回 Copilot 额度。")
    }
    let data = try await CopilotClient.collect(bytes, response: http, limit: 1_048_576)
    return try parseQuota(data)
  }

  private static func parseQuotaEntry(
    id: String,
    snapshot: [String: Any],
    accountTokenBased: Bool?
  ) -> CopilotQuotaEntry {
    let creditKeys = ["credits_used", "creditsUsed", "used_credits", "usedCredits"]
    let requestEntitlementKeys = ["entitlement_requests", "entitlementRequests"]
    let requestUsedKeys = ["used_requests", "usedRequests"]
    let normalizedID = normalizedQuotaID(id)
    let explicitlyCreditValued =
      firstValue(in: snapshot, keys: creditKeys) != nil
      || id.localizedCaseInsensitiveContains("credit")
      || normalizedID == "premium_models"
    let explicitlyRequestValued =
      firstValue(in: snapshot, keys: requestEntitlementKeys) != nil
      || firstValue(in: snapshot, keys: requestUsedKeys) != nil
    let tokenBased =
      boolean(
        firstValue(in: snapshot, keys: ["token_based_billing", "tokenBasedBilling"]))
      ?? accountTokenBased
    let isServiceRequestBucket = ["chat", "completions", "code_completions"]
      .contains(normalizedID)
    let unit: CopilotQuotaUnit
    if explicitlyRequestValued || isServiceRequestBucket {
      unit = .requests
    } else if explicitlyCreditValued || tokenBased == true {
      unit = .aiCredits
    } else if normalizedID == "premium_interactions" {
      unit = .requests
    } else {
      unit = .unspecified
    }

    let entitlement = number(
      firstValue(
        in: snapshot,
        keys: requestEntitlementKeys
          + ["entitlement", "monthly_quota", "monthlyQuota", "total", "limit"]))
    let remaining = number(
      firstValue(
        in: snapshot,
        keys: [
          "remaining", "quota_remaining", "quotaRemaining", "remaining_requests",
          "remainingRequests",
        ]))
    let explicitUsed = number(
      firstValue(
        in: snapshot,
        keys: creditKeys + requestUsedKeys + ["used", "consumed"]))
    let used =
      explicitUsed
      ?? entitlement.flatMap { total in
        guard total >= 0 else { return nil }
        return remaining.map { total - $0 }
      }
    let explicitPercent = number(
      firstValue(
        in: snapshot,
        keys: [
          "percent_remaining", "percentRemaining", "remaining_percentage", "remainingPercentage",
        ]))
    return CopilotQuotaEntry(
      id: id,
      unit: unit,
      entitlement: entitlement,
      used: used,
      remaining: remaining,
      percentRemaining: percentage(
        remaining: remaining,
        entitlement: entitlement,
        explicit: explicitPercent),
      unlimited: boolean(
        firstValue(
          in: snapshot,
          keys: ["unlimited", "isUnlimited", "isUnlimitedEntitlement"])) == true
        || entitlement == -1,
      hasQuota: boolean(firstValue(in: snapshot, keys: ["has_quota", "hasQuota"])),
      overagePermitted: boolean(
        firstValue(
          in: snapshot,
          keys: [
            "overage_permitted", "overagePermitted", "usageAllowedWithExhaustedQuota",
            "overageAllowedWithExhaustedQuota",
          ])),
      resetAt: date(
        firstValue(
          in: snapshot,
          keys: ["quota_reset_at", "quotaResetAt", "reset_at", "resetAt", "resetDate"]))
    )
  }

  private static func supportIsEnabled(_ supports: [String: Any]?, keys: [String]) -> Bool {
    guard let value = firstValue(in: supports, keys: keys) else { return false }
    if let enabled = boolean(value) { return enabled }
    if let values = value as? [Any] { return !values.isEmpty }
    if let value = nonemptyString(value) { return value.lowercased() != "false" }
    return false
  }

  private static func quotaScalar(_ value: Any?) -> Double? {
    if let nested = dictionary(value) {
      return number(
        firstValue(
          in: nested,
          keys: ["remaining", "quota_remaining", "quotaRemaining", "value", "total", "limit"]))
    }
    return number(value)
  }

  private static func percentage(
    remaining: Double?,
    entitlement: Double?,
    explicit: Double?
  ) -> Double? {
    if let remaining, let entitlement, entitlement > 0 {
      return min(100, max(0, remaining / entitlement * 100))
    }
    if let explicit, explicit.isFinite {
      return min(100, max(0, explicit))
    }
    return nil
  }

  private static func quotaSortKey(_ id: String) -> String {
    let normalized = normalizedQuotaID(id)
    let priority: Int
    switch normalized {
    case "ai_credits", "premium_models", "premium_interactions": priority = 0
    case "chat": priority = 1
    case "completions", "code_completions": priority = 2
    default: priority = 3
    }
    return "\(priority)-\(normalized)"
  }

  private static func normalizedQuotaID(_ id: String) -> String {
    id.lowercased().replacingOccurrences(of: "-", with: "_")
  }

  private static func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  private static func firstValue(in dictionary: [String: Any]?, keys: [String]) -> Any? {
    guard let dictionary else { return nil }
    for key in keys where dictionary[key] != nil {
      return dictionary[key]
    }
    return nil
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func stringArray(_ value: Any?) -> [String] {
    guard let values = value as? [Any] else { return [] }
    var seen = Set<String>()
    return values.compactMap { value in
      guard let value = nonemptyString(value), seen.insert(value).inserted else { return nil }
      return value
    }
  }

  private static func boolean(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? String {
      switch value.lowercased() {
      case "true", "yes", "1": return true
      case "false", "no", "0": return false
      default: return nil
      }
    }
    return nil
  }

  private static func number(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber else { return nil }
    if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
    let result = value.doubleValue
    return result.isFinite ? result : nil
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let value = number(value), value.rounded() == value,
      value >= Double(Int.min), value <= Double(Int.max)
    else { return nil }
    return Int(value)
  }

  private static func date(_ value: Any?) -> Date? {
    if let number = number(value) {
      let timestamp = number > 10_000_000_000 ? number / 1_000 : number
      return Date(timeIntervalSince1970: timestamp)
    }
    guard let value = nonemptyString(value) else { return nil }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let parsed = fractional.date(from: value) { return parsed }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    if let parsed = standard.date(from: value) { return parsed }

    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.calendar = Calendar(identifier: .gregorian)
    day.timeZone = TimeZone(secondsFromGMT: 0)
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: value)
  }
}
