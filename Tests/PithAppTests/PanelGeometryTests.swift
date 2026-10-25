import CoreGraphics
import Testing

@testable import Pith

@Test func panelHangsUnderItemAndStaysOnScreen() {  // Review Focus 5
  let visible = CGRect(x: 1440, y: 0, width: 1920, height: 1055)  // secondary display
  let f = PanelGeometry.attachedFrame(
    itemFrame: CGRect(x: 3340, y: 1055, width: 22, height: 24),
    panelSize: CGSize(width: 360, height: 520), visibleFrame: visible)
  #expect(f.maxX <= visible.maxX - 8 && f.maxY <= visible.maxY && f.width == 360)
  #expect(
    PanelGeometry.clamp(CGRect(x: -500, y: -40, width: 360, height: 520), to: visible).minX
      == visible.minX + 8)
}
