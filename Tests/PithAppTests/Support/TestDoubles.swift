import AppKit
import Foundation
import PithCore
import Testing

@testable import Pith

/// The test's own defaults suite, "pith.tests.<test name>" (R70). One fixed name per test keeps the
/// preference files bounded.
func testSuite(_ test: String = #function) -> String {
  "pith.tests.\(test.replacing("()", with: ""))"
}

/// The test's suite, emptied first.
func testDefaults(_ test: String = #function) -> UserDefaults {
  clearDefaults(test)
  return UserDefaults(suiteName: testSuite(test))!
}

func clearDefaults(_ test: String = #function) {
  UserDefaults().removePersistentDomain(forName: testSuite(test))
}

/// The login item and `top` are never real in tests.
extension LoginItem {
  static let stub = LoginItem(isEnabled: { false }, set: { _ in })
}

/// No app is running, so no row offers Quit, and Quit Pith does nothing.
extension RunningApps {
  static let stub = RunningApps(
    running: { _ in [] }, ownerUID: { _ in nil }, exits: NotificationCenter(),
    forceOfferDelay: { try await Task.sleep(for: .seconds(5)) }, quitPith: {})
}

@MainActor func testStore(
  guide: Guide = .empty, loginItem: LoginItem = .stub, runningApps: RunningApps = .stub,
  nowNs: @escaping @MainActor @Sendable () -> UInt64 = { 0 },
  measure: @escaping @Sendable () async throws -> SystemBreakdown = {
    throw SystemDetailsError.failed("no top in tests")
  }
) -> Store {
  Store(
    settings: Settings(), guide: guide, loginItem: loginItem, runningApps: runningApps,
    measureSystem: measure, nowNs: nowNs)
}

/// A running app that a test controls. Each instance records its own calls, so a call that goes
/// to another instance, even one with the same PID, shows (R95). Its `isEqual` is identity.
@MainActor final class FakeApp: NSObject, QuitTarget {
  let processIdentifier: pid_t
  let bundleURL: URL?
  let bundleIdentifier: String?
  let activationPolicy: NSApplication.ActivationPolicy
  var isTerminated = false
  private(set) var terminations = 0
  private(set) var forcedTerminations = 0

  init(
    pid: pid_t, bundlePath: String, bundleID: String?,
    policy: NSApplication.ActivationPolicy = .regular
  ) {
    processIdentifier = pid
    bundleURL = URL(fileURLWithPath: bundlePath)
    bundleIdentifier = bundleID
    activationPolicy = policy
  }

  func terminate() -> Bool {
    terminations += 1
    return true
  }

  func forceTerminate() -> Bool {
    forcedTerminations += 1
    return true
  }
}

/// A wait that the test ends by hand, such as the quit flow's 5 s timer (R111) or a pinned panel's
/// drag check (R106): `fire()` ends each pending wait, `waits` counts the waits begun, each a
/// wakeup of the app, and `waiting` those not ended yet.
@MainActor final class ManualChecks {
  private(set) var waits = 0
  private var pending: [CheckedContinuation<Void, Never>] = []
  var waiting: Int { pending.count }

  func wait() async {
    waits += 1
    await withCheckedContinuation { pending.append($0) }
  }

  /// Ends the pending waits, then lets the app act on them.
  func fire() async {
    let ended = pending
    pending = []
    for continuation in ended { continuation.resume() }
    await settle()
  }
}

/// A notification center that counts the block observers added and not yet removed.
final class CountingCenter: NotificationCenter, @unchecked Sendable {
  private(set) var observers = 0

  override func addObserver(
    forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
    using block: @escaping @Sendable (Notification) -> Void
  ) -> any NSObjectProtocol {
    observers += 1
    return super.addObserver(forName: name, object: obj, queue: queue, using: block)
  }

  override func removeObserver(_ observer: Any) {
    observers -= 1
    super.removeObserver(observer)
  }
}

/// The mouse button that a test holds down or lets go, as a pinned panel's drag check reads it
/// (R106).
@MainActor final class MouseButton {
  var down = false
}

/// Lets the main actor's pending tasks run, such as a timer that has just started.
@MainActor func settle() async {
  for _ in 0..<10 { await Task.yield() }
}

/// The apps that a test runs, by PID, which the test adds, ends and replaces, owned by the user
/// unless `owners` says otherwise. The time is the test's, and so are the 5 s timer and the exit
/// notices. Nothing real is ever quit.
@MainActor final class FakeRunningApps {
  var apps: [pid_t: FakeApp]
  var owners: [pid_t: UInt32] = [:]
  var nowNs: UInt64 = 0
  let timer = ManualChecks()
  let exits = CountingCenter()
  private(set) var pithQuits = 0

  init(_ apps: [FakeApp]) {
    self.apps = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
  }

  var runningApps: RunningApps {
    RunningApps(
      running: { pids in pids.compactMap { self.apps[$0] } },
      ownerUID: { self.owners[$0] ?? getuid() }, exits: exits,
      forceOfferDelay: { await self.timer.wait() }, quitPith: { self.pithQuits += 1 })
  }

