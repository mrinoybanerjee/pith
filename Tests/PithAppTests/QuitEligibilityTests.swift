import AppKit
import PithTestSupport
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
      quittable: quittable, source: kind == .system ? "man:example(8)" : nil, programsInside: nil)
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

/// A row for the app at `bundlePath`, holding `pids`.
private func row(_ bundlePath: String, _ bundleID: String, pids: [Int32]) -> AppUsage {
  AppUsage(
    id: bundlePath, name: "Example", bundlePath: bundlePath, bundleID: bundleID, pids: pids,
    processCount: pids.count, memory: 1 << 20, cpu: .value(0), diskBytesPerSecond: .value(0),
    inside: [])
}

/// The target for `row` among `apps`.
@MainActor private func target(_ row: AppUsage, _ apps: [FakeApp]) -> (any QuitTarget)? {
  QuitEligibility.target(
    for: row, in: FakeRunningApps(apps).runningApps, uid: getuid(), guide: .empty)
}

/// R90 and R100: Quit acts on the row's own app, never a helper: the regular app whose bundle is
/// the row's, even when an accessory helper comes first; an accessory app whose bundle is the
/// row's, a menu-bar app; and nothing when only a helper or a background process is left.
@MainActor @Test func theQuitTargetIsTheAppNeverAHelper() {
  let bundle = "/Applications/Example.app"
  let example = row(bundle, "com.example.app", pids: [503, 501, 502])
  let helper = FakeApp(
    pid: 501, bundlePath: "\(bundle)/Contents/Helpers/Example Helper.app",
    bundleID: "com.example.app.helper", policy: .accessory)
  let main = FakeApp(pid: 502, bundlePath: bundle, bundleID: "com.example.app")
  let background = FakeApp(
    pid: 503, bundlePath: bundle, bundleID: "com.example.app", policy: .prohibited)
  #expect(target(example, [helper, main, background]) === main)
  let menuBar = FakeApp(
    pid: 502, bundlePath: bundle, bundleID: "com.example.app", policy: .accessory)
  #expect(target(example, [helper, menuBar, background]) === menuBar)
  #expect(target(example, [helper, background]) == nil)
}

/// R100: a row can hold another bundle's app, such as one started from Terminal. Terminal's row
/// quits Terminal, whatever the PID order, and a row whose only app is another bundle's has no
/// Quit.
@MainActor @Test func theQuitTargetIsTheRowsOwnAppNotOneItHolds() {
  let path = "/System/Applications/Utilities/Terminal.app"
  let started = { (pid: Int32) in
    FakeApp(pid: pid, bundlePath: "/Applications/Started.app", bundleID: "com.example.started")
  }
  let terminal = FakeApp(pid: 600, bundlePath: path, bundleID: "com.apple.Terminal")
  let orders: [([Int32], FakeApp)] = [([600, 601], started(601)), ([599, 600], started(599))]
  for (pids, child) in orders {
    #expect(target(row(path, "com.apple.Terminal", pids: pids), [terminal, child]) === terminal)
  }
  #expect(target(row(path, "com.apple.Terminal", pids: [601]), [started(601)]) == nil)
}

/// R100 and R125: Chromium's main process can run from its code-sign clone, outside the row's
/// bundle. With no bundle match, the one regular app with the row's bundle ID that runs from a
/// clone is the target; another installation with that ID does not count, and two clones give no
/// target, as Pith cannot tell which the row means.
@MainActor @Test func aBundleIDMatchIsTheTargetOnlyWhenItIsTheOnlyOne() {
  let chrome = row("/Applications/Google Chrome.app", "com.google.Chrome", pids: [410, 411, 412])
  let clone = FakeApp(
    pid: 410,
    bundlePath: "/private/var/folders/xy/T/code_sign_clone.aB3dE9/Google Chrome.app.bundle",
    bundleID: "com.google.Chrome")
  let helper = FakeApp(
    pid: 411, bundlePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app",
    bundleID: "com.google.Chrome.helper", policy: .accessory)
  #expect(target(chrome, [clone, helper]) === clone)
  let other = FakeApp(
    pid: 412, bundlePath: "/Users/Shared/Google Chrome.app", bundleID: "com.google.Chrome")
  #expect(target(chrome, [clone, helper, other]) === clone)
  let secondClone = FakeApp(
    pid: 412,
    bundlePath: "/private/var/folders/xy/T/code_sign_clone.Zz9Yy8/Google Chrome.app.bundle",
    bundleID: "com.google.Chrome")
  #expect(target(chrome, [clone, helper, secondClone]) == nil)
}

