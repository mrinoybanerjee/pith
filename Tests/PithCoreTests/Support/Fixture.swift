import Foundation

@testable import PithCore

/// Synthetic test data from `Fixtures/`.
enum Fixture {
  /// `Fixtures/tables/<name>.json`, a hand-written `ProcessTable`.
  static func table(_ name: String) -> ProcessTable {
    let url = Bundle.module.url(
      forResource: name, withExtension: "json", subdirectory: "Fixtures/tables")!
    return try! JSONDecoder().decode(ProcessTable.self, from: Data(contentsOf: url))
  }

  /// `Fixtures/<name>.txt`, for example `top/two-samples`: made-up command output.
  static func text(_ name: String) -> String {
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name).txt")
    return try! String(contentsOf: url, encoding: .utf8)
  }

  /// The bundles the table fixtures use. Any other `.app` has no readable bundle.
  static func bundleInfo(_ appPath: String) -> (id: String, name: String)? {
    bundles[appPath]
  }

  private static let bundles: [String: (id: String, name: String)] = [
    "/Applications/Google Chrome.app": ("com.google.Chrome", "Google Chrome"),
    "/private/var/folders/xx/T/code_sign_clone.AbC123/Google Chrome.app.bundle": (
      "com.google.Chrome", "Google Chrome"
    ),
    "/Applications/Xcode.app": ("com.apple.dt.Xcode", "Xcode"),
    "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app": (
      "com.apple.iphonesimulator", "Simulator"
    ),
    "/System/Applications/Utilities/Terminal.app": ("com.apple.Terminal", "Terminal"),
    "/Applications/Codex.app": ("com.example.Codex", "Codex"),
    "/Applications/Claude.app": ("com.example.Claude", "Claude"),
    "/Applications/Slack.app": ("com.example.Slack", "Slack"),
    "/System/Applications/Preview.app": ("com.apple.Preview", "Preview"),
    "/Applications/Notes.app": ("com.example.Notes", "Notes"),
  ]
}
