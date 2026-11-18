import Foundation

actor AsyncOperationProbe<Value: Sendable> {
  private var continuations: [UUID: CheckedContinuation<Value, any Error>] = [:]
  private(set) var startCount = 0
  private(set) var cancellationCount = 0

  func run() async throws -> Value {
    let operationID = UUID()
    startCount += 1

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        continuations[operationID] = continuation
      }
    } onCancel: {
      Task { await self.cancel(operationID: operationID) }
    }
  }

  func succeed(with value: Value) {
    let continuations = Array(self.continuations.values)
    self.continuations.removeAll()
    for continuation in continuations {
      continuation.resume(returning: value)
    }
  }

  private func cancel(operationID: UUID) {
    guard let continuation = continuations.removeValue(forKey: operationID) else { return }
    cancellationCount += 1
    continuation.resume(throwing: CancellationError())
  }
}

enum AsyncTestError: Error {
  case timedOut
}

func waitUntil(
  timeout: Duration = .seconds(1),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !(await condition()) {
    guard clock.now < deadline else { throw AsyncTestError.timedOut }
    try await Task.sleep(for: .milliseconds(5))
  }
}