/// R125: a row can keep only another installation of its app, one with the same bundle ID that
/// the row's own app started before it ended. That installation is not the row's app, so the row
/// has no Quit.
@MainActor @Test func anotherInstallationWithTheSameBundleIDIsNoTarget() {
  let chrome = row("/Applications/Google Chrome.app", "com.google.Chrome", pids: [412])
  let other = FakeApp(
    pid: 412, bundlePath: "/Users/Shared/Google Chrome.app", bundleID: "com.google.Chrome")
  #expect(target(chrome, [other]) == nil)
}

/// R100: the bundle paths are compared with their symlinks resolved on both sides, so an app that
/// runs through a symlinked folder still matches its row, and so does a row read through one.
@MainActor @Test func aSymlinkedInstallStillMatchesItsRow() throws {
  let base = FileManager.default.temporaryDirectory.appending(path: "pith.tests.symlinked")
  defer { try? FileManager.default.removeItem(at: base) }
  try? FileManager.default.removeItem(at: base)
  let real = base.appending(path: "Real/Example.app")
  try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    at: base.appending(path: "Linked"), withDestinationURL: base.appending(path: "Real"))
  let linkedPath = base.appending(path: "Linked/Example.app").path
  let linked = FakeApp(pid: 700, bundlePath: linkedPath, bundleID: "com.example.other")
  #expect(target(row(real.path, "com.example.app", pids: [700]), [linked]) === linked)
  let direct = FakeApp(pid: 701, bundlePath: real.path, bundleID: "com.example.other")
  #expect(target(row(linkedPath, "com.example.app", pids: [701]), [direct]) === direct)
}

/// R103: Pith cannot tell which of two path matches the row means (an app opened twice), so there
/// is no Quit. The bundle-ID rule counts regular apps only, so an accessory app with the row's
/// bundle ID, outside the row's bundle, is no target either.
@MainActor @Test func twoPathMatchesOrAnAccessoryIDMatchGiveNoTarget() {
  let bundle = "/Applications/Example.app"
  let example = row(bundle, "com.example.app", pids: [801, 802])
  let first = FakeApp(pid: 801, bundlePath: bundle, bundleID: "com.example.app")
  let second = FakeApp(pid: 802, bundlePath: bundle, bundleID: "com.example.app")
  #expect(target(example, [first, second]) == nil)
  let accessory = FakeApp(
    pid: 801, bundlePath: "/Applications/Other/Example.app", bundleID: "com.example.app",
    policy: .accessory)
  #expect(target(example, [accessory]) == nil)
}

/// R104: the `/System/Library/` guard reads the target's path with its symlinks resolved, as the
/// match does, so an app reached through a symlink into `/System/Library/` has no Quit.
@MainActor @Test func anAppLinkedIntoSystemLibraryCannotQuit() throws {
  let base = FileManager.default.temporaryDirectory.appending(path: "pith.tests.systemlinked")
  defer { try? FileManager.default.removeItem(at: base) }
  try? FileManager.default.removeItem(at: base)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  let real = "/System/Library/CoreServices/Finder.app"
  let link = base.appending(path: "Example.app")
  try FileManager.default.createSymbolicLink(
    at: link, withDestinationURL: URL(fileURLWithPath: real))
  let app = FakeApp(pid: 900, bundlePath: link.path, bundleID: "com.example.agent")
  #expect(target(row(real, "com.example.agent", pids: [900]), [app]) == nil)
}
