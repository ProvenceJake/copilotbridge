import Foundation
import XCTest

@testable import CopilotBridgeCore

final class GitHubDeviceAuthTests: XCTestCase {
  func testRequestCodeUsesFormEncodingAndDefaultsMissingIntervalToFiveSeconds() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .json(
        status: 200,
        object: Self.deviceCodeResponse(interval: nil)
      )
    ])
    let fixture = makeFixture(scenario: scenario, clientID: "test client+id")
    defer { fixture.close() }

    let authorization = try await fixture.auth.requestCode()

    XCTAssertEqual(authorization.interval, 5)
    XCTAssertEqual(authorization.expiresIn, 900)
    let request = try XCTUnwrap(scenario.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertTrue(
      request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix(
        "application/x-www-form-urlencoded") == true
    )
    XCTAssertEqual(
      try Self.formValues(in: request),
      ["client_id": "test client+id", "scope": "read:user"]
    )
    XCTAssertTrue(
      String(decoding: try XCTUnwrap(request.body), as: UTF8.self).contains(
        "client_id=test+client%2Bid"))
    XCTAssertEqual(fixture.clock.sleeps, [])
  }

  func testRequestCodeRetriesSecureConnectionFailureWithExponentialBackoff() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .failure(.secureConnectionFailed),
      .failure(.secureConnectionFailed),
      .json(status: 200, object: Self.deviceCodeResponse(interval: 7)),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    let authorization = try await fixture.auth.requestCode()

    XCTAssertEqual(authorization.interval, 7)
    XCTAssertEqual(scenario.requests.count, 3)
    XCTAssertEqual(fixture.clock.sleeps, [0.5, 1.0])
  }

  func testRequestCodeDoesNotRetryUntrustedServerCertificate() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .failure(.serverCertificateUntrusted),
      .json(status: 200, object: Self.deviceCodeResponse(interval: 5)),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    do {
      _ = try await fixture.auth.requestCode()
      XCTFail("An untrusted certificate must fail without retrying")
    } catch {
      // Expected. Certificate trust failures must never be hidden by retry/fallback logic.
    }

    XCTAssertEqual(scenario.requests.count, 1)
    XCTAssertEqual(fixture.clock.sleeps, [])
  }

  func testRequestCodeHonorsRetryAfterForRetryableHTTPStatus() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .json(status: 503, headers: ["Retry-After": "3"], object: [:]),
      .json(status: 200, object: Self.deviceCodeResponse(interval: 5)),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    _ = try await fixture.auth.requestCode()

    XCTAssertEqual(scenario.requests.count, 2)
    XCTAssertEqual(fixture.clock.sleeps, [3])
  }

  func testRequestCodeDoesNotWaitPastRetryBudget() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .json(status: 503, headers: ["Retry-After": "31"], object: [:]),
      .json(status: 200, object: Self.deviceCodeResponse(interval: 5)),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    do {
      _ = try await fixture.auth.requestCode()
      XCTFail("Retry-After beyond the request budget must fail without retrying")
    } catch {
      // Expected.
    }

    XCTAssertEqual(scenario.requests.count, 1)
    XCTAssertEqual(fixture.clock.sleeps, [])
  }

  func testRequestCodeStopsAfterMaximumAttemptCount() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .failure(.secureConnectionFailed),
      .failure(.secureConnectionFailed),
      .failure(.secureConnectionFailed),
      .failure(.secureConnectionFailed),
      .json(status: 200, object: Self.deviceCodeResponse(interval: 5)),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    do {
      _ = try await fixture.auth.requestCode()
      XCTFail("Device-code acquisition must have a bounded attempt count")
    } catch {
      // Expected.
    }

    XCTAssertEqual(scenario.requests.count, 4)
    XCTAssertEqual(fixture.clock.sleeps, [0.5, 1, 2])
  }

  func testRequestCodeDoesNotSendRequestWhenAlreadyCancelled() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .json(status: 200, object: Self.deviceCodeResponse(interval: 5))
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }
    let gate = GitHubAuthAsyncGate()
    let auth = fixture.auth
    let task = Task {
      await gate.wait()
      return try await auth.requestCode()
    }
    task.cancel()
    await gate.open()

    do {
      _ = try await task.value
      XCTFail("A pre-cancelled login must finish with cancellation")
    } catch is CancellationError {
      // Expected.
    }

    XCTAssertEqual(scenario.requests.count, 0)
    XCTAssertEqual(fixture.clock.sleeps, [])
  }

  func testRequestCodeDoesNotRetryOversizedResponse() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .data(status: 200, body: Data(repeating: 0x20, count: 1_048_577)),
      .json(status: 200, object: Self.deviceCodeResponse(interval: 5)),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    do {
      _ = try await fixture.auth.requestCode()
      XCTFail("An oversized response must be rejected")
    } catch {
      // Expected.
    }

    XCTAssertEqual(scenario.requests.count, 1)
    XCTAssertEqual(fixture.clock.sleeps, [])
  }

  func testPollParsesAuthorizationPendingFromHTTP400BeforeStatusFailure() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .json(status: 400, object: ["error": "authorization_pending"]),
      .json(status: 200, object: ["access_token": "test-access-token"]),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    let token = try await fixture.auth.pollForToken(Self.authorization(interval: 5))

    XCTAssertEqual(token, "test-access-token")
    XCTAssertEqual(scenario.requests.count, 2)
    XCTAssertEqual(fixture.clock.sleeps, [5, 5])
    let request = try XCTUnwrap(scenario.requests.first)
    XCTAssertTrue(
      request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix(
        "application/x-www-form-urlencoded") == true
    )
    XCTAssertEqual(
      try Self.formValues(in: request),
      [
        "client_id": "test-client-id",
        "device_code": "test-device-code",
        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
      ]
    )
  }

  func testConsecutiveSlowDownResponsesPermanentlyAddFiveSeconds() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .json(status: 200, object: ["error": "slow_down"]),
      .json(status: 200, object: ["error": "slow_down"]),
      .json(status: 200, object: ["error": "authorization_pending"]),
      .json(status: 200, object: ["access_token": "test-access-token"]),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    let token = try await fixture.auth.pollForToken(Self.authorization(interval: 5))

    XCTAssertEqual(token, "test-access-token")
    XCTAssertEqual(fixture.clock.sleeps, [5, 10, 15, 15])
  }

  func testSlowDownReturnedIntervalCannotUndoPermanentFiveSecondIncrease() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .json(status: 200, object: ["error": "slow_down", "interval": 30]),
      .json(status: 200, object: ["error": "slow_down", "interval": 6]),
      .json(status: 200, object: ["access_token": "test-access-token"]),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    let token = try await fixture.auth.pollForToken(Self.authorization(interval: 5))

    XCTAssertEqual(token, "test-access-token")
    XCTAssertEqual(fixture.clock.sleeps, [5, 30, 35])
  }

  func testPollTransportFailureWaitsForProtocolIntervalAndExponentialBackoff() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .failure(.secureConnectionFailed),
      .failure(.timedOut),
      .json(status: 200, object: ["access_token": "test-access-token"]),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    let token = try await fixture.auth.pollForToken(Self.authorization(interval: 5))

    XCTAssertEqual(token, "test-access-token")
    XCTAssertEqual(scenario.requests.count, 3)
    XCTAssertEqual(fixture.clock.sleeps, [5, 10, 20])
  }

  func testPollRetryAfterIsNotCappedByLocalBackoffMaximum() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .json(status: 503, headers: ["Retry-After": "75"], object: [:]),
      .json(status: 200, object: ["access_token": "test-access-token"]),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    let token = try await fixture.auth.pollForToken(Self.authorization(interval: 5))

    XCTAssertEqual(token, "test-access-token")
    XCTAssertEqual(fixture.clock.sleeps, [5, 75])
  }

  func testValidOAuthResponseResetsConsecutiveTransportBackoff() async throws {
    let scenario = GitHubAuthURLProtocolScenario([
      .failure(.secureConnectionFailed),
      .json(status: 400, object: ["error": "authorization_pending"]),
      .failure(.timedOut),
      .json(status: 200, object: ["access_token": "test-access-token"]),
    ])
    let fixture = makeFixture(scenario: scenario)
    defer { fixture.close() }

    let token = try await fixture.auth.pollForToken(Self.authorization(interval: 5))

    XCTAssertEqual(token, "test-access-token")
    XCTAssertEqual(fixture.clock.sleeps, [5, 10, 5, 10])
  }

  private func makeFixture(
    scenario: GitHubAuthURLProtocolScenario,
    clientID: String = "test-client-id",
    retryPolicy: GitHubAuthRetryPolicy = GitHubAuthRetryPolicy(
      requestCodeMaximumAttempts: 4,
      requestCodeBaseDelay: 0.5,
      requestCodeRetryBudget: 30,
      maximumPollBackoff: 60
    )
  ) -> GitHubAuthFixture {
    let userAgent = "CopilotBridgeTests/\(UUID().uuidString)"
    GitHubAuthMockURLProtocol.register(scenario, for: userAgent)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GitHubAuthMockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let clock = GitHubAuthVirtualClock()
    let timing = GitHubAuthTiming(
      monotonicNow: { clock.monotonicNow },
      wallNow: { clock.wallNow },
      sleep: { delay in try await clock.sleep(for: delay) }
    )
    let auth = GitHubDeviceAuth(
      clientID: clientID,
      userAgent: userAgent,
      session: session,
      retryPolicy: retryPolicy,
      timing: timing
    )
    return GitHubAuthFixture(
      auth: auth,
      clock: clock,
      close: {
        session.invalidateAndCancel()
        GitHubAuthMockURLProtocol.unregister(userAgent: userAgent)
      }
    )
  }

  private static func authorization(interval: Int) -> DeviceAuthorization {
    DeviceAuthorization(
      deviceCode: "test-device-code",
      userCode: "TEST-CODE",
      verificationURL: URL(string: "https://github.com/login/device")!,
      expiresIn: 300,
      interval: interval
    )
  }

  private static func deviceCodeResponse(interval: Int?) -> [String: Any] {
    var response: [String: Any] = [
      "device_code": "test-device-code",
      "user_code": "TEST-CODE",
      "verification_uri": "https://github.com/login/device",
      "expires_in": 900,
    ]
    response["interval"] = interval
    return response
  }

  private static func formValues(in request: GitHubAuthRecordedRequest) throws -> [String: String] {
    let body = try XCTUnwrap(request.body)
    let encoded = String(decoding: body, as: UTF8.self)
    return try Dictionary(
      uniqueKeysWithValues: encoded.split(separator: "&").map { field in
        let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = try XCTUnwrap(Self.decodeFormComponent(String(pair[0])))
        let value = try XCTUnwrap(Self.decodeFormComponent(pair.count == 2 ? String(pair[1]) : ""))
        return (name, value)
      })
  }

  private static func decodeFormComponent(_ value: String) -> String? {
    value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
  }
}

