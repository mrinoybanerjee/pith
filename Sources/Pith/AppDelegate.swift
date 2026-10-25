import AppKit
import PithCore
import os

/// Builds the app at launch (spec 5.1): the store, the engine and its clock, the lifecycle, the
/// panel and the status item.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private let debugHooks: Bool
  private var lifecycle: Lifecycle!
  private var panel: PanelController!
  private var statusItem: StatusItemController!

  /// With `debugHooks` (`--debug-hooks`), the panel notification opens and closes the panel.
  init(debugHooks: Bool) {
    self.debugHooks = debugHooks
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let defaults = UserDefaults.standard
    let guide = try! Guide.bundled(in: .main)
    let nowNs = { @Sendable in clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    let details = SystemDetails(guide: guide, nowNs: nowNs)
    let store = Store(
      settings: .load(defaults), guide: guide, loginItem: .main, runningApps: .live,
      measureSystem: { try await details.measure() }, nowNs: nowNs)
    let reader = SystemReader()
    let engine = Engine.live(reader, guide: guide)
    // The clock keeps `onTick` until it is released, so `onTick` must not hold its owners.
    let clock = Clock { [weak self] in Task { @MainActor in self?.lifecycle.tick() } }
    lifecycle = Lifecycle(
      clock: clock, engine: engine, store: store, reader: reader, defaults: defaults)
    panel = PanelController(
      store: store, defaults: defaults, onChange: lifecycle.panelChanged(visible:pinned:occluded:))
    lifecycle.onPause = { [weak self] in self?.panel.cancelOpening() }
    statusItem = StatusItemController { [weak self] in
      guard let self else { return }
      panel.toggle(under: statusItem.anchor)
    }
    follow({ [store] in store.status }, then: { [weak self] in self?.statusItem.show(status: $0) })
    // R128: only on request, as any process can post a distributed notification. Pith is never
    // the active app, so the notification must not wait for that.
    if debugHooks {
      DistributedNotificationCenter.default().addObserver(
        self, selector: #selector(panelNotification(_:)),
        name: Notification.Name("com.mrinoy.pith.panel"), object: nil,
        suspensionBehavior: .deliverImmediately)
    }
    lifecycle.start()
    // The first click must not wait for every app's bundle to be read, nor for SwiftUI, the fonts
    // and the row icons to load (spec 10). So the panel draws one open snapshot offscreen, on a
    // store of its own. The first reading reaches the engine before this.
    Task {
      let warm = Store(
        settings: store.settings, guide: guide, loginItem: .main, runningApps: .none,
        measureSystem: { throw SystemDetailsError.failed("not measured") }, nowNs: nowNs)
      warm.apply(await engine.warmUp())
      PanelController.prepare(warm)
    }
    // One line per launch, so an install can confirm the bundled guide and the login item. The
    // store reads the login item only when the panel opens, so this asks macOS itself.
    Logger(subsystem: "com.mrinoy.pith", category: "startup").notice(
      "guide \(guide.entries.count) entries, launch at login \(LoginItem.main.isEnabled())")
  }

  /// `userInfo["action"]` "open" opens the panel as a click does, and "close" closes it.
  /// `scripts/perf.sh` sends it.
  @objc private func panelNotification(_ notification: Notification) {
    let visible = panel.panel.isVisible
    switch notification.userInfo?["action"] as? String {
    case "open" where !visible, "close" where visible: panel.toggle(under: statusItem.anchor)
    case "open", "close": break
    case let action:
      Logger(subsystem: "com.mrinoy.pith", category: "debug-hooks").error(
        "unknown panel action \(String(describing: action), privacy: .public)")
    }
  }
}

extension Engine {
  /// The engine on this Mac's own readers.
  static func live(_ reader: SystemReader, guide: Guide) -> Engine {
    Engine(
      system: reader, processes: LibprocProcessTable(), grouper: .live(), guide: guide,
      cpuCount: ProcessInfo.processInfo.activeProcessorCount)
  }
}
