import Foundation

public enum BridgeVersion {
  /// The fallback also identifies unbundled SwiftPM builds and the reusable Core library.
  public static let release = "1.0.0"
  public static let current: String = {
    guard Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "CopilotBridge",
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String,
      !version.isEmpty
    else { return release }
    return version
  }()
  public static var userAgent: String { "CopilotBridge/\(current)" }
}
