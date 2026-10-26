import Dispatch
import os

/// "Refresh while open" (spec 4.6). The app persists the raw value.
public enum RefreshSetting: String, Sendable, Codable { case oneSecond, twoSeconds }

/// How often to sample, and how late a tick may fire so macOS can coalesce wakeups (spec 9).
public enum SamplingPolicy {
  /// Closed: 5 s with 1 s leeway. Open: the refresh setting with a tenth of it as leeway. Low
  /// Power Mode or a serious thermal state doubles both, once.
  public static func interval(
    mode: Mode, refresh: RefreshSetting, lowPower: Bool, thermalSerious: Bool
  ) -> (seconds: Double, leeway: Double) {
    let base: (seconds: Double, leeway: Double) =
      switch (mode, refresh) {
      case (.closed, _): (5, 1)
      case (.open, .oneSecond): (1, 0.1)
      case (.open, .twoSeconds): (2, 0.2)
      }
    let factor: Double = lowPower || thermalSerious ? 2 : 1
    return (base.seconds * factor, base.leeway * factor)
  }
}

public enum ModePolicy {
  /// Open while the panel is visible, unless it is pinned and fully covered (spec 9). A visible
  /// attached panel stays open whatever its occlusion state.
  public static func mode(panelVisible: Bool, pinned: Bool, occluded: Bool) -> Mode {
    panelVisible && !(pinned && occluded) ? .open : .closed
  }
}

/// The one timer that drives every reader (spec 9). `onTick` runs on the clock's private serial
/// queue, never on the main thread. A lock guards the paused state; the timer is thread-safe.
public final class Clock: Sendable {
  private typealias Interval = (seconds: Double, leeway: Double)

  private let queue: DispatchQueue
  private let timer: any DispatchSourceTimer
  private let paused = OSAllocatedUnfairLock(initialState: false)
  /// The interval that follows a first tick with a leeway of its own. The first tick's handler
  /// schedules it; both run on `queue`, so a new `configure` never races it.
  private let steady: OSAllocatedUnfairLock<Interval?>

  public init(onTick: @escaping @Sendable () -> Void) {
    let queue = DispatchQueue(label: "com.mrinoy.pith.clock")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let steady = OSAllocatedUnfairLock<Interval?>(initialState: nil)
    timer.setEventHandler {
      if let next = steady.withLock({ $0.take() }) {
        Self.schedule(timer, first: next, then: next.seconds)
      }
      onTick()
    }
    self.queue = queue
    self.timer = timer
    self.steady = steady
    timer.activate()
  }

  /// Replaces the schedule. The first tick comes `first` from now, then one every `seconds`. A
  /// timer has one leeway, so a first tick with another leeway is scheduled alone (R146).
  public func configure(seconds: Double, leeway: Double, first: Double, firstLeeway: Double) {
    precondition(
      seconds > 0 && first > 0 && leeway >= 0 && firstLeeway >= 0,
      "seconds \(seconds), leeway \(leeway), first \(first), first leeway \(firstLeeway)")
    queue.sync {
      let alone = firstLeeway != leeway
      steady.withLock { $0 = alone ? (seconds, leeway) : nil }
      Self.schedule(timer, first: (first, firstLeeway), then: alone ? nil : seconds)
    }
  }

  /// The next tick after `first.seconds`, then one every `then`, or none when `then` is nil.
  private static func schedule(
    _ timer: any DispatchSourceTimer, first: Interval, then: Double?
  ) {
    timer.schedule(
      deadline: .now() + first.seconds,
      repeating: then.map { .nanoseconds(Int($0 * 1_000_000_000)) } ?? .never,
      leeway: .nanoseconds(Int(first.leeway * 1_000_000_000)))
  }

  /// Stops ticks until `resume()`. Both are idempotent, so the suspend count stays at 0 or 1.
  public func pause() {
    paused.withLock { p in
      if !p { timer.suspend() }
      p = true
    }
  }

  public func resume() {
    paused.withLock { p in
      if p { timer.resume() }
      p = false
    }
  }

  /// Releasing a suspended timer traps, so a paused clock resumes it. It cancels first, so no
  /// tick runs on the way out.
  deinit {
    timer.cancel()
    if paused.withLock({ $0 }) { timer.resume() }
  }
}
