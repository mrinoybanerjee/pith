import Observation
import PithCore

/// What the "macOS system" row shows (spec 4.4).
enum SystemDetailsState {
  case idle, measuring
  case loaded(SystemBreakdown)
  case failed
}

/// The app's state on the main actor (spec 5.1): the latest snapshot and its status, the UI choices
/// and the settings. Views read it; `Lifecycle` hands it each snapshot.
@MainActor @Observable final class Store {
  var snapshot: Snapshot?
  /// Calm until the first tick, a moment after launch.
  var status = Status.calm
  var metric = Metric.memory
  var expandedAppID: String?
  var systemDetails = SystemDetailsState.idle
  var pinned = false
  var settings: Settings {
    didSet {
      if settings.amberOnCPU != oldValue.amberOnCPU {
        rules = StatusRules(amberOnCPU: settings.amberOnCPU)
      }
    }
  }
  @ObservationIgnored private var rules: StatusRules

  init(settings: Settings) {
    self.settings = settings
    rules = StatusRules(amberOnCPU: settings.amberOnCPU)
  }

  /// The snapshot and its status change in one main-actor step (spec 5.3).
  func apply(_ snapshot: Snapshot) {
    self.snapshot = snapshot
    status = rules.evaluate(snapshot, nowNs: snapshot.takenAtNs)
  }

  /// A CPU run must not span a pause, or one reading could flip the dot (ruling R45).
  func resetCPUTimer() { rules.resetCPUTimer() }
}

/// Passes `value()` to `action` now, and again after each change to the observable state that
/// `value` reads. Only `value` is tracked, so `action` can read anything without re-running.
@MainActor func follow<T>(
  _ value: @escaping @MainActor @Sendable () -> T,
  then action: @escaping @MainActor @Sendable (T) -> Void
) {
  action(withObservationTracking(value) { Task { @MainActor in follow(value, then: action) } })
}
