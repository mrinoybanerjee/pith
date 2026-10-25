import AppKit
import PithCore
import Testing

@testable import Pith

/// Records each pause, resume and schedule, and passes them on to `real` when a test sets one.
@MainActor private final class RecordingClock: Ticker {
  var calls: [String] = []
  var real: Clock?

  func configure(seconds: Double, leeway: Double) {
    calls.append("configure \(seconds) \(leeway)")
    real?.configure(seconds: seconds, leeway: leeway)
  }

  func pause() {
    calls.append("pause")
    real?.pause()
  }

  func resume() {
    calls.append("resume")
    real?.resume()
  }
}

/// Records each call. While `holding` is set, a call waits until `release()`.
@MainActor private final class RecordingEngine: Sampler {
  var calls: [String] = []
  var holding = false
  /// The CPU and the time of the readings it returns.
  var cpu = Reading<Double>.unavailable("test")
  var nowNs: UInt64 = 0
  private var held: [CheckedContinuation<Void, Never>] = []

  func tick(mode: Mode) async -> Snapshot {
    calls.append("tick \(mode)")
    await hold()
    return snapshot(cpu: cpu, at: nowNs, mode: mode)
  }

  func resetBaseline() async {
    calls.append("resetBaseline")
    await hold()
  }

  func release() {
    holding = false
    for continuation in held { continuation.resume() }
    held = []
  }

  private func hold() async {
    if holding { await withCheckedContinuation { held.append($0) } }
  }
}

/// Stands in for `PressureMonitor`, so only the test sends pressure events.
@MainActor private final class StubPressureMonitor {
  var onChange: (@Sendable (Reading<Pressure>) -> Void)?

  /// Calls `onChange` from a background queue, as a kernel event does, and waits until it returns.
  func change() async {
    let onChange = onChange!
    await withCheckedContinuation { done in
      DispatchQueue.global().async {
        onChange(.value(.warning))
        done.resume()
      }
    }
  }
}

/// A snapshot in which only the CPU can change the status.
private func snapshot(cpu: Reading<Double>, at ns: UInt64, mode: Mode = .closed) -> Snapshot {
  Snapshot(
    takenAtNs: ns, mode: mode,
    totals: SystemTotals(
      memoryUsed: .value(6 << 30), memoryTotal: 16 << 30, pressure: .value(.normal),
      swapUsed: .value(0), cpuBusy: cpu, storageFree: .unavailable("test"),
      storageTotal: .unavailable("test")),
    apps: [], system: .unavailable("test"), grouping: .full)
}

/// A `Lifecycle` over the recording fakes, fresh notification centers, a stub pressure monitor, and
/// a fixed thermal and Low Power state. So no test posts to a center that other processes hear,
/// and no real system event reaches the logs. Its defaults are the test's own suite, emptied
/// first unless it is the next launch of the same Mac.
@MainActor private final class Rig {
  let suite: String
  let clock = RecordingClock()
  let engine = RecordingEngine()
  let store: Store
  let workspace = NotificationCenter()
  let distributed = NotificationCenter()
  let pressure = StubPressureMonitor()
  let defaults: UserDefaults
  let lifecycle: Lifecycle

  init(loginItem: LoginItem = .stub, nextLaunch: Bool = false, test: String = #function) {
    suite = testSuite(test)
    defaults = nextLaunch ? UserDefaults(suiteName: suite)! : testDefaults(test)
    store = testStore(loginItem: loginItem)
    lifecycle = Lifecycle(
      clock: clock, engine: engine, store: store, reader: SystemReader(), defaults: defaults,
      workspaceCenter: workspace, distributedCenter: distributed, localCenter: NotificationCenter(),
      makePressureMonitor: { [pressure] in
        pressure.onChange = $0
        return pressure
      }, thermalState: { .nominal }, isLowPowerModeEnabled: { false })
  }

  /// Starts the lifecycle, waits for its first reading, then clears the logs.
  func start() async throws {
    lifecycle.start()
    #expect(try await settled { engine.calls == ["tick closed"] })
    #expect(clock.calls == [closedSchedule])
    clock.calls = []
    engine.calls = []
  }

  func post(_ center: NotificationCenter, _ name: String) {
    center.post(name: Notification.Name(name), object: nil)
  }
}

