import Darwin
import os

@testable import PithCore

actor Counter {
  private(set) var value = 0
  func bump() { value += 1 }
}

/// Fixed whole-machine totals: 16 GB used of 16 GB, half the CPU busy.
struct FakeSystem: SystemTotalsReading {
  static let totals = SystemTotals(
    memoryUsed: 16 << 30, memoryTotal: 16 << 30, pressure: .normal, swapUsed: 0,
    cpuBusy: .value(0.5), storageFree: .unavailable("fake"), storageTotal: .unavailable("fake"))

  func read() -> SystemTotals { Self.totals }
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

/// Returns the given tables in order. A read past the last one traps.
final class SequenceTable: ProcessTableReading {
  private let tables: OSAllocatedUnfairLock<[ProcessTable]>

  init(_ tables: ProcessTable...) { self.tables = OSAllocatedUnfairLock(initialState: tables) }

  func readTable() -> ProcessTable { tables.withLock { $0.removeFirst() } }
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

extension rusage_info_v6 {
  static func fake(footprint: UInt64) -> rusage_info_v6 {
    var usage = rusage_info_v6()
    usage.ri_phys_footprint = footprint
    return usage
  }
}
