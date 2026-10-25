import AppKit
import PithCore

/// The calm dot in the menu bar (spec 4.1). The item has a fixed width, and its image changes only
/// when the dot state changes, so the status bar is not laid out again on every tick (spec 9).
@MainActor final class StatusItemController: NSObject {
  private static let images: [DotState: NSImage] = [
    .calm: dot(fill: nil), .tight: dot(fill: .systemOrange), .critical: dot(fill: .systemRed),
  ]

  let item: NSStatusItem
  private let onClick: () -> Void
  private var dot: DotState?
  private(set) var imageChanges = 0

  var statusItemLength: CGFloat { item.length }

  /// The item's frame on screen and the visible frame of its screen, where the attached panel hangs.
  var anchor: (itemFrame: CGRect, visibleFrame: CGRect) {
    let button = item.button!
    let window = button.window!
    let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
    return (frame, window.screen!.visibleFrame)
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

  func show(status: Status) {
    show(status.dot)
    item.button!.setAccessibilityLabel("Pith: \(status.title)")
  }

  func show(_ dot: DotState) {
    guard dot != self.dot else { return }
    self.dot = dot
    item.button!.image = Self.images[dot]
    imageChanges += 1
  }

  @objc private func clicked() { onClick() }

  /// A 16 pt image with a 9 pt circle: an outline template when calm, filled with `fill` otherwise.
  private static func dot(fill: NSColor?) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
      if let fill {
        fill.setFill()
        NSBezierPath(ovalIn: NSRect(x: 3.5, y: 3.5, width: 9, height: 9)).fill()
      } else {
        // Inset by half the line width, so the stroke's outer edge is the 9 pt circle.
        let ring = NSBezierPath(ovalIn: NSRect(x: 4.3, y: 4.3, width: 7.4, height: 7.4))
        ring.lineWidth = 1.6
        NSColor.black.setStroke()
        ring.stroke()
      }
      return true
    }
    image.isTemplate = fill == nil
    return image
  }
}
