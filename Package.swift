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
      // Not a SwiftPM resource: Bundle.module would compile this Mac's .build path into the app.
      // scripts/build-app.sh copies guide.json into Contents/Resources; tests read it here.
      exclude: ["Resources/guide.json"]
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
      dependencies: ["Pith", "PithCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
