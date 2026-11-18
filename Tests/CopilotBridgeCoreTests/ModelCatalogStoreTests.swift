import Foundation
import XCTest

@testable import CopilotBridgeCore

final class ModelCatalogStoreTests: XCTestCase {
  func testCachedEndpointLookupWithLargeMetadata() async throws {
    let response = try catalogResponse(
      models: (0..<18).map { index in
        [
          "id": "model-\(index)", "supported_endpoints": ["/responses"],
          "description": String(repeating: "metadata", count: 256),
        ]
      })
    let loader = CatalogResponseSequence([response])
    let store = ModelCatalogStore { try await loader.next() }
    _ = try await store.response()
    let started = ContinuousClock.now
    for _ in 0..<1_000 {
      let endpoints = try await store.supportedEndpoints(for: "model-17")
      XCTAssertEqual(endpoints, [.responses])
    }
    print("Catalog benchmark: 1000 cached endpoint lookups in \(started.duration(to: .now))")
    let count = await loader.loadCount
    XCTAssertEqual(count, 1)
  }

  func testSuccessfulResponseIsCachedUntilTTLExpires() async throws {
    let first = try catalogResponse(ids: ["gpt-first"])
    let refreshed = try catalogResponse(ids: ["gpt-refreshed"])
    let loader = CatalogResponseSequence([first, refreshed])
    let clock = TestDateSource(Date(timeIntervalSince1970: 1_000))
    let store = ModelCatalogStore(
      timeToLive: 300,
      now: { clock.now() },
      loader: { try await loader.next() })

    let initial = try await store.response()
    clock.advance(by: 299)
    let cached = try await store.response()

    XCTAssertEqual(initial.data, first.data)
    XCTAssertEqual(cached.data, first.data)
    var loadCount = await loader.loadCount
    XCTAssertEqual(loadCount, 1)

    clock.advance(by: 1)
    let afterExpiration = try await store.response()

    XCTAssertEqual(afterExpiration.data, refreshed.data)
    loadCount = await loader.loadCount
    XCTAssertEqual(loadCount, 2)
  }

  func testParsedEndpointsExpireWithRawCatalogAndPreserveFirstDuplicate() async throws {
    let first = try catalogResponse(models: [
      ["id": "duplicate"], ["id": "duplicate", "supported_endpoints": ["/responses"]],
      ["id": "switching", "supported_endpoints": ["/chat/completions"]],
    ])
    let second = try catalogResponse(models: [
      ["id": "switching", "supported_endpoints": ["/responses"]],
      ["id": "unknown-endpoint", "supported_endpoints": ["ws:/responses"]],
    ])
    let loader = CatalogResponseSequence([first, second])
    let clock = TestDateSource(Date(timeIntervalSince1970: 1_000))
    let store = ModelCatalogStore(
      timeToLive: 1, now: { clock.now() }, loader: { try await loader.next() })
    let duplicate = try await store.supportedEndpoints(for: "duplicate")
    let before = try await store.supportedEndpoints(for: "switching")
    XCTAssertNil(duplicate)
    XCTAssertEqual(before, [.chatCompletions])
    clock.advance(by: 1)
    let after = try await store.supportedEndpoints(for: "switching")
    let unsupported = try await store.supportedEndpoints(for: "unknown-endpoint")
    let ids = try await store.modelIDs()
    XCTAssertEqual(after, [.responses])
    XCTAssertEqual(unsupported, [])
    XCTAssertEqual(ids, ["switching", "unknown-endpoint"])
  }

  func testConcurrentCacheMissesShareOneLoad() async throws {
    let response = try catalogResponse(ids: ["gpt-shared"])
    let probe = AsyncOperationProbe<CopilotDataResponse>()
    let store = ModelCatalogStore {
      try await probe.run()
    }
    let waiters = (0..<16).map { _ in
      Task { try await store.response() }
    }

    try await waitUntil {
      let starts = await probe.startCount
      let waiterCount = await store.activeFetchWaiterCount()
      return starts == 1 && waiterCount == waiters.count
    }
    await probe.succeed(with: response)

    for waiter in waiters {
      let result = try await waiter.value
      XCTAssertEqual(result.data, response.data)
    }
    let startCount = await probe.startCount
    XCTAssertEqual(startCount, 1)
  }

