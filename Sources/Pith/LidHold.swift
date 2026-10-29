import Foundation
import IOKit
import IOKit.ps
import notify

/// What keeps the Mac awake with the lid closed (Awake spec 4.2): a copy of Pith started with
/// `--hold-lid`, which sets `LidFlag` and clears it at the end of its input, which `stop` or Pith's
/// end brings. One copy runs at a time, and Pith clears the flag each time one exits, so a copy
/// that died cannot leave it set, nor an old copy clear a new hold. If the copy ends by itself,
/// Pith calls `ended`.
struct LidHold {
  /// Its first use, at launch, clears a hold left when Pith and its copy were killed at once.
  @MainActor static let main = process(
    Bundle.main.executableURL!, arguments: ["--hold-lid"], hasLid: LidFlag.supported,
    clear: { LidFlag.set(false) })

  /// A Mac with no lid: no checkbox, and nothing to hold. For tests and the debug panels.
  static let none = LidHold(hasLid: false, start: { _ in }, stop: {})

  /// Whether this Mac has a lid that Pith can hold. Without one, the bar offers no "Lid closed".
  let hasLid: Bool
  /// Starts the hold. `ended` runs if the hold ends by itself, never after `stop`.
  let start: @MainActor @Sendable (_ ended: @escaping @MainActor @Sendable () -> Void) -> Void
  /// Ends the hold.
  let stop: @MainActor @Sendable () -> Void

  /// The hold kept by `executable` while its input stays open. Tests pass a stand-in.
  @MainActor static func process(
    _ executable: URL, arguments: [String], hasLid: Bool,
    clear: @escaping @MainActor @Sendable () -> Void
  ) -> LidHold {
    let holder = Holder(executable: executable, arguments: arguments, clear: clear)
    return LidHold(hasLid: hasLid, start: { holder.start(ended: $0) }, stop: { holder.stop() })
  }
}

/// The lid hold's copy, from its launch to its exit.
@MainActor private final class Holder {
  let executable: URL
  let arguments: [String]
  let clear: @MainActor @Sendable () -> Void
  /// The copy that has not exited yet, with its input until `stop` closes it.
  private var copy: (id: ObjectIdentifier, process: Process, input: FileHandle?)?
  /// Set while the hold is wanted: from `start` to `stop`, or to the copy's own end.
  private var ended: (@MainActor @Sendable () -> Void)?

  init(executable: URL, arguments: [String], clear: @escaping @MainActor @Sendable () -> Void) {
    self.executable = executable
    self.arguments = arguments
    self.clear = clear
  }

  /// A copy that `stop` ended may still be exiting; the new one starts when it has.
  func start(ended: @escaping @MainActor @Sendable () -> Void) {
    precondition(self.ended == nil, "a lid hold already runs")
    self.ended = ended
    if copy == nil { launch() }
  }

  func stop() {
    precondition(ended != nil, "no lid hold runs")
    ended = nil
    if let input = copy?.input {
      try! input.close()
      copy!.input = nil
    }
  }

  private func launch() {
    let process = Process()
    let input = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = input
    let id = ObjectIdentifier(process)
    process.terminationHandler = { _ in Task { @MainActor in self.exited(id) } }
    try! process.run()
    copy = (id, process, input.fileHandleForWriting)
  }

  /// No copy runs now, so the clear cannot end a newer hold. A copy whose input was still open
  /// ended by itself; otherwise a `start` may wait for this exit.
  private func exited(_ id: ObjectIdentifier) {
    precondition(copy?.id == id, "an unknown copy exited")
    let input = copy!.input
    copy = nil
    clear()
    if let input {
      try! input.close()
      let ended = self.ended!
      self.ended = nil
      ended()
    } else if ended != nil {
      launch()
    }
  }
}

/// `--hold-lid`: sets `LidFlag`, then clears it and exits on the first of: the end of its input
/// (Pith stopped the hold, or Pith ended), SIGTERM, SIGINT or SIGHUP, macOS's low-battery warning,
/// or a serious thermal state (Awake spec 4.2). It waits on events only.
func holdLid() -> Never {
  let release: @Sendable () -> Void = {
    LidFlag.set(false)
    exit(0)
  }
  // Before the flag is set, so that no signal can end this process with the flag left set.
  let signals = [SIGTERM, SIGINT, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler(handler: release)
    source.resume()
    return source
  }
  LidFlag.set(true)
  let check: @Sendable () -> Void = {
    if IOPSGetBatteryWarningLevel() != kIOPSLowBatteryWarningNone
      || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    {
      release()
    }
  }
  Thread.detachNewThread {
    _ = FileHandle.standardInput.readDataToEndOfFile()
    DispatchQueue.main.async(execute: release)
  }
  var token: Int32 = 0
  let registered = notify_register_dispatch(kIOPSNotifyLowBattery, &token, .main) { _ in check() }
  precondition(registered == NOTIFY_STATUS_OK, "cannot watch the battery: \(registered)")
  _ = NotificationCenter.default.addObserver(
    forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
  ) { _ in check() }
  DispatchQueue.main.async(execute: check)
  withExtendedLifetime(signals) { dispatchMain() }
}

/// macOS's flag that keeps a closed lid from sleeping the Mac: `kPMSetClamshellSleepState`
/// (selector 12 in `IOPMLibDefs.h`) on the power root domain. It needs no privilege, and it stays
/// set until it is cleared or the Mac restarts, even after the process that set it ends (lid
/// test, 2026-10-28).
enum LidFlag {
  /// Whether this Mac has a lid: only then does the root domain report the lid's state.
  static var exists: Bool {
    withRootDomain {
      IORegistryEntryCreateCFProperty($0, "AppleClamshellState" as CFString, nil, 0)?
        .takeRetainedValue() != nil
    }
  }

  /// Whether this Mac has a lid and macOS takes the flag. It clears the flag to find out, so a Mac
  /// or macOS that refuses it shows no "Lid closed" instead of stopping Pith.
  static var supported: Bool { exists && call(false) == KERN_SUCCESS }

  /// Sets the flag. Once `supported` is true, a refusal is a bug, so it traps.
  static func set(_ on: Bool) {
    let result = call(on)
    precondition(result == KERN_SUCCESS, "cannot set the lid flag to \(on): \(result)")
  }

  private static func call(_ on: Bool) -> kern_return_t {
    withRootDomain { domain in
      var connect: io_connect_t = 0
      let opened = IOServiceOpen(domain, mach_task_self_, 0, &connect)
      guard opened == KERN_SUCCESS else { return opened }
      defer { IOServiceClose(connect) }
      var input: UInt64 = on ? 1 : 0
      return IOConnectCallScalarMethod(connect, 12, &input, 1, nil, nil)
    }
  }

  private static func withRootDomain<T>(_ body: (io_service_t) -> T) -> T {
    let domain = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    precondition(domain != 0, "no power root domain")
    defer { IOObjectRelease(domain) }
    return body(domain)
  }
}
