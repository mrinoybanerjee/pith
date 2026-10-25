import Foundation
import Testing

@testable import Pith

@Test func settingsDefaultsAndPersist() {
  let name = "pith.tests.\(UUID())"
  defer { UserDefaults().removePersistentDomain(forName: name) }
  let d = UserDefaults(suiteName: name)!
  var s = Settings.load(d)
  #expect(s == Settings())
  s.refresh = .twoSeconds
  s.save(d)
  #expect(Settings.load(d).refresh == .twoSeconds)
}

@Test func everySettingAndThePinnedFrameSurviveASaveAndReload() {
  let name = "pith.tests.\(UUID())"
  defer { UserDefaults().removePersistentDomain(forName: name) }
  let saved = Settings(launchAtLogin: false, refresh: .twoSeconds, amberOnCPU: false)
  let frame = CGRect(x: 1520.5, y: 300, width: 360, height: 480)
  let d = UserDefaults(suiteName: name)!
  saved.save(d)
  d.pinnedFrame = frame
  let reloaded = UserDefaults(suiteName: name)!
  #expect(Settings.load(reloaded) == saved)
  #expect(reloaded.pinnedFrame == frame)
}