private struct GitHubAuthFixture {
  let auth: GitHubDeviceAuth
  let clock: GitHubAuthVirtualClock
  let close: () -> Void
}

private final class GitHubAuthVirtualClock: @unchecked Sendable {
  private let lock = NSLock()
  private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  private var elapsed: TimeInterval = 0
  private var recordedSleeps: [TimeInterval] = []

  var monotonicNow: TimeInterval {
    lock.withLock { elapsed }
  }

  var wallNow: Date {
    lock.withLock { epoch.addingTimeInterval(elapsed) }
  }

  var sleeps: [TimeInterval] {
    lock.withLock { recordedSleeps }
  }

  func sleep(for delay: TimeInterval) async throws {
    try Task.checkCancellation()
    lock.withLock {
      recordedSleeps.append(delay)
      elapsed += delay
    }
  }
}

private actor GitHubAuthAsyncGate {
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
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private final class GitHubAuthURLProtocolScenario: @unchecked Sendable {
  enum Step: @unchecked Sendable {
    case json(status: Int, headers: [String: String] = [:], object: [String: Any])
    case data(status: Int, headers: [String: String] = [:], body: Data)
    case failure(URLError.Code)
  }

  private let lock = NSLock()
  private var remainingSteps: [Step]
  private var recordedRequests: [GitHubAuthRecordedRequest] = []

  init(_ steps: [Step]) {
    remainingSteps = steps
  }

  var requests: [GitHubAuthRecordedRequest] {
    lock.withLock { recordedRequests }
  }

  func takeStep(for request: URLRequest) -> Step {
    let recordedRequest = GitHubAuthRecordedRequest(request)
    return lock.withLock {
      recordedRequests.append(recordedRequest)
      guard !remainingSteps.isEmpty else {
        return GitHubAuthURLProtocolScenario.Step.failure(.badServerResponse)
      }
      return remainingSteps.removeFirst()
    }
  }
}

private struct GitHubAuthRecordedRequest: @unchecked Sendable {
  let url: URL?
  let httpMethod: String?
  let headers: [String: String]
  let body: Data?

  init(_ request: URLRequest) {
    url = request.url
    httpMethod = request.httpMethod
    headers = request.allHTTPHeaderFields ?? [:]
    body = request.httpBody ?? Self.read(request.httpBodyStream)
  }

  func value(forHTTPHeaderField name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private static func read(_ stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        stream.read(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: bytes.count)
      }
      if count > 0 {
        data.append(buffer, count: count)
      } else if count == 0 {
        return data
      } else {
        return nil
      }
    }
  }
}

private final class GitHubAuthURLProtocolRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var scenarios: [String: GitHubAuthURLProtocolScenario] = [:]

  func register(_ scenario: GitHubAuthURLProtocolScenario, for userAgent: String) {
    lock.withLock { scenarios[userAgent] = scenario }
  }

  func unregister(userAgent: String) {
    _ = lock.withLock { scenarios.removeValue(forKey: userAgent) }
  }

  func scenario(for request: URLRequest) -> GitHubAuthURLProtocolScenario? {
    guard let userAgent = request.value(forHTTPHeaderField: "User-Agent") else { return nil }
    return lock.withLock { scenarios[userAgent] }
  }
}

private final class GitHubAuthMockURLProtocol: URLProtocol, @unchecked Sendable {
  private static let registry = GitHubAuthURLProtocolRegistry()

  static func register(_ scenario: GitHubAuthURLProtocolScenario, for userAgent: String) {
    registry.register(scenario, for: userAgent)
  }

  static func unregister(userAgent: String) {
    registry.unregister(userAgent: userAgent)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "github.com"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let scenario = Self.registry.scenario(for: request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }

    switch scenario.takeStep(for: request) {
    case .failure(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .json(let status, let headers, let object):
      do {
        let data = try JSONSerialization.data(withJSONObject: object)
        deliver(status: status, headers: headers, body: data, contentType: "application/json")
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    case .data(let status, let headers, let body):
      deliver(status: status, headers: headers, body: body, contentType: nil)
    }
  }

  override func stopLoading() {}

  private func deliver(
    status: Int,
    headers: [String: String],
    body: Data,
    contentType: String?
  ) {
    var responseHeaders = headers
    if let contentType {
      responseHeaders["Content-Type"] = contentType
    }
    responseHeaders["Content-Length"] = String(body.count)
    guard
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: responseHeaders
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
}
