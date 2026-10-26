import PithCore
import Testing

@testable import Pith

@Test func appModuleLoads() { #expect(PithCore.version == "0.1.0") }

/// R130: a made-up row's bundle ID must not be another app's, or the row shows that app's guide
/// entry. The demo's Codex rows once used ChatGPT's real ID, `com.openai.codex`.
@Test func demoRowsShowTheirOwnGuideEntries() throws {
  let guide = try Guide.bundled()
  for app in DemoSnapshots.calm.apps + DemoSnapshots.tight.apps {
    let entry = guide.entry(name: app.name, bundleID: app.bundleID, path: app.bundlePath)
    #expect(entry == nil || entry?.title == app.name, "\(app.name): \(entry?.title ?? "")")
  }
}
