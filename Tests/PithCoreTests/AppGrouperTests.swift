import Darwin
import Testing
import os

@testable import PithCore

/// Groups a fixture with every process responsible for itself, the usual answer.
private func grouped(_ fixture: String) -> [ProcessKey: AppIdentity] {
  var a = AppGrouper(responsible: { $0 }, bundleInfo: Fixture.bundleInfo)
  return a.assign(Fixture.table(fixture))
}

private func key(_ pid: Int32) -> ProcessKey { ProcessKey(pid: pid, startTime: 1_000) }

@Test func helpersFoldIntoOutermostApp() {
  #expect(
    AppGrouper.enclosingAppPath(
      "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    ) == "/Applications/Google Chrome.app")
  #expect(AppGrouper.enclosingAppPath("/opt/homebrew/bin/node") == nil)
  #expect(AppGrouper.enclosingAppPath("") == nil)  // the path could not be read
}

@Test func chromeIsOneApp() {
  #expect(Set(grouped("chrome").values.map(\.id)) == ["com.google.Chrome"])
}

@Test func xcodeXPCServicesFoldIntoXcode() {
  #expect(Set(grouped("xcode").values.map(\.name)) == ["Xcode"])
}

@Test func cliToolsJoinTheirParentApp() {
  let g = grouped("node-under-terminal-and-codex")
  #expect(g[key(201)]?.name == "Terminal")  // node → zsh → Terminal
  #expect(g[key(301)]?.name == "Codex")  // node → Codex
}

@Test func responsibleProcessWins() {
  var a = AppGrouper(responsible: { $0 == 401 ? 400 : nil }, bundleInfo: Fixture.bundleInfo)
  #expect(a.assign(Fixture.table("responsible"))[key(401)]?.name == "Claude")
}

@Test func orphanCLIStandsAlone() {  // python3 → zsh → a root process outside the table
  #expect(grouped("orphan")[key(501)]?.id == "proc:python3")
}

@Test func reusedPIDIsRegrouped() {
  var a = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  _ = a.assign(Fixture.table("reuse-before"))
  let after = a.assign(Fixture.table("reuse-after"))
  #expect(after[ProcessKey(pid: 77, startTime: 2_000)]?.name == "Slack")
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
  #expect(g[key(602)] == AppIdentity(id: "proc:gone", name: "gone", bundlePath: nil))
}

@Test func parentChainStopsAfterFiveLevels() {
  let g = grouped("deep-chain")
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
  let t = LibprocProcessTable().readTable()
  let me = try #require(t.samples.first { $0.key.pid == getpid() })
  let g = a.assign(t)
  #expect(g[me.key] != nil && g.count == t.samples.count && a.quality == .full)
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
