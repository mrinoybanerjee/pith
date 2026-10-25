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

  /// The bundles the table fixtures use. Any other `.app` has no readable bundle.
  static func bundleInfo(_ appPath: String) -> (id: String, name: String)? {
    bundles[appPath]
  }

  private static let bundles: [String: (id: String, name: String)] = [
    "/Applications/Google Chrome.app": ("com.google.Chrome", "Google Chrome"),
    "/Applications/Xcode.app": ("com.apple.dt.Xcode", "Xcode"),
    "/System/Applications/Utilities/Terminal.app": ("com.apple.Terminal", "Terminal"),
    "/Applications/Codex.app": ("com.example.Codex", "Codex"),
    "/Applications/Claude.app": ("com.example.Claude", "Claude"),
    "/Applications/Slack.app": ("com.example.Slack", "Slack"),
    "/System/Applications/Preview.app": ("com.apple.Preview", "Preview"),
    "/Applications/Notes.app": ("com.example.Notes", "Notes"),
  ]
}