/// Whether `condition` holds once the work in flight has settled: it waits up to 2 s for
/// `condition`, then 50 ms more, so a step that must not happen has time to show.
@MainActor private func settled(_ condition: () -> Bool) async throws -> Bool {
  for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
  try await Task.sleep(for: .milliseconds(50))
  return condition()
}

/// The schedules `Lifecycle` gives the clock with Low Power Mode off and a nominal thermal state.
private let closedSchedule = "configure 5.0 1.0"
private let openSchedule = "configure 1.0 0.1"

private let seconds: UInt64 = 1_000_000_000
private let willSleep = NSWorkspace.willSleepNotification.rawValue
private let didWake = NSWorkspace.didWakeNotification.rawValue
private let screensDidSleep = NSWorkspace.screensDidSleepNotification.rawValue
private let screensDidWake = NSWorkspace.screensDidWakeNotification.rawValue
private let locked = "com.apple.screenIsLocked"
private let unlocked = "com.apple.screenIsUnlocked"

@MainActor @Test func panelChangesReconfigureTheClockAndOpeningTicksAtOnce() async throws {
  let rig = Rig()
  defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
  try await rig.start()

  rig.lifecycle.panelChanged(visible: true, pinned: false, occluded: false)  // opened
  #expect(try await settled { rig.engine.calls == ["tick open"] })
  rig.lifecycle.panelChanged(visible: true, pinned: false, occluded: true)  // attached: still open
  rig.lifecycle.panelChanged(visible: true, pinned: true, occluded: true)  // pinned and covered
  rig.lifecycle.panelChanged(visible: true, pinned: true, occluded: false)
  rig.lifecycle.panelChanged(visible: false, pinned: true, occluded: false)  // closed
  #expect(rig.clock.calls == [openSchedule, closedSchedule, openSchedule, closedSchedule])
}

/// Rule 1: each pause reason pauses the clock, and its own wake resumes it.
@MainActor @Test func sleepScreensSleepAndLockEachPauseTheClock() async throws {
  let rig = Rig()
  defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
  try await rig.start()

  for (center, pause, wake) in [
    (rig.workspace, willSleep, didWake), (rig.workspace, screensDidSleep, screensDidWake),
    (rig.distributed, locked, unlocked),
  ] {
    rig.post(center, pause)
    #expect(rig.clock.calls == ["pause"], "\(pause)")
    rig.post(center, wake)
    #expect(
      try await settled { rig.clock.calls == ["pause", closedSchedule, "resume"] }, "\(wake)")
    rig.clock.calls = []
  }
}

/// Rule 2: a wake resets the engine's baseline, then the CPU timer, then reschedules, resumes and
/// ticks, so no reading spans the gap (R45, R57, R65).
@MainActor @Test func wakeResetsTheBaselineThenTheCPUTimerThenResumes() async throws {
  let rig = Rig()
  defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
  try await rig.start()

  rig.post(rig.workspace, willSleep)
  rig.engine.holding = true
  rig.post(rig.workspace, didWake)
  #expect(try await settled { rig.engine.calls == ["resetBaseline"] })
  #expect(rig.clock.calls == ["pause"])  // not while the reset runs
  // A reading in flight lands during the reset. The CPU run it starts must not reach past it.
  rig.store.apply(snapshot(cpu: .value(0.9), at: 0))
  rig.engine.cpu = .value(0.9)
  rig.engine.nowNs = 60 * seconds
  rig.engine.release()
  #expect(try await settled { rig.engine.calls == ["resetBaseline", "tick closed"] })
  #expect(rig.clock.calls == ["pause", closedSchedule, "resume"])
  #expect(rig.store.status == .calm)  // the run restarted after the reset
  // The reading at 60 s was applied and began the new run, so 60 s later the dot turns.
  rig.store.apply(snapshot(cpu: .value(0.9), at: 120 * seconds))
  #expect(rig.store.status.dot == .tight)
}

/// Rule 3: the clock resumes only when the last pause reason goes.
@MainActor @Test func screensWakeDoesNotResumeWhileLocked() async throws {
  let rig = Rig()
  defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
  try await rig.start()

  rig.post(rig.workspace, screensDidWake)  // nothing to wake from
  rig.post(rig.distributed, locked)
  rig.post(rig.workspace, screensDidSleep)
  rig.post(rig.workspace, screensDidWake)
  #expect(try await settled { rig.clock.calls == ["pause", "pause"] && rig.engine.calls.isEmpty })
  rig.post(rig.distributed, unlocked)
  #expect(try await settled { rig.clock.calls == ["pause", "pause", closedSchedule, "resume"] })
  #expect(rig.engine.calls == ["resetBaseline", "tick closed"])
}

