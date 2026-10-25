import AppKit
import PithCore
import os

/// Builds the app at launch (spec 5.1): the store, the engine and its clock, the lifecycle, the
/// panel and the status item.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private var lifecycle: Lifecycle!
  private var panel: PanelController!
  private var statusItem: StatusItemController!

  func applicationDidFinishLaunching(_ notification: Notification) {
    let defaults = UserDefaults.standard
    let guide = try! Guide.bundled(in: .main)
    let nowNs = { @Sendable in clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    let details = SystemDetails(guide: guide, nowNs: nowNs)
    let store = Store(
      settings: .load(defaults), guide: guide, loginItem: .main, runningApps: .live,
      measureSystem: { try await details.measure() }, nowNs: nowNs)
    let reader = SystemReader()
    let engine = Engine(
      system: reader, processes: LibprocProcessTable(), grouper: .live(), guide: guide,
      cpuCount: ProcessInfo.processInfo.activeProcessorCount)
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
    lifecycle.start()
    // One line per launch, so an install can confirm the bundled guide and the login item. The
    // store reads the login item only when the panel opens, so this asks macOS itself.
    Logger(subsystem: "com.mrinoy.pith", category: "startup").notice(
      "guide \(guide.entries.count) entries, launch at login \(LoginItem.main.isEnabled())")
  }
}
