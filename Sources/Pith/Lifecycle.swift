import AppKit
import PithCore

/// The clock's controls, so a test can record them. `Clock` is the real one.
@MainActor protocol Ticker: AnyObject {
  func configure(seconds: Double, leeway: Double)
  func pause()
  func resume()
}

extension Clock: Ticker {}

/// Runs the sampling loop (spec 5.3 and 9):
/// - the clock's speed follows the panel, the refresh setting, Low Power Mode and the thermal state;
/// - sleep, screen lock and display sleep pause the clock, and each wake starts a fresh baseline;
/// - a pressure change ticks at once, and a volume mount or unmount re-reads storage;
/// - the settings stay saved, and the login item follows them.
@MainActor final class Lifecycle {
  private let clock: any Ticker
  private let engine: Engine
  private let store: Store
  private let reader: SystemReader
  private let defaults: UserDefaults
  private let loginItem: (Bool) -> Void
  private var mode = Mode.closed
  /// Set by the last sleep or lock, cleared by the last wake.
  private var paused = false
  private var pressure: PressureMonitor?
  private var observers: [any NSObjectProtocol] = []

  init(
    clock: any Ticker, engine: Engine, store: Store, reader: SystemReader, defaults: UserDefaults,
    loginItem: @escaping (Bool) -> Void
  ) {
    self.clock = clock
    self.engine = engine
    self.store = store
    self.reader = reader
    self.defaults = defaults
    self.loginItem = loginItem
  }

  /// Follows the settings and the system, and takes the first reading.
  func start() {
    follow({ [store] in store.settings }, then: { [weak self] in self?.apply($0) })
    pressure = PressureMonitor { [weak self] _ in Task { await self?.tick() } }
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()
    let local = NotificationCenter.default
    let events:
      [(NotificationCenter, Notification.Name, @MainActor @Sendable (Lifecycle) -> Void)] = [
        (workspace, NSWorkspace.willSleepNotification, { $0.pause() }),
        (workspace, NSWorkspace.screensDidSleepNotification, { $0.pause() }),
        (distributed, Notification.Name("com.apple.screenIsLocked"), { $0.pause() }),
        (workspace, NSWorkspace.didWakeNotification, { $0.wake() }),
        (workspace, NSWorkspace.screensDidWakeNotification, { $0.wake() }),
        (distributed, Notification.Name("com.apple.screenIsUnlocked"), { $0.wake() }),
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
    Task { await tick() }
  }

  /// Called whenever the panel's visibility, pin or occlusion changes. Opening shows the last
  /// snapshot and ticks at once (spec 6.3).
  func panelChanged(visible: Bool, pinned: Bool, occluded: Bool) {
    let newMode = ModePolicy.mode(panelVisible: visible, pinned: pinned, occluded: occluded)
    guard newMode != mode else { return }
    mode = newMode
    configure()
    if mode == .open { Task { await tick() } }
  }

  /// One reading in the current mode. The engine works on its own executor; only `apply` runs on
  /// the main actor.
  func tick() async { store.apply(await engine.tick(mode: mode)) }

  private func apply(_ settings: Settings) {
    settings.save(defaults)
    loginItem(settings.launchAtLogin)
    configure()
  }

  private func configure() {
    let thermal = ProcessInfo.processInfo.thermalState
    let interval = SamplingPolicy.interval(
      mode: mode, refresh: store.settings.refresh,
      lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
      thermalSerious: thermal == .serious || thermal == .critical)
    clock.configure(seconds: interval.seconds, leeway: interval.leeway)
  }

  private func pause() {
    paused = true
    clock.pause()
  }

  /// No reading spans the gap (rulings R45 and R57). The clock resumes only after the baseline is
  /// reset, and not if a later sleep or lock paused it again.
  private func wake() {
    paused = false
    store.resetCPUTimer()
    Task {
      await engine.resetBaseline()
      if !paused { clock.resume() }
    }
  }

  /// The storage read holds the reader's lock, so waiting for it stays off the main thread.
  private func invalidateStorage() {
    DispatchQueue.global().async { [reader] in reader.invalidateStorageCache() }
  }
}
