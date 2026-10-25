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

  /// The bundles the table fixtures use. Any other `.app` has no readable bundle. Firefox's
  /// executable is "firefox", unlike its name.
  static func bundleInfo(_ appPath: String) -> AppGrouper.BundleInfo? {
    bundles[appPath].map { ($0.bundleID, $0.name, $0.executable ?? $0.name) }
  }

  private static let bundles: [String: (bundleID: String, name: String, executable: String?)] = [
    "/Applications/Google Chrome.app": ("com.google.Chrome", "Google Chrome", nil),
    "/private/var/folders/xx/T/code_sign_clone.AbC123/Google Chrome.app.bundle": (
      "com.google.Chrome", "Google Chrome", nil
    ),
    "/private/var/folders/xx/T/code_sign_clone.DeF456/Google Chrome.app.bundle": (
      "com.google.Chrome", "Google Chrome", nil
    ),
    "/Applications/Xcode.app": ("com.apple.dt.Xcode", "Xcode", nil),
    "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app": (
      "com.apple.iphonesimulator", "Simulator", nil
    ),
    "/System/Applications/Utilities/Terminal.app": ("com.apple.Terminal", "Terminal", nil),
    "/Applications/Codex.app": ("com.example.Codex", "Codex", nil),
    "/Applications/Claude.app": ("com.example.Claude", "Claude", nil),
    "/Applications/Slack.app": ("com.example.Slack", "Slack", nil),
    "/System/Applications/Preview.app": ("com.apple.Preview", "Preview", nil),
    "/Applications/Notes.app": ("com.example.Notes", "Notes", nil),
    "/Volumes/Demo/Notes.app": ("com.example.Notes", "Notes", nil),
    "/Volumes/Demo/Google Chrome.app": ("com.google.Chrome", "Google Chrome", nil),
    "/Applications/Firefox.app": ("org.mozilla.firefox", "Firefox", "firefox"),
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
