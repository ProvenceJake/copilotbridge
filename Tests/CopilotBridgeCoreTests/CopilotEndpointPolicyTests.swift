import XCTest

@testable import CopilotBridgeCore

final class CopilotEndpointPolicyTests: XCTestCase {
  func testAcceptsOfficialAndEnterpriseEndpoints() throws {
    let accepted = [
      "https://api.githubcopilot.com",
      "https://API.INDIVIDUAL.GITHUBCOPILOT.COM/",
      "https://api.business.githubcopilot.com:443",
      "https://api.enterprise.githubcopilot.com",
      "https://copilot-proxy.githubusercontent.com",
      "https://copilot-api.example.ghe.com",
      "https://copilot-proxy.tenant-1.ghe.com/",
    ]

    for raw in accepted {
      XCTAssertNotNil(try CopilotEndpointPolicy.validatedAPIEndpoint(raw), raw)
    }
    XCTAssertNil(try CopilotEndpointPolicy.validatedAPIEndpoint(nil))
  }

  func testRejectsConfusedOrUnapprovedEndpoints() {
    let rejected: [Any] = [
      42,
      "http://api.githubcopilot.com",
      "https://user:pass@api.githubcopilot.com",
      "https://api.githubcopilot.com:8443",
      "https://api.githubcopilot.com/v1",
      "https://api.githubcopilot.com?next=evil",
      "https://api.githubcopilot.com#fragment",
      "https://githubcopilot.com",
      "https://evilgithubcopilot.com",
      "https://api.githubcopilot.com.evil.test",
      "https://api.githubcopilot.com@evil.test",
      "https://raw.githubusercontent.com",
      "https://tenant.ghe.com",
      "https://wrong-service.tenant.ghe.com",
      "https://127.0.0.1",
      "https://localhost",
      "https://api%2egithubcopilot.com",
      "https://api.githubcopilot.com\\@evil.test",
    ]

    for raw in rejected {
      XCTAssertThrowsError(
        try CopilotEndpointPolicy.validatedAPIEndpoint(raw), raw as? String ?? "42")
    }
  }
}
