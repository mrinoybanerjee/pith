import Foundation
import Testing

@testable import Pith

@Test func settingsDefaultsAndPersist() {
  let d = testDefaults()
  defer { clearDefaults() }
  var s = Settings.load(d)
  #expect(s == Settings())
  s.refresh = .twoSeconds
  s.save(d)
  #expect(Settings.load(d).refresh == .twoSeconds)
}

@Test func everySettingAndThePinnedFrameSurviveASaveAndReload() {
  let d = testDefaults()
  defer { clearDefaults() }
  let saved = Settings(refresh: .twoSeconds, amberOnCPU: false)
  let frame = CGRect(x: 1520.5, y: 300, width: 360, height: 480)
  saved.save(d)
  d.pinnedFrame = frame
  d.loginItemOfferedOnce = true
  let reloaded = UserDefaults(suiteName: testSuite())!
  #expect(Settings.load(reloaded) == saved)
  #expect(reloaded.pinnedFrame == frame && reloaded.loginItemOfferedOnce)
}
