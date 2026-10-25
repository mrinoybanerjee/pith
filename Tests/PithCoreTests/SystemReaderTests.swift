import Foundation
import Testing
import os

@testable import PithCore

@Test func usedMatchesActivityMonitorFormula() {
  let c = VMCounts(internal: 600_000, purgeable: 100_000, wired: 150_000, compressor: 50_000)
  #expect(memoryUsed(c, pageSize: 16_384) == 700_000 * 16_384)
}

@Test func memoryUsedDoesNotUnderflowOnTheWay() {
  let c = VMCounts(internal: 1, purgeable: 2, wired: 3, compressor: 0)  // internal - purgeable < 0
  #expect(memoryUsed(c, pageSize: 1) == 2)
}

@Test func cpuBusyAcrossCores() {
  let a = [
    CPUTicks(user: 100, system: 50, idle: 850, nice: 0),
    CPUTicks(user: 0, system: 0, idle: 1000, nice: 0),
  ]
  let b = [
    CPUTicks(user: 200, system: 100, idle: 1700, nice: 0),
    CPUTicks(user: 100, system: 0, idle: 1900, nice: 0),
  ]
  #expect(abs(cpuBusyFraction(previous: a, current: b) - 0.125) < 1e-9)  // 250 busy of 2000
}

@Test func cpuTicksWrapSafely() {
  let a = [CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
  let b = [CPUTicks(user: 10, system: 0, idle: 20, nice: 0)]  // user advanced 20, idle 20
  #expect(abs(cpuBusyFraction(previous: a, current: b) - 0.5) < 1e-9)
}

@Test func cpuBusyIsNaNWhenNoTicksElapsed() {
  let a = [CPUTicks(user: 5, system: 5, idle: 5, nice: 5)]
  #expect(cpuBusyFraction(previous: a, current: a).isNaN)
}

@Test func pressureLevels() {  // the kernel defines no level 3, so it is unknown
  #expect(
    [1, 2, 4, 3].map(Pressure.reading(kernelLevel:)) == [
      .value(.normal), .value(.warning), .value(.critical),
      .unavailable("unknown pressure level 3"),
    ])
}

@Test func liveReadIsSane() throws {
  let r = SystemReader()
  let first = r.read()
  #expect(first.memoryTotal == ProcessInfo.processInfo.physicalMemory)
  let used = try #require(first.memoryUsed.value)
  #expect(used > 0 && used <= first.memoryTotal)
  #expect(first.pressure.value != nil && first.swapUsed.value != nil)
  #expect(first.cpuBusy == .unavailable("first sample"))
  Thread.sleep(forTimeInterval: 0.2)
  let busy = try #require(r.read().cpuBusy.value)
  #expect((0...1).contains(busy))
  #expect((first.storageFree.value ?? 0) > 0)
}

@Test func storageIsCachedUntilInvalidated() throws {
  let r = SystemReader()
  #expect(r.storageCachedAt == nil)
  _ = r.read()
  let readAt = try #require(r.storageCachedAt)
  _ = r.read()
  #expect(r.storageCachedAt == readAt)  // second read within 60 s reuses the cache
  r.invalidateStorageCache()
  #expect(r.storageCachedAt == nil)
  _ = r.read()
  #expect(try #require(r.storageCachedAt) > readAt)
}

@Test func monitorStartsAtTheKernelLevel() {
  #expect(PressureMonitor { _ in }.current == Pressure.fromKernel())
}

@Test func concurrentReadsKeepTheTickSamplesInOrder() async {
  // Each sample advances busy by 1 and idle by 3, so a correctly ordered pair reads 0.25.
  // A pair swapped out of order wraps and reads about 0.5.
  let counter = OSAllocatedUnfairLock(initialState: UInt32(0))
  let r = SystemReader(sampleTicks: {
    let n = counter.withLock { count -> UInt32 in
      count += 1
      return count
    }
    Thread.sleep(forTimeInterval: 0.0002)  // widens any gap between sampling and recording
    return .value([CPUTicks(user: n, system: 0, idle: 3 * n, nice: 0)])
  })
  let busy = await withTaskGroup(of: Reading<Double>.self) { group in
    for _ in 0..<50 { group.addTask { r.read().cpuBusy } }
    return await group.reduce(into: []) { $0.append($1) }
  }
  #expect(busy.filter { $0 == .unavailable("first sample") }.count == 1)
  #expect(busy.filter { $0 == .value(0.25) }.count == 49)
}

@Test func failedCPUSampleClearsTheBaseline() {
  let r = SystemReader(
    sampleTicks: scriptedTicks(
      .unavailable("host_processor_info failed: 4"),  // before any baseline
      .value([CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]),
      .unavailable("host_processor_info failed: 4"),
      .value([CPUTicks(user: 4, system: 0, idle: 4, nice: 0)]),
      .value([CPUTicks(user: 5, system: 0, idle: 7, nice: 0)])))
  #expect(r.read().cpuBusy == .unavailable("host_processor_info failed: 4"))
  #expect(r.read().cpuBusy == .unavailable("first sample"))
  #expect(r.read().cpuBusy == .unavailable("host_processor_info failed: 4"))
  #expect(r.read().cpuBusy == .unavailable("first sample"))  // not 0.5 against the old baseline
  #expect(r.read().cpuBusy == .value(0.25))  // against the recovery sample
}

/// R122: two reads so close together that no tick elapsed have no busy share yet. That is a first
/// sample, which the panel reads as "not available yet"; the next read has it.
@Test func readsWithNoTicksBetweenThemAreAFirstSample() {
  let same = CPUTicks(user: 10, system: 0, idle: 30, nice: 0)
  let r = SystemReader(
    sampleTicks: scriptedTicks(
      .value([same]), .value([same]), .value([CPUTicks(user: 11, system: 0, idle: 33, nice: 0)])))
  #expect(r.read().cpuBusy.isFirstSample)
  #expect(r.read().cpuBusy.isFirstSample)
  #expect(r.read().cpuBusy == .value(0.25))
}
