import AppKit
import PithCore

/// The calm dot in the menu bar (spec 4.1), in a thin ring while the Mac is kept awake (Awake spec
/// 3.1). The item has a fixed width, and its image changes only when the dot state or the ring
/// changes, so the status bar is not laid out again on every tick (spec 9).
@MainActor final class StatusItemController: NSObject {
  /// The 6 images: the dot of each state, alone and in the ring.
  private static let images = [false: dots(ring: false), true: dots(ring: true)]

  let item: NSStatusItem
  private let onClick: () -> Void
  private var dot: DotState?
  private var ring = false
  private(set) var imageChanges = 0

  var statusItemLength: CGFloat { item.length }

  /// The item's frame on screen and the visible frame of its screen, where the attached panel hangs.
  var anchor: (itemFrame: CGRect, visibleFrame: CGRect)? { Self.anchor(of: item.button) }

  /// `button`'s frame on screen and its screen's visible frame. Nil while it has no window or the
  /// window no screen, as while macOS lays out the menu bar again: a click then does nothing.
  static func anchor(of button: NSView?) -> (itemFrame: CGRect, visibleFrame: CGRect)? {
    guard let button, let window = button.window, let screen = window.screen else { return nil }
    return (window.convertToScreen(button.convert(button.bounds, to: nil)), screen.visibleFrame)
  }

  /// AppKit must be up first: without `NSApplication.shared`, macOS 15's status bar calls the
  /// window server before the process has a connection, and the process aborts in
  /// `CGSConnectionByID` (R124). macOS 26 sets the app up itself, which hides the mistake.
  init(onClick: @escaping () -> Void) {
    assert(NSApp != nil, "a status item needs NSApplication.shared first")
    item = NSStatusBar.system.statusItem(withLength: 22)
    self.onClick = onClick
    super.init()
    item.button!.target = self
    item.button!.action = #selector(clicked)
  }

  func show(status: Status, awake: Awake?) {
    show(status.dot, ring: awake != nil)
    item.button!.setAccessibilityLabel(
      "Pith: \(status.title)." + (awake.map { " \($0.title)." } ?? ""))
  }

  func show(_ dot: DotState, ring: Bool) {
    guard dot != self.dot || ring != self.ring else { return }
    (self.dot, self.ring) = (dot, ring)
    item.button!.image = Self.images[ring]![dot]
    imageChanges += 1
  }

  @objc private func clicked() { onClick() }

  private static func dots(ring: Bool) -> [DotState: NSImage] {
    [
      .calm: dot(fill: nil, ring: ring), .tight: dot(fill: .systemOrange, ring: ring),
      .critical: dot(fill: .systemRed, ring: ring),
    ]
  }

  /// A 16 pt image with a 9 pt circle: an outline template when calm, filled with `fill` otherwise.
  /// With `ring`, a 14 pt circle with a 1.25 pt line goes around it, in the menu bar's text color
  /// whatever the dot's state (Awake spec 3.1).
  private static func dot(fill: NSColor?, ring: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
      if let fill {
        fill.setFill()
        NSBezierPath(ovalIn: NSRect(x: 3.5, y: 3.5, width: 9, height: 9)).fill()
      } else {
        // Inset by half the line width, so the stroke's outer edge is the 9 pt circle.
        let outline = NSBezierPath(ovalIn: NSRect(x: 4.3, y: 4.3, width: 7.4, height: 7.4))
        outline.lineWidth = 1.6
        NSColor.black.setStroke()
        outline.stroke()
      }
      if ring {
        // Inset as the outline is. A template takes the menu bar's color; a colored image draws in
        // the menu bar's appearance, so its label color is the menu bar's text color.
        let circle = NSBezierPath(ovalIn: NSRect(x: 1.625, y: 1.625, width: 12.75, height: 12.75))
        circle.lineWidth = 1.25
        (fill == nil ? NSColor.black : .labelColor).setStroke()
        circle.stroke()
      }
      return true
    }
    image.isTemplate = fill == nil
    return image
  }
}
