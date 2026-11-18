// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CopilotBridge",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "CopilotBridge", targets: ["CopilotBridgeApp"]),
    .library(name: "CopilotBridgeCore", targets: ["CopilotBridgeCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3")
  ],
  targets: [
    .target(
      name: "CopilotBridgeCore",
      dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
      ],
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .executableTarget(
      name: "CopilotBridgeApp",
      dependencies: ["CopilotBridgeCore"],
      linkerSettings: [
        .linkedFramework("ServiceManagement")
      ]
    ),
    .testTarget(
      name: "CopilotBridgeCoreTests",
      dependencies: ["CopilotBridgeCore"]
    ),
    .testTarget(
      name: "CopilotBridgeAppTests",
      dependencies: ["CopilotBridgeApp", "CopilotBridgeCore"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