  /// `app` ends, and macOS says so, as `NSWorkspace` does.
  func exit(_ app: FakeApp) async {
    app.isTerminated = true
    exits.post(
      name: NSWorkspace.didTerminateApplicationNotification, object: nil,
      userInfo: [NSWorkspace.applicationUserInfoKey: app])
    await settle()
  }

  func store(guide: Guide) -> Store {
    testStore(guide: guide, runningApps: runningApps, nowNs: { self.nowNs })
  }

  /// Moves the time past the 0.4 s that a confirm's default button waits once in view (R93).
  func passTheConfirmGuard() { nowNs += 400_000_000 }
}

/// The main process of the mockups' Google Chrome.
@MainActor func fakeChrome() -> FakeApp {
  FakeApp(pid: 410, bundlePath: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome")
}

extension AppUsage {
  /// A one-process app. An id that is not "proc:" or "clone:" is also its bundle ID, so guide
  /// lookups by bundle ID work, and its bundle is in /Applications. The name is the id's last part.
  static func fake(id: String, pids: [Int32]) -> AppUsage {
    let bundled = !id.hasPrefix("proc:") && !id.hasPrefix("clone:")
    let name = String(id.split(separator: /[.:]/).last!)
    return AppUsage(
      id: id, name: name, bundlePath: bundled ? "/Applications/\(name).app" : nil,
      bundleID: bundled ? id : nil, pids: pids, processCount: pids.count, memory: 100 << 20,
      cpu: .value(0.01), diskBytesPerSecond: .value(0), inside: [])
  }
}

/// A login item that counts registrations and that a test can make refuse every change, or turn
/// off as a user does in System Settings.
@MainActor final class FakeLoginItem {
  var enabled: Bool
  var refuses = false
  private(set) var registrations = 0

  init(enabled: Bool) { self.enabled = enabled }

  var loginItem: LoginItem {
    LoginItem(
      isEnabled: { self.enabled },
      set: { enabled in
        if self.refuses { throw SystemDetailsError.failed("synthetic refusal") }
        if enabled, !self.enabled { self.registrations += 1 }
        self.enabled = enabled
      })
  }
}

/// Stands in for `SystemDetails.measure()`: each call waits until the test releases it.
@MainActor final class HeldMeasurer {
  private(set) var calls = 0
  private var waiting: [CheckedContinuation<SystemBreakdown, any Error>] = []

  func measure() async throws -> SystemBreakdown {
    calls += 1
    return try await withCheckedThrowingContinuation { waiting.append($0) }
  }

  func release(_ result: Result<SystemBreakdown, any Error>) {
    for continuation in waiting { continuation.resume(with: result) }
    waiting = []
  }
}

/// Synthetic `top` results whose items and "Other" match the tight mockup's opened system row.
let systemBreakdown = SystemBreakdown(
  items: [
    SystemItem(
      title: "Spotlight indexing", memory: 420 << 20,
      explanation: "Builds the search index after files change."),
    SystemItem(title: "Window server", memory: 310 << 20, explanation: nil),
    SystemItem(title: "Photos analysis", memory: 180 << 20, explanation: nil),
  ], other: 999 << 20)

/// `snapshot` with other apps, with no CPU or disk rates yet (an open panel's first tick), with
/// another "macOS system" residual, or with other grouping.
func remake(
  _ snapshot: Snapshot, apps: [AppUsage]? = nil, firstTick: Bool = false,
  system: Reading<SystemResidual>? = nil, grouping: GroupingQuality? = nil
) -> Snapshot {
  let t = snapshot.totals
  let rate = Reading<Double>.unavailable("first sample")
  return Snapshot(
    takenAtNs: snapshot.takenAtNs, mode: snapshot.mode,
    totals: SystemTotals(
      memoryUsed: t.memoryUsed, memoryTotal: t.memoryTotal, pressure: t.pressure,
      swapUsed: t.swapUsed, cpuBusy: firstTick ? rate : t.cpuBusy, storageFree: t.storageFree,
      storageTotal: t.storageTotal),
    apps: (apps ?? snapshot.apps).map { a in
      guard firstTick else { return a }
      return AppUsage(
        id: a.id, name: a.name, bundlePath: a.bundlePath, bundleID: a.bundleID, pids: a.pids,
        processCount: a.processCount, memory: a.memory, cpu: rate, diskBytesPerSecond: rate,
        inside: a.inside)
    },
    system: system
      ?? (firstTick
        ? .value(SystemResidual(memory: snapshot.system.value!.memory, cpu: rate))
        : snapshot.system),
    grouping: grouping ?? snapshot.grouping)
}

/// What a closed tick of `snapshot`'s Mac reads: its totals, no apps and no residual.
func closed(_ snapshot: Snapshot) -> Snapshot {
  Snapshot(
    takenAtNs: snapshot.takenAtNs, mode: .closed, totals: snapshot.totals, apps: [],
    system: .unavailable("closed"), grouping: snapshot.grouping)
}
