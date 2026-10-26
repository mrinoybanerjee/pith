import Darwin
import Foundation
import Testing
import os

@testable import PithCore

/// Who each fixture process names as responsible, as macOS reports it: an app names itself, and
/// its helpers and the shells it opens name the app (on the mini, all 41 Chrome helpers name the
/// main process). A PID that is not listed gets nil.
private let responsibleFor: [String: [Int32: Int32]] = [
  "chrome": [100: 100, 101: 100, 102: 100, 103: 100, 104: 100, 105: 100],
  "clone-two-installs": [100: 100, 101: 100, 102: 102, 103: 103],
  "clone-native-host": [100: 100, 101: 100, 102: 100],
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

/// The code-sign clones that Chrome main processes run from in the fixtures.
private let clonePaths = [
  "/private/var/folders/xx/T/code_sign_clone.AbC123/Google Chrome.app.bundle",
  "/private/var/folders/xx/T/code_sign_clone.DeF456/Google Chrome.app.bundle",
]

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
  let chrome = AppIdentity(
    id: "/Applications/Google Chrome.app", name: "Google Chrome",
    bundlePath: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome",
    executable: "Google Chrome")
  // The main process runs from a temporary code-sign clone, so it adopts the one installation.
  for g in [grouped("chrome"), grouped("chrome", limited: true)] {
    #expect(g.count == 6 && g.values.allSatisfy { $0 == chrome })
  }
}

@Test func cloneJoinsOnlyASingleInstallation() {  // R52
  let clone = AppIdentity(
    id: "clone:\(clonePaths[0])", name: "Google Chrome", bundlePath: nil,
    bundleID: "com.google.Chrome", executable: "Google Chrome")
  let chrome = Fixture.table("chrome")
  let alone = ProcessTable(samples: [chrome.samples[0]], takenAtNs: 0, vanished: 0)
  var a = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  // The cache keeps the clone, so it joins and leaves its installation as the table changes.
  #expect(a.assign(alone)[key(100)] == clone)
  #expect(a.assign(chrome)[key(100)]?.id == "/Applications/Google Chrome.app")
  #expect(a.assign(alone)[key(100)] == clone)
  // Chrome in two places: the clone joins the one that holds its own helper, 101 (R156).
  let two = a.assign(Fixture.table("clone-two-installs"))
  #expect(two[key(100)]?.id == "/Applications/Google Chrome.app")
  #expect(two[key(102)]?.id == "/Volumes/Demo/Google Chrome.app")
}

@Test func clonesOfTwoInstallationsStayApart() {  // R53 and R156: they never share one app
  // 100 joins the installation of its own helper; 103 has none, so it keeps its clone's path.
  let g = grouped("clone-two-installs")
  #expect(
    [g[key(100)]?.id, g[key(103)]?.id] == [
      "/Applications/Google Chrome.app", "clone:\(clonePaths[1])",
    ])
}

@Test func clonesWithNoHelpersOfTheirOwnStayApart() {  // R156
  // Without helper 101 neither clone has a child process, so neither joins the one installation
  // left in the table, /Volumes/Demo/Google Chrome.app.
  let map = responsibleFor["clone-two-installs"]!
  var a = AppGrouper(responsible: { map[$0] }, bundleInfo: Fixture.bundleInfo)
  let t = Fixture.table("clone-two-installs")
  let g = a.assign(
    ProcessTable(samples: t.samples.filter { $0.key.pid != 101 }, takenAtNs: 0, vanished: 0))
  #expect([g[key(100)]?.id, g[key(103)]?.id] == clonePaths.map { "clone:\($0)" })
  #expect(g[key(102)]?.id == "/Volumes/Demo/Google Chrome.app")
}

@Test func aCloneJoinsWithAllItsProcesses() {  // R162
  // 102 is an unbundled child of the clone with no child of its own; it follows its clone.
  for limited in [false, true] {
    let g = grouped("clone-native-host", limited: limited)
    #expect(g.count == 3 && Set(g.values.map(\.id)) == ["/Applications/Google Chrome.app"])
  }
}

@Test func helperOfAnUnjoinedCloneKeepsItsInstallation() {  // step 1 skips the clone owner
  #expect(grouped("clone-two-installs")[key(101)]?.id == "/Applications/Google Chrome.app")
}

