import AppKit
import PithCore

/// An app's own process as macOS runs it (R77).
struct RunningAppInfo {
  let pid: Int32
  let bundlePath: String
  let ownerUID: UInt32
}

/// A running app that Quit acts on: an `NSRunningApplication` in the app, a fake in tests. Two
/// lookups of one process are equal (`isEqual`); a new launch, even with a reused PID, is not
/// (R95).
@MainActor protocol QuitTarget: NSObjectProtocol {
  var processIdentifier: pid_t { get }
  var bundleURL: URL? { get }
  var bundleIdentifier: String? { get }
  var activationPolicy: NSApplication.ActivationPolicy { get }
  var isTerminated: Bool { get }
  func terminate() -> Bool
  func forceTerminate() -> Bool
}

extension NSRunningApplication: QuitTarget {}

/// Whether an opened row offers Quit (spec 4.5).
enum QuitEligibility {
  /// Only for a bundled app, never a command-line process (R96), and only for its own process,
  /// owned by the user and outside `/System/Library/` (Apple apps in `/System/Applications`, such
  /// as Notes, stay quittable). Not when the guide entry that the row shows calls the app part of
  /// macOS or not quittable (R77), and never for Pith itself (R81).
  static func canQuit(_ app: AppUsage, running: RunningAppInfo?, uid: UInt32, guide: Guide) -> Bool
  {
    guard let running, app.bundlePath != nil, app.pids.contains(running.pid) else { return false }
    let entry = guide.entry(name: app.name, bundleID: app.bundleID, path: app.bundlePath)
    return running.ownerUID == uid && !running.bundlePath.hasPrefix("/System/Library/")
      && running.pid != getpid() && entry.map { $0.kind != .system && $0.quittable } ?? true
  }

  /// The process that Quit acts on for `app`, when Pith may quit it: the row's own app, never a
  /// helper or another app that the row holds, such as one started from Terminal (R90 and R100).
  /// It is the one regular or accessory app whose bundle, symlinks resolved, is the row's;
  /// otherwise the one regular app with the row's bundle ID that runs from a Chromium code-sign
  /// clone (R125). Another installation with the same bundle ID is no target, and two of either
  /// is none: Pith cannot tell which.
  @MainActor static func target(
    for app: AppUsage, in apps: RunningApps, uid: UInt32, guide: Guide
  ) -> (any QuitTarget)? {
    guard let bundlePath = app.bundlePath else { return nil }
    // Each path is resolved once: the match and the `/System/Library/` guard read the same one.
    let candidates = apps.running(app.pids)
      .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
      .map { (target: $0, path: $0.bundleURL?.resolvingSymlinksInPath().path) }
    let own = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
    let byPath = candidates.filter { $0.path == own }
    let byID = candidates.filter {
      $0.target.activationPolicy == .regular && $0.target.bundleIdentifier != nil
        && $0.target.bundleIdentifier == app.bundleID
        && $0.path.map(AppGrouper.isCodeSignClone) == true
    }
    let matches = byPath.isEmpty ? byID : byPath
    guard matches.count == 1, let path = matches[0].path,
      let owner = apps.ownerUID(matches[0].target.processIdentifier)
    else { return nil }
    let running = RunningAppInfo(
      pid: matches[0].target.processIdentifier, bundlePath: path, ownerUID: owner)
    return canQuit(app, running: running, uid: uid, guide: guide) ? matches[0].target : nil
  }
}

/// What Quit asks of macOS (spec 4.5): `NSRunningApplication` in the app, stand-ins in tests,
/// which never quit a real app.
struct RunningApps {
  static let live = RunningApps(
    running: { pids in
      let pids = Set(pids)
      return NSWorkspace.shared.runningApplications.filter { pids.contains($0.processIdentifier) }
    },
    ownerUID: { ProcessProbe.live.bsdInfo($0)?.uid },
    exits: NSWorkspace.shared.notificationCenter,
    // The suspending clock, as the flow's uptime clock, stops while the Mac sleeps.
    forceOfferDelay: { try await Task.sleep(for: .seconds(5), clock: .suspending) },
    quitPith: { NSApplication.shared.terminate(nil) })

  /// No app is running, so no row offers Quit, and Quit Pith does nothing: for tests, and for a
  /// store whose rows must never quit a real app, such as made-up or offscreen ones.
  static let none = RunningApps(
    running: { _ in [] }, ownerUID: { _ in nil }, exits: NotificationCenter(),
    forceOfferDelay: { try await Task.sleep(for: .seconds(5)) }, quitPith: {})

  /// The apps that macOS runs among these PIDs. Live, it reads `runningApplications` once, as
  /// every PID of a row is a candidate (R100); its instances are kept by `NSWorkspace`.
  let running: @MainActor @Sendable ([Int32]) -> [any QuitTarget]
  let ownerUID: @MainActor @Sendable (Int32) -> UInt32?
  /// Posts `didTerminateApplicationNotification` when an app exits (R111).
  let exits: NotificationCenter
  /// Returns once, 5 s after a quit, when Force Quit is offered (R111).
  let forceOfferDelay: @MainActor @Sendable () async throws -> Void
  /// Quits Pith itself (R91).
  let quitPith: @MainActor @Sendable () -> Void
}
