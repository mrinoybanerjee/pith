import AppKit
import SwiftUI

/// Owns the panel (spec 4.2 and 4.7). It never takes focus from the app in front.
/// - A click asks for an open reading; the panel shows once that reading is applied, laid out and
///   sized for it, so it never opens on old rows and then jumps (R71).
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
  /// From a click that opens the panel until the first open reading applied after it, unless a
  /// pause or a second click comes first.
  private var opening = false
  /// Counts the opens, so each one draws a new panel view (R85).
  private var opens = 0
  /// Where the attached panel hangs: the status item's frame and its screen's visible frame.
  private var anchor = (itemFrame: CGRect.zero, visibleFrame: CGRect.zero)
  /// The outside-click monitor, installed while the panel is attached and open.
  private var monitors: [Any] = []

  init(
    store: Store, defaults: UserDefaults,
    onChange: @escaping @MainActor (_ visible: Bool, _ pinned: Bool, _ occluded: Bool) -> Void
  ) {
    self.store = store
    self.defaults = defaults
    self.onChange = onChange
    hosting = PanelHostingView(rootView: PanelView(store: store, open: 0))
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
    store.appliedOpenSnapshot = { [weak self] in self?.show() }
    follow({ [store] in store.pinned }, then: { [weak self] in self?.pin($0) })
  }

  /// Opens the panel, attached under `anchor` unless it is pinned, or closes it if it is open or
  /// opening.
  func toggle(under anchor: (itemFrame: CGRect, visibleFrame: CGRect)) {
    guard !panel.isVisible, !opening else { return close() }
    self.anchor = anchor
    opening = true
    store.readLoginItem()
    // The lifecycle takes an open reading at once. Not shown yet, so not covered either.
    onChange(true, store.pinned, false)
  }

  func windowDidMove(_ notification: Notification) {
    if store.pinned { defaults.pinnedFrame = panel.frame }
  }

  func windowDidChangeOcclusionState(_ notification: Notification) { report() }

  /// The content's height, up to `maxHeight`.
  private var height: CGFloat { min(hosting.fittingSize.height.rounded(.up), Self.maxHeight) }

  /// A pause drops a pending open: its reading does not come, and the wake must not open the
  /// panel by itself (R88).
  func cancelOpening() {
    guard opening else { return }
    opening = false
    report()
  }

  /// Shows the panel when the first open reading after the click has been applied. It draws a new
  /// view, laid out at once, so the panel opens at its final size with nothing animating (R85).
  private func show() {
    guard opening else { return }
    opening = false
    opens += 1
    hosting.rootView = PanelView(store: store, open: opens)
    hosting.layoutSubtreeIfNeeded()
    if store.pinned {
      resize()
    } else {
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
  }

  /// Follows the content's height after each layout of the shown panel.
  private func fit() {
    if panel.isVisible { resize() }
  }

  /// Sets the content's height, keeping the top edge: under the status item when attached, the
  /// top-left corner when pinned. The frame stays 8 pt inside its screen's visible frame. The new
  /// size lays out again, which changes nothing more.
  private func resize() {
    let height = height
    guard panel.frame.height != height else { return }
    let frame = panel.frame
    guard let visible = visibleFrame(of: panel.screen) else { return }
    panel.setFrame(
      PanelGeometry.clamp(
        CGRect(x: frame.minX, y: frame.maxY - height, width: Self.width, height: height),
        to: visible),
      display: true)
  }

  /// `screen`'s visible frame. A panel dragged fully off screen has no screen of its own, so it
  /// comes back onto the main one.
  private func visibleFrame(of screen: NSScreen?) -> CGRect? {
    let screen = screen ?? NSScreen.main
    assert(screen != nil, "no screen to keep the panel on")
    return screen?.visibleFrame
  }

  /// Spec 4.8: ↑ and ↓ move between the rows and Return opens or closes one, while the list
  /// shows; in Settings they go to the controls. ⌘1–⌘3 pick the metric by key, on any keyboard
  /// layout. Escape closes the attached panel. ⌘Q quits Pith (R91).
  ///
  /// While a quit confirm is up (R94), ↑ and ↓ cancel it and do not move. Return presses its
  /// default button only while that shows whole in the list, and otherwise does nothing. Escape
  /// cancels it even when it is not drawn.
  private func handle(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let list = !store.showingSettings
    let confirming = [.confirming, .confirmingForce].contains(store.quitFlow.state)
    switch (modifiers, event.keyCode) {
    case ([.command], 18): store.metric = .memory
    case ([.command], 19): store.metric = .cpu
    case ([.command], 20): store.metric = .disk
    case ([.command], _) where event.charactersIgnoringModifiers == "q": store.quitPith()
    case ([], 126) where list && confirming, ([], 125) where list && confirming: store.cancelQuit()
    case ([], 126) where list: store.moveSelection(-1)
    case ([], 125) where list: store.moveSelection(1)
    case ([], 36) where list && confirming, ([], 76) where list && confirming:
      if store.confirmButtonInView { store.confirmQuit() }
    case ([], 36) where list, ([], 76) where list: store.toggleSelected()
    case ([], 53) where confirming: store.cancelQuit()
    case ([], 53) where !store.pinned: close()
    default: return false
    }
    return true
  }

  private func close() {
    opening = false
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
      if let visible = visibleFrame(
        of: NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? panel.screen)
      {
        panel.setFrame(PanelGeometry.clamp(frame, to: visible), display: true)
      }
    }
    report()
  }

  private func removeMonitors() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
  }

  /// An open that waits for its reading counts as shown and not covered, so a late occlusion note
  /// from the closed panel cannot switch the speed to closed (R88).
  private func report() {
    onChange(
      opening || panel.isVisible, store.pinned,
      !opening && !panel.occlusionState.contains(.visible))
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
