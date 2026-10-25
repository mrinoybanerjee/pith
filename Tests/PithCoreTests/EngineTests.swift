import Darwin
import Testing

@testable import PithCore

private func engine(_ processes: any ProcessTableReading) -> Engine {
  Engine(system: FakeSystem(), processes: processes, grouper: .fake, guide: .empty, cpuCount: 10)
}

@Test func closedTickReadsNoProcesses() async {
  let spy = SpyTable()
  let s = await engine(spy).tick(mode: .closed)
  #expect(s.apps.isEmpty && spy.reads == 0)
}

@Test func closedTickIsTakenNowWithSystemTotals() async {
  let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  let s = await engine(SpyTable()).tick(mode: .closed)
  #expect((before...clock_gettime_nsec_np(CLOCK_UPTIME_RAW)).contains(s.takenAtNs))
  #expect(s.mode == .closed && s.totals == FakeSystem.totals)
}

@Test func openTickDiffsAcrossClosedTicks() async {
  let e = engine(SequenceTable(.chromeAt0, .chromeAt1s))
  _ = await e.tick(mode: .open)
  _ = await e.tick(mode: .closed)  // reads no table and keeps the previous one
  // 5 processes × 0.1 s of CPU over 1 s on 10 cores.
  #expect(await e.tick(mode: .open).apps[0].cpu == .value(0.05))
}

@Test func resetBaselineHidesStaleCPU() async {  // Review Focus 3
  let e = engine(SequenceTable(.chromeAt0, .chromeAt1s))
  _ = await e.tick(mode: .open)
  await e.resetBaseline()
  #expect(await e.tick(mode: .open).apps[0].cpu == .unavailable("first sample"))
}
