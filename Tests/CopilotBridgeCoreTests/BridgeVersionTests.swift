import Foundation
import XCTest

@testable import CopilotBridgeCore

final class BridgeVersionTests: XCTestCase {
  func testReleaseMatchesAppBundleSource() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, BridgeVersion.release)
    XCTAssertEqual(BridgeVersion.release, "1.0.0")
    XCTAssertEqual(BridgeVersion.userAgent, "CopilotBridge/\(BridgeVersion.current)")
  }
}
