import Foundation

/// Coalesces identical work without letting one cancelled caller tear down work
/// that is still needed by other callers.
actor SharedOperation<Value: Sendable> {
  typealias Operation = @Sendable () async throws -> Value

  private struct Flight {
    let id: UInt64
    let task: Task<Void, Never>
    var waiters: [UUID: CheckedContinuation<Value, any Error>]
  }

  private var flight: Flight?
  private var nextFlightID: UInt64 = 0
  private var isInvalidated = false

  func value(operation: @escaping Operation) async throws -> Value {
    let waiterID = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        register(waiterID: waiterID, continuation: continuation, operation: operation)
      }
    } onCancel: {
      Task { await self.cancel(waiterID: waiterID) }
    }
  }

  func invalidate() {
    isInvalidated = true
    guard let flight else { return }
    self.flight = nil
    flight.task.cancel()
    for continuation in flight.waiters.values {
      continuation.resume(throwing: CancellationError())
    }
  }

  func waiterCount() -> Int {
    flight?.waiters.count ?? 0
  }

  private func register(
    waiterID: UUID,
    continuation: CheckedContinuation<Value, any Error>,
    operation: @escaping Operation
  ) {
    guard !isInvalidated else {
      continuation.resume(throwing: CancellationError())
      return
    }
    if Task.isCancelled {
      continuation.resume(throwing: CancellationError())
      return
    }

    if var flight {
      flight.waiters[waiterID] = continuation
      self.flight = flight
      return
    }

    nextFlightID &+= 1
    let flightID = nextFlightID
    let task = Task.detached(priority: Task.currentPriority) { [weak self] in
      let result: Result<Value, any Error>
      do {
        result = .success(try await operation())
      } catch {
        result = .failure(error)
      }
      await self?.complete(flightID: flightID, result: result)
    }
    flight = Flight(
      id: flightID,
      task: task,
      waiters: [waiterID: continuation]
    )
  }

  private func cancel(waiterID: UUID) {
    guard var flight, let continuation = flight.waiters.removeValue(forKey: waiterID) else {
      return
    }

    if flight.waiters.isEmpty {
      self.flight = nil
      flight.task.cancel()
    } else {
      self.flight = flight
    }
    continuation.resume(throwing: CancellationError())
  }

  private func complete(flightID: UInt64, result: Result<Value, any Error>) {
    guard let flight, flight.id == flightID else { return }
    self.flight = nil
    for continuation in flight.waiters.values {
      continuation.resume(with: result)
    }
  }
}

actor ModelResolver {
  private let aliases: [String: String]
  private let fetchModelIDs: @Sendable () async throws -> Set<String>
  private let fetchOperation = SharedOperation<Set<String>>()
  private var cache: (ids: Set<String>, fetchedAt: Date)?

  init(client: CopilotClient, aliases: [String: String]) {
    self.aliases = aliases
    fetchModelIDs = {
      let response = try await client.data(
        path: "models", method: "GET", timeoutInterval: 20)
      guard (200..<300).contains(response.status),
        let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
        let models = object["data"] as? [[String: Any]]
      else {
        throw BridgeError.protocolFailure("无法读取 Copilot 模型列表。")
      }
      return Set(models.compactMap { $0["id"] as? String })
    }
  }

  init(
    aliases: [String: String],
    fetchModelIDs: @escaping @Sendable () async throws -> Set<String>
  ) {
    self.aliases = aliases
    self.fetchModelIDs = fetchModelIDs
  }

  func resolve(_ requested: String) async -> String {
    if let alias = aliases[requested], !alias.isEmpty { return alias }
    guard !requested.isEmpty else { return requested }
    let candidates = Self.candidates(for: requested)
    guard candidates.count > 1 else { return requested }

    let ids: Set<String>
    do {
      ids = try await availableModelIDs()
    } catch {
      return requested
    }
    return candidates.first(where: ids.contains) ?? requested
  }

  func activeFetchWaiterCount() async -> Int {
    await fetchOperation.waiterCount()
  }

  private func availableModelIDs() async throws -> Set<String> {
    if let cache, Date().timeIntervalSince(cache.fetchedAt) < 300 {
      return cache.ids
    }
    let ids = try await fetchOperation.value(operation: fetchModelIDs)
    cache = (ids, Date())
    return ids
  }

  static func candidates(for requested: String) -> [String] {
    var output: [String] = []
    func add(_ value: String) {
      if !value.isEmpty && !output.contains(value) { output.append(value) }
    }
    add(requested)

    var base = requested
    var wantsOneMillion = false
    if base.lowercased().hasSuffix("[1m]") {
      wantsOneMillion = true
      base.removeLast(4)
    } else {
      for suffix in ["-1m-internal", "-1m"] where base.lowercased().hasSuffix(suffix) {
        wantsOneMillion = true
        base.removeLast(suffix.count)
        break
      }
    }
    if let separator = base.lastIndex(of: "-") {
      let suffix = base[base.index(after: separator)...]
      if suffix.count == 8, suffix.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
        base.removeSubrange(separator...)
      }
    }
    let dotted = dotVersion(base)

    if wantsOneMillion {
      for candidate in [dotted, base] {
        add("\(candidate)-1m-internal")
        add("\(candidate)-1m")
      }
    }
    add(dotted)
    add(base)
    return output
  }

  private static func dotVersion(_ input: String) -> String {
    var components = input.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    guard components.count >= 3 else { return input }

    for start in 1..<(components.count - 1) where isDigits(components[start]) {
      var end = start + 1
      guard isDigits(components[end]) else { continue }
      while end + 1 < components.count, isDigits(components[end + 1]) { end += 1 }
      components.replaceSubrange(
        start...end, with: [components[start...end].joined(separator: ".")])
      return components.joined(separator: "-")
    }
    return input
  }

  private static func isDigits(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
  }
}
