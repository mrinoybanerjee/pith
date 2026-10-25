// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Pith",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "PithCore", targets: ["PithCore"]),
    .executable(name: "Pith", targets: ["Pith"]),
  ],
  targets: [
    .target(
      name: "PithCore",
      resources: [.copy("Resources/guide.json")]
    ),
    .executableTarget(
      name: "Pith",
      dependencies: ["PithCore"]
    ),
    .testTarget(
      name: "PithCoreTests",
      dependencies: ["PithCore"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "PithAppTests",
      dependencies: ["Pith"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
