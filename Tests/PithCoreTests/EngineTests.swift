import Darwin
import Testing
import os

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

@Test func warmUpGroupsTheProcessesBeforeTheFirstOpen() async {  // R21, spec 10
  // Reading every app's bundle at once takes about 40 ms, which the first open must not wait for.
  let bundleReads = OSAllocatedUnfairLock(initialState: 0)
  let grouper = AppGrouper(responsible: nil) { path in
    bundleReads.withLock { $0 += 1 }
    return Fixture.bundleInfo(path)
  }
  let e = Engine(
    system: FakeSystem(), processes: SequenceTable(.chromeAt0, .chromeAt1s), grouper: grouper,
    guide: .empty, cpuCount: 10)
  let warm = await e.warmUp()
  let warmed = bundleReads.withLock { $0 }
  let s = await e.tick(mode: .open)
  #expect(warm.mode == .open && warm.apps.map(\.name) == ["Google Chrome"])
  #expect(warmed > 0 && bundleReads.withLock { $0 } == warmed)
  // The warm-up keeps no table: the first open reading still has no rates.
  #expect(s.apps[0].cpu == .unavailable("first sample"))
}

@Test func resetBaselineHidesStaleCPU() async {  // Review Focus 3
  let e = engine(SequenceTable(.chromeAt0, .chromeAt1s))
  _ = await e.tick(mode: .open)
  await e.resetBaseline()
  #expect(await e.tick(mode: .open).apps[0].cpu == .unavailable("first sample"))
}

@Test func resetBaselineRestartsTheSystemCPUBaseline() async {  // R57: wake
  // Without the reset, the first tick after wake would average the busy share over the sleep.
  let ticks = scriptedTicks(
    .value([CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]),
    .value([CPUTicks(user: 10, system: 0, idle: 30, nice: 0)]),
    .value([CPUTicks(user: 20, system: 0, idle: 1000, nice: 0)]))
  let e = Engine(
    system: SystemReader(sampleTicks: ticks), processes: SpyTable(), grouper: .fake, guide: .empty,
    cpuCount: 10)
  _ = await e.tick(mode: .closed)
  #expect(await e.tick(mode: .closed).totals.cpuBusy == .value(0.25))
  await e.resetBaseline()
  #expect(await e.tick(mode: .closed).totals.cpuBusy == .unavailable("first sample"))
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

@Test func reopeningRestartsBothCPUBaselines() async {  // R56
  // The reader diffs on every tick, a closed one included, so an open tick after a closed one
  // would put one interval of system CPU against two of app CPU.
  let ticks = scriptedTicks(
    .value([CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]),
    .value([CPUTicks(user: 90, system: 0, idle: 10, nice: 0)]),
    .value([CPUTicks(user: 100, system: 0, idle: 100, nice: 0)]),
    .value([CPUTicks(user: 130, system: 0, idle: 170, nice: 0)]))
  let e = Engine(
    system: SystemReader(sampleTicks: ticks),
    processes: SequenceTable(.chromeAt0, .chromeAt2s, .chromeAt3s), grouper: .fake, guide: .empty,
    cpuCount: 10)
  _ = await e.tick(mode: .open)
  _ = await e.tick(mode: .closed)  // reads no table
  let reopened = await e.tick(mode: .open)
  #expect(reopened.apps[0].cpu == .unavailable("first sample"))
  #expect(reopened.system.value?.cpu == .unavailable("first sample"))
  let next = await e.tick(mode: .open)  // 5 processes × 0.1 s over 1 s on 10 cores, 30 busy of 100
  #expect(next.apps[0].cpu == .value(0.05))
  #expect(abs(next.system.value!.cpu.value! - 0.25) < 1e-9)
}

@Test func execOfTheSameBinaryFromAnotherAppRegroupsWithNoRate() async {  // R140
  // One helper binary in two bundles: the exec keeps the PID, the start time and the Mach-O UUID
  // (the fake's is 0), and only p_idversion changes.
  let execed = OSAllocatedUnfairLock(initialState: false)
  var probe = ProcessProbe.fake(pids: [10], uid: 501)
  probe.bsdInfo = { _ in (501, 1, "Helper", execed.withLock { $0 } ? 2 : 1, 10, 1) }
  probe.idVersion = { _ in execed.withLock { $0 } ? 2 : 1 }
  probe.path = { _ in
    "/Applications/\(execed.withLock { $0 } ? "Slack" : "Notes").app/Contents/MacOS/Helper"
  }
  let e = engine(LibprocProcessTable(probe: probe, uid: 501))
  #expect(await e.tick(mode: .open).apps.map(\.id) == ["/Applications/Notes.app"])
  execed.withLock { $0 = true }
  let after = await e.tick(mode: .open)
  #expect(after.apps.map(\.id) == ["/Applications/Slack.app"])
  #expect(after.apps.map(\.cpu) == [.unavailable("first sample")])
}
