import Dispatch
import Testing

@testable import PithCore

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

@Test func clockTicksAndPauses() async {
  let n = Counter()
  let c = Clock(onTick: { Task { await n.bump() } })
  c.configure(seconds: 0.05, leeway: 0.005)
  try? await Task.sleep(for: .milliseconds(180))
  c.pause()
  let paused = await n.value
  try? await Task.sleep(for: .milliseconds(150))
  #expect(paused >= 2)
  #expect(await n.value == paused)
}

@Test func pauseAndResumeAreIdempotent() async {
  let n = Counter()
  let c = Clock(onTick: {
    dispatchPrecondition(condition: .notOnQueue(.main))
    Task { await n.bump() }
  })
  c.resume()  // already running: not an over-resume
  c.configure(seconds: 0.05, leeway: 0.005)
  c.pause()
  c.pause()
  c.resume()  // one resume ends any number of pauses
  try? await Task.sleep(for: .milliseconds(180))
  #expect(await n.value >= 2)
}

@Test func configureReschedules() async {
  let n = Counter()
  let c = Clock(onTick: { Task { await n.bump() } })
  c.configure(seconds: 60, leeway: 1)
  c.configure(seconds: 0.5, leeway: 0.05)
  try? await Task.sleep(for: .milliseconds(100))
  #expect(await n.value == 0)  // the first tick comes one interval after `configure`
  try? await Task.sleep(for: .milliseconds(600))
  #expect(await n.value >= 1)
}

@Test func pausedClockCanBeReleased() {
  Clock(onTick: {}).pause()  // libdispatch traps if a suspended timer is released
}
