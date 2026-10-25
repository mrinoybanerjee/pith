import Darwin
import Foundation
import os

@testable import PithCore

actor Counter {
  private(set) var value = 0
  func bump() { value += 1 }
}

/// Fixed whole-machine totals: 16 GB used of 16 GB, nothing compressed, half the CPU busy.
struct FakeSystem: SystemTotalsReading {
  static let totals = SystemTotals(
    memoryUsed: .value(16 << 30), footprintTotal: .value(16 << 30), memoryTotal: 16 << 30,
    pressure: .value(.normal),
    swapUsed: .value(0), cpuBusy: .value(0.5), storageFree: .unavailable("fake"),
    storageTotal: .unavailable("fake"))

  func read() -> SystemTotals { Self.totals }
  func resetCPUBaseline() {}
}

/// Counts reads. Each read returns an empty table.
final class SpyTable: ProcessTableReading {
  private let count = OSAllocatedUnfairLock(initialState: 0)

  var reads: Int { count.withLock { $0 } }

  func readTable() -> ProcessTable {
    count.withLock { $0 += 1 }
    return ProcessTable(samples: [], takenAtNs: 1, vanished: 0)
  }
}

/// Both readers in one, logging each read in order. It returns `FakeSystem.totals` and
/// `ProcessTable.chromeAt0`.
final class ReadLog: SystemTotalsReading, ProcessTableReading {
  private let log = OSAllocatedUnfairLock(initialState: [String]())

  var reads: [String] { log.withLock { $0 } }

  func read() -> SystemTotals {
    log.withLock { $0.append("system") }
    return FakeSystem.totals
  }

  func resetCPUBaseline() {}

  func readTable() -> ProcessTable {
    log.withLock { $0.append("table") }
    return .chromeAt0
  }
}

/// Returns the given tables in order. A read past the last one traps.
final class SequenceTable: ProcessTableReading {
  private let tables: OSAllocatedUnfairLock<[ProcessTable]>

  init(_ tables: ProcessTable...) { self.tables = OSAllocatedUnfairLock(initialState: tables) }

  func readTable() -> ProcessTable { tables.withLock { $0.removeFirst() } }
}

/// A `SystemReader` CPU sampler that returns the given samples in order. A read past the last
/// one traps.
func scriptedTicks(_ samples: Reading<[CPUTicks]>...) -> @Sendable () -> Reading<[CPUTicks]> {
  let rest = OSAllocatedUnfairLock(initialState: samples)
  return { rest.withLock { $0.removeFirst() } }
}

extension AppGrouper {
  /// Groups the table fixtures in `.limited` mode.
  static let fake = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
}

extension ProcessProbe {
  /// Synthetic processes: each PID belongs to `uid`, has parent 1 and a footprint of 1 byte.
  static func fake(pids: [Int32], uid: UInt32) -> ProcessProbe {
    ProcessProbe(
      listPIDs: { pids },
      bsdInfo: { _ in (uid, 1, "fake") },
      rusage: { _ in .success(.fake(footprint: 1)) },
      path: { _ in "/Applications/Fake.app/Contents/MacOS/Fake" })
  }
}

extension UUID {
  /// A made-up executable UUID: `n`, then 15 zero bytes. The table fixtures use `executable(0)`.
  static func executable(_ n: UInt8) -> UUID {
    UUID(uuid: (n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  }
}

extension rusage_info_v6 {
  static func fake(footprint: UInt64) -> rusage_info_v6 {
    var usage = rusage_info_v6()
    usage.ri_phys_footprint = footprint
    return usage
  }
}
