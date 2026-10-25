import AppKit
import PithCore
import SwiftUI
import Testing

@testable import Pith

/// The panels a test shows stay alive until its process ends.
@MainActor private var hostedPanels: [PanelController] = []

/// A status item in the middle of the main screen's menu bar.
@MainActor func anchor() throws -> (itemFrame: CGRect, visibleFrame: CGRect) {
  let screen = try #require(NSScreen.main).visibleFrame
  return (CGRect(x: screen.midX, y: screen.maxY, width: 22, height: 24), screen)
}

/// SwiftUI builds its accessibility tree only for an assistive client, which sets this.
@MainActor func enableAccessibilityTree() {
  _ = NSApplication.shared.perform(
    NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
    with: "AXEnhancedUserInterface")
}

/// The real panel, attached under a status item, opened as the app opens it: the click asks for
/// an open reading, here `snapshot` at once, and the panel shows with it, laid out. The panel's
/// defaults are the test's own suite.
@MainActor func hostPanelWithStore(
  _ snapshot: Snapshot, appearance: NSAppearance.Name = .aqua, store: Store? = nil,
  test: String = #function
) throws -> (NSWindow, Store) {
  let (controller, store) = try hostPanelController(
    snapshot, appearance: appearance, store: store, test: test)
  return (controller.panel, store)
}

/// `hostPanelWithStore` with the panel's controller, which stays alive until the process ends.
@MainActor func hostPanelController(
  _ snapshot: Snapshot, appearance: NSAppearance.Name = .aqua, store: Store? = nil,
  test: String = #function
) throws -> (PanelController, Store) {
  enableAccessibilityTree()
  let store = try store ?? testStore(guide: Guide.bundled())
  let controller = PanelController(
    store: store, defaults: testDefaults(test),
    // Stands in for the lifecycle, which reads at once when the panel opens.
    onChange: { visible, _, _ in if visible { store.apply(snapshot) } })
  controller.uptimeNs = { 0 }  // the clicks come before the readings (R121)
  controller.panel.appearance = NSAppearance(named: appearance)
  controller.toggle(under: try anchor())
  #expect(controller.panel.isVisible)
  controller.panel.contentView!.layoutSubtreeIfNeeded()
  hostedPanels.append(controller)
  return (controller, store)
}

@MainActor func hostPanel(
  _ snapshot: Snapshot, appearance: NSAppearance.Name = .aqua, test: String = #function
) throws -> NSWindow {
  try hostPanelWithStore(snapshot, appearance: appearance, test: test).0
}

/// Clicks the status item of the hosted panel `window`: it closes an open panel, and opens a
/// closed one.
@MainActor func clickStatusItem(of window: NSWindow) throws {
  try #require(hostedPanels.first { $0.panel === window }).toggle(under: try anchor())
}

/// Any view, laid out in a window, for checks of the test helpers themselves.
@MainActor func hostView(_ view: some View) -> NSWindow {
  enableAccessibilityTree()
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.titled],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = NSHostingView(rootView: view)
  window.orderFront(nil)
  window.contentView!.layoutSubtreeIfNeeded()
  return window
}

/// Whether `condition` holds within 2 s. It stops at the first success and lays out the panel
/// between checks.
@MainActor func eventually(_ w: NSWindow, _ condition: () -> Bool) async throws -> Bool {
  for _ in 0..<200 {
    if condition() { return true }
    try await Task.sleep(for: .milliseconds(10))
    w.contentView!.layoutSubtreeIfNeeded()
  }
  return condition()
}

/// Sends a key press to `window` as the application does. `key` is a digit, q or ↑ ↓ ↩ ⎋, and
/// `characters` what another keyboard layout types with that key.
@MainActor func sendKey(
  _ key: String, modifiers: NSEvent.ModifierFlags = [], characters: String? = nil,
  to window: NSWindow
) {
  let keys: [String: (code: UInt16, characters: String)] = [
    "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "↑": (126, "\u{F700}"),
    "↓": (125, "\u{F701}"), "↩": (36, "\r"), "⎋": (53, "\u{1B}"), "q": (12, "q"),
  ]
  let (code, typed) = keys[key]!
  // A real arrow key also carries the function-key and keypad flags.
  let flags = code >= 125 ? modifiers.union([.function, .numericPad]) : modifiers
  window.sendEvent(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: characters ?? typed,
      charactersIgnoringModifiers: characters ?? typed, isARepeat: false, keyCode: code)!)
}

/// The panel as it draws now, as PNG data. It renders offscreen, as `screencapture` cannot run
/// over SSH.
@MainActor func pixels(_ window: NSWindow) throws -> Data {
  let view = try #require(window.contentView)
  view.layoutSubtreeIfNeeded()
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.cacheDisplay(in: view.bounds, to: bitmap)
  return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor func writePNG(_ window: NSWindow, to path: String) throws {
  let url = URL(fileURLWithPath: path)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try pixels(window).write(to: url)
}
