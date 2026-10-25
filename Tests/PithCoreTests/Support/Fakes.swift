import Darwin

@testable import PithCore

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
