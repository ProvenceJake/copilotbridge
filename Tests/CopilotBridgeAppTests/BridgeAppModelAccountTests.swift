import Foundation
import XCTest

@testable import CopilotBridgeApp
@testable import CopilotBridgeCore

@MainActor
final class BridgeAppModelAccountTests: XCTestCase {
  func testConnectedBootstrapLoadsModelsAndQuotaIndependentlyOfProxyServer() async throws {
    let expectedModel = CopilotAvailableModel(
      id: "gpt-current",
      displayName: "GPT Current",
      capabilities: [.reasoning],
      supportedEndpoints: ["/responses"])
    let expectedQuota = CopilotQuotaSnapshot(
      accountName: "octocat",
      planName: "copilot_pro",
      entries: [
        CopilotQuotaEntry(
          id: "premium_models",
          unit: .aiCredits,
          entitlement: 1_000,
          remaining: 750,
          percentRemaining: 75)
      ])
    let model = makeModel(
      accountDataSource: CopilotAccountDataSource(
        fetchModels: { [expectedModel] },
        fetchQuota: { _ in expectedQuota }))

    try await waitUntil {
      model.isCredentialStoreReady
        && !model.isRefreshingAccountOverview
        && model.accountOverviewUpdatedAt != nil
    }

    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.availableModels, [expectedModel])
    XCTAssertEqual(model.copilotQuota, expectedQuota)
    XCTAssertEqual(model.accountOverviewStatus, "已更新")
  }

  func testFailedModelRefreshKeepsLastGoodCatalogAndReportsPartialResult() async throws {
    let expectedModel = CopilotAvailableModel(id: "gpt-current", displayName: "GPT Current")
    let sequence = AccountModelSequence(first: [expectedModel])
    let model = makeModel(
      accountDataSource: CopilotAccountDataSource(
        fetchModels: { try await sequence.next() },
        fetchQuota: { _ in CopilotQuotaSnapshot(entries: []) }))
    try await waitUntil {
      model.accountOverviewUpdatedAt != nil && !model.isRefreshingAccountOverview
    }

    model.refreshModelsAndQuota()
    try await waitUntil {
      !model.isRefreshingAccountOverview && model.modelCatalogMessage != nil
    }

    XCTAssertEqual(model.availableModels, [expectedModel])
    XCTAssertEqual(model.accountOverviewStatus, "部分信息不可用")
    XCTAssertTrue(model.modelCatalogMessage?.contains("catalog unavailable") == true)
  }

  func testFailedQuotaRefreshKeepsTimestampedSnapshotAndShowsFailure() async throws {
    let expectedQuota = CopilotQuotaSnapshot(
      entries: [
        CopilotQuotaEntry(
          id: "premium_models",
          unit: .aiCredits,
          entitlement: 100,
          remaining: 75)
      ])
    let sequence = AccountQuotaSequence(first: expectedQuota)
    let model = makeModel(
      accountDataSource: CopilotAccountDataSource(
        fetchModels: { [] },
        fetchQuota: { _ in try await sequence.next() }))
    try await waitUntil { model.quotaUpdatedAt != nil && !model.isRefreshingAccountOverview }
    let originalTimestamp = try XCTUnwrap(model.quotaUpdatedAt)

    model.refreshModelsAndQuota()
    try await waitUntil { !model.isRefreshingAccountOverview && model.quotaMessage != nil }

    XCTAssertEqual(model.copilotQuota, expectedQuota)
    XCTAssertEqual(model.quotaUpdatedAt, originalTimestamp)
    XCTAssertEqual(model.accountOverviewStatus, "部分信息不可用")
    XCTAssertTrue(model.quotaMessage?.contains("quota unavailable") == true)
  }

  func testUserRefreshIsBlockedDuringGitHubCredentialActivity() async throws {
    let requestStarted = AccountAsyncGate()
    let fetchCounter = AccountFetchCounter()
    let model = makeModel(
      authFactory: { AccountBlockingAuth(requestStarted: requestStarted) },
      accountDataSource: CopilotAccountDataSource(
        fetchModels: { await fetchCounter.models() },
        fetchQuota: { _ in await fetchCounter.quota() }))
    try await waitUntil {
      model.accountOverviewUpdatedAt != nil && !model.isRefreshingAccountOverview
    }

    model.beginGitHubLogin()
    await requestStarted.wait()
    XCTAssertTrue(model.isBusy)
    model.refreshModelsAndQuota()
    try await Task.sleep(for: .milliseconds(20))

    let counts = await fetchCounter.counts
    XCTAssertEqual(counts.models, 1)
    XCTAssertEqual(counts.quotas, 1)
    model.cancelGitHubLogin()
    try await waitUntil { !model.isBusy }
  }

  func testTerminationDoesNotWaitForCancelledReadOnlyRefresh() async throws {
    let fetchStarted = AccountAsyncGate()
    let releaseFetch = AccountAsyncGate()
    let model = makeModel(
      accountDataSource: CopilotAccountDataSource(
        fetchModels: {
          await fetchStarted.open()
          await releaseFetch.wait()
          return []
        },
        fetchQuota: { _ in
          await releaseFetch.wait()
          return CopilotQuotaSnapshot()
        }))
    await fetchStarted.wait()
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }
    let didFinish = AccountLockedFlag()

    let termination = Task { @MainActor in
      await model.prepareForTermination()
      didFinish.setTrue()
    }
    try await Task.sleep(for: .milliseconds(30))
    let finishedBeforeRelease = didFinish.value
    await releaseFetch.open()
    await termination.value

    XCTAssertTrue(finishedBeforeRelease, "Read-only refresh must not hold app termination open")
  }

  func testSignOutCancelsRefreshAndFencesLateResults() async throws {
    let fetchStarted = AccountAsyncGate()
    let releaseFetch = AccountAsyncGate()
    let staleModel = CopilotAvailableModel(id: "stale", displayName: "Stale")
    let deleteCount = AccountLockedCounter()
    let model = makeModel(
      deleteGitHubToken: { deleteCount.increment() },
      accountDataSource: CopilotAccountDataSource(
        fetchModels: {
          await fetchStarted.open()
          await releaseFetch.wait()
          return [staleModel]
        },
        fetchQuota: { _ in
          await releaseFetch.wait()
          return CopilotQuotaSnapshot(accountName: "stale")
        }))

    await fetchStarted.wait()
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }
    await model.signOut()
    await releaseFetch.open()
    try await Task.sleep(for: .milliseconds(30))

    XCTAssertEqual(deleteCount.value, 1)
    XCTAssertFalse(model.isGitHubConnected)
    XCTAssertTrue(model.availableModels.isEmpty)
    XCTAssertNil(model.copilotQuota)
    XCTAssertNil(model.accountOverviewUpdatedAt)
    XCTAssertEqual(model.accountOverviewStatus, "登录 GitHub 后可读取")
  }

  private func makeModel(
    deleteGitHubToken: @escaping @Sendable () async throws -> Void = {},
    authFactory: @escaping @Sendable () -> any GitHubDeviceAuthenticating = {
      AccountStubAuth()
    },
    accountDataSource: CopilotAccountDataSource
  ) -> BridgeAppModel {
    let dependencies = BridgeAppDependencies(
      loadCredentials: {
        KeychainBootstrapResult(localAPIKey: "local-key", hasGitHubCredential: true)
      },
      makeGitHubDeviceAuth: authFactory,
      presentDeviceAuthorization: { _ in },
      writeGitHubToken: { _ in },
      deleteGitHubToken: deleteGitHubToken,
      writeLocalAPIKey: { _ in })
    let tokenManager = CopilotTokenManager(
      oauthTokenLoader: { "oauth-token" },
      exchangeToken: { _ in
        CopilotAccessToken(
          value: "short-token",
          expiresAt: Date().addingTimeInterval(1_800),
          apiEndpoint: nil)
      })
    return BridgeAppModel(
      dependencies: dependencies,
      tokenManager: tokenManager,
      accountDataSource: accountDataSource,
      initialPort: 41_422,
      initialAutoStart: false)
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else { throw AccountTestError.timedOut }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

private struct AccountStubAuth: GitHubDeviceAuthenticating {
  func requestCode() async throws -> DeviceAuthorization { throw AccountTestError.unused }
  func pollForToken(_ authorization: DeviceAuthorization) async throws -> String {
    throw AccountTestError.unused
  }
}

private actor AccountModelSequence {
  private var first: [CopilotAvailableModel]?

  init(first: [CopilotAvailableModel]) {
    self.first = first
  }

  func next() throws -> [CopilotAvailableModel] {
    if let first {
      self.first = nil
      return first
    }
    throw AccountTestError.catalogUnavailable
  }
}

private actor AccountQuotaSequence {
  private var first: CopilotQuotaSnapshot?

  init(first: CopilotQuotaSnapshot) {
    self.first = first
  }

  func next() throws -> CopilotQuotaSnapshot {
    if let first {
      self.first = nil
      return first
    }
    throw AccountTestError.quotaUnavailable
  }
}

private struct AccountBlockingAuth: GitHubDeviceAuthenticating {
  let requestStarted: AccountAsyncGate

  func requestCode() async throws -> DeviceAuthorization {
    await requestStarted.open()
    try await Task.sleep(for: .seconds(60))
    throw AccountTestError.unused
  }

  func pollForToken(_ authorization: DeviceAuthorization) async throws -> String {
    throw AccountTestError.unused
  }
}

private actor AccountFetchCounter {
  private var modelCalls = 0
  private var quotaCalls = 0

  var counts: (models: Int, quotas: Int) { (modelCalls, quotaCalls) }

  func models() -> [CopilotAvailableModel] {
    modelCalls += 1
    return []
  }

  func quota() -> CopilotQuotaSnapshot {
    quotaCalls += 1
    return CopilotQuotaSnapshot()
  }
}

private actor AccountAsyncGate {
  private var isOpen = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuations.append($0) }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let pending = continuations
    continuations.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

private final class AccountLockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int { lock.withLock { storage } }

  func increment() {
    lock.withLock { storage += 1 }
  }
}

private final class AccountLockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false

  var value: Bool { lock.withLock { storage } }

  func setTrue() {
    lock.withLock { storage = true }
  }
}

private enum AccountTestError: LocalizedError {
  case catalogUnavailable
  case quotaUnavailable
  case timedOut
  case unused

  var errorDescription: String? {
    switch self {
    case .catalogUnavailable: "catalog unavailable"
    case .quotaUnavailable: "quota unavailable"
    case .timedOut: "timed out"
    case .unused: "unused"
    }
  }
}
