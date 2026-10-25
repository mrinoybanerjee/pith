import AppKit
import PithCore
import os

/// The clock's controls, so a test can record them. `Clock` is the real one.
@MainActor protocol Ticker: AnyObject {
  func configure(seconds: Double, leeway: Double)
  func pause()
  func resume()
}

extension Clock: Ticker {}

/// The engine's calls, so a test can hold and record them. `Engine` is the real one.
protocol Sampler: Sendable {
  func tick(mode: Mode) async -> Snapshot
  func resetBaseline() async
}

extension Engine: Sampler {}

/// Why the clock is paused (spec 9).
enum PauseReason { case sleep, screensSleep, locked }

/// Runs the sampling loop (spec 5.3 and 9):
/// - the clock's speed follows the panel, the refresh setting, Low Power Mode and the thermal state;
/// - sleep, screen lock and display sleep pause the clock; it resumes on a fresh baseline when none
///   of them is left, or when the user opens the panel;
/// - readings run one at a time, never while paused, and a pressure change takes one at once;
/// - a volume mount or unmount re-reads storage;
/// - the settings stay saved, and the first launch registers the login item;
/// - the time from launch to the first reading goes to the log, for `scripts/perf.sh` (spec 10).
@MainActor final class Lifecycle {
  private let clock: any Ticker
  private let engine: any Sampler
  private let store: Store
  private let reader: SystemReader
  private let defaults: UserDefaults
  private let workspaceCenter: NotificationCenter
  private let distributedCenter: NotificationCenter
  private let localCenter: NotificationCenter
  private let makePressureMonitor: (@escaping @Sendable (Reading<Pressure>) -> Void) -> AnyObject
  private let thermalState: () -> ProcessInfo.ThermalState
  private let isLowPowerModeEnabled: () -> Bool
  private var mode = Mode.closed
  /// The panel's visibility at the last change, so an open is told apart from an occlusion change.
  private var panelVisible = false
  private var pauseReasons: Set<PauseReason> = []
  /// From a pause until the clock resumes, which is after the wake's reset. No reading runs.
  private var paused = false
  /// A reading is running; `pending` asks for one more when it ends.
  private var ticking = false
  private var pending = false
  /// The next reading starts on a fresh baseline (R109).
  private var resetPending = false
  private var firstReadingLogged = false
  private var pressure: AnyObject?
  private var observers: [any NSObjectProtocol] = []
  /// Told about each pause, so a panel that waits for an open reading stops waiting (R88).
  var onPause: () -> Void = {}

  /// Tests replace the system's parts: fresh notification centers (the screen lock notifications
  /// on the real distributed center reach every process in the login session), a pressure monitor
  /// they drive, and a fixed thermal and Low Power state.
  init(
    clock: any Ticker, engine: any Sampler, store: Store, reader: SystemReader,
    defaults: UserDefaults,
    workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
    localCenter: NotificationCenter = .default,
    makePressureMonitor: @escaping (@escaping @Sendable (Reading<Pressure>) -> Void) -> AnyObject =
      { PressureMonitor(onChange: $0) },
    thermalState: @escaping () -> ProcessInfo.ThermalState = {
      ProcessInfo.processInfo.thermalState
    },
    isLowPowerModeEnabled: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
  ) {
    self.clock = clock
    self.engine = engine
    self.store = store
    self.reader = reader
    self.defaults = defaults
    self.workspaceCenter = workspaceCenter
    self.distributedCenter = distributedCenter
    self.localCenter = localCenter
    self.makePressureMonitor = makePressureMonitor
    self.thermalState = thermalState
    self.isLowPowerModeEnabled = isLowPowerModeEnabled
  }