/// Rule 4: a sleep that comes back during the wake's reset wins.
@MainActor @Test func aSleepDuringTheWakeResetKeepsTheClockPaused() async throws {
  let rig = Rig()
  defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
  try await rig.start()

  rig.post(rig.workspace, willSleep)
  rig.engine.holding = true
  rig.post(rig.workspace, didWake)
  #expect(try await settled { rig.engine.calls == ["resetBaseline"] })
  rig.post(rig.workspace, willSleep)
  rig.engine.release()
  #expect(try await settled { rig.clock.calls == ["pause", "pause"] })
  #expect(rig.engine.calls == ["resetBaseline"])
}

/// Rule 5: a pressure change comes from a background queue. While paused, and until the wake's
/// reset ends, it takes no reading.
@MainActor @Test func aPressureChangeWhilePausedTakesNoReading() async throws {
  let rig = Rig()
  defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
  try await rig.start()

  rig.engine.holding = true
  rig.lifecycle.tick()  // a clock tick
  #expect(try await settled { rig.engine.calls == ["tick closed"] })
  await rig.pressure.change()  // during that reading
  rig.post(rig.workspace, willSleep)
  rig.engine.release()
  await rig.pressure.change()  // while asleep
  #expect(try await settled { rig.engine.calls == ["tick closed"] })  // the pause dropped both
  rig.engine.holding = true
  rig.post(rig.workspace, didWake)
  #expect(try await settled { rig.engine.calls == ["tick closed", "resetBaseline"] })
  await rig.pressure.change()  // during the reset
  rig.engine.release()
  #expect(
    try await settled { rig.engine.calls == ["tick closed", "resetBaseline", "tick closed"] })
  await rig.pressure.change()  // while running
  #expect(
    try await settled {
      rig.engine.calls == ["tick closed", "resetBaseline", "tick closed", "tick closed"]
    })
}

/// Rule 6: one reading at a time. Requests during a reading give exactly one more, in the mode of
/// the moment it runs, not the moment it was asked for.
@MainActor @Test func requestsDuringAReadingCoalesceIntoOne() async throws {
  let rig = Rig()
  defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
  try await rig.start()

  rig.engine.holding = true
  rig.lifecycle.panelChanged(visible: true, pinned: false, occluded: false)  // opened
  #expect(try await settled { rig.engine.calls == ["tick open"] })
  rig.lifecycle.tick()
  rig.lifecycle.tick()
  rig.lifecycle.panelChanged(visible: false, pinned: false, occluded: false)  // closed
  rig.engine.release()
  #expect(try await settled { rig.engine.calls == ["tick open", "tick closed"] })
  #expect(rig.store.snapshot?.mode == .open)  // a closed reading changes only the status (R71)
}

/// R74 and spec 12: the first launch registers the login item once. A later launch never does,
/// even when the user has turned it off in System Settings, and the toggle then shows Off.
@MainActor @Test func onlyTheFirstLaunchRegistersTheLoginItem() async throws {
  let item = FakeLoginItem(enabled: false)
  let first = Rig(loginItem: item.loginItem)
  defer { UserDefaults().removePersistentDomain(forName: first.suite) }
  try await first.start()
  #expect(item.registrations == 1 && first.store.launchesAtLogin)
  #expect(first.defaults.loginItemOfferedOnce)

  item.enabled = false  // the user turns it off in System Settings
  let second = Rig(loginItem: item.loginItem, nextLaunch: true)
  try await second.start()
  second.store.readLoginItem()  // the panel opens
  #expect(item.registrations == 1 && !second.store.launchesAtLogin)
}

/// Rule 7: a settings change is saved and sets the clock's speed.
@MainActor @Test func aSettingsChangeIsSavedAndReconfiguresTheClock() async throws {
  let rig = Rig()
  defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
  try await rig.start()

  rig.lifecycle.panelChanged(visible: true, pinned: false, occluded: false)  // opened
  for (refresh, schedule) in [
    (RefreshSetting.twoSeconds, "configure 2.0 0.2"), (.oneSecond, openSchedule),
  ] {
    rig.store.settings.refresh = refresh
    #expect(try await settled { rig.clock.calls.last == schedule }, "\(refresh)")
    #expect(Settings.load(rig.defaults).refresh == refresh)
  }
}

