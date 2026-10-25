import Foundation
import Testing

@testable import PithCore

@Test func usedMatchesActivityMonitorFormula() {
  let c = VMCounts(internal: 600_000, purgeable: 100_000, wired: 150_000, compressor: 50_000)
  #expect(memoryUsed(c, pageSize: 16_384) == 700_000 * 16_384)
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

@Test func pressureLevels() {
  #expect(Pressure(kernelLevel: 1) == .normal)
  #expect(Pressure(kernelLevel: 2) == .warning)
  #expect(Pressure(kernelLevel: 4) == .critical)
}

@Test func liveReadIsSane() throws {
  let r = SystemReader()
  let first = r.read()
  #expect(first.memoryTotal == ProcessInfo.processInfo.physicalMemory)
  #expect(first.memoryUsed > 0 && first.memoryUsed <= first.memoryTotal)
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
