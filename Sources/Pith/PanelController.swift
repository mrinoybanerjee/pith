import AppKit
import SwiftUI

/// Owns the panel (spec 4.2 and 4.7). It never takes focus from the app in front.
/// - Attached, it hangs under the status item and closes on an outside click, Escape or a second
///   click on the item.
/// - Pinned, it floats where the user drags it, on every Space, and its frame is saved.
///
/// Every change to its visibility, pin or occlusion goes to `onChange`, which sets the speed.
@MainActor final class PanelController: NSObject, NSWindowDelegate {
  private static let width: CGFloat = 360

  private let panel = KeyPanel(
    contentRect: .zero, styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered,
    defer: true)
  private let hosting: NSHostingView<PanelPlaceholder>
  private let store: Store
  private let defaults: UserDefaults
  private let onChange: @MainActor (_ visible: Bool, _ pinned: Bool, _ occluded: Bool) -> Void
  /// The outside-click and Escape monitors, installed while the panel is attached and open.
  private var monitors: [Any] = []

  init(
    store: Store, defaults: UserDefaults,
    onChange: @escaping @MainActor (_ visible: Bool, _ pinned: Bool, _ occluded: Bool) -> Void
  ) {
    self.store = store
    self.defaults = defaults
    self.onChange = onChange
    hosting = NSHostingView(rootView: PanelPlaceholder(store: store))
    super.init()
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.delegate = self
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.state = .active
    effect.wantsLayer = true
    effect.layer!.cornerRadius = 14
    effect.layer!.masksToBounds = true
    hosting.autoresizingMask = [.width, .height]
    effect.addSubview(hosting)
    panel.contentView = effect
    follow({ [store] in store.pinned }, then: { [weak self] in self?.pin($0) })
  }

  /// Opens the panel, attached under `anchor` unless it is pinned, or closes it if it is open.
  func toggle(under anchor: (itemFrame: CGRect, visibleFrame: CGRect)) {
    guard !panel.isVisible else { return close() }
    if !store.pinned {
      panel.setFrame(
        PanelGeometry.attachedFrame(
          itemFrame: anchor.itemFrame,
          panelSize: CGSize(width: Self.width, height: hosting.fittingSize.height),
          visibleFrame: anchor.visibleFrame),
        display: false)
      monitors = [
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
          MainActor.assumeIsolated { self?.close() }
        }!,
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
          guard event.keyCode == 53 else { return event }  // Escape
          MainActor.assumeIsolated { self?.close() }
          return nil
        }!,
      ]
    }
    panel.makeKeyAndOrderFront(nil)
    // Just ordered front, so not covered: a pinned panel opens in the open mode and ticks at once.
    // `windowDidChangeOcclusionState` reports any later change.
    onChange(true, store.pinned, false)
  }

  func windowDidMove(_ notification: Notification) {
    if store.pinned { defaults.pinnedFrame = panel.frame }
  }

  func windowDidChangeOcclusionState(_ notification: Notification) { report() }

  private func close() {
    panel.orderOut(nil)
    removeMonitors()
    report()
  }

  /// Pinning detaches the panel to where it was last pinned, keeping its top-left corner on a
  /// screen. Unpinning re-attaches it, closed.
  private func pin(_ pinned: Bool) {
    panel.isMovableByWindowBackground = pinned
    guard pinned else { return close() }
    removeMonitors()
    if let saved = defaults.pinnedFrame {
      let size = panel.frame.size
      let frame = CGRect(
        x: saved.minX, y: saved.maxY - size.height, width: size.width, height: size.height)
      // The screen it was saved on may be gone.
      let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? panel.screen!
      panel.setFrame(PanelGeometry.clamp(frame, to: screen.visibleFrame), display: true)
    }
    report()
  }

  private func removeMonitors() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
  }

  private func report() {
    onChange(panel.isVisible, store.pinned, !panel.occlusionState.contains(.visible))
  }
}

/// A borderless panel becomes key only if it says it can. The key panel receives Escape.
private final class KeyPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// Shows the status title, so the wiring is visible, until the panel views replace it.
private struct PanelPlaceholder: View {
  let store: Store

  var body: some View {
    Text(store.status.title).font(.system(size: 17, weight: .semibold)).padding(16)
  }
}