  /// Follows the settings and the system, registers the login item on the first launch only
  /// (spec 4.6 and 12), and takes the first reading.
  func start() {
    follow({ [store] in store.settings }, then: { [weak self] in self?.apply($0) })
    if !defaults.loginItemOfferedOnce {
      defaults.loginItemOfferedOnce = true
      store.setLaunchAtLogin(true)
    }
    pressure = makePressureMonitor { [weak self] _ in Task { @MainActor in self?.tick() } }
    let workspace = workspaceCenter
    let distributed = distributedCenter
    let local = localCenter
    let events:
      [(NotificationCenter, Notification.Name, @MainActor @Sendable (Lifecycle) -> Void)] = [
        (workspace, NSWorkspace.willSleepNotification, { $0.pause(.sleep) }),
        (workspace, NSWorkspace.screensDidSleepNotification, { $0.pause(.screensSleep) }),
        (distributed, Notification.Name("com.apple.screenIsLocked"), { $0.pause(.locked) }),
        (workspace, NSWorkspace.didWakeNotification, { $0.wake(.sleep) }),
        (workspace, NSWorkspace.screensDidWakeNotification, { $0.wake(.screensSleep) }),
        (distributed, Notification.Name("com.apple.screenIsUnlocked"), { $0.wake(.locked) }),
        (local, .NSProcessInfoPowerStateDidChange, { $0.configure() }),
        (local, ProcessInfo.thermalStateDidChangeNotification, { $0.configure() }),
        (workspace, NSWorkspace.didMountNotification, { $0.invalidateStorage() }),
        (workspace, NSWorkspace.didUnmountNotification, { $0.invalidateStorage() }),
      ]
    for (center, name, action) in events {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { if let self { action(self) } }
        })
    }
    tick()
  }

  /// Called whenever the panel's visibility, pin or occlusion changes. Opening shows the last
  /// snapshot and ticks at once (spec 6.3). The click that opens it proves the Mac is awake and
  /// unlocked, so any pause reason left then is stale: its wake never came (ruling R67).
  func panelChanged(visible: Bool, pinned: Bool, occluded: Bool) {
    if visible, !panelVisible, !pauseReasons.isEmpty {
      let stale = pauseReasons.map { "\($0)" }.sorted()
      Logger(subsystem: "com.mrinoy.pith", category: "lifecycle")
        .info("panel opened while paused; clearing stale reasons \(stale, privacy: .public)")
      pauseReasons = []
      resume()
    }
    panelVisible = visible
    let newMode = ModePolicy.mode(panelVisible: visible, pinned: pinned, occluded: occluded)
    guard newMode != mode else { return }
    mode = newMode
    configure()
    // R109: an open reading never measures across the closed time. Each opening, attached,
    // pinned or uncovered, resets the baseline in the same reading as the open tick.
    if mode == .open {
      resetPending = true
      tick()
    }
  }

  /// Asks for a reading. Every trigger calls this on the main actor. While paused it does nothing.
  /// Readings run one at a time, so they apply in the order they were asked for; requests during a
  /// reading give one more when it ends, in the mode of that moment (ruling R61). A pending reset
  /// runs just before its reading, so no other reading comes between them (R109). The engine works
  /// on its own executor; only `apply` runs on the main actor.
  func tick() {
    guard !paused else { return }
    guard !ticking else {
      pending = true
      return
    }
    ticking = true
    Task {
      repeat {
        pending = false
        if resetPending {
          resetPending = false
          await engine.resetBaseline()
        }
        store.apply(await engine.tick(mode: mode))
        if !firstReadingLogged { logFirstReading() }
      } while pending && !paused
      ticking = false
    }
  }

  /// From the process's start, as the kernel recorded it, to the first reading applied.
  private func logFirstReading() {
    firstReadingLogged = true
    let start = try! ProcessProbe.live.rusage(getpid()).get().ri_proc_start_abstime
    let ns = MachTimebase.current.nanoseconds(fromTicks: mach_absolute_time() - start)
    Logger(subsystem: "com.mrinoy.pith", category: "timing").notice(
      "launch_to_first_reading_ms=\(Double(ns) / 1e6, format: .fixed(precision: 1))")
  }

  private func apply(_ settings: Settings) {
    settings.save(defaults)
    configure()
  }

  private func configure() {
    let thermal = thermalState()
    let interval = SamplingPolicy.interval(
      mode: mode, refresh: store.settings.refresh, lowPower: isLowPowerModeEnabled(),
      thermalSerious: thermal == .serious || thermal == .critical)
    clock.configure(seconds: interval.seconds, leeway: interval.leeway)
  }

  private func pause(_ reason: PauseReason) {
    pauseReasons.insert(reason)
    paused = true
    clock.pause()
    onPause()
  }

  private func wake(_ reason: PauseReason) {
    guard pauseReasons.remove(reason) != nil, pauseReasons.isEmpty else { return }
    resume()
  }

  /// No reading spans the gap (rulings R45, R57, R62 and R65). The baseline and the CPU timer are
  /// reset first. Then, unless a reason came back meanwhile, the clock is rescheduled, which drops
  /// the fire it missed while suspended, resumes, and reads once.
  private func resume() {
    Task {
      await engine.resetBaseline()
      // No reading runs while paused, so this reset also serves an opening during the pause.
      resetPending = false
      store.resetCPUTimer()
      guard pauseReasons.isEmpty else { return }
      paused = false
      configure()
      clock.resume()
      tick()
    }
  }

  /// The storage read holds the reader's lock, so waiting for it stays off the main thread.
  private func invalidateStorage() {
    DispatchQueue.global().async { [reader] in reader.invalidateStorageCache() }
  }
}
