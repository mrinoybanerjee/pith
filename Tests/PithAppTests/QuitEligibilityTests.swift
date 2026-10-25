import AppKit
import Testing

@testable import Pith
@testable import PithCore

/// The brief's test. Its `RunningAppInfo` values name the type: an implicit `.init` inside
/// `#expect` makes the macro's expansion warn.
@Test func eligibility() throws {
  let g = try Guide.bundled()
  let chrome = AppUsage.fake(id: "com.google.Chrome", pids: [300])
  #expect(
    QuitEligibility.canQuit(
      chrome,
      running: RunningAppInfo(
        pid: 300, bundlePath: "/Applications/Google Chrome.app", ownerUID: 501),
      uid: 501, guide: g))
  #expect(
    !QuitEligibility.canQuit(
      chrome,
      running: RunningAppInfo(
        pid: 300, bundlePath: "/Applications/Google Chrome.app", ownerUID: 502),
      uid: 501, guide: g))
  #expect(
    !QuitEligibility.canQuit(
      .fake(id: "com.apple.finder", pids: [90]),
      running: RunningAppInfo(
        pid: 90, bundlePath: "/System/Library/CoreServices/Finder.app", ownerUID: 501),
      uid: 501, guide: g))
  #expect(
    !QuitEligibility.canQuit(
      .fake(id: "proc:python3", pids: [70]), running: nil, uid: 501, guide: g))
}

/// R77: the app's own process must be one of the row's; Apple apps in /System/Applications stay
/// quittable; the guide blocks an entry that is part of macOS or not quittable, found by bundle ID
/// first, then by name. R81: Pith never offers to quit itself.
@Test func eligibilityFollowsTheProcessThePathTheGuideAndNeverPith() throws {
  let g = try Guide.bundled()
  func canQuit(_ app: AppUsage, pid: Int32, path: String) -> Bool {
    QuitEligibility.canQuit(
      app, running: .init(pid: pid, bundlePath: path, ownerUID: 501), uid: 501, guide: g)
  }
  let chrome = AppUsage.fake(id: "com.google.Chrome", pids: [300])
  #expect(!canQuit(chrome, pid: 301, path: "/Applications/Google Chrome.app"))
  #expect(
    canQuit(
      .fake(id: "com.apple.Notes", pids: [80]), pid: 80, path: "/System/Applications/Notes.app"))
  // Finder outside /System/Library/ is still not quittable in the guide.
  #expect(
    !canQuit(.fake(id: "com.apple.finder", pids: [90]), pid: 90, path: "/Applications/Finder.app"))
  // A system entry found by name.
  let windowServer = AppUsage(
    id: "/Applications/WindowServer.app", name: "WindowServer",
    bundlePath: "/Applications/WindowServer.app", bundleID: nil, pids: [60], processCount: 1,
    memory: 1 << 20, cpu: .value(0), diskBytesPerSecond: .value(0), inside: [])
  #expect(!canQuit(windowServer, pid: 60, path: "/Applications/WindowServer.app"))
  // The bundle ID's entry wins over the name's.
  let renamed = AppUsage(
    id: "/Applications/Google Chrome.app", name: "WindowServer",
    bundlePath: "/Applications/Google Chrome.app",
    bundleID: "com.google.Chrome", pids: [300], processCount: 1, memory: 1 << 20,
    cpu: .value(0), diskBytesPerSecond: .value(0), inside: [])
  #expect(canQuit(renamed, pid: 300, path: "/Applications/Google Chrome.app"))
  let pith = getpid()
  #expect(
    !canQuit(.fake(id: "com.mrinoy.pith", pids: [pith]), pid: pith, path: "/Applications/Pith.app"))
}

/// `canQuit` for `app` whose own process runs from `path`, owned by the user.
private func canQuit(_ app: AppUsage, from path: String, guide: Guide = .empty) -> Bool {
  QuitEligibility.canQuit(
    app, running: RunningAppInfo(pid: app.pids[0], bundlePath: path, ownerUID: 501), uid: 501,
    guide: guide)
}

