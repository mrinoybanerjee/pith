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

@Test func ticksReadSystemThenTable() async {
  let log = ReadLog()
  let e = Engine(system: log, processes: log, grouper: .fake, guide: .empty, cpuCount: 10)
  _ = await e.tick(mode: .open)
  _ = await e.tick(mode: .closed)
  #expect(log.reads == ["system", "table", "system"])
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

@Test func cpuResidualRestartsAfterAFailedSystemRead() async {  // R55
  // Each interval is 1 s, and Chrome uses 0.05 of the machine in it (5 processes × 0.1 s on 10
  // cores). The sample before the failure is 0, the recovery sample is 100 busy of 200 ticks
  // (0.5 over the two intervals), and the last interval is 30 busy of 100 (0.3).
  let ticks = scriptedTicks(
    .value([CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]),
    .unavailable("host_processor_info failed: 4"),
    .value([CPUTicks(user: 100, system: 0, idle: 100, nice: 0)]),
    .value([CPUTicks(user: 130, system: 0, idle: 170, nice: 0)]))
  let e = Engine(
    system: SystemReader(sampleTicks: ticks),
    processes: SequenceTable(.chromeAt0, .chromeAt1s, .chromeAt2s, .chromeAt3s), grouper: .fake,
    guide: .empty, cpuCount: 10)
  var residual: [Reading<Double>] = []
  for _ in 0..<4 { residual.append(await e.tick(mode: .open).system.value!.cpu) }
  #expect(
    residual.prefix(3) == [
      .unavailable("first sample"), .unavailable("host_processor_info failed: 4"),
      .unavailable("first sample"),  // not 0.5 - 0.05, which spans two intervals against one
    ])
  #expect(abs(residual[3].value! - 0.25) < 1e-9)  // 0.3 - 0.05, both over the last interval
}
