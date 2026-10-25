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
  static func bundleInfo(_ appPath: String) -> (bundleID: String, name: String)? {
    bundles[appPath]
  }

  private static let bundles: [String: (bundleID: String, name: String)] = [
    "/Applications/Google Chrome.app": ("com.google.Chrome", "Google Chrome"),
    "/private/var/folders/xx/T/code_sign_clone.AbC123/Google Chrome.app.bundle": (
      "com.google.Chrome", "Google Chrome"
    ),
    "/private/var/folders/xx/T/code_sign_clone.DeF456/Google Chrome.app.bundle": (
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
    "/Volumes/Demo/Notes.app": ("com.example.Notes", "Notes"),
    "/Volumes/Demo/Google Chrome.app": ("com.google.Chrome", "Google Chrome"),
  ]
}

extension ProcessTable {
  /// The `chrome-usage` fixture taken at 0 s, then each second after with 0.1 s more CPU in each
  /// process.
  static let chromeAt0 = chromeUsage(at: 0, cpuNs: 0)
  static let chromeAt1s = chromeUsage(at: 1_000_000_000, cpuNs: 100_000_000)
  static let chromeAt2s = chromeUsage(at: 2_000_000_000, cpuNs: 200_000_000)
  static let chromeAt3s = chromeUsage(at: 3_000_000_000, cpuNs: 300_000_000)

  private static func chromeUsage(at ns: UInt64, cpuNs: UInt64) -> ProcessTable {
    let samples = Fixture.table("chrome-usage").samples.map {
      ProcessSample(
        key: $0.key, parent: $0.parent, uid: $0.uid, name: $0.name, path: $0.path,
        idVersion: $0.idVersion, footprint: $0.footprint, cpuTimeNs: cpuNs, diskRead: 0,
        diskWritten: 0)
    }
    return ProcessTable(samples: samples, takenAtNs: ns, vanished: 0)
  }
}
