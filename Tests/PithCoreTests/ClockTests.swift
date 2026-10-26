import Darwin
import Dispatch
import Testing
import os

@testable import PithCore

/// A clock that counts its ticks synchronously on its own queue, which is never the main queue.
private func countingClock() -> (clock: Clock, ticks: @Sendable () -> Int) {
  let n = OSAllocatedUnfairLock(initialState: 0)
  let clock = Clock(onTick: {
    dispatchPrecondition(condition: .notOnQueue(.main))
    n.withLock { $0 += 1 }
  })
  return (clock, { n.withLock { $0 } })
}

@Test func intervals() {
  #expect(
    SamplingPolicy.interval(
      mode: .closed, refresh: .oneSecond, lowPower: false, thermalSerious: false) == (5, 1))
  #expect(
    SamplingPolicy.interval(
      mode: .open, refresh: .oneSecond, lowPower: false, thermalSerious: false) == (1, 0.1))
  #expect(
    SamplingPolicy.interval(
      mode: .open, refresh: .twoSeconds, lowPower: false, thermalSerious: false) == (2, 0.2))
  #expect(
    SamplingPolicy.interval(
      mode: .closed, refresh: .oneSecond, lowPower: true, thermalSerious: false) == (10, 2))
  #expect(  // the closed speed ignores the refresh setting
    SamplingPolicy.interval(
      mode: .closed, refresh: .twoSeconds, lowPower: false, thermalSerious: false) == (5, 1))
  #expect(
    SamplingPolicy.interval(
      mode: .open, refresh: .twoSeconds, lowPower: false, thermalSerious: true) == (4, 0.4))
  #expect(  // both causes double the interval once, not twice
    SamplingPolicy.interval(
      mode: .open, refresh: .oneSecond, lowPower: true, thermalSerious: true) == (2, 0.2))
}

@Test func refreshSettingPersistsByName() {
  #expect(RefreshSetting.oneSecond.rawValue == "oneSecond")
  #expect(RefreshSetting(rawValue: "twoSeconds") == .twoSeconds)
}

@Test func modes() {  // (panel visible, pinned, occluded) -> mode
  let cases: [(Bool, Bool, Bool, Mode)] = [
    (true, false, false, .open), (true, false, true, .open),  // attached: never occluded-closed
    (true, true, false, .open), (true, true, true, .closed),  // a fully covered pinned panel
    (false, false, false, .closed), (false, false, true, .closed),
    (false, true, false, .closed), (false, true, true, .closed),
  ]
  for (visible, pinned, occluded, mode) in cases {
    #expect(
      ModePolicy.mode(panelVisible: visible, pinned: pinned, occluded: occluded) == mode,
      "visible \(visible), pinned \(pinned), occluded \(occluded)")
  }
}

@Test func clockTicksAndPauses() async throws {
  let (c, ticks) = countingClock()
  c.configure(seconds: 0.05, leeway: 0.005, first: 0.05)
  try await Task.sleep(for: .milliseconds(180))
  c.pause()
  try await Task.sleep(for: .milliseconds(20))  // a tick already running at `pause()` can finish
  let paused = ticks()
  try await Task.sleep(for: .milliseconds(150))
  #expect(paused >= 2)
  #expect(ticks() == paused)
}

@Test func pauseAndResumeAreIdempotent() async throws {
  let (c, ticks) = countingClock()
  c.resume()  // already running: not an over-resume
  c.configure(seconds: 0.05, leeway: 0.005, first: 0.05)
  c.pause()
  c.pause()
  c.resume()  // one resume ends any number of pauses
  try await Task.sleep(for: .milliseconds(180))
  #expect(ticks() >= 2)
}

/// The first tick comes `first` after the last `configure`, never sooner, and well before the 60 s
/// it replaced. A loaded test run can make it later, so the test waits for it and compares its
/// time, rather than counting ticks after a sleep.
@Test(.timeLimit(.minutes(1))) func configureReschedules() async {
  let first = OSAllocatedUnfairLock<CheckedContinuation<UInt64, Never>?>(initialState: nil)
  let c = Clock(onTick: {
    first.withLock { $0.take() }?.resume(returning: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
  })
  var configuredNs: UInt64 = 0
  let tickNs = await withCheckedContinuation { continuation in
    first.withLock { $0 = continuation }
    c.configure(seconds: 60, leeway: 1, first: 60)
    configuredNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    c.configure(seconds: 0.5, leeway: 0.05, first: 0.5)
  }
  let seconds = Double(tickNs - configuredNs) / 1e9
  #expect(seconds >= 0.5 && seconds < 30, "first tick \(seconds) s after configure")
}

@Test func theFirstTickCanComeSoonerThanTheInterval() async throws {  // R134
  let (c, ticks) = countingClock()
  c.configure(seconds: 0.5, leeway: 0.01, first: 0.05)
  try await Task.sleep(for: .milliseconds(250))
  #expect(ticks() == 1)  // at 50 ms; the next comes at 550 ms
}

@Test func pausedClockCanBeReleased() {
  Clock(onTick: {}).pause()  // libdispatch traps if a suspended timer is released
}