/// A guide with one entry.
private func guide(_ match: GuideMatch, kind: GuideKind, quittable: Bool) -> Guide {
  Guide(entries: [
    GuideEntry(
      match: match, title: "Example", explanation: "A synthetic entry.", kind: kind,
      quittable: quittable, source: kind == .system ? "man:example(8)" : nil)
  ])
}

/// R96: the `/System/Library/` guard alone stops an app there that the guide does not know.
@Test func anAppInSystemLibraryThatTheGuideDoesNotKnowCannotQuit() {
  let agent = AppUsage.fake(id: "com.example.agent", pids: [95])
  #expect(!canQuit(agent, from: "/System/Library/CoreServices/Agent.app"))
  #expect(canQuit(agent, from: "/Applications/Agent.app"))
}

/// R96: a system entry blocks Quit on its kind alone, even marked quittable.
@Test func aSystemEntryBlocksQuitEvenWhenMarkedQuittable() {
  let tool = AppUsage.fake(id: "com.example.tool", pids: [96])
  let path = "/Applications/tool.app"
  #expect(
    !canQuit(tool, from: path, guide: guide(.bundleID(tool.id), kind: .system, quittable: true)))
  #expect(canQuit(tool, from: path, guide: guide(.bundleID(tool.id), kind: .app, quittable: true)))
}

/// R96 and spec 4.5: a command-line process never shows Quit, even when macOS runs it as an app.
@Test func aCommandLineRowCannotQuitEvenWithARunningApp() {
  let path = "/Applications/tool.app"
  #expect(!canQuit(.fake(id: "proc:tool", pids: [71]), from: path))
  #expect(canQuit(.fake(id: "com.example.tool", pids: [71]), from: path))
}

/// R96: the guide is read with the row's bundle path, as the row's view reads it, so a path prefix
/// entry that is not quittable blocks Quit.
@Test func aPathPrefixEntryThatIsNotQuittableBlocksQuit() {
  let path = "/Applications/Example/Example.app"
  let app = AppUsage(
    id: path, name: "Example", bundlePath: path, bundleID: "com.example.suite", pids: [97],
    processCount: 1, memory: 1 << 20, cpu: .value(0), diskBytesPerSecond: .value(0), inside: [])
  let prefix = GuideMatch.pathPrefix("/Applications/Example/")
  #expect(!canQuit(app, from: path, guide: guide(prefix, kind: .app, quittable: false)))
  #expect(canQuit(app, from: path, guide: guide(prefix, kind: .app, quittable: true)))
}

/// R90: Quit acts on the app itself, never a helper: the first regular app among the row's PIDs,
/// even when an accessory helper is older; else an accessory app whose bundle is the row's own,
/// a menu-bar app; else nothing.
@MainActor @Test func theQuitTargetIsTheAppNeverAHelper() {
  let bundle = "/Applications/Example.app"
  let row = AppUsage(
    id: bundle, name: "Example", bundlePath: bundle, bundleID: "com.example.app",
    pids: [503, 501, 502], processCount: 3, memory: 1 << 20, cpu: .value(0),
    diskBytesPerSecond: .value(0), inside: [])
  let helper = FakeApp(
    pid: 501, bundlePath: "\(bundle)/Contents/Helpers/Example Helper.app", policy: .accessory)
  let main = FakeApp(pid: 502, bundlePath: bundle)
  let background = FakeApp(pid: 503, bundlePath: bundle, policy: .prohibited)
  func target(_ apps: [FakeApp]) -> (any QuitTarget)? {
    QuitEligibility.target(
      for: row, in: FakeRunningApps(apps).runningApps, uid: getuid(), guide: .empty)
  }
  #expect(target([helper, main, background]) === main)
  let menuBar = FakeApp(pid: 502, bundlePath: bundle, policy: .accessory)
  #expect(target([helper, menuBar, background]) === menuBar)
  #expect(target([helper, background]) == nil)
}
