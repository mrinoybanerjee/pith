import Darwin

/// Owns the readers, the grouper and the previous table (spec 5.3), and returns one immutable
/// `Snapshot` per tick. Only an open tick reads the process table. The system reader diffs on every
/// tick, so a closed tick drops the previous table: the next open tick shows no app CPU, and app and
/// system CPU always cover the same interval.
public actor Engine {
  private let system: any SystemTotalsReading
  private let processes: any ProcessTableReading
  private var grouper: AppGrouper
  private let guide: Guide
  private let cpuCount: Int
  private var previousTable: ProcessTable?

  /// `cpuCount` is the number of active cores: `ProcessInfo.processInfo.activeProcessorCount`.
  public init(
    system: any SystemTotalsReading, processes: any ProcessTableReading, grouper: AppGrouper,
    guide: Guide, cpuCount: Int
  ) {
    precondition(cpuCount > 0, "cpuCount \(cpuCount)")
    self.system = system
    self.processes = processes
    self.grouper = grouper
    self.guide = guide
    self.cpuCount = cpuCount
  }

  public func tick(mode: Mode) -> Snapshot {
    let totals = system.read()
    guard mode == .open else {
      previousTable = nil
      return Aggregator.snapshot(
        previous: nil, current: nil, groups: [:], totals: totals, cpuCount: cpuCount,
        guide: guide, grouping: grouper.quality, mode: .closed,
        nowNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))  // the process table's clock
    }
    let table = processes.readTable()
    defer { previousTable = table }
    return Aggregator.snapshot(
      previous: previousTable, current: table, groups: grouper.assign(table), totals: totals,
      cpuCount: cpuCount, guide: guide, grouping: grouper.quality, mode: .open,
      nowNs: table.takenAtNs)
  }

  /// An open snapshot for the app to draw once before the first click (spec 10). It groups every
  /// process, so the first open reading finds their apps already read: reading every app's bundle
  /// takes about 40 ms (R21). It keeps no table, so the next open tick has no rates yet.
  public func warmUp() -> Snapshot {
    defer { previousTable = nil }
    return tick(mode: .open)
  }

  /// The next open tick has no previous table, so it shows no CPU or disk rates yet. The next system
  /// CPU reading is a first sample too, so none averages over the gap, for example after wake.
  public func resetBaseline() {
    previousTable = nil
    system.resetCPUBaseline()
  }
}
