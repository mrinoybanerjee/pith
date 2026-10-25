import AppKit
import PithCore

/// An app's own process as macOS runs it (R77).
struct RunningAppInfo {
  let pid: Int32
  let bundlePath: String
  let ownerUID: UInt32
}

/// Whether an opened row offers Quit (spec 4.5).
enum QuitEligibility {
  /// Only for the app's own process, owned by the user and outside `/System/Library/` (Apple apps
  /// in `/System/Applications`, such as Notes, stay quittable). Not when the guide calls the app
  /// part of macOS or not quittable (R77), and never for Pith itself (R81). A process outside any
  /// app has no `RunningAppInfo`, so it never shows Quit.
  static func canQuit(_ app: AppUsage, running: RunningAppInfo?, uid: UInt32, guide: Guide) -> Bool
  {
    guard let running, app.pids.contains(running.pid) else { return false }
    let entry = guide.entry(name: app.name, bundleID: app.bundleID, path: nil)
    return running.ownerUID == uid && !running.bundlePath.hasPrefix("/System/Library/")
      && running.pid != getpid() && entry.map { $0.kind != .system && $0.quittable } ?? true
  }
}

/// What Quit asks of macOS (spec 4.5): `NSRunningApplication` in the app, a stand-in in tests,
/// which never quit a real app. Each call after `find` takes the PID that `find` returned.
struct RunningApps {
  static let live = RunningApps(
    find: { pids in
      // The app's own process is almost always its oldest, so the lookups stop at the first.
      pids.sorted().lazy.compactMap { pid -> RunningAppInfo? in
        guard let app = NSRunningApplication(processIdentifier: pid),
          app.activationPolicy != .prohibited, let path = app.bundleURL?.path,
          let owner = ProcessProbe.live.bsdInfo(pid)?.uid
        else { return nil }
        return RunningAppInfo(pid: pid, bundlePath: path, ownerUID: owner)
      }.first
    },
    isRunning: { NSRunningApplication(processIdentifier: $0)?.isTerminated == false },
    terminate: { _ = NSRunningApplication(processIdentifier: $0)?.terminate() },
    forceTerminate: { _ = NSRunningApplication(processIdentifier: $0)?.forceTerminate() })

  /// The app's own process among a row's PIDs: the first that macOS runs as an app, not a helper
  /// or a command-line process (R77).
  let find: @MainActor @Sendable ([Int32]) -> RunningAppInfo?
  let isRunning: @MainActor @Sendable (Int32) -> Bool
  let terminate: @MainActor @Sendable (Int32) -> Void
  let forceTerminate: @MainActor @Sendable (Int32) -> Void
}