  func testNonSuccessfulResponseIsNotCached() async throws {
    let unavailable = CopilotDataResponse(
      status: 503,
      headers: [:],
      data: Data(#"{"error":{"message":"unavailable"}}"#.utf8)
    )
    let loader = CatalogResponseSequence([unavailable, unavailable])
    let store = ModelCatalogStore {
      try await loader.next()
    }

    let first = try await store.response()
    let second = try await store.response()

    XCTAssertEqual(first.status, 503)
    XCTAssertEqual(second.status, 503)
    let loadCount = await loader.loadCount
    XCTAssertEqual(loadCount, 2)
  }

  func testInvalidSuccessfulJSONThrowsAndIsNotCached() async throws {
    let malformed = CopilotDataResponse(
      status: 200,
      headers: [:],
      data: Data("not-json".utf8)
    )
    let valid = try catalogResponse(ids: ["gpt-valid"])
    let loader = CatalogResponseSequence([malformed, valid])
    let store = ModelCatalogStore {
      try await loader.next()
    }

    do {
      _ = try await store.response()
      XCTFail("A malformed successful catalog must be rejected")
    } catch let error as BridgeError {
      XCTAssertEqual(error, .protocolFailure("无法读取 Copilot 模型列表。"))
    }

    let recovered = try await store.response()
    XCTAssertEqual(recovered.data, valid.data)
    _ = try await store.response()
    let loadCount = await loader.loadCount
    XCTAssertEqual(loadCount, 2)
  }

  func testInvalidModelIDThrowsAndIsNotCached() async throws {
    let invalid = try catalogResponse(ids: [" gpt-invalid "])
    let valid = try catalogResponse(ids: ["gpt-valid"])
    let loader = CatalogResponseSequence([invalid, valid])
    let store = ModelCatalogStore {
      try await loader.next()
    }

    do {
      _ = try await store.modelIDs()
      XCTFail("A non-canonical model ID must be rejected")
    } catch let error as BridgeError {
      XCTAssertEqual(error, .protocolFailure("Copilot 模型列表包含无效 id。"))
    }

    let ids = try await store.modelIDs()
    XCTAssertEqual(ids, ["gpt-valid"])
    let loadCount = await loader.loadCount
    XCTAssertEqual(loadCount, 2)
  }

  func testModelIDsAreDeduplicatedAndShareTheResponseCache() async throws {
    let response = try catalogResponse(ids: ["gpt-5.4", "claude-sonnet-4.6", "gpt-5.4"])
    let loader = CatalogResponseSequence([response])
    let store = ModelCatalogStore {
      try await loader.next()
    }

    let ids = try await store.modelIDs()
    _ = try await store.response()

    XCTAssertEqual(ids, ["gpt-5.4", "claude-sonnet-4.6"])
    let loadCount = await loader.loadCount
    XCTAssertEqual(loadCount, 1)
  }

  func testSupportedEndpointsNormalizeTopLevelAndCapabilityMetadata() async throws {
    let response = try catalogResponse(models: [
      [
        "id": "gpt-responses",
        "supported_endpoints": ["/responses", "ws:/responses", "/v1/responses/"],
      ],
      [
        "id": "claude-native",
        "capabilities": ["supportedEndpoints": ["v1/messages", "/chat/completions"]],
      ],
      ["id": "legacy-without-metadata"],
    ])
    let store = ModelCatalogStore { response }

    let responses = try await store.supportedEndpoints(for: "gpt-responses")
    let native = try await store.supportedEndpoints(for: "claude-native")
    let legacy = try await store.supportedEndpoints(for: "legacy-without-metadata")
    let unknown = try await store.supportedEndpoints(for: "missing")

    XCTAssertEqual(responses, [.responses])
    XCTAssertEqual(native, [.messages, .chatCompletions])
    XCTAssertNil(legacy)
    XCTAssertNil(unknown)
  }

  func testMalformedSupportedEndpointsAreRejectedWithoutPoisoningCatalogCache() async throws {
    let response = try catalogResponse(models: [
      ["id": "gpt-invalid", "supported_endpoints": "/responses"]
    ])
    let loader = CatalogResponseSequence([response])
    let store = ModelCatalogStore { try await loader.next() }

    do {
      _ = try await store.supportedEndpoints(for: "gpt-invalid")
      XCTFail("Non-array endpoint metadata must be rejected")
    } catch let error as BridgeError {
      XCTAssertEqual(error, .protocolFailure("Copilot 模型端点目录格式无效。"))
    }

    let modelIDs = try await store.modelIDs()
    XCTAssertEqual(modelIDs, ["gpt-invalid"])
    let loadCount = await loader.loadCount
    XCTAssertEqual(loadCount, 1)
  }

  func testCancellingOneWaiterDoesNotCancelSharedLoad() async throws {
    let response = try catalogResponse(ids: ["gpt-after-cancellation"])
    let probe = AsyncOperationProbe<CopilotDataResponse>()
    let store = ModelCatalogStore {
      try await probe.run()
    }
    let cancelledWaiter = Task { try await store.response() }
    let remainingWaiter = Task { try await store.response() }

    try await waitUntil {
      let starts = await probe.startCount
      let waiterCount = await store.activeFetchWaiterCount()
      return starts == 1 && waiterCount == 2
    }
    cancelledWaiter.cancel()

    do {
      _ = try await cancelledWaiter.value
      XCTFail("The cancelled waiter must finish with cancellation")
    } catch is CancellationError {
      // Expected.
    }
    let cancellationCount = await probe.cancellationCount
    XCTAssertEqual(cancellationCount, 0)

    await probe.succeed(with: response)
    let result = try await remainingWaiter.value
    XCTAssertEqual(result.data, response.data)
    _ = try await store.response()
    let startCount = await probe.startCount
    XCTAssertEqual(startCount, 1)
  }
}

private actor CatalogResponseSequence {
  private var responses: [CopilotDataResponse]
  private(set) var loadCount = 0

  init(_ responses: [CopilotDataResponse]) {
    self.responses = responses
  }

  func next() throws -> CopilotDataResponse {
    guard !responses.isEmpty else { throw CatalogTestError.noResponse }
    loadCount += 1
    return responses.removeFirst()
  }
}

private final class TestDateSource: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    value = value.addingTimeInterval(interval)
    lock.unlock()
  }
}

private enum CatalogTestError: Error {
  case noResponse
}

private func catalogResponse(ids: [String]) throws -> CopilotDataResponse {
  try catalogResponse(models: ids.map { ["id": $0] })
}

private func catalogResponse(models: [[String: Any]]) throws -> CopilotDataResponse {
  let data = try JSONSerialization.data(
    withJSONObject: [
      "object": "list",
      "data": models,
    ])
  return CopilotDataResponse(status: 200, headers: [:], data: data)
}
