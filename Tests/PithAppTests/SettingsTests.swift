import Foundation
import Testing

@testable import Pith

@Test func settingsDefaultsAndPersist() {
  let d = UserDefaults(suiteName: "pith.tests.\(UUID())")!
  var s = Settings.load(d)
  #expect(s == Settings())
  s.refresh = .twoSeconds
  s.save(d)
  #expect(Settings.load(d).refresh == .twoSeconds)
}
