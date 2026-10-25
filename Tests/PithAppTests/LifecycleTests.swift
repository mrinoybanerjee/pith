import Foundation
import PithCore
import Testing

@testable import Pith

/// Records the interval of each schedule it is given.
@MainActor private final class RecordingClock: Ticker {
  var intervals: [Double] = []

  func configure(seconds: Double, leeway: Double) { intervals.append(seconds) }
  func pause() {}
  func resume() {}
}

@MainActor @Test func panelChangesReconfigureTheClockAndOpeningTicksAtOnce() async throws {
  let clock = RecordingClock()
  let store = Store(settings: Settings())
  let reader = SystemReader()
  let engine = Engine(
    system: reader, processes: LibprocProcessTable(), grouper: .live(), guide: .empty,
    cpuCount: ProcessInfo.processInfo.activeProcessorCount)
  let lifecycle = Lifecycle(
    clock: clock, engine: engine, store: store, reader: reader,
    defaults: UserDefaults(suiteName: "pith.tests.\(UUID())")!,
    loginItem: { _ in Issue.record("the login item was set") })

  lifecycle.panelChanged(visible: true, pinned: false, occluded: false)  // opened
  for _ in 0..<200 where store.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
  #expect(store.snapshot?.mode == .open)
  lifecycle.panelChanged(visible: true, pinned: false, occluded: true)  // attached: still open
  lifecycle.panelChanged(visible: true, pinned: true, occluded: true)  // pinned and covered
  lifecycle.panelChanged(visible: true, pinned: true, occluded: false)
  lifecycle.panelChanged(visible: false, pinned: true, occluded: false)  // closed

  let thermal = ProcessInfo.processInfo.thermalState
  func interval(_ mode: Mode) -> Double {
    SamplingPolicy.interval(
      mode: mode, refresh: .oneSecond, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
      thermalSerious: thermal == .serious || thermal == .critical
    ).seconds
  }
  #expect(
    clock.intervals == [interval(.open), interval(.closed), interval(.open), interval(.closed)])
}
