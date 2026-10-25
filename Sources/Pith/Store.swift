import Observation
import PithCore
import os

/// What the "macOS system" row shows (spec 4.4).
enum SystemDetailsState: Equatable {
  case idle, measuring
  case loaded(SystemBreakdown)
  case failed
}

/// The app's state on the main actor (spec 5.1): the latest snapshot and its status, the UI choices
/// and the settings. Views read it; `Lifecycle` hands it each snapshot.
@MainActor @Observable final class Store {
  /// The "macOS system" row's id. App ids are paths or start with "proc:" or "clone:".
  static let systemRowID = "system"

  private(set) var snapshot: Snapshot?
  /// Calm until the first tick, a moment after launch.
  var status = Status.calm
  var metric = Metric.memory {
    didSet { rows = RowOrder.stable(previous: [], apps: snapshot?.apps ?? [], metric: metric) }
  }
  /// The app rows in the order shown (spec 4.2 and 4.8).
  private(set) var rows: [AppUsage] = []
  var expandedAppID: String?
  /// The row that ↑ and ↓ moved to (spec 4.8).
  private(set) var selectedRowID: String?
  /// Settings take the place of the tiles and the list.
  var showingSettings = false
  private(set) var systemDetails = SystemDetailsState.idle
  var pinned = false
  var settings: Settings {
    didSet {
      if settings.amberOnCPU != oldValue.amberOnCPU {
        rules = StatusRules(amberOnCPU: settings.amberOnCPU)
      }
    }
  }
  /// Whether Pith really opens at login, which the user can change in System Settings.
  private(set) var launchesAtLogin = false
  /// macOS refused the last change to the login item.
  private(set) var loginItemFailed = false
  let guide: Guide
  @ObservationIgnored private var rules: StatusRules
  @ObservationIgnored private let loginItem: LoginItem
  @ObservationIgnored private let measureSystem: @Sendable () async throws -> SystemBreakdown

  init(
    settings: Settings, guide: Guide, loginItem: LoginItem,
    measureSystem: @escaping @Sendable () async throws -> SystemBreakdown
  ) {
    self.settings = settings
    self.guide = guide
    self.loginItem = loginItem
    self.measureSystem = measureSystem
    rules = StatusRules(amberOnCPU: settings.amberOnCPU)
  }

  /// The snapshot, its status and the row order change in one main-actor step (spec 5.3).
  func apply(_ snapshot: Snapshot) {
    self.snapshot = snapshot
    status = rules.evaluate(snapshot, nowNs: snapshot.takenAtNs)
    rows = RowOrder.stable(previous: rows.map(\.id), apps: snapshot.apps, metric: metric)
  }

  /// A CPU run must not span a pause, or one reading could flip the dot (ruling R45).
  func resetCPUTimer() { rules.resetCPUTimer() }

  /// Opens the row `id` and closes any other, or closes it (spec 4.3). Opening "macOS system"
  /// measures it (spec 4.4).
  func toggle(_ id: String) {
    expandedAppID = expandedAppID == id ? nil : id
    if expandedAppID == Self.systemRowID { openSystemDetails() }
  }

  /// Moves the selection `step` rows down, or up when negative, and stops at the ends.
  func moveSelection(_ step: Int) {
    let ids = rows.map(\.id) + [Self.systemRowID]
    let index =
      selectedRowID.flatMap(ids.firstIndex).map { $0 + step } ?? (step > 0 ? 0 : ids.count - 1)
    selectedRowID = ids[min(max(index, 0), ids.count - 1)]
  }

  func toggleSelected() {
    if let selectedRowID { toggle(selectedRowID) }
  }

  /// A closed panel opens fresh, so an opened "macOS system" is measured again.
  func panelClosed() {
    expandedAppID = nil
    selectedRowID = nil
    showingSettings = false
  }

  /// Asks `top` what macOS itself uses, at most once per 10 s (spec 4.4 and 6.7). Retry calls it
  /// again.
  func openSystemDetails() {
    systemDetails = .measuring
    Task {
      do {
        systemDetails = .loaded(try await measureSystem())
      } catch {
        Logger(subsystem: "com.mrinoy.pith", category: "system-details")
          .error("cannot measure system details: \(error, privacy: .public)")
        systemDetails = .failed
      }
    }
  }

  /// Reads whether Pith opens at login, when the panel opens (R59).
  func readLoginItem() { launchesAtLogin = loginItem.isEnabled() }

  /// Asks macOS to follow `settings.launchAtLogin`. A refusal is logged and shown in Settings.
  func applyLoginItem() {
    do {
      try loginItem.set(settings.launchAtLogin)
      loginItemFailed = false
    } catch {
      Logger(subsystem: "com.mrinoy.pith", category: "login-item")
        .error("cannot set launch at login: \(error, privacy: .public)")
      loginItemFailed = true
    }
    readLoginItem()
  }

  /// The Settings toggle. It moves at once, then shows what macOS really did.
  func setLaunchAtLogin(_ enabled: Bool) {
    launchesAtLogin = enabled
    settings.launchAtLogin = enabled
    applyLoginItem()
  }
}

/// Passes `value()` to `action` now, and again after each change to the observable state that
/// `value` reads. Only `value` is tracked, so `action` can read anything without re-running.
@MainActor func follow<T>(
  _ value: @escaping @MainActor @Sendable () -> T,
  then action: @escaping @MainActor @Sendable (T) -> Void
) {
  action(withObservationTracking(value) { Task { @MainActor in follow(value, then: action) } })
}
