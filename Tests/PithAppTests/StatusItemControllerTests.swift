import AppKit
import PithCore
import Testing

@testable import Pith

/// The image changes only when the dot state or the awake ring changes (Awake spec 3.1).
@MainActor @Test func dotImageChangesOnlyOnStateChange() {
  startAppKit()
  let c = StatusItemController(onClick: {})
  for (dot, ring) in [
    (DotState.calm, false), (.calm, false), (.tight, false), (.tight, false), (.tight, true),
    (.tight, true), (.calm, true), (.calm, false),
  ] {
    c.show(dot, ring: ring)
  }
  #expect(c.imageChanges == 5)
  #expect(c.statusItemLength == 22)  // fixed width, never variable
}

/// Awake spec 3.1: 6 images, the dot of each state alone and in the ring. Only the calm ones are
/// templates.
@MainActor @Test func sixImagesAndOnlyTheCalmOnesAreTemplates() {
  startAppKit()
  let c = StatusItemController(onClick: {})
  var images: [NSImage] = []
  for ring in [false, true] {
    for dot in [DotState.calm, .tight, .critical] {
      c.show(dot, ring: ring)
      images.append(c.item.button!.image!)
    }
  }
  #expect(Set(images.map(ObjectIdentifier.init)).count == 6 && c.imageChanges == 6)
  #expect(images.map(\.isTemplate) == [true, false, false, true, false, false])
}

/// Awake spec 3.1: the label names the status, then the session's end while one runs, then the
/// lid while "Lid closed" is ticked.
@MainActor @Test func theLabelNamesTheStatusAndTheSession() {
  startAppKit()
  let c = StatusItemController(onClick: {})
  let status = Status(
    dot: .critical, title: "Memory is very tight", sentence: "Synthetic sentence.")
  c.show(status: status, awake: nil)
  #expect(c.item.button!.accessibilityLabel() == "Pith: Memory is very tight.")
  let timed = Awake(until: Date.now + 3600)
  c.show(status: status, awake: timed)
  #expect(c.item.button!.accessibilityLabel() == "Pith: Memory is very tight. \(timed.title).")
  c.show(status: status, awake: Awake(until: nil))
  #expect(
    c.item.button!.accessibilityLabel() == "Pith: Memory is very tight. Awake until you end it.")
  c.show(status: status, awake: Awake(until: nil, lidClosed: true))
  #expect(
    c.item.button!.accessibilityLabel()
      == "Pith: Memory is very tight. Awake until you end it. Even with the lid closed.")
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
