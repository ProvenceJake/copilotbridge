import Foundation
import XCTest

@testable import CopilotBridgeApp
@testable import CopilotBridgeCore

@MainActor
final class BridgeAppModelLoginTests: XCTestCase {
  func testStopCannotClearBusyWhileDeviceLoginIsAuthorizing() async throws {
    let pollStarted = AsyncGate()
    let auth = StubGitHubDeviceAuth(
      requestCode: { Self.authorization },
      pollForToken: { _ in
        await pollStarted.open()
        try await Task.sleep(for: .seconds(60))
        return "unreachable"
      })
    let writes = LockedValues<String>()
    let model = makeModel(auth: auth, writes: writes)
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }

    model.beginGitHubLogin()
    await pollStarted.wait()
    XCTAssertTrue(model.isBusy)
    XCTAssertNotNil(model.deviceAuthorization)

    await model.stopServer()

    XCTAssertTrue(model.isBusy, "Stopping must not finish the login activity")
    XCTAssertNotNil(model.deviceAuthorization)
    XCTAssertTrue(writes.values.isEmpty)

    model.cancelGitHubLogin()
    try await waitUntil { !model.isBusy }
    XCTAssertNil(model.deviceAuthorization)
  }

  func testCommitRejectsCancelAndReloginAndQuitWaitsForPersistence() async throws {
    let writeStarted = AsyncGate()
    let releaseWrite = AsyncGate()
    let factoryCalls = LockedCounter()
    let writes = LockedValues<String>()
    let blockedMutationEffects = LockedValues<String>()
    let verificationCalls = LockedCounter()
    let auth = StubGitHubDeviceAuth(
      requestCode: { Self.authorization },
      pollForToken: { _ in "device-token" })
    let model = makeModel(
      authFactory: {
        factoryCalls.increment()
        return auth
      },
      writeGitHubToken: { token in
        writes.append(token)
        await writeStarted.open()
        await releaseWrite.wait()
      },
      deleteGitHubToken: { blockedMutationEffects.append("delete-github") },
      writeLocalAPIKey: { _ in blockedMutationEffects.append("write-local") },
      exchangeToken: { _ in
        verificationCalls.increment()
        return Self.copilotAccessToken
      })
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }

    model.beginGitHubLogin()
    await writeStarted.wait()
    XCTAssertTrue(model.isBusy)
    XCTAssertNil(model.deviceAuthorization)

    model.cancelGitHubLogin()
    model.beginGitHubLogin()
    await model.stopServer()
    await model.saveManualGitHubToken("manual-token")
    await model.signOut()
    await model.regenerateLocalAPIKey()

    XCTAssertTrue(model.isBusy)
    XCTAssertEqual(factoryCalls.value, 1, "A replacement login must not start during commit")
    XCTAssertEqual(writes.values, ["device-token"])
    XCTAssertTrue(
      blockedMutationEffects.values.isEmpty,
      "No other persistent credential mutation may overlap a device login")

    let shutdownFinished = LockedFlag()
    let shutdown = Task { @MainActor in
      await model.prepareForTermination()
      shutdownFinished.setTrue()
    }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(shutdownFinished.value, "Quit must wait for the non-cancellable commit")
    XCTAssertTrue(model.isBusy)

    await releaseWrite.open()
    await shutdown.value

    XCTAssertTrue(shutdownFinished.value)
    XCTAssertFalse(model.isBusy)
    XCTAssertTrue(model.isGitHubConnected)
    XCTAssertNil(model.copilotTokenExpiry)
    XCTAssertEqual(model.credentialStatus, "已保存 GitHub 凭据，尚未验证")
    XCTAssertEqual(
      verificationCalls.value, 0,
      "Quit requested during commit must defer post-commit network verification")
    XCTAssertEqual(writes.values, ["device-token"])
  }

  func testQuitCancelsAuthorizingLoginBeforeReturning() async throws {
    let pollStarted = AsyncGate()
    let releaseCancelledPoll = AsyncGate()
    let pollCancelled = LockedFlag()
    let writes = LockedValues<String>()
    let auth = StubGitHubDeviceAuth(
      requestCode: { Self.authorization },
      pollForToken: { _ in
        await pollStarted.open()
        do {
          try await Task.sleep(for: .seconds(60))
          return "unreachable"
        } catch is CancellationError {
          pollCancelled.setTrue()
          await releaseCancelledPoll.wait()
          throw CancellationError()
        }
      })
    let model = makeModel(auth: auth, writes: writes)
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }

    model.beginGitHubLogin()
    await pollStarted.wait()
    XCTAssertNotNil(model.deviceAuthorization)

    let shutdownFinished = LockedFlag()
    let shutdown = Task { @MainActor in
      await model.prepareForTermination()
      shutdownFinished.setTrue()
    }
    try await waitUntil { pollCancelled.value }

    XCTAssertTrue(model.isBusy, "Quit must own busy while cancellation winds down")
    XCTAssertFalse(shutdownFinished.value)
    await releaseCancelledPoll.open()
    await shutdown.value

    XCTAssertTrue(pollCancelled.value)
    XCTAssertTrue(shutdownFinished.value)
    XCTAssertTrue(writes.values.isEmpty)
    XCTAssertNil(model.deviceAuthorization)
    XCTAssertFalse(model.isBusy)
  }

  func testRequestCodeFailureReportsStageAndSecureProxyTLSGuidance() async throws {
    let writes = LockedValues<String>()
    let auth = StubGitHubDeviceAuth(
      requestCode: { throw URLError(.secureConnectionFailed) },
      pollForToken: { _ in "unreachable" })
    let model = makeModel(auth: auth, writes: writes)
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }

    model.beginGitHubLogin()
    try await waitUntil { !model.isBusy }

    XCTAssertEqual(model.credentialStatus, "获取 GitHub 登录码失败")
    XCTAssertTrue(model.errorMessage?.contains("系统代理/VPN") == true)
    XCTAssertTrue(model.errorMessage?.contains("不会跳过证书校验") == true)
    XCTAssertTrue(model.logs.contains { $0.contains("ERROR GitHub 登录码请求失败。") })
    XCTAssertFalse(model.logs.contains { $0.contains("GitHub 登录失败。") })
    XCTAssertTrue(writes.values.isEmpty)
  }

  func testPollFailureClearsAuthorizationAndReportsPollingStage() async throws {
    let releaseFailure = AsyncGate()
    let writes = LockedValues<String>()
    let auth = StubGitHubDeviceAuth(
      requestCode: { Self.authorization },
      pollForToken: { _ in
        await releaseFailure.wait()
        throw LoginTestError.pollFailed
      })
    let model = makeModel(auth: auth, writes: writes)
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }

    model.beginGitHubLogin()
    try await waitUntil { model.deviceAuthorization != nil }
    await releaseFailure.open()
    try await waitUntil { !model.isBusy }

    XCTAssertNil(model.deviceAuthorization)
    XCTAssertEqual(model.credentialStatus, "GitHub 授权失败")
    XCTAssertEqual(model.errorMessage, LoginTestError.pollFailed.localizedDescription)
    XCTAssertTrue(model.logs.contains { $0.contains("ERROR GitHub 设备授权失败。") })
    XCTAssertFalse(model.logs.contains { $0.contains("GitHub 登录失败。") })
    XCTAssertTrue(writes.values.isEmpty)
  }

  func testKeychainSaveFailureIsNotReportedAsLoginFailure() async throws {
    let writes = LockedValues<String>()
    let auth = StubGitHubDeviceAuth(
      requestCode: { Self.authorization },
      pollForToken: { _ in "device-token" })
    let model = makeModel(
      authFactory: { auth },
      writeGitHubToken: { token in
        writes.append(token)
        throw LoginTestError.keychainSaveFailed
      })
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }

    model.beginGitHubLogin()
    try await waitUntil { !model.isBusy }

    XCTAssertEqual(writes.values, ["device-token"])
    XCTAssertFalse(model.isGitHubConnected)
    XCTAssertEqual(model.credentialStatus, "GitHub 凭据保存失败")
    XCTAssertNotNil(model.errorMessage)
    XCTAssertTrue(model.logs.contains { $0.contains("ERROR GitHub 凭据保存失败。") })
    XCTAssertFalse(model.logs.contains { $0.contains("GitHub 登录失败。") })
  }

  func testVerificationFailureAfterCommitKeepsSavedCredentialConnected() async throws {
    let writes = LockedValues<String>()
    let auth = StubGitHubDeviceAuth(
      requestCode: { Self.authorization },
      pollForToken: { _ in "device-token" })
    let model = makeModel(
      authFactory: { auth },
      writeGitHubToken: { writes.append($0) },
      exchangeToken: { _ in throw LoginTestError.verificationFailed })
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }

    model.beginGitHubLogin()
    try await waitUntil { !model.isBusy }

    XCTAssertEqual(writes.values, ["device-token"])
    XCTAssertTrue(model.isGitHubConnected)
    XCTAssertNil(model.copilotTokenExpiry)
    XCTAssertEqual(model.credentialStatus, "Copilot 验证失败")
    XCTAssertNotNil(model.errorMessage)
    XCTAssertTrue(model.logs.contains { $0.contains("WARN  Copilot 权限验证失败。") })
    XCTAssertFalse(model.logs.contains { $0.contains("GitHub 登录失败。") })
  }

  func testPostCommitVerificationCanBeCancelledWithoutUndoingSavedCredential() async throws {
    let verificationStarted = AsyncGate()
    let verificationCancelled = LockedFlag()
    let writes = LockedValues<String>()
    let auth = StubGitHubDeviceAuth(
      requestCode: { Self.authorization },
      pollForToken: { _ in "device-token" })
    let model = makeModel(
      authFactory: { auth },
      writeGitHubToken: { writes.append($0) },
      exchangeToken: { _ in
        await verificationStarted.open()
        do {
          try await Task.sleep(for: .seconds(60))
          return Self.copilotAccessToken
        } catch is CancellationError {
          verificationCancelled.setTrue()
          throw CancellationError()
        }
      })
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }

    model.beginGitHubLogin()
    await verificationStarted.wait()
    XCTAssertTrue(model.isBusy)
    XCTAssertTrue(model.isGitHubConnected)
    XCTAssertEqual(model.credentialStatus, "GitHub 已授权，正在验证 Copilot…")

    model.cancelGitHubLogin()
    try await waitUntil { !model.isBusy }
    try await waitUntil { verificationCancelled.value }

    XCTAssertEqual(writes.values, ["device-token"])
    XCTAssertTrue(model.isGitHubConnected)
    XCTAssertNil(model.copilotTokenExpiry)
    XCTAssertEqual(model.credentialStatus, "已保存 GitHub 凭据")
    XCTAssertFalse(model.logs.contains { $0.contains("Copilot 权限验证失败。") })
  }

  func testCancelledOldPollCannotCommitOrClearReplacementLogin() async throws {
    let firstPollStarted = AsyncGate()
    let releaseFirstPoll = AsyncGate()
    let secondPollStarted = AsyncGate()
    let factoryCalls = LockedCounter()
    let writes = LockedValues<String>()
    let firstAuth = StubGitHubDeviceAuth(
      requestCode: { Self.authorization },
      pollForToken: { _ in
        await firstPollStarted.open()
        // Deliberately ignore cancellation to exercise the generation fence.
        await releaseFirstPoll.wait()
        return "stale-token"
      })
    let secondAuth = StubGitHubDeviceAuth(
      requestCode: { Self.authorization },
      pollForToken: { _ in
        await secondPollStarted.open()
        try await Task.sleep(for: .seconds(60))
        return "unreachable"
      })
    let model = makeModel(
      authFactory: {
        factoryCalls.increment()
        return factoryCalls.value == 1 ? firstAuth : secondAuth
      },
      writeGitHubToken: { writes.append($0) })
    try await waitUntil { model.isCredentialStoreReady && !model.isBusy }

    model.beginGitHubLogin()
    await firstPollStarted.wait()
    model.cancelGitHubLogin()
    model.beginGitHubLogin()
    await secondPollStarted.wait()
    XCTAssertTrue(model.isBusy)
    XCTAssertNotNil(model.deviceAuthorization)

    await releaseFirstPoll.open()
    try await Task.sleep(for: .milliseconds(30))

    XCTAssertTrue(model.isBusy)
    XCTAssertNotNil(model.deviceAuthorization)
    XCTAssertTrue(writes.values.isEmpty)

    model.cancelGitHubLogin()
    try await waitUntil { !model.isBusy }
  }

  nonisolated private static let authorization = DeviceAuthorization(
    deviceCode: "device-code",
    userCode: "ABCD-EFGH",
    verificationURL: URL(string: "https://github.com/login/device")!,
    expiresIn: 900,
    interval: 1)

  nonisolated private static var copilotAccessToken: CopilotAccessToken {
    CopilotAccessToken(
      value: "copilot-token",
      expiresAt: Date().addingTimeInterval(1_800),
      apiEndpoint: nil)
  }

  private func makeModel(
    auth: any GitHubDeviceAuthenticating,
    writes: LockedValues<String>
  ) -> BridgeAppModel {
    makeModel(authFactory: { auth }, writeGitHubToken: { writes.append($0) })
  }

  private func makeModel(
    authFactory: @escaping @Sendable () -> any GitHubDeviceAuthenticating,
    writeGitHubToken: @escaping @Sendable (String) async throws -> Void,
    deleteGitHubToken: @escaping @Sendable () async throws -> Void = {},
    writeLocalAPIKey: @escaping @Sendable (String) async throws -> Void = { _ in },
    exchangeToken:
      @escaping @Sendable (String) async throws -> CopilotAccessToken = { _ in
        BridgeAppModelLoginTests.copilotAccessToken
      }
  ) -> BridgeAppModel {
    let dependencies = BridgeAppDependencies(
      loadCredentials: {
        KeychainBootstrapResult(localAPIKey: "local-key", hasGitHubCredential: false)
      },
      makeGitHubDeviceAuth: authFactory,
      presentDeviceAuthorization: { _ in },
      writeGitHubToken: writeGitHubToken,
      deleteGitHubToken: deleteGitHubToken,
      writeLocalAPIKey: writeLocalAPIKey)
    let tokenManager = CopilotTokenManager(
      oauthTokenLoader: { "oauth-token" },
      exchangeToken: exchangeToken)
    return BridgeAppModel(
      dependencies: dependencies,
      tokenManager: tokenManager,
      accountDataSource: CopilotAccountDataSource(
        fetchModels: { [] },
        fetchQuota: { _ in CopilotQuotaSnapshot() }),
      initialPort: 41_421,
      initialAutoStart: false)
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else { throw LoginTestError.timedOut }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
  func testRepeatedTerminationRequestsPrepareAndReplyOnlyOnce() async {
    let preparationStarted = AsyncGate()
    let releasePreparation = AsyncGate()
    let replyReceived = AsyncGate()
    let preparationCount = LockedCounter()
    let replies = LockedValues<Bool>()
    let coordinator = ApplicationTerminationCoordinator()
    coordinator.bind {
      preparationCount.increment()
      await preparationStarted.open()
      await releasePreparation.wait()
    }

    XCTAssertEqual(
      coordinator.requestTermination(reply: {
        replies.append($0)
        Task { await replyReceived.open() }
      }), .terminateLater)
    XCTAssertEqual(
      coordinator.requestTermination(reply: { replies.append($0) }), .terminateLater)
    await preparationStarted.wait()
    XCTAssertEqual(preparationCount.value, 1)
    XCTAssertTrue(replies.values.isEmpty)

    await releasePreparation.open()
    await replyReceived.wait()

    XCTAssertTrue(coordinator.isPrepared)
    XCTAssertEqual(replies.values, [true])
    XCTAssertEqual(
      coordinator.requestTermination(reply: { replies.append($0) }), .terminateNow)
    XCTAssertEqual(replies.values, [true])
  }

  func testTerminationRequestedBeforeModelBindingStartsAfterBinding() async {
    let preparationFinished = AsyncGate()
    let replyReceived = AsyncGate()
    let replies = LockedValues<Bool>()
    let coordinator = ApplicationTerminationCoordinator()

    XCTAssertEqual(
      coordinator.requestTermination(reply: {
        replies.append($0)
        Task { await replyReceived.open() }
      }), .terminateLater)
    XCTAssertTrue(replies.values.isEmpty)

    coordinator.bind {
      await preparationFinished.open()
    }
    await preparationFinished.wait()
    await replyReceived.wait()

    XCTAssertTrue(coordinator.isPrepared)
    XCTAssertEqual(replies.values, [true])
  }
}

private struct StubGitHubDeviceAuth: GitHubDeviceAuthenticating {
  let requestCode: @Sendable () async throws -> DeviceAuthorization
  let pollForToken: @Sendable (DeviceAuthorization) async throws -> String

  func requestCode() async throws -> DeviceAuthorization {
    try await requestCode()
  }

  func pollForToken(_ authorization: DeviceAuthorization) async throws -> String {
    try await pollForToken(authorization)
  }
}

private actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let waiters = self.waiters
    self.waiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.withLock { storage }
  }

  func increment() {
    lock.withLock { storage += 1 }
  }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false

  var value: Bool {
    lock.withLock { storage }
  }

  func setTrue() {
    lock.withLock { storage = true }
  }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Value] = []

  var values: [Value] {
    lock.withLock { storage }
  }

  func append(_ value: Value) {
    lock.withLock { storage.append(value) }
  }
}

private enum LoginTestError: Error {
  case keychainSaveFailed
  case pollFailed
  case timedOut
  case verificationFailed
}
