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
  private let timer: any DispatchSourceTimer
  private let paused = OSAllocatedUnfairLock(initialState: false)

  public init(onTick: @escaping @Sendable () -> Void) {
    timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.mrinoy.pith.clock"))
    timer.setEventHandler(handler: onTick)
    timer.activate()
  }

  /// Replaces the schedule. The first tick comes one interval from now.
  public func configure(seconds: Double, leeway: Double) {
    precondition(seconds > 0 && leeway >= 0, "seconds \(seconds), leeway \(leeway)")
    timer.schedule(
      deadline: .now() + seconds, repeating: seconds,
      leeway: .nanoseconds(Int(leeway * 1_000_000_000)))
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
