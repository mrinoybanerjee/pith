import Testing

@testable import Pith

@MainActor @Test func dotImageChangesOnlyOnStateChange() {
  let c = StatusItemController(onClick: {})
  c.show(.calm)
  c.show(.calm)
  c.show(.tight)
  c.show(.tight)
  c.show(.calm)
  #expect(c.imageChanges == 3)
  #expect(c.statusItemLength == 22)  // fixed width, never variable
}
