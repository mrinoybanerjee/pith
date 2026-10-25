import Observation
import PithCore
import os

/// What the "macOS system" row shows (spec 4.4).
enum SystemDetailsState: Equatable {
  case idle, measuring
  case loaded(SystemBreakdown)
  case failed
}

/// The app's state on the main actor (spec 5.1): the status, what the panel draws, the UI choices
/// and the settings. Views read it; `Lifecycle` hands it each snapshot.
@MainActor @Observable final class Store {
  /// The "macOS system" row's id. App ids are paths or start with "proc:" or "clone:".
  static let systemRowID = "system"

  /// The latest open snapshot, which the panel draws. A closed tick never changes it, so the hidden
  /// panel has nothing to redraw (R71).
  private(set) var snapshot: Snapshot?
  /// Calm until the first tick, a moment after launch. It changes only when the state changes.
  private(set) var status = Status.calm
  var metric = Metric.memory {
    didSet { rows = RowOrder.stable(previous: [], apps: snapshot?.apps ?? [], metric: metric) }
  }
  /// The app rows in the order shown (spec 4.2 and 4.8).
  private(set) var rows: [AppUsage] = []
  private(set) var expandedAppID: String?
  /// The row that ↑ and ↓ moved to (spec 4.8).
  private(set) var selectedRowID: String?
  /// Settings take the place of the tiles and the list.
  var showingSettings = false
  private(set) var systemDetails = SystemDetailsState.idle
  /// The opened row's quit flow (spec 4.5). It starts over when the row closes, another row opens,
  /// the panel closes or the app leaves the list (R78), so no confirm outlives its row. A quit
  /// already sent stays sent.
  private(set) var quitFlow = QuitFlow()
  var pinned = false
  var settings: Settings {
    didSet {
      if settings.amberOnCPU != oldValue.amberOnCPU {
        rules = StatusRules(amberOnCPU: settings.amberOnCPU)
      }
    }
  }
  /// Whether Pith opens at login, as macOS says (R74).
  private(set) var launchesAtLogin = false
  /// macOS refused the last change to the login item.
  private(set) var loginItemFailed = false
  let guide: Guide
  let runningApps: RunningApps
  /// Called after each open snapshot is applied. The panel shows on the first one after a click.
  @ObservationIgnored var appliedOpenSnapshot: () -> Void = {}
  @ObservationIgnored private var rules: StatusRules
  @ObservationIgnored private let loginItem: LoginItem
  @ObservationIgnored private let measureSystem: @Sendable () async throws -> SystemBreakdown
  /// The time that the quit flow's 5 s are counted in.
  @ObservationIgnored private let nowNs: @MainActor @Sendable () -> UInt64
  /// Sends `.tick` to the quit flow once per second while it waits (R78).
  @ObservationIgnored private var quitTicks: Task<Void, any Error>? {
    didSet { oldValue?.cancel() }
  }

  init(
    settings: Settings, guide: Guide, loginItem: LoginItem, runningApps: RunningApps,
    measureSystem: @escaping @Sendable () async throws -> SystemBreakdown,
    nowNs: @escaping @MainActor @Sendable () -> UInt64
  ) {
    self.settings = settings
    self.guide = guide
    self.loginItem = loginItem
    self.runningApps = runningApps
    self.measureSystem = measureSystem
    self.nowNs = nowNs
    rules = StatusRules(amberOnCPU: settings.amberOnCPU)
  }

  /// Every snapshot sets the status. Only an open one changes what the panel draws: the snapshot
  /// and the row order, in the same main-actor step (spec 5.3).
  func apply(_ snapshot: Snapshot) {
    let status = rules.evaluate(snapshot, nowNs: snapshot.takenAtNs)
    if status != self.status { self.status = status }
    guard snapshot.mode == .open else { return }
    self.snapshot = snapshot
    rows = RowOrder.stable(previous: rows.map(\.id), apps: snapshot.apps, metric: metric)
    if !rows.contains(where: { $0.id == expandedAppID }) { resetQuit() }
    appliedOpenSnapshot()
  }

  /// A CPU run must not span a pause, or one reading could flip the dot (ruling R45).
  func resetCPUTimer() { rules.resetCPUTimer() }

  /// Opens the row `id` and closes any other, or closes it (spec 4.3). Opening "macOS system"
  /// measures it (spec 4.4).
  func toggle(_ id: String) {
    resetQuit()
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
    resetQuit()
    expandedAppID = nil
    selectedRowID = nil
    showingSettings = false
  }

  /// Sends `event` to the opened row's quit flow, for the app whose own process is `pid`
  /// (spec 4.5). While the flow waits for the app to quit, it ticks once per second (R78).
  func sendQuit(_ event: QuitFlow.Event, pid: Int32) {
    quitFlow.send(
      event, nowNs: nowNs(), isRunning: { runningApps.isRunning(pid) },
      terminate: { runningApps.terminate(pid) }, forceTerminate: { runningApps.forceTerminate(pid) }
    )
    switch quitFlow.state {
    case .waiting:
      if quitTicks == nil {
        quitTicks = Task { [weak self] in
          while true {
            try await Task.sleep(for: .seconds(1))
            guard let self else { return }
            sendQuit(.tick, pid: pid)
          }
        }
      }
    default: quitTicks = nil
    }
  }

  private func resetQuit() {
    guard quitFlow.state != .idle else { return }
    quitFlow = QuitFlow()
    quitTicks = nil
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

  /// When the panel opens: what macOS says now, and no old refusal (R74).
  func readLoginItem() {
    launchesAtLogin = loginItem.isEnabled()
    loginItemFailed = false
  }

  /// Registers Pith as a login item or removes it. The toggle moves at once, then shows what macOS
  /// really did; a refusal is logged and shown under it.
  func setLaunchAtLogin(_ enabled: Bool) {
    launchesAtLogin = enabled
    do {
      try loginItem.set(enabled)
      loginItemFailed = false
    } catch {
      Logger(subsystem: "com.mrinoy.pith", category: "login-item")
        .error("cannot set launch at login to \(enabled): \(error, privacy: .public)")
      loginItemFailed = true
    }
    launchesAtLogin = loginItem.isEnabled()
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
