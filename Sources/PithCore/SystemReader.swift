// Portions adapted from Stats (https://github.com/exelban/stats), MIT License,
// Copyright (c) 2020 Serhiy Mytrovtsiy. Source: Modules/RAM/readers.swift L37-L103 at v3.0.22 (1282cd5).
// Portions adapted from Stats (https://github.com/exelban/stats), MIT License,
// Copyright (c) 2020 Serhiy Mytrovtsiy. Source: Modules/CPU/readers.swift L42-L156 at v3.0.22 (1282cd5).

import Darwin
import Foundation
import os

/// Page counts from `host_statistics64`.
public struct VMCounts: Sendable {
  public let `internal`: UInt64  // anonymous pages
  public let purgeable: UInt64
  public let wired: UInt64
  public let compressor: UInt64
}

/// Activity Monitor's "Memory Used": app memory (anonymous minus purgeable), wired and compressed.
public func memoryUsed(_ c: VMCounts, pageSize: UInt64) -> UInt64 {
  (c.internal + c.wired + c.compressor - c.purgeable) * pageSize
}

/// Cumulative scheduler ticks of one core. The counters are 32-bit and wrap.
public struct CPUTicks: Sendable {
  public let user: UInt32
  public let system: UInt32
  public let idle: UInt32
  public let nice: UInt32
}

/// The busy share of all cores between two samples, 0...1. NaN when no ticks elapsed.
public func cpuBusyFraction(previous: [CPUTicks], current: [CPUTicks]) -> Double {
  assert(previous.count == current.count)
  var busy: UInt64 = 0
  var idle: UInt64 = 0
  for (p, c) in zip(previous, current) {
    busy += UInt64(c.user &- p.user) + UInt64(c.system &- p.system) + UInt64(c.nice &- p.nice)
    idle += UInt64(c.idle &- p.idle)
  }
  return Double(busy) / Double(busy + idle)
}

public protocol SystemTotalsReading: Sendable {
  func read() -> SystemTotals
}

/// Reads the whole-machine totals. CPU busy is the change since the previous `read()`, so the
/// first `read()` has none, and a failed sample clears the baseline, so the next good `read()` has
/// none either. Both baselines then restart at that tick, in step with the engine's process table.
/// Storage is read at most once a minute until `invalidateStorageCache()`. A failed kernel read is
/// unavailable, never 0.
public final class SystemReader: SystemTotalsReading {
  private struct StorageCache: Sendable {
    let at: ContinuousClock.Instant
    let free: Reading<UInt64>
    let total: Reading<UInt64>
  }

  private struct State: Sendable {
    var ticks: [CPUTicks]?
    var storage: StorageCache?
  }

  private static let host = mach_host_self()
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let sampleTicks: @Sendable () -> Reading<[CPUTicks]>

  public init() { sampleTicks = Self.readCPUTicks }

  init(sampleTicks: @escaping @Sendable () -> Reading<[CPUTicks]>) {
    self.sampleTicks = sampleTicks
  }

  /// When the storage cache was filled; `nil` before the first read and after invalidation.
  var storageCachedAt: ContinuousClock.Instant? { state.withLock { $0.storage?.at } }

  public func invalidateStorageCache() {
    state.withLock { $0.storage = nil }
  }

  public func read() -> SystemTotals {
    // Sample inside the lock: sampling outside lets two reads record out of order.
    let cpuBusy: Reading<Double> = state.withLock { s in
      switch sampleTicks() {
      case .unavailable(let reason):
        s.ticks = nil
        return .unavailable(reason)
      case .value(let ticks):
        defer { s.ticks = ticks }
        guard let previous = s.ticks else { return .unavailable("first sample") }
        let busy = cpuBusyFraction(previous: previous, current: ticks)
        return busy.isNaN ? .unavailable("no ticks elapsed") : .value(busy)
      }
    }
    let storage = cachedStorage()
    return SystemTotals(
      memoryUsed: Self.readMemoryUsed(),
      memoryTotal: ProcessInfo.processInfo.physicalMemory,
      pressure: Pressure.fromKernel(),
      swapUsed: Self.readSwapUsed(),
      cpuBusy: cpuBusy,
      storageFree: storage.free,
      storageTotal: storage.total)
  }

  private func cachedStorage() -> StorageCache {
    // Read inside the lock, so an in-flight read cannot overwrite a newer invalidation.
    state.withLock { s in
      if let cached = s.storage, ContinuousClock.now - cached.at < .seconds(60) { return cached }
      let fresh = Self.readStorage()
      s.storage = fresh
      return fresh
    }
  }

  private static func readMemoryUsed() -> Reading<UInt64> {
    var pageSize: vm_size_t = 0
    let pageStatus = host_page_size(host, &pageSize)
    guard pageStatus == KERN_SUCCESS else {
      return .unavailable("host_page_size failed: \(pageStatus)")
    }
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return .unavailable("host_statistics64 failed: \(status)") }
    let counts = VMCounts(
      internal: UInt64(stats.internal_page_count), purgeable: UInt64(stats.purgeable_count),
      wired: UInt64(stats.wire_count), compressor: UInt64(stats.compressor_page_count))
    return .value(memoryUsed(counts, pageSize: UInt64(pageSize)))
  }

  private static func readSwapUsed() -> Reading<UInt64> {
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else {
      return .unavailable("vm.swapusage failed: errno \(errno)")
    }
    return .value(swap.xsu_used)
  }

  private static func readCPUTicks() -> Reading<[CPUTicks]> {
    var cpuCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
    guard status == KERN_SUCCESS else {
      return .unavailable("host_processor_info failed: \(status)")
    }
    defer {
      vm_deallocate(
        mach_task_self_, vm_address_t(bitPattern: info),
        vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
    }
    let raw = UnsafeBufferPointer(start: info, count: Int(infoCount))
    let ticks = (0..<Int(cpuCount)).map { cpu in
      let base = cpu * Int(CPU_STATE_MAX)
      return CPUTicks(
        user: UInt32(bitPattern: raw[base + Int(CPU_STATE_USER)]),
        system: UInt32(bitPattern: raw[base + Int(CPU_STATE_SYSTEM)]),
        idle: UInt32(bitPattern: raw[base + Int(CPU_STATE_IDLE)]),
        nice: UInt32(bitPattern: raw[base + Int(CPU_STATE_NICE)]))
    }
    return .value(ticks)
  }

  private static func readStorage() -> StorageCache {
    func reading<T: BinaryInteger>(_ bytes: T?) -> Reading<UInt64> {
      bytes.map { .value(UInt64($0)) } ?? .unavailable("no value")
    }
    let now = ContinuousClock.now
    do {
      let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
      ])
      return StorageCache(
        at: now, free: reading(values.volumeAvailableCapacityForImportantUsage),
        total: reading(values.volumeTotalCapacity))
    } catch {
      return StorageCache(at: now, free: .unavailable("\(error)"), total: .unavailable("\(error)"))
    }
  }
}