@Test func cloneJoinsNoInstallationOfAnotherApp() {  // Notes is the only installation in the table
  let clone = Fixture.table("chrome").samples[0]
  let notes = Fixture.table("same-name").samples[0]
  var a = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  let g = a.assign(ProcessTable(samples: [clone, notes], takenAtNs: 0, vanished: 0))
  #expect(g[clone.key]?.id == "clone:\(clonePaths[0])")
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

@Test func anAssignmentThatMissedAProcessIsGroupedAgain() {  // R157
  // The responsible owner is not in the first table, then it is.
  var a = AppGrouper(responsible: { $0 == 401 ? 400 : nil }, bundleInfo: Fixture.bundleInfo)
  let t = Fixture.table("responsible")
  let agent = ProcessTable(
    samples: t.samples.filter { $0.key.pid == 401 }, takenAtNs: 0, vanished: 0)
  #expect(a.assign(agent)[key(401)]?.name == "Example Agent")
  #expect(a.assign(t)[key(401)]?.name == "Claude")
  // Without the call, node's parent Codex is not in the first table, then it is.
  var limited = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  let codex = Fixture.table("node-under-terminal-and-codex")
  let node = ProcessTable(
    samples: codex.samples.filter { $0.key.pid == 301 }, takenAtNs: 0, vanished: 0)
  #expect(limited.assign(node)[key(301)]?.id == "proc:node")
  #expect(limited.assign(codex)[key(301)]?.name == "Codex")
}

@Test func responsibleStepFallsThrough() {
  let g = grouped("precedence")
  #expect(g[key(303)]?.id == "/Applications/Slack.app")  // its responsible PID is not in the table
  #expect(g[key(304)]?.id == "/Applications/Codex.app")  // its responsible process has no app
}

@Test func reusedResponsiblePIDIsIgnored() {  // 307 started after 306, so it reuses the PID
  #expect(grouped("precedence")[key(306)]?.id == "proc:node")
}

@Test func ownAppBeatsParentApp() {
  #expect(grouped("precedence", limited: true)[key(302)]?.id == "/System/Applications/Preview.app")
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
  #expect(after[ProcessKey(pid: 77, startTime: 2_000)]?.id == "/Applications/Slack.app")
}

@Test func execIsRegrouped() {  // an exec keeps the PID and start time: an SSH shell runs Python
  let shell = Fixture.table("orphan").samples[0]  // zsh, ID version 0
  let python = ProcessSample(
    key: shell.key, parent: shell.parent, uniqueID: shell.uniqueID,
    parentUniqueID: shell.parentUniqueID, uid: 501, name: "python3", path: "/usr/bin/python3",
    idVersion: 1, footprint: 1, cpuTimeNs: 0, diskRead: 0, diskWritten: 0)
  var a = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  let ids = [shell, python].map {
    a.assign(ProcessTable(samples: [$0], takenAtNs: 0, vanished: 0))[$0.key]?.id
  }
  #expect(ids == ["proc:zsh", "proc:python3"])
}

@Test func aReusedParentPIDIsNotFollowed() {  // R151
  // The tool's parent exited, and a newer Slack took its PID. Slack's unique ID is not the tool's
  // parent's, so the walk stops at that edge and the tool stands alone.
  let slack = ProcessSample(
    key: ProcessKey(pid: 600, startTime: 5_000), parent: 1, uniqueID: 5_600, parentUniqueID: 1,
    uid: 501, name: "Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack", idVersion: 0,
    footprint: 1, cpuTimeNs: 0, diskRead: 0, diskWritten: 0)
  let tool = ProcessSample(
    key: ProcessKey(pid: 601, startTime: 1_000), parent: 600, uniqueID: 1_601,
    parentUniqueID: 1_600, uid: 501, name: "example-tool", path: "/usr/local/bin/example-tool",
    idVersion: 0, footprint: 1, cpuTimeNs: 0, diskRead: 0, diskWritten: 0)
  var a = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  let groups = a.assign(ProcessTable(samples: [slack, tool], takenAtNs: 0, vanished: 0))
  #expect(groups[tool.key]?.id == "proc:example-tool")
}

@Test func sameNameDifferentPathsStayApart() {  // Review Focus 4 and R52
  // /Applications/Notes.app and /Volumes/Demo/Notes.app, both com.example.Notes
  let g = grouped("same-name")
  #expect(Set(g.values.map(\.id)).count == 2)
  #expect(
    g[key(81)]
      == AppIdentity(
        id: "/Volumes/Demo/Notes.app", name: "Notes", bundlePath: "/Volumes/Demo/Notes.app",
        bundleID: "com.example.Notes", executable: "Notes"))
}

@Test func aBundleThatCannotBeReadIsReadAgainOnTheNextTable() {  // R168 and R157
  let reads = OSAllocatedUnfairLock(initialState: 0)
  var a = AppGrouper(
    responsible: nil,
    bundleInfo: { path in
      let read = reads.withLock { n -> Int in
        n += 1
        return n
      }
      return read == 1 ? nil : Fixture.bundleInfo(path)  // an app in the middle of an update
    })
  let notes = Fixture.table("same-name").samples[0]
  let t = ProcessTable(samples: [notes], takenAtNs: 0, vanished: 0)
  #expect(a.assign(t)[notes.key]?.bundleID == nil)
  #expect(a.assign(t)[notes.key]?.bundleID == "com.example.Notes")
}

