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
    // Test-only helpers. No product and neither app target depends on it, so it never ships.
    .target(
      name: "PithTestSupport",
      dependencies: ["PithCore"],
      path: "Tests/PithTestSupport"
    ),
    .testTarget(
      name: "PithCoreTests",
      dependencies: ["PithCore", "PithTestSupport"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "PithAppTests",
      dependencies: ["Pith", "PithCore", "PithTestSupport"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
