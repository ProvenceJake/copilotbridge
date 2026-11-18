import XCTest

@testable import CopilotBridgeCore

final class ModelResolverTests: XCTestCase {
  func testCancellingOneModelWaiterDoesNotCancelSharedFetch() async throws {
    let probe = AsyncOperationProbe<Set<String>>()
    let resolver = ModelResolver(aliases: [:]) {
      try await probe.run()
    }
    let requested = "claude-sonnet-4-6-20260301"
    let waiterA = Task { await resolver.resolve(requested) }
    let waiterB = Task { await resolver.resolve(requested) }

    try await waitUntil {
      let starts = await probe.startCount
      let waiters = await resolver.activeFetchWaiterCount()
      return starts == 1 && waiters == 2
    }
    waiterA.cancel()

    let cancelledResult = await waiterA.value
    XCTAssertEqual(cancelledResult, requested)
    let cancellationCount = await probe.cancellationCount
    XCTAssertEqual(cancellationCount, 0)

    await probe.succeed(with: ["claude-sonnet-4.6"])
    let successfulResult = await waiterB.value
    XCTAssertEqual(successfulResult, "claude-sonnet-4.6")
    let startCount = await probe.startCount
    XCTAssertEqual(startCount, 1)
  }

  func testCancellingEveryModelWaiterCancelsSharedFetch() async throws {
    let probe = AsyncOperationProbe<Set<String>>()
    let resolver = ModelResolver(aliases: [:]) {
      try await probe.run()
    }
    let requestedA = "claude-sonnet-4-6-20260301"
    let requestedB = "claude-opus-4-6-20260301"
    let waiterA = Task { await resolver.resolve(requestedA) }
    let waiterB = Task { await resolver.resolve(requestedB) }

    try await waitUntil {
      let starts = await probe.startCount
      let waiters = await resolver.activeFetchWaiterCount()
      return starts == 1 && waiters == 2
    }
    waiterA.cancel()
    waiterB.cancel()

    let resultA = await waiterA.value
    let resultB = await waiterB.value
    XCTAssertEqual(resultA, requestedA)
    XCTAssertEqual(resultB, requestedB)
    try await waitUntil { await probe.cancellationCount == 1 }

    let startCount = await probe.startCount
    XCTAssertEqual(startCount, 1)
  }

  func testInvalidatedSharedOperationRejectsLateWaiter() async throws {
    let probe = AsyncOperationProbe<Int>()
    let operation = SharedOperation<Int>()
    await operation.invalidate()

    do {
      _ = try await operation.value { try await probe.run() }
      XCTFail("An invalidated shared operation must reject late waiters")
    } catch is CancellationError {
      // Expected.
    }

    let startCount = await probe.startCount
    XCTAssertEqual(startCount, 0)
  }

  func testAnthropicDateAndVersionCandidates() {
    let candidates = ModelResolver.candidates(for: "claude-sonnet-4-6-20260301")
    XCTAssertEqual(candidates.first, "claude-sonnet-4-6-20260301")
    XCTAssertTrue(candidates.contains("claude-sonnet-4.6"))
  }

  func testOneMillionCandidatesPreferOneMillion() {
    let candidates = ModelResolver.candidates(for: "claude-opus-4-6[1m]")
    XCTAssertTrue(candidates.contains("claude-opus-4.6-1m-internal"))
    XCTAssertTrue(candidates.contains("claude-opus-4.6-1m"))
    XCTAssertTrue(candidates.contains("claude-opus-4.6"))
  }

  func testExactModelIsFirst() {
    XCTAssertEqual(ModelResolver.candidates(for: "gpt-5.4"), ["gpt-5.4"])
  }

  func testExactModelSkipsCatalogFetchWhenThereAreNoAlternateCandidates() async {
    let catalog = ImmediateModelCatalog(ids: ["gpt-5.4"])
    let resolver = ModelResolver(aliases: [:]) {
      await catalog.fetch()
    }

    let resolved = await resolver.resolve("gpt-5.4")

    XCTAssertEqual(resolved, "gpt-5.4")
    let fetchCount = await catalog.fetchCount
    XCTAssertEqual(fetchCount, 0)
  }
}

private actor ImmediateModelCatalog {
  private let ids: Set<String>
  private(set) var fetchCount = 0

  init(ids: Set<String>) {
    self.ids = ids
  }

  func fetch() -> Set<String> {
    fetchCount += 1
    return ids
  }
}
