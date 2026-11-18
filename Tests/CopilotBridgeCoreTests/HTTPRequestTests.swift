import Foundation
import NIOHTTP1
import XCTest

@testable import CopilotBridgeCore

final class HTTPRequestTests: XCTestCase {
  func testNormalizesQueryAndTrailingSlashesOnce() {
    let request = BridgeHTTPRequest(
      method: .POST,
      uri: "/v1/chat/completions///?api-version=2024-10-21",
      headers: HTTPHeaders(),
      body: Data())

    XCTAssertTrue(request.hasValidRequestTarget)
    XCTAssertEqual(request.path, "/v1/chat/completions")
  }

  func testRejectsAmbiguousOrEncodedSlashTargets() {
    for uri in ["//v1/models", "/v1%2Fmodels", "/v1%5cmodels", "/v1/models#fragment"] {
      let request = BridgeHTTPRequest(
        method: .GET, uri: uri, headers: HTTPHeaders(), body: Data())
      XCTAssertFalse(request.hasValidRequestTarget, "uri=\(uri)")
    }
  }

  func testAllowsAsteriskOnlyForOptions() {
    XCTAssertTrue(
      BridgeHTTPRequest(method: .OPTIONS, uri: "*", headers: HTTPHeaders(), body: Data())
        .hasValidRequestTarget)
    XCTAssertFalse(
      BridgeHTTPRequest(method: .GET, uri: "*", headers: HTTPHeaders(), body: Data())
        .hasValidRequestTarget)
  }
}
