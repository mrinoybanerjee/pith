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
  /// The opened row's quit flow (spec 4.5). It starts over when the row closes, another row opens
  /// or the panel closes (R78), and when the row no longer has the process that the user asked to
  /// quit (R95). So no confirm outlives its row or its process. A quit already sent stays sent.
  private(set) var quitFlow = QuitFlow()
  /// Whether the confirm's default button shows whole in the list. Only then does Return press it
  /// (R94). The confirm reports it.
  @ObservationIgnored var confirmButtonInView = false
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
  /// The process that the quit flow acts on, from the Quit click until the flow starts over (R95).
  @ObservationIgnored private var flowTarget: (any QuitTarget)?
  /// When the confirm that shows appeared. Its buttons wait 0.4 s (R93).
  @ObservationIgnored private var confirmShownNs: UInt64 = 0
  /// Checks the quitting app once per second (R78 and R95).
  @ObservationIgnored private var quitChecks: Task<Void, any Error>? {
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
    if !flowTargetHolds { resetQuit() }
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

  /// The process that Quit acts on for the opened row `app`, when Pith may quit it (spec 4.5).
  func quitTarget(for app: AppUsage) -> (any QuitTarget)? {
    QuitEligibility.target(for: app, in: runningApps, uid: getuid(), guide: guide)
  }

  /// Quit, on the opened row: the confirm shows, for `target`, the process the row has now (R95).
  func askToQuit(_ target: any QuitTarget) {
    flowTarget = target
    sendQuit(.tapQuit)
  }

  /// The Force Quit offer: the second confirm shows.
  func offerForceQuit() { sendQuit(.tapForce) }

  /// A confirm's default button, by a click, Return or VoiceOver. It does nothing for 0.4 s after
  /// the confirm shows, so a double-click cannot pass it (R93). It acts only while the row still
  /// has the process that the user asked to quit and may quit it; otherwise the flow starts over
  /// (R95).
  func confirmQuit() {
    guard confirmArmed else { return }
    guard flowTargetHolds else { return resetQuit() }
    sendQuit(quitFlow.state == .confirming ? .confirm : .confirmForce)
  }

  /// Cancel, Escape, ↑ or ↓ cancel a confirm at once, drawn or not (R94). A cancel is never
  /// harmful, so it does not wait (R99).
  func cancelQuit() { sendQuit(.cancel) }

  /// Quit Pith, in Settings or with ⌘Q: Pith's own quit, at once (R91).
  func quitPith() { runningApps.quitPith() }

  private var confirmArmed: Bool { nowNs() - confirmShownNs >= 400_000_000 }

  /// Whether the opened row still has the flow's process, and Pith may quit it (R95).
  private var flowTargetHolds: Bool {
    guard let flowTarget, let app = rows.first(where: { $0.id == expandedAppID }) else {
      return false
    }
    return quitTarget(for: app)?.isEqual(flowTarget) == true
  }

  /// Every call goes to the flow's own process, never to a PID looked up again (R95). While the
  /// app quits, or Force Quit is offered or asked, the flow checks it once per second.
  private func sendQuit(_ event: QuitFlow.Event) {
    let target = flowTarget!
    let shown = quitFlow.state
    quitFlow.send(
      event, nowNs: nowNs(), isRunning: { !target.isTerminated },
      terminate: { if !target.terminate() { Self.refused("terminate", target) } },
      forceTerminate: { if !target.forceTerminate() { Self.refused("forceTerminate", target) } })
    let state = quitFlow.state
    if state != shown, state == .confirming || state == .confirmingForce {
      confirmShownNs = nowNs()
      confirmButtonInView = false
    }
    switch state {
    case .idle:
      flowTarget = nil
      quitChecks = nil
    case .confirming, .done: quitChecks = nil
    case .waiting, .offerForce, .confirmingForce:
      if quitChecks == nil {
        quitChecks = Task { [weak self, runningApps] in
          while !Task.isCancelled {
            try await runningApps.nextCheck()
            // A check that ends as the flow starts over does not tick.
            try Task.checkCancellation()
            guard let self else { return }
            sendQuit(.tick)
          }
        }
      }
    }
  }

  private static func refused(_ call: String, _ target: any QuitTarget) {
    Logger(subsystem: "com.mrinoy.pith", category: "quit")
      .error("\(call, privacy: .public) refused for pid \(target.processIdentifier)")
  }

  private func resetQuit() {
    guard quitFlow.state != .idle else { return }
    quitFlow = QuitFlow()
    flowTarget = nil
    quitChecks = nil
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
