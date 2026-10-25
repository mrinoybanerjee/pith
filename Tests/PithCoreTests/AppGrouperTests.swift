import Darwin
import Testing
import os

@testable import PithCore

/// Who each fixture process names as responsible, as macOS reports it: an app names itself, and
/// its helpers and the shells it opens name the app (on the mini, all 41 Chrome helpers name the
/// main process). A PID that is not listed gets nil.
private let responsibleFor: [String: [Int32: Int32]] = [
  "chrome": [100: 100, 101: 100, 102: 100, 103: 100, 104: 100, 105: 100],
  "xcode": [200: 200, 201: 200, 202: 200, 203: 200],
  "node-under-terminal-and-codex": [200: 200, 202: 200, 201: 200, 300: 300, 301: 300],
  "orphan": [502: 590, 501: 590, 503: 503],  // 590: a root SSH session, not in the table
  "same-name": [80: 80, 81: 81],
  "unreadable-path": [600: 600, 601: 600, 602: 602, 603: 603],
  "nested-app": [200: 200, 201: 200, 210: 210, 211: 210],
  "precedence": [300: 300, 302: 300, 303: 999, 304: 305, 305: 305, 306: 307, 307: 307],
]

/// Groups a fixture with its responsible map, or in `.limited` mode without the call.
private func grouped(_ fixture: String, limited: Bool = false) -> [ProcessKey: AppIdentity] {
  let map = responsibleFor[fixture]
  let responsible: (@Sendable (Int32) -> Int32?)? = { map![$0] }
  var a = AppGrouper(responsible: limited ? nil : responsible, bundleInfo: Fixture.bundleInfo)
  return a.assign(Fixture.table(fixture))
}

private func key(_ pid: Int32) -> ProcessKey { ProcessKey(pid: pid, startTime: 1_000) }

@Test func helpersFoldIntoOutermostApp() {
  #expect(
    AppGrouper.enclosingAppPath(
      "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    ) == "/Applications/Google Chrome.app")
  #expect(AppGrouper.enclosingAppPath("/opt/homebrew/bin/node") == nil)
}

@Test func enclosingAppPathMatchesWholeBundleNames() {
  #expect(AppGrouper.enclosingAppPath("") == nil)  // the path could not be read
  #expect(AppGrouper.enclosingAppPath("/x/.app/y") == nil)  // no name before ".app"
  #expect(AppGrouper.enclosingAppPath("/opt/my.apps/bin/tool") == nil)
  #expect(AppGrouper.enclosingAppPath("/Applications/Foo.app") == "/Applications/Foo.app")
  #expect(
    AppGrouper.enclosingAppPath(
      "/private/var/folders/xx/T/code_sign_clone.AbC123/Google Chrome.app.bundle/Contents/MacOS/Google Chrome"
    ) == "/private/var/folders/xx/T/code_sign_clone.AbC123/Google Chrome.app.bundle")
}

@Test func chromeIsOneApp() {
  let g = grouped("chrome")
  #expect(Set(g.values.map(\.id)) == ["com.google.Chrome"])
  #expect(Set((101...105).map { g[key($0)]?.bundlePath }) == ["/Applications/Google Chrome.app"])
  // The main process runs from a temporary code-sign clone, so it joins by bundle ID, pathless.
  #expect(
    g[key(100)] == AppIdentity(id: "com.google.Chrome", name: "Google Chrome", bundlePath: nil))
}

@Test func xcodeXPCServicesFoldIntoXcode() {
  #expect(Set(grouped("xcode").values.map(\.name)) == ["Xcode"])
}

@Test func cliToolsJoinTheirParentApp() {
  let g = grouped("node-under-terminal-and-codex")
  #expect(g[key(201)]?.name == "Terminal")  // node → zsh → login → Terminal
  #expect(g[key(301)]?.name == "Codex")  // node → Codex
  // Without the call, the chain stops at the root `login`, which is not in the table (R30).
  let limited = grouped("node-under-terminal-and-codex", limited: true)
  #expect(limited[key(201)]?.id == "proc:node")
  #expect(limited[key(301)]?.name == "Codex")
}

@Test func responsibleProcessWins() {
  var a = AppGrouper(responsible: { $0 == 401 ? 400 : nil }, bundleInfo: Fixture.bundleInfo)
  #expect(a.assign(Fixture.table("responsible"))[key(401)]?.name == "Claude")
}

@Test func responsibleStepFallsThrough() {
  let g = grouped("precedence")
  #expect(g[key(303)]?.id == "com.example.Slack")  // its responsible PID is not in the table
  #expect(g[key(304)]?.id == "com.example.Codex")  // its responsible process has no app
}

