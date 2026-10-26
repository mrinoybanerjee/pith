import AppKit
import PithCore
import Testing

@testable import Pith

@MainActor @Test func dotImageChangesOnlyOnStateChange() {
  startAppKit()
  let c = StatusItemController(onClick: {})
  c.show(.calm)
  c.show(.calm)
  c.show(.tight)
  c.show(.tight)
  c.show(.calm)
  #expect(c.imageChanges == 3)
  #expect(c.statusItemLength == 22)  // fixed width, never variable
}

@MainActor @Test func onlyTheCalmDotIsATemplateAndCriticalIsShown() {
  startAppKit()
  let c = StatusItemController(onClick: {})
  c.show(.calm)
  #expect(c.item.button!.image!.isTemplate)
  c.show(.tight)
  let tight = c.item.button!.image!
  #expect(!tight.isTemplate)
  c.show(.critical)
  #expect(!c.item.button!.image!.isTemplate && c.item.button!.image !== tight)
  #expect(c.imageChanges == 3)
}

@MainActor @Test func theLabelNamesTheStatus() {
  startAppKit()
  let c = StatusItemController(onClick: {})
  c.show(
    status: Status(dot: .critical, title: "Memory is very tight", sentence: "Synthetic sentence."))
  #expect(c.item.button!.accessibilityLabel() == "Pith: Memory is very tight")
}

/// A status item button with no window, or a window with no screen, has no anchor, so a click on it
/// is ignored, not a trap (the PR 2 council's minor).
@MainActor @Test func aButtonWithNoWindowOrScreenHasNoAnchor() {
  startAppKit()
  #expect(StatusItemController.anchor(of: nil) == nil)
  #expect(StatusItemController.anchor(of: NSButton()) == nil)
  let offscreen = NSWindow(
    contentRect: NSRect(x: -100_000, y: -100_000, width: 40, height: 40), styleMask: [.borderless],
    backing: .buffered, defer: true)
  #expect(offscreen.screen == nil)
  #expect(StatusItemController.anchor(of: offscreen.contentView) == nil)
  #expect(StatusItemController {}.anchor != nil)
}
