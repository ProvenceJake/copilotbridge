import CopilotBridgeCore

struct CopilotAccountDataSource: Sendable {
  let fetchModels: @Sendable () async throws -> [CopilotAvailableModel]
  let fetchQuota: @Sendable (Bool) async throws -> CopilotQuotaSnapshot

  static func live(tokenManager: CopilotTokenManager) -> Self {
    let service = CopilotAccountService(tokenManager: tokenManager)
    return Self(
      fetchModels: { try await service.fetchModels() },
      fetchQuota: { forceRefresh in
        try await service.fetchQuota(forceRefresh: forceRefresh)
      }
    )
  }
}
