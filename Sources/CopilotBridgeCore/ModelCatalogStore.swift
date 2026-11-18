import Foundation

enum CopilotInferenceEndpoint: String, CaseIterable, Sendable {
  case chatCompletions = "/chat/completions"
  case responses = "/responses"
  case messages = "/v1/messages"

  fileprivate init?(catalogValue: String) {
    let normalized = catalogValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
    case "chat/completions", "v1/chat/completions": self = .chatCompletions
    case "responses", "v1/responses": self = .responses
    case "messages", "v1/messages": self = .messages
    default: return nil
    }
  }
}

/// Shares the relatively expensive Copilot model discovery request between
/// model listing and compatibility-name resolution.
actor ModelCatalogStore {
  typealias Loader = @Sendable () async throws -> CopilotDataResponse
  typealias Now = @Sendable () -> Date

  private enum EndpointMetadata: Sendable {
    case absent
    case supported(Set<CopilotInferenceEndpoint>)
    case invalid
  }

  private struct Snapshot: Sendable {
    let response: CopilotDataResponse
    let ids: Set<String>
    let endpoints: [String: EndpointMetadata]
  }

  private let timeToLive: TimeInterval
  private let now: Now
  private let loader: Loader
  private let fetchOperation = SharedOperation<Snapshot>()
  private var cache: (snapshot: Snapshot, fetchedAt: Date)?

  init(
    timeToLive: TimeInterval = 300,
    now: @escaping Now = { Date() },
    loader: @escaping Loader
  ) {
    self.timeToLive = max(0, timeToLive)
    self.now = now
    self.loader = loader
  }

  init(client: CopilotClient) {
    timeToLive = 300
    now = { Date() }
    loader = {
      try await client.data(path: "models", method: "GET", timeoutInterval: 20)
    }
  }

  func response() async throws -> CopilotDataResponse {
    try await snapshot().response
  }

  private func snapshot() async throws -> Snapshot {
    try Task.checkCancellation()
    let currentTime = now()
    if let cache {
      let age = currentTime.timeIntervalSince(cache.fetchedAt)
      if age >= 0, age < timeToLive {
        return cache.snapshot
      }
    }

    let snapshot = try await fetchOperation.value { [loader] in
      let response = try await loader()
      guard (200..<300).contains(response.status) else {
        return Snapshot(response: response, ids: [], endpoints: [:])
      }
      let snapshot = try Self.parsedSnapshot(response)
      try Task.checkCancellation()
      try await self.storeSuccessfulSnapshot(snapshot)
      return snapshot
    }
    try Task.checkCancellation()
    return snapshot
  }

  func modelIDs() async throws -> Set<String> {
    let snapshot = try await snapshot()
    guard (200..<300).contains(snapshot.response.status) else {
      throw BridgeError.upstream(
        status: snapshot.response.status, message: "无法读取 Copilot 模型列表。")
    }
    return snapshot.ids
  }

  /// Returns nil when the model or endpoint metadata is absent. An empty set
  /// means the catalog explicitly supplied endpoint metadata but none of its
  /// values describe an HTTP inference endpoint supported by this bridge.
  func supportedEndpoints(for modelID: String) async throws -> Set<CopilotInferenceEndpoint>? {
    let snapshot = try await snapshot()
    guard (200..<300).contains(snapshot.response.status) else {
      throw BridgeError.upstream(
        status: snapshot.response.status, message: "无法读取 Copilot 模型列表。")
    }
    switch snapshot.endpoints[modelID] ?? .absent {
    case .absent: return nil
    case .supported(let endpoints): return endpoints
    case .invalid: throw BridgeError.protocolFailure("Copilot 模型端点目录格式无效。")
    }
  }

  func activeFetchWaiterCount() async -> Int {
    await fetchOperation.waiterCount()
  }

  private func storeSuccessfulSnapshot(_ snapshot: Snapshot) throws {
    try Task.checkCancellation()
    cache = (snapshot, now())
  }

  private static func parsedSnapshot(_ response: CopilotDataResponse) throws -> Snapshot {
    let models = try models(in: response)
    var ids = Set<String>()
    var endpoints: [String: EndpointMetadata] = [:]
    for model in models {
      guard let id = model["id"] as? String else {
        throw BridgeError.protocolFailure("Copilot 模型列表包含无效 id。")
      }
      let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedID.isEmpty, trimmedID == id else {
        throw BridgeError.protocolFailure("Copilot 模型列表包含无效 id。")
      }
      ids.insert(id)
      // Preserve first-entry semantics for duplicate IDs, including absent/invalid metadata.
      if endpoints[id] == nil { endpoints[id] = endpointMetadata(in: model) }
    }
    return Snapshot(response: response, ids: ids, endpoints: endpoints)
  }

  private static func endpointMetadata(in model: [String: Any]) -> EndpointMetadata {
    let capabilities = model["capabilities"] as? [String: Any]
    let raw =
      model["supported_endpoints"] ?? model["supportedEndpoints"]
      ?? capabilities?["supported_endpoints"] ?? capabilities?["supportedEndpoints"]
    guard let raw else { return .absent }
    guard let values = raw as? [String] else {
      return .invalid
    }
    return .supported(Set(values.compactMap(CopilotInferenceEndpoint.init(catalogValue:))))
  }

  private static func models(in response: CopilotDataResponse) throws -> [[String: Any]] {
    guard
      let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
      let models = object["data"] as? [[String: Any]]
    else {
      throw BridgeError.protocolFailure("无法读取 Copilot 模型列表。")
    }
    return models
  }
}
