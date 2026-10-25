import AppKit
import PithCore

/// Builds the app at launch (spec 5.1): the store, the engine and its clock, the lifecycle, the
/// panel and the status item.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private var lifecycle: Lifecycle!
  private var panel: PanelController!
  private var statusItem: StatusItemController!

  func applicationDidFinishLaunching(_ notification: Notification) {
    let defaults = UserDefaults.standard
    let store = Store(settings: .load(defaults))
    let reader = SystemReader()
    let engine = Engine(
      system: reader, processes: LibprocProcessTable(), grouper: .live(),
      guide: try! Guide.bundled(), cpuCount: ProcessInfo.processInfo.activeProcessorCount)
    // The clock keeps `onTick` until it is released, so `onTick` must not hold its owners.
    let clock = Clock { [weak self] in Task { @MainActor in self?.lifecycle.tick() } }
    lifecycle = Lifecycle(
      clock: clock, engine: engine, store: store, reader: reader, defaults: defaults,
      loginItem: Settings.setLoginItem)
    panel = PanelController(
      store: store, defaults: defaults, onChange: lifecycle.panelChanged(visible:pinned:occluded:))
    statusItem = StatusItemController { [weak self] in
      guard let self else { return }
      panel.toggle(under: statusItem.anchor)
    }
    follow({ [store] in store.status }, then: { [weak self] in self?.statusItem.show(status: $0) })
    lifecycle.start()
  }
}
