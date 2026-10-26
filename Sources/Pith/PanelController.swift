import AppKit
import SwiftUI
import os

/// Owns the panel (spec 4.2 and 4.7). It never takes focus from the app in front.
/// - A click asks for an open reading; the panel shows once a reading taken after the click is
///   applied, laid out and sized for it, so it never opens on old rows and then jumps (R71, R121).
/// - Attached, it hangs under the status item and closes on an outside click, Escape or a second
///   click on the item.
/// - Pinned, it floats where the user drags it, on every Space, and its frame is saved.
/// - Its height follows the content up to 560 pt and to its screen's visible height less the 8 pt
///   insets; taller content scrolls the app list (R59, R120).
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
  /// When the click that opens the panel came, on the clock of a reading's `takenAtNs` (R121).
  private var clickNs: UInt64 = 0
  /// Counts the opens, so each one draws a new panel view (R85).
  private var opens = 0
  /// Where the attached panel hangs: the status item's frame and its screen's visible frame.
  private var anchor = (itemFrame: CGRect.zero, visibleFrame: CGRect.zero)
  /// The outside-click monitor, installed while the panel is attached and open.
  private var monitors: [Any] = []
  /// Sees each scroll of the list, which can move the confirm's default button in or out of view.
  private var scrolls: (any NSObjectProtocol)?
  /// The check that keeps a moved pinned panel on screen (R106).
  private var dragCheck: Task<Void, any Error>?
  /// Whether other windows cover the panel, as macOS reports it. Tests set it (R104).
  var isCovered: (NSWindow) -> Bool = { !$0.occlusionState.contains(.visible) }
  /// The wait before each check of a moved pinned panel, which throws once the check is cancelled;
  /// whether a mouse button is still down; and the visible frame of the panel's own screen. Tests
  /// set them (R106).
  var nextDragCheck: @MainActor @Sendable () async throws -> Void = {
    try await Task.sleep(for: .seconds(0.25))
  }
  var mouseIsDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
  var ownScreenFrame: (NSWindow) -> CGRect? = { $0.screen?.visibleFrame }
  /// The clock of a reading's `takenAtNs`. Tests set it (R121).
  var uptimeNs: () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

  init(
    store: Store, defaults: UserDefaults,
    onChange: @escaping @MainActor (_ visible: Bool, _ pinned: Bool, _ occluded: Bool) -> Void
  ) {
    self.store = store
    self.defaults = defaults
    self.onChange = onChange
    hosting = PanelHostingView(rootView: PanelView(store: store, open: nil))
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
    store.confirmButtonMoved = { [weak self] in self?.checkConfirmButton() }
    // A scroll of the list sets its clip view's bounds. Pith has no other scroll view.
    scrolls = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.checkConfirmButton() } }
    follow({ [store] in store.pinned }, then: { [weak self] in self?.pin($0) })
  }

  /// Opens the panel, attached under `anchor` unless it is pinned, or closes it if it is open or
  /// opening.
  func toggle(under anchor: (itemFrame: CGRect, visibleFrame: CGRect)) {
    guard !panel.isVisible, !opening else { return close() }
    self.anchor = anchor
    opening = true
    clickNs = uptimeNs()
    // The lifecycle takes an open reading at once. Not shown yet, so not covered either.
    onChange(true, store.pinned, false)
  }

  /// A drag may report each step as a move, so a moved pinned panel is checked 0.25 s after its
  /// last move, and every 0.25 s after that while a mouse button is down. The first check with no
  /// button down clamps the panel 8 pt inside its own screen and saves the frame, so no part of
  /// it, such as a quit confirm, stays off screen. The clamp's own move is checked too, and
  /// changes nothing. A later move or a close cancels the check.
  func windowDidMove(_ notification: Notification) {
    guard store.pinned else { return }
    dragCheck?.cancel()
    dragCheck = Task {
      repeat { try await nextDragCheck() } while mouseIsDown()
      try Task.checkCancellation()
      guard store.pinned, let visible = ownVisibleFrame else { return }
      // The screen it landed on may be shorter: refit the height first (R126).
      panel.setFrame(fitted(in: visible), display: true)
      defaults.pinnedFrame = panel.frame
    }
  }

  func windowDidChangeOcclusionState(_ notification: Notification) { report() }

  /// The content's height, up to `maxHeight` and to `visible`'s height less the 8 pt insets, so
  /// the panel fits a short screen; the app list scrolls inside it (R120).
  private func height(in visible: CGRect) -> CGFloat {
    min(hosting.fittingSize.height.rounded(.up), Self.maxHeight, visible.height - 16)
  }

  /// A pause drops a pending open: its reading does not come, and the wake must not open the
  /// panel by itself (R88).
  func cancelOpening() {
    guard opening else { return }
    opening = false
    report()
  }

  /// Shows the panel when the first open reading taken after the click has been applied. A reading
  /// that was already in flight, from an open that was closed again, does not count (R121). It
  /// draws a new view, laid out at once, so the panel opens at its final size with nothing
  /// animating (R85).
  private func show() {
    guard opening, let snapshot = store.snapshot, snapshot.takenAtNs > clickNs else { return }
    opening = false
    opens += 1
    hosting.rootView = PanelView(store: store, open: opens)
    hosting.layoutSubtreeIfNeeded()
    if store.pinned {
      resize()
    } else {
      panel.setFrame(
        PanelGeometry.attachedFrame(
          itemFrame: anchor.itemFrame,
          panelSize: CGSize(width: Self.width, height: height(in: anchor.visibleFrame)),
          visibleFrame: anchor.visibleFrame),
        display: false)
      monitors = [
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
          MainActor.assumeIsolated { self?.close() }
        }!
      ]
    }
    panel.makeKeyAndOrderFront(nil)
    // The run loop draws the panel at the end of this pass; this task runs in the next pass, after
    // that first draw. `scripts/perf.sh` gates the time from the click (spec 10). Only then does
    // it ask macOS about the login item, which takes up to 15 ms.
    Task { [clickNs] in
      Logger(subsystem: "com.mrinoy.pith", category: "timing").notice(
        "open_to_visible_ms=\(Double(self.uptimeNs() - clickNs) / 1e6, format: .fixed(precision: 1))"
      )
      self.store.readLoginItem()
    }
  }

  /// Lays out and draws the panel for `store` offscreen once, then lets the view go, so the first
  /// click finds SwiftUI, the fonts and the row icons loaded (spec 10).
  static func prepare(_ store: Store) {
    let view = NSHostingView(rootView: PanelView(store: store, open: 0))
    view.setFrameSize(CGSize(width: width, height: maxHeight))
    view.layoutSubtreeIfNeeded()
    view.cacheDisplay(in: view.bounds, to: view.bitmapImageRepForCachingDisplay(in: view.bounds)!)
  }

  /// Follows the content's height after each layout of the shown panel. The list may have just come
  /// back, as after Settings, so the confirm's button is checked again too (R147).
  private func fit() {
    checkConfirmButton()
    if panel.isVisible { resize() }
  }

  /// Sets the content's height when it changed, keeping the top edge: under the status item when
  /// attached, the top-left corner when pinned. The new size lays out again, which changes nothing
  /// more.
  private func resize() {
    guard let visible = ownVisibleFrame, panel.frame.height != height(in: visible) else { return }
    panel.setFrame(fitted(in: visible), display: true)
  }

  /// The panel's frame refit for `visible`: the height for that screen (R120), the top-left corner
  /// kept, then 8 pt inside it.
  private func fitted(in visible: CGRect) -> CGRect {
    let height = height(in: visible)
    let frame = panel.frame
    return PanelGeometry.clamp(
      CGRect(x: frame.minX, y: frame.maxY - height, width: Self.width, height: height), to: visible)
  }

  /// The visible frame of the panel's own screen. A panel dragged fully off screen has no screen of
  /// its own, so it comes back onto the main one.
  private var ownVisibleFrame: CGRect? {
    let visible = ownScreenFrame(panel) ?? NSScreen.main?.visibleFrame
    assert(visible != nil, "no screen to keep the panel on")
    return visible
  }

  /// Spec 4.8: ↑ and ↓ move between the rows and Return opens or closes one, while the list
  /// shows; in Settings they go to the controls. ⌘1–⌘3 pick the metric by key, on any keyboard
  /// layout. Escape closes the attached panel. ⌘Q quits Pith (R91).
  ///
  /// While a quit confirm is up (R94), ↑ and ↓ cancel it and do not move. Return presses its
  /// default button through the store's one gate, which acts only while the user sees the button
  /// (R101). Escape cancels it even when it is not drawn. ⌘Q does nothing, as it could be read as
  /// the confirm's Quit.
  private func handle(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let list = !store.showingSettings
    let confirming = [.confirming, .confirmingForce].contains(store.quitFlow.state)
    switch (modifiers, event.keyCode) {
    case ([.command], 18): store.metric = .memory
    case ([.command], 19): store.metric = .cpu
    case ([.command], 20): store.metric = .disk
    case ([.command], _) where event.charactersIgnoringModifiers == "q":
      if !confirming { store.quitPith() }
    case ([], 126) where list && confirming, ([], 125) where list && confirming: store.cancelQuit()
    case ([], 126) where list: store.moveSelection(-1)
    case ([], 125) where list: store.moveSelection(1)
    case ([], 36) where list && confirming, ([], 76) where list && confirming:
      checkConfirmButton()
      store.confirmQuit()
    case ([], 36) where list, ([], 76) where list: store.toggleSelected()
    case ([], 53) where confirming: store.cancelQuit()
    case ([], 53) where !store.pinned: close()
    default: return false
    }
    return true
  }

  /// R147: whether the confirm's default button shows whole in the list, from where the list is
  /// scrolled now. SwiftUI on macOS 15 can drop the last geometry change after a scroll, so no
  /// reported flag decides it. The list is the panel's one NSScrollView, and its flipped document
  /// has the list content's coordinates; a test pins both. While Settings show there is no list,
  /// and the button's frame can still be set until its disappearance reaches the store.
  private func checkConfirmButton() {
    func list(in view: NSView) -> NSScrollView? {
      view as? NSScrollView ?? view.subviews.lazy.compactMap(list).first
    }
    store.confirmButtonInView =
      store.confirmButtonFrame.map { frame in
        list(in: hosting).map { $0.documentVisibleRect.contains(frame) } ?? false
      } ?? false
  }

  private func close() {
    opening = false
    dragCheck?.cancel()
    panel.orderOut(nil)
    // A closed panel holds no view. One left in place would see the next open's reading, and an
    // animated row change would keep it alive and watching the store after `show()` replaces it
    // (R118).
    hosting.rootView = PanelView(store: store, open: nil)
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
      if let visible = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })?
        .visibleFrame ?? ownVisibleFrame
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
  /// from the closed panel cannot switch the speed to closed (R88). As for the speed, only a
  /// pinned panel counts as covered, which hides a confirm on it (R101).
  private func report() {
    let covered = !opening && isCovered(panel)
    store.panelCovered = store.pinned && covered
    onChange(opening || panel.isVisible, store.pinned, covered)
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

extension NSWindow {
  /// The window as it draws now, as PNG data. It renders offscreen, as `screencapture` cannot run
  /// over SSH: the tests' screenshots and `--render-panel` (R129) use it.
  func pngData() -> Data {
    let view = contentView!
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])!
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
