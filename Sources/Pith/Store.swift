import AppKit
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
  /// Whether the confirm's default button is drawn whole in the list; the button reports it.
  @ObservationIgnored var confirmButtonInView = false {
    didSet { confirmVisible = confirmButtonInView && !panelCovered }
  }
  /// Whether the pinned panel is covered by other windows; the panel reports it.
  @ObservationIgnored var panelCovered = false {
    didSet { confirmVisible = confirmButtonInView && !panelCovered }
  }
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
  /// Whether the user can see the confirm's default button. Each time it comes into view, its
  /// 0.4 s start again (R93 and R101): when it appears, after Settings, after a moment undrawn,
  /// and when a pinned panel is uncovered.
  @ObservationIgnored private var confirmVisible = false {
    didSet { if confirmVisible, !oldValue { confirmShownNs = nowNs() } }
  }
  @ObservationIgnored private var confirmShownNs: UInt64 = 0
  /// Sends `.tick` once, 5 s after the app was asked to quit, which offers Force Quit (R111).
  @ObservationIgnored private var forceOffer: Task<Void, any Error>? {
    didSet { oldValue?.cancel() }
  }
  /// Watches for the flow's own process to exit (R111). Nothing polls.
  @ObservationIgnored private var exitWatch: (any NSObjectProtocol)? {
    didSet { oldValue.map(runningApps.exits.removeObserver) }
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
    // The icons kept are those of the rows shown now, whatever the view drew before (R112).
    AppIcons.keep(Set(rows.compactMap(\.bundlePath)))
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
  /// A flow in progress keeps its own process.
  func askToQuit(_ target: any QuitTarget) {
    guard quitFlow.offers(.tapQuit) else { return }
    flowTarget = target
    sendQuit(.tapQuit)
  }

  /// The Force Quit offer: the second confirm shows.
  func offerForceQuit() { sendQuit(.tapForce) }

  /// The one gate for a confirm's default button, by a click, Space, Return or VoiceOver (R101).
  /// It acts only while a confirm shows, once its button has been in view for 0.4 s, so a
  /// double-click cannot pass it (R93), and only while the user can see the whole button (R94).
  /// It acts only while the row still has the process that the user asked to quit and may quit
  /// it; otherwise the flow starts over (R95).
  func confirmQuit() {
    let event: QuitFlow.Event = quitFlow.state == .confirming ? .confirm : .confirmForce
    guard quitFlow.offers(event), confirmVisible, nowNs() - confirmShownNs >= 400_000_000 else {
      return
    }
    guard flowTargetHolds else { return resetQuit() }
    sendQuit(event)
  }

  /// Cancel, Escape, ↑ or ↓ cancel a confirm at once, drawn or not (R94). A cancel is never
  /// harmful, so it does not wait (R99).
  func cancelQuit() { sendQuit(.cancel) }

  /// Quit Pith, in Settings or with ⌘Q: Pith's own quit, at once (R91).
  func quitPith() { runningApps.quitPith() }

  /// Whether the opened row still has the flow's process, and Pith may quit it (R95).
  private var flowTargetHolds: Bool {
    guard let flowTarget, let app = rows.first(where: { $0.id == expandedAppID }) else {
      return false
    }
    return quitTarget(for: app)?.isEqual(flowTarget) == true
  }

  /// Every call goes to the flow's own process, never to a PID looked up again (R95). An event
  /// that the state does not offer, such as a late click, does nothing (R101). Once the app is
  /// asked to quit, two events move the flow on, and nothing polls (R111): the app's exit, and one
  /// timer 5 s after each quit or Force Quit, which offers Force Quit if the app still runs.
  /// `exited` is the exit event.
  private func sendQuit(_ event: QuitFlow.Event, exited: Bool = false) {
    guard quitFlow.offers(event) else { return }
    guard let target = flowTarget else {
      return assertionFailure("the quit flow in \(quitFlow.state) has no process")
    }
    let shown = quitFlow.state
    quitFlow.send(
      event, nowNs: nowNs(), isRunning: { !exited && !target.isTerminated },
      terminate: { if !target.terminate() { Self.refused("terminate", target) } },
      forceTerminate: { if !target.forceTerminate() { Self.refused("forceTerminate", target) } })
    let state = quitFlow.state
    // A new confirm counts as seen only once its button reports itself in view.
    if state != shown, state == .confirming || state == .confirmingForce {
      confirmButtonInView = false
    }
    switch state {
    case .idle:
      flowTarget = nil
      stopWatching()
    case .done: stopWatching()
    case .waiting where state != shown:
      if exitWatch == nil { watchExit() }
      forceOffer = Task { [weak self, runningApps] in
        try await runningApps.forceOfferDelay()
        // A timer that ends as the flow starts over does not tick.
        try Task.checkCancellation()
        guard let self else { return }
        sendQuit(.tick)
        // 5 s have passed on the flow's own clock, so it offers Force Quit or found the app gone.
        if case .waiting = quitFlow.state {
          assertionFailure("the quit flow still waits after 5 s")
        }
      }
    case .confirming, .waiting, .offerForce, .confirmingForce: break
    }
  }

  /// Watches for the exit of the flow's own process, `flowTarget`.
  private func watchExit() {
    exitWatch = runningApps.exits.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      // Delivered on the main queue, so the app object never leaves the main thread.
      nonisolated(unsafe) let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSObject
      MainActor.assumeIsolated {
        guard let self, let target = self.flowTarget, app?.isEqual(target) == true else { return }
        self.sendQuit(.tick, exited: true)
      }
    }
  }

  private func stopWatching() {
    forceOffer = nil
    exitWatch = nil
  }

  private static func refused(_ call: String, _ target: any QuitTarget) {
    Logger(subsystem: "com.mrinoy.pith", category: "quit")
      .error("\(call, privacy: .public) refused for pid \(target.processIdentifier)")
  }

  private func resetQuit() {
    guard quitFlow.state != .idle else { return }
    quitFlow = QuitFlow()
    flowTarget = nil
    stopWatching()
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

  /// Once the panel shows: what macOS says now, and no old refusal (R74).
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
