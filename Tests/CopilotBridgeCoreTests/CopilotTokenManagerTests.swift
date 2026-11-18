import Foundation
import XCTest

@testable import CopilotBridgeCore

final class CopilotTokenManagerTests: XCTestCase {
  func testCancellingOneTokenWaiterDoesNotCancelSharedRefresh() async throws {
    let expected = CopilotAccessToken(
      value: "access-token",
      expiresAt: Date().addingTimeInterval(1_800),
      apiEndpoint: nil
    )
    let probe = AsyncOperationProbe<CopilotAccessToken>()
    let manager = CopilotTokenManager(
      oauthTokenLoader: { "oauth-token" },
      exchangeToken: { _ in try await probe.run() }
    )
    let waiterA = Task { try await manager.accessToken(forceRefresh: true) }
    let waiterB = Task { try await manager.accessToken(forceRefresh: true) }

    try await waitUntil {
      let starts = await probe.startCount
      let waiters = await manager.activeRefreshWaiterCount()
      return starts == 1 && waiters == 2
    }
    waiterA.cancel()

    do {
      _ = try await waiterA.value
      XCTFail("A cancelled waiter must finish with cancellation")
    } catch is CancellationError {
      // Expected.
    }
    let cancellationCount = await probe.cancellationCount
    XCTAssertEqual(cancellationCount, 0)

    await probe.succeed(with: expected)
    let result = try await waiterB.value
    XCTAssertEqual(result, expected)
    let startCount = await probe.startCount
    XCTAssertEqual(startCount, 1)
  }

  func testCancellingEveryTokenWaiterCancelsSharedRefresh() async throws {
    let probe = AsyncOperationProbe<CopilotAccessToken>()
    let manager = CopilotTokenManager(
      oauthTokenLoader: { "oauth-token" },
      exchangeToken: { _ in try await probe.run() }
    )
    let waiterA = Task { try await manager.accessToken(forceRefresh: true) }
    let waiterB = Task { try await manager.accessToken(forceRefresh: true) }

    try await waitUntil {
      let starts = await probe.startCount
      let waiters = await manager.activeRefreshWaiterCount()
      return starts == 1 && waiters == 2
    }
    waiterA.cancel()
    waiterB.cancel()

    for waiter in [waiterA, waiterB] {
      do {
        _ = try await waiter.value
        XCTFail("Every cancelled waiter must finish with cancellation")
      } catch is CancellationError {
        // Expected.
      }
    }
    try await waitUntil { await probe.cancellationCount == 1 }
    let startCount = await probe.startCount
    XCTAssertEqual(startCount, 1)
  }

  func testInvalidateCancelsOldRefreshWithoutCancellingReplacement() async throws {
    let expected = CopilotAccessToken(
      value: "replacement-token",
      expiresAt: Date().addingTimeInterval(1_800),
      apiEndpoint: nil
    )
    let probe = AsyncOperationProbe<CopilotAccessToken>()
    let manager = CopilotTokenManager(
      oauthTokenLoader: { "oauth-token" },
      exchangeToken: { _ in try await probe.run() }
    )
    let invalidatedWaiter = Task { try await manager.accessToken(forceRefresh: true) }

    try await waitUntil { await manager.activeRefreshWaiterCount() == 1 }
    await manager.invalidate()
    do {
      _ = try await invalidatedWaiter.value
      XCTFail("Invalidating a refresh must cancel its waiters")
    } catch is CancellationError {
      // Expected.
    }
    try await waitUntil { await probe.cancellationCount == 1 }

    let replacementWaiter = Task { try await manager.accessToken(forceRefresh: true) }
    try await waitUntil {
      let starts = await probe.startCount
      let waiters = await manager.activeRefreshWaiterCount()
      return starts == 2 && waiters == 1
    }
    await probe.succeed(with: expected)

    let result = try await replacementWaiter.value
    XCTAssertEqual(result, expected)
    let cancellationCount = await probe.cancellationCount
    XCTAssertEqual(cancellationCount, 1)
  }
}
