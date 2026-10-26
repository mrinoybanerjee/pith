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
