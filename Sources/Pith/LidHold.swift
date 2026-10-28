import Foundation
import IOKit
import IOKit.ps
import notify

/// What keeps the Mac awake with the lid closed (Awake spec 4.2): a copy of Pith started with
/// `--hold-lid`, which sets `LidFlag` and clears it if Pith ends. `stop` clears the flag in Pith,
/// then tells the copy to exit. If the copy ends first, Pith clears the flag and calls `ended`.
struct LidHold {
  @MainActor static let main = process(
    Bundle.main.executableURL!, arguments: ["--hold-lid"], hasLid: LidFlag.exists,
    clear: { LidFlag.set(false) })

  /// A Mac with no lid: no checkbox, and nothing to hold. For tests and the debug panels.
  static let none = LidHold(hasLid: false, start: { _ in }, stop: {})

  /// Whether this Mac has a lid. Without one, the bar offers no "Lid closed".
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

/// The copy that holds the lid, if one runs.
@MainActor private final class Holder {
  let executable: URL
  let arguments: [String]
  let clear: @MainActor @Sendable () -> Void
  private var running: (process: Process, input: Pipe, ended: @MainActor @Sendable () -> Void)?

  init(executable: URL, arguments: [String], clear: @escaping @MainActor @Sendable () -> Void) {
    self.executable = executable
    self.arguments = arguments
    self.clear = clear
  }

  func start(ended: @escaping @MainActor @Sendable () -> Void) {
    precondition(running == nil, "a lid hold already runs")
    let process = Process()
    let input = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = input
    let id = ObjectIdentifier(process)
    process.terminationHandler = { _ in Task { @MainActor in self.exited(id) } }
    // A copy that ended before `stop` makes the write fail with EPIPE, not kill Pith.
    precondition(fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0)
    try! process.run()
    running = (process, input, ended)
  }

  /// Pith clears the flag, then sends the copy one byte and closes its input: the copy exits
  /// without touching the flag, so it cannot clear a hold that starts after this.
  func stop() {
    let input = running!.input.fileHandleForWriting
    running = nil
    clear()
    // EPIPE: the copy already ended, and the flag is clear now either way.
    try? input.write(contentsOf: [0])
    try! input.close()
  }

  /// A copy that `stop` ended is no longer `running`. One that ended by itself may have died
  /// before it cleared the flag.
  private func exited(_ id: ObjectIdentifier) {
    guard let hold = running, ObjectIdentifier(hold.process) == id else { return }
    running = nil
    try! hold.input.fileHandleForWriting.close()
    clear()
    hold.ended()
  }
}

/// `--hold-lid`: sets `LidFlag`, then exits on the first of: Pith's byte (Pith cleared the flag),
/// the end of its input with no byte (Pith ended), SIGTERM, SIGINT or SIGHUP, macOS's low-battery
/// warning, or a serious thermal state (Awake spec 4.2). All but the first clear the flag. It
/// waits on events only.
func holdLid() -> Never {
  LidFlag.set(true)
  let release: @Sendable () -> Void = {
    LidFlag.set(false)
    exit(0)
  }
  let check: @Sendable () -> Void = {
    if IOPSGetBatteryWarningLevel() != kIOPSLowBatteryWarningNone
      || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    {
      release()
    }
  }
  Thread.detachNewThread {
    let byte = FileHandle.standardInput.readDataToEndOfFile()
    DispatchQueue.main.async { if byte.isEmpty { release() } else { exit(0) } }
  }
  let signals = [SIGTERM, SIGINT, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler(handler: release)
    source.resume()
    return source
  }
  var token: Int32 = 0
  notify_register_dispatch(kIOPSNotifyLowBattery, &token, .main) { _ in check() }
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

  static func set(_ on: Bool) {
    withRootDomain { domain in
      var connect: io_connect_t = 0
      let opened = IOServiceOpen(domain, mach_task_self_, 0, &connect)
      precondition(opened == KERN_SUCCESS, "cannot open the power root domain: \(opened)")
      defer { IOServiceClose(connect) }
      var input: UInt64 = on ? 1 : 0
      let result = IOConnectCallScalarMethod(connect, 12, &input, 1, nil, nil)
      precondition(result == KERN_SUCCESS, "cannot set the lid flag to \(on): \(result)")
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