/// Rule 8: the rules start afresh when `amberOnCPU` changes.
@MainActor @Test func changingAmberOnCPURebuildsTheRules() {
  let store = testStore()
  store.apply(snapshot(cpu: .value(0.9), at: 0))
  store.apply(snapshot(cpu: .value(0.9), at: 60 * seconds))
  #expect(store.status.dot == .tight)
  store.settings.amberOnCPU = false
  store.apply(snapshot(cpu: .value(0.9), at: 120 * seconds))
  #expect(store.status == .calm)
  store.settings.amberOnCPU = true
  store.apply(snapshot(cpu: .value(0.9), at: 180 * seconds))
  store.apply(snapshot(cpu: .value(0.9), at: 240 * seconds))
  #expect(store.status.dot == .tight)
}

/// R65: a suspended timer keeps the fire it missed and delivers it on resume. The wake reschedules
/// the real clock first, so exactly one reading follows within the first interval.
@MainActor @Test func wakeTakesOneReadingAndNoCatchUp() async throws {
  let rig = Rig()
  defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
  rig.clock.real = Clock { [weak lifecycle = rig.lifecycle] in
    Task { @MainActor in lifecycle?.tick() }
  }
  try await rig.start()

  rig.lifecycle.panelChanged(visible: true, pinned: false, occluded: false)  // a 1 s interval
  #expect(try await settled { rig.engine.calls == ["tick open"] })
  rig.post(rig.workspace, willSleep)
  try await Task.sleep(for: .milliseconds(1500))  // the suspended timer misses a fire
  rig.engine.calls = []
  rig.post(rig.workspace, didWake)
  #expect(try await settled { rig.engine.calls == ["resetBaseline", "tick open"] })
  try await Task.sleep(for: .milliseconds(500))  // still inside the first interval
  #expect(rig.engine.calls == ["resetBaseline", "tick open"])
}

/// R67: a click that opens the panel proves the Mac is awake and unlocked, so opening it clears a
/// pause reason whose wake never came. An occlusion change of a pinned panel that stays open
/// proves nothing.
@MainActor @Test func openingThePanelClearsStalePauseReasons() async throws {
  let rig = Rig()
  defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
  try await rig.start()

  rig.lifecycle.panelChanged(visible: true, pinned: true, occluded: false)  // pinned and open
  #expect(try await settled { rig.engine.calls == ["tick open"] })
  rig.post(rig.distributed, locked)
  rig.lifecycle.panelChanged(visible: true, pinned: true, occluded: true)  // the lock covers it
  rig.lifecycle.panelChanged(visible: true, pinned: true, occluded: false)
  #expect(try await settled { rig.engine.calls == ["tick open"] })  // still paused
  rig.lifecycle.panelChanged(visible: false, pinned: true, occluded: false)  // closed
  rig.lifecycle.panelChanged(visible: true, pinned: true, occluded: false)  // opened: no unlock
  #expect(try await settled { rig.engine.calls == ["tick open", "resetBaseline", "tick open"] })
  #expect(
    rig.clock.calls == [
      openSchedule, "pause", closedSchedule, openSchedule, closedSchedule, openSchedule,
      openSchedule, "resume",
    ])
}

extension NativeInteractionTests {
  /// R64 and R71: a pinned panel is not covered when it opens, so it is open at once and ticks; it
  /// shows once that reading is applied. Later occlusion changes update the mode.
  @Test func openingAPinnedPanelTicksAtOnce() async throws {
    let rig = Rig()
    defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
    try await rig.start()
    rig.store.pinned = true
    let panel = PanelController(
      store: rig.store, defaults: rig.defaults,
      onChange: rig.lifecycle.panelChanged(visible:pinned:occluded:))

    panel.toggle(under: (.zero, .zero))  // a pinned panel ignores the anchor
    #expect(rig.clock.calls == [openSchedule])
    #expect(try await settled { rig.engine.calls == ["tick open"] && panel.panel.isVisible })
    panel.toggle(under: (.zero, .zero))
    #expect(rig.clock.calls.last == closedSchedule)
  }
}