@Test func reusedResponsiblePIDIsIgnored() {  // 307 started after 306, so it reuses the PID
  #expect(grouped("precedence")[key(306)]?.id == "proc:node")
}

@Test func ownAppBeatsParentApp() {
  #expect(grouped("precedence", limited: true)[key(302)]?.id == "com.apple.Preview")
}

@Test func selfResponsibleNestedAppStandsAlone() {  // R28
  let g = grouped("nested-app")
  #expect(g[key(210)]?.name == "Simulator")
  #expect(g[key(211)]?.name == "Simulator")  // its host is Simulator
  #expect(g[key(201)]?.name == "Xcode")
  #expect(grouped("nested-app", limited: true)[key(210)]?.name == "Xcode")
}

@Test func orphanCLIStandsAlone() {  // python3 → zsh → a root process outside the table
  let g = grouped("orphan")
  #expect(g[key(501)]?.id == "proc:python3")
  #expect(g[key(503)]?.id == "proc:example-long-tool-name")  // not the 16-character kernel name
}

@Test func reusedPIDIsRegrouped() {
  var a = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  _ = a.assign(Fixture.table("reuse-before"))
  let after = a.assign(Fixture.table("reuse-after"))
  #expect(after[ProcessKey(pid: 77, startTime: 2_000)]?.id == "com.example.Slack")
}

@Test func sameNameDifferentPathsStayApart() {  // Review Focus 4
  let g = grouped("same-name")  // /Applications/Notes.app and /Volumes/Demo/Notes.app
  #expect(Set(g.values.map(\.id)).count == 2)
  #expect(
    g[key(81)]
      == AppIdentity(
        id: "/Volumes/Demo/Notes.app", name: "Notes", bundlePath: "/Volumes/Demo/Notes.app"))
}

@Test func missingResponsibilityCallIsLimited() {
  var a = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  _ = a.assign(Fixture.table("chrome"))
  #expect(a.quality == .limited)
  #expect(AppGrouper(responsible: { $0 }, bundleInfo: Fixture.bundleInfo).quality == .full)
}

@Test func unreadablePathGroupsByParentOrStandsAlone() {
  let g = grouped("unreadable-path")
  #expect(g[key(601)]?.name == "Slack")
  #expect(grouped("unreadable-path", limited: true)[key(601)]?.name == "Slack")
  #expect(g[key(602)] == AppIdentity(id: "proc:gone", name: "gone", bundlePath: nil))
  // A clone with no readable bundle is no app, so its temporary path never becomes an id.
  #expect(
    g[key(603)] == AppIdentity(id: "proc:Brave Browser", name: "Brave Browser", bundlePath: nil))
}

@Test func parentChainStopsAfterFiveLevels() {
  let g = grouped("deep-chain", limited: true)
  #expect(g[key(705)]?.name == "Codex")  // Codex is its fifth parent
  #expect(g[key(706)]?.id == "proc:python3")  // and the sixth of this one
}

@Test func groupsAreCachedByKeyAndEvictedWhenGone() {
  let asked = OSAllocatedUnfairLock(initialState: [Int32]())
  var a = AppGrouper(
    responsible: { pid in
      asked.withLock { $0.append(pid) }
      return nil
    }, bundleInfo: Fixture.bundleInfo)
  let t = Fixture.table("same-name")
  _ = a.assign(t)
  _ = a.assign(t)  // both groups come from the cache
  _ = a.assign(ProcessTable(samples: [t.samples[0]], takenAtNs: 2, vanished: 0))  // 81 is evicted
  #expect(a.assign(t).count == 2)  // so it is grouped again
  #expect(asked.withLock { $0 } == [80, 81, 81])
}

@Test func liveGrouperGroupsRealProcessesAndReadsBundles() throws {
  var a = AppGrouper.live()
  #expect(a.quality == .full)  // the responsibility call resolves on this macOS
  let t = LibprocProcessTable().readTable()
  let me = try #require(t.samples.first { $0.key.pid == getpid() })
  let runner = try #require(a.assign(t)[me.key])
  #expect(runner.id.count > "proc:".count)
  let finder = ProcessSample(
    key: ProcessKey(pid: 99_999, startTime: 1), parent: 1, uid: 501, name: "Finder",
    path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", footprint: 1,
    cpuTimeNs: 0, diskRead: 0, diskWritten: 0)
  #expect(
    a.assign(ProcessTable(samples: [finder], takenAtNs: 0, vanished: 0))[finder.key]
      == AppIdentity(
        id: "com.apple.finder", name: "Finder",
        bundlePath: "/System/Library/CoreServices/Finder.app"))
}
