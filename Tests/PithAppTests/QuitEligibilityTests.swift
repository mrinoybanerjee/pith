import Darwin
import PithCore
import Testing

@testable import Pith

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
  #expect(
    !canQuit(
      .fake(id: "proc:WindowServer", pids: [60]), pid: 60, path: "/Applications/WindowServer.app"))
  // The bundle ID's entry wins over the name's.
  let renamed = AppUsage(
    id: "/Applications/Google Chrome.app", name: "WindowServer", bundlePath: nil,
    bundleID: "com.google.Chrome", pids: [300], processCount: 1, memory: 1 << 20,
    cpu: .value(0), diskBytesPerSecond: .value(0), inside: [])
  #expect(canQuit(renamed, pid: 300, path: "/Applications/Google Chrome.app"))
  let pith = getpid()
  #expect(
    !canQuit(.fake(id: "com.mrinoy.pith", pids: [pith]), pid: pith, path: "/Applications/Pith.app"))
}
