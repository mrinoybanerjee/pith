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

  /// The process that Quit acts on for `app`, when Pith may quit it. It is the app itself, never a
  /// helper (R90): the first `.regular` app among the row's PIDs, oldest first; else an
  /// `.accessory` one whose bundle is the row's own, a menu-bar app.
  @MainActor static func target(
    for app: AppUsage, in apps: RunningApps, uid: UInt32, guide: Guide
  ) -> (any QuitTarget)? {
    func eligible(_ target: any QuitTarget) -> (any QuitTarget)? {
      guard let path = target.bundleURL?.path, let owner = apps.ownerUID(target.processIdentifier)
      else { return nil }
      let running = RunningAppInfo(pid: target.processIdentifier, bundlePath: path, ownerUID: owner)
      return canQuit(app, running: running, uid: uid, guide: guide) ? target : nil
    }
    var menuBarApp: (any QuitTarget)?
    for pid in app.pids.sorted() {
      guard let candidate = apps.app(pid) else { continue }
      if candidate.activationPolicy == .regular { return eligible(candidate) }
      if menuBarApp == nil, candidate.activationPolicy == .accessory,
        candidate.bundleURL?.path == app.bundlePath
      {
        menuBarApp = candidate
      }
    }
    return menuBarApp.flatMap(eligible)
  }
}

/// What Quit asks of macOS (spec 4.5): `NSRunningApplication` in the app, stand-ins in tests,
/// which never quit a real app.
struct RunningApps {
  static let live = RunningApps(
    app: { NSRunningApplication(processIdentifier: $0) },
    ownerUID: { ProcessProbe.live.bsdInfo($0)?.uid },
    nextCheck: { try await Task.sleep(for: .seconds(1)) },
    quitPith: { NSApplication.shared.terminate(nil) })

  /// The app that macOS runs as a PID, if any.
  let app: @MainActor @Sendable (Int32) -> (any QuitTarget)?
  let ownerUID: @MainActor @Sendable (Int32) -> UInt32?
  /// Returns at the next check of an app that is quitting, 1 s on (R97).
  let nextCheck: @MainActor @Sendable () async throws -> Void
  /// Quits Pith itself (R91).
  let quitPith: @MainActor @Sendable () -> Void
}
