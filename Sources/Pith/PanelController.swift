import AppKit
import SwiftUI

/// Owns the panel (spec 4.2 and 4.7). It never takes focus from the app in front.
/// - Attached, it hangs under the status item and closes on an outside click, Escape or a second
///   click on the item.
/// - Pinned, it floats where the user drags it, on every Space, and its frame is saved.
/// - Its height follows the content up to 560 pt; taller content scrolls the app list (R59).
///
/// Every change to its visibility, pin or occlusion goes to `onChange`, which sets the speed.
@MainActor final class PanelController: NSObject, NSWindowDelegate {
  private static let width: CGFloat = 360
  private static let maxHeight: CGFloat = 560

  let panel = KeyPanel(
    contentRect: .zero, styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered,
    defer: true)
  private let hosting: PanelHostingView
  private let store: Store
  private let defaults: UserDefaults
  private let onChange: @MainActor (_ visible: Bool, _ pinned: Bool, _ occluded: Bool) -> Void
  /// The outside-click monitor, installed while the panel is attached and open.
  private var monitors: [Any] = []

  init(
    store: Store, defaults: UserDefaults,
    onChange: @escaping @MainActor (_ visible: Bool, _ pinned: Bool, _ occluded: Bool) -> Void
  ) {
    self.store = store
    self.defaults = defaults
    self.onChange = onChange
    hosting = PanelHostingView(rootView: PanelView(store: store))
    super.init()
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.delegate = self
    panel.onKeyDown = { [weak self] in self?.handle($0) ?? false }
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.state = .active
    effect.wantsLayer = true
    effect.layer!.cornerRadius = 14
    effect.layer!.masksToBounds = true
    hosting.autoresizingMask = [.width, .height]
    hosting.onLayout = { [weak self] in self?.fit() }
    effect.addSubview(hosting)
    panel.contentView = effect
    follow({ [store] in store.pinned }, then: { [weak self] in self?.pin($0) })
  }

  /// Opens the panel, attached under `anchor` unless it is pinned, or closes it if it is open.
  func toggle(under anchor: (itemFrame: CGRect, visibleFrame: CGRect)) {
    guard !panel.isVisible else { return close() }
    store.readLoginItem()
    if !store.pinned {
      panel.setFrame(
        PanelGeometry.attachedFrame(
          itemFrame: anchor.itemFrame, panelSize: CGSize(width: Self.width, height: height),
          visibleFrame: anchor.visibleFrame),
        display: false)
      monitors = [
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
          MainActor.assumeIsolated { self?.close() }
        }!
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

  /// The content's height, up to `maxHeight`.
  private var height: CGFloat { min(hosting.fittingSize.height.rounded(.up), Self.maxHeight) }

  /// Follows the content's height after each layout, at once, keeping the top edge: under the
  /// status item when attached, the top-left corner when pinned. The new size lays out again,
  /// which changes nothing more.
  private func fit() {
    let height = height
    guard panel.isVisible, panel.frame.height != height else { return }
    let frame = panel.frame
    let resized = CGRect(x: frame.minX, y: frame.maxY - height, width: Self.width, height: height)
    let corner = CGPoint(x: frame.minX, y: frame.maxY)
    let screen = NSScreen.screens.first { $0.frame.contains(corner) }!
    panel.setFrame(PanelGeometry.clamp(resized, to: screen.visibleFrame), display: true)
  }

  /// ↑ and ↓ move between the rows, Return opens or closes one, ⌘1–⌘3 pick the metric, and
  /// Escape closes the attached panel (spec 4.8).
  private func handle(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    switch (modifiers, event.keyCode, event.charactersIgnoringModifiers) {
    case ([.command], _, "1"): store.metric = .memory
    case ([.command], _, "2"): store.metric = .cpu
    case ([.command], _, "3"): store.metric = .disk
    case ([], 126, _): store.moveSelection(-1)
    case ([], 125, _): store.moveSelection(1)
    case ([], 36, _), ([], 76, _): store.toggleSelected()
    case ([], 53, _) where !store.pinned: close()
    default: return false
    }
    return true
  }

  private func close() {
    panel.orderOut(nil)
    removeMonitors()
    store.panelClosed()
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

/// A borderless panel becomes key only if it says it can. The key panel receives the keys, and
/// `onKeyDown` sees each one before the views do.
final class KeyPanel: NSPanel {
  var onKeyDown: (NSEvent) -> Bool = { _ in false }

  override var canBecomeKey: Bool { true }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, onKeyDown(event) { return }
    super.sendEvent(event)
  }
}

/// Reports each layout, so the panel can follow a change in the content's height.
private final class PanelHostingView: NSHostingView<PanelView> {
  var onLayout: () -> Void = {}

  override func layout() {
    super.layout()
    onLayout()
  }
}