@Test func aGroupingIsKeptOnlyOnceTwoTablesHaveItsPath() {  // R175 (a)
  // A new exec's first path can be its old one: the key is grouped again on the next table.
  let notes = Fixture.table("same-name").samples[0]
  let slack = ProcessSample(
    key: notes.key, parent: notes.parent, uniqueID: notes.uniqueID,
    parentUniqueID: notes.parentUniqueID, uid: notes.uid, name: "Slack",
    path: "/Applications/Slack.app/Contents/MacOS/Slack", idVersion: notes.idVersion,
    footprint: 1, cpuTimeNs: 0, diskRead: 0, diskWritten: 0)
  var a = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  let ids = [notes, slack, slack].map {
    a.assign(ProcessTable(samples: [$0], takenAtNs: 0, vanished: 0))[$0.key]?.id
  }
  #expect(ids == ["/Applications/Notes.app", "/Applications/Slack.app", "/Applications/Slack.app"])
}

/// R175 (b, c): the bundle reader reads `Contents/Info.plist` itself. An unreadable bundle is read
/// again on the next call, as `Bundle(path:)` would keep it unreadable for the process's life, and
/// a bundle without a bundle ID still counts as read.
@Test func theBundleReaderReadsInfoPlistEachTime() throws {
  let app = FileManager.default.temporaryDirectory.appending(path: "pith-\(UUID()).app")
  defer { try? FileManager.default.removeItem(at: app) }
  let contents = app.appending(path: "Contents")
  try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
  #expect(AppGrouper.readBundle(app.path) == nil)  // no Info.plist yet, as in an update
  var plist: [String: String] = ["CFBundleName": "Example Tool", "CFBundleExecutable": "tool"]
  func write() throws {
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appending(path: "Info.plist"))
  }
  try write()
  let read = try #require(AppGrouper.readBundle(app.path))
  #expect(read.bundleID == nil && read.name == "Example Tool" && read.executable == "tool")
  plist["CFBundleIdentifier"] = "com.example.tool"
  try write()
  #expect(AppGrouper.readBundle(app.path)?.bundleID == "com.example.tool")
}

/// A flat bundle, such as the inner Wrapper/*.app of an iPhone or iPad app on a Mac, keeps its
/// Info.plist at the top.
@Test func theBundleReaderReadsAFlatBundle() throws {
  let app = FileManager.default.temporaryDirectory.appending(path: "pith-\(UUID()).app")
  defer { try? FileManager.default.removeItem(at: app) }
  try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
  let plist = ["CFBundleIdentifier": "com.example.flat", "CFBundleName": "Example Flat"]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: app.appending(path: "Info.plist"))
  let read = try #require(AppGrouper.readBundle(app.path))
  #expect(read.bundleID == "com.example.flat" && read.name == "Example Flat")
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
  #expect(
    g[key(602)]
      == AppIdentity(
        id: "proc:gone", name: "gone", bundlePath: nil, bundleID: nil, executable: nil))
  // A clone with no readable bundle is no app, so its temporary path never becomes an id.
  #expect(
    g[key(603)]
      == AppIdentity(
        id: "proc:Brave Browser", name: "Brave Browser", bundlePath: nil, bundleID: nil,
        executable: nil))
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
    key: ProcessKey(pid: 99_999, startTime: 1), parent: 1, uniqueID: 100_000, parentUniqueID: 1,
    uid: 501, name: "Finder",
    path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
    idVersion: 0, footprint: 1, cpuTimeNs: 0, diskRead: 0, diskWritten: 0)
  #expect(
    a.assign(ProcessTable(samples: [finder], takenAtNs: 0, vanished: 0))[finder.key]
      == AppIdentity(
        id: "/System/Library/CoreServices/Finder.app", name: "Finder",
        bundlePath: "/System/Library/CoreServices/Finder.app", bundleID: "com.apple.finder",
        executable: "Finder"))
}

/// R125: a code-sign clone is a `code_sign_clone.<suffix>` folder, then an `<App>.app.bundle` in it.
@Test func aCodeSignCloneNeedsBothItsFolderAndItsBundle() {
  let clone = "/private/var/folders/xx/T/code_sign_clone.AbC123/Google Chrome.app.bundle"
  #expect(AppGrouper.isCodeSignClone(clone))
  #expect(AppGrouper.isCodeSignClone(clone + "/Contents/MacOS/Google Chrome"))
  for other in [
    "/Applications/Google Chrome.app", "/Users/Shared/Example.app.bundle",
    "/private/var/folders/xx/T/code_sign_clone.AbC123/Google Chrome.app",
    "/private/var/folders/xx/T/code_sign_clone./Google Chrome.app.bundle",
    "/private/var/folders/xx/T/code_sign_clone.AbC123/x/Google Chrome.app.bundle",
  ] {
    #expect(!AppGrouper.isCodeSignClone(other), "\(other)")
  }
}
