import CoreGraphics

/// Where the panel goes (spec 4.2 and 4.7). Pure, so placement on any display and near any edge is
/// testable.
enum PanelGeometry {
  /// Centered under the status item, then clamped onto the item's screen.
  static func attachedFrame(itemFrame: CGRect, panelSize: CGSize, visibleFrame: CGRect) -> CGRect {
    clamp(
      CGRect(
        x: itemFrame.midX - panelSize.width / 2, y: itemFrame.minY - panelSize.height,
        width: panelSize.width, height: panelSize.height),
      to: visibleFrame)
  }

  /// Moves `frame`, keeping its size, until it lies at least 8 pt inside `visibleFrame`.
  static func clamp(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
    let inner = visibleFrame.insetBy(dx: 8, dy: 8)
    var clamped = frame
    clamped.origin.x = max(inner.minX, min(frame.minX, inner.maxX - frame.width))
    clamped.origin.y = max(inner.minY, min(frame.minY, inner.maxY - frame.height))
    return clamped
  }
}
