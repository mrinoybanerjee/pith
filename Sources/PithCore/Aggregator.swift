import os

/// Turns two process tables, their app groups and the system totals into one `Snapshot`
/// (spec 6.3, 6.4, 6.6). It is a pure function.
public enum Aggregator {
  /// The previous table's samples by key, and the wall-clock time since it was taken.
  private typealias Baseline = (samples: [ProcessKey: ProcessSample], wallNs: Double)

  /// Rows are keyed by app id. CPU and disk rates come only from processes in both tables, so a
  /// new process adds memory but no rate this tick; with no `previous`, every rate is unavailable.
  /// A closed snapshot has no table, no apps and no residual. `.open` needs a `current` table.
  public static func snapshot(
    previous: ProcessTable?, current: ProcessTable?, groups: [ProcessKey: AppIdentity],
    totals: SystemTotals, cpuCount: Int, guide: Guide, grouping: GroupingQuality, mode: Mode
  ) -> Snapshot {
    guard mode == .open else {
      return Snapshot(
        takenAtNs: 0, mode: mode, totals: totals, apps: [], system: .unavailable("closed"),
        grouping: grouping)
    }
    let current = current!
    let baseline = previous.map { p -> Baseline in
      assert(current.takenAtNs > p.takenAtNs, "takenAtNs \(p.takenAtNs) -> \(current.takenAtNs)")
      return (
        Dictionary(uniqueKeysWithValues: p.samples.map { ($0.key, $0) }),
        Double(current.takenAtNs - p.takenAtNs)
      )
    }
    let apps = Dictionary(grouping: current.samples) { groups[$0.key]!.id }.values
      .map { usage($0, groups, baseline, cpuCount, guide) }
      .sorted { $0.memory != $1.memory ? $0.memory > $1.memory : $0.id < $1.id }
    let appCPU: Reading<Double> =
      baseline == nil ? .unavailable("first sample") : .value(apps.reduce(0) { $0 + $1.cpu.value! })
    return Snapshot(
      takenAtNs: current.takenAtNs, mode: mode, totals: totals, apps: apps,
      system: residual(totals, appMemory: apps.reduce(0) { $0 + $1.memory }, appCPU: appCPU),
      grouping: grouping)
  }

  /// One app's row. Its path is the first member path that is not nil (a Chromium clone's main
  /// process has none). Inside, processes group by helper label, else by their own file name.
  private static func usage(
    _ members: [ProcessSample], _ groups: [ProcessKey: AppIdentity], _ baseline: Baseline?,
    _ cpuCount: Int, _ guide: Guide
  ) -> AppUsage {
    let identity = groups[members[0].key]!
    var cpu = Reading<Double>.unavailable("first sample")
    var disk = cpu
    if let baseline {
      var cpuNs: UInt64 = 0
      var bytes: UInt64 = 0
      for s in members {
        guard let p = baseline.samples[s.key] else { continue }
        cpuNs += delta(p.cpuTimeNs, s.cpuTimeNs)
        bytes += delta(p.diskRead, s.diskRead) + delta(p.diskWritten, s.diskWritten)
      }
      let share = Double(cpuNs) / (baseline.wallNs * Double(cpuCount))
      assert((0...(1 + 1e-9)).contains(share), "\(identity.id) CPU share \(share)")
      cpu = .value(share)
      disk = .value(Double(bytes) / (baseline.wallNs / 1e9))
    }
    let inside = Dictionary(grouping: members) {
      guide.helperLabel(processName: $0.fileName) ?? $0.fileName
    }
    .map { label, group in HelperGroup(label: label, count: group.count, memory: footprint(group)) }
    .sorted { $0.memory != $1.memory ? $0.memory > $1.memory : $0.label < $1.label }
    return AppUsage(
      id: identity.id, name: identity.name,
      bundlePath: members.lazy.compactMap { groups[$0.key]!.bundlePath }.first,
      pids: members.map(\.key.pid), processCount: members.count, memory: footprint(members),
      cpu: cpu, diskBytesPerSecond: disk, inside: inside)
  }

  /// Spec 6.6: what the user's own processes leave unexplained. A negative memory residual makes
  /// the whole row a mismatch. A CPU residual less than 0.01 below 0 is rounding, so it reads 0.
  private static func residual(
    _ totals: SystemTotals, appMemory: UInt64, appCPU: Reading<Double>
  ) -> Reading<SystemResidual> {
    guard appMemory <= totals.memoryUsed else {
      return mismatch("memory used \(totals.memoryUsed), apps \(appMemory)")
    }
    let cpu: Reading<Double> =
      switch (totals.cpuBusy, appCPU) {
      case (.value(let busy), .value(let apps)) where busy - apps > -0.01:
        .value(max(0, busy - apps))
      case (.value(let busy), .value(let apps)): mismatch("CPU busy \(busy), apps \(apps)")
      case (.unavailable(let reason), _), (_, .unavailable(let reason)): .unavailable(reason)
      }
    return .value(SystemResidual(memory: totals.memoryUsed - appMemory, cpu: cpu))
  }

  /// Shown as "—", never as 0. Debug builds log the inputs (spec 6.6).
  private static func mismatch<Value>(_ inputs: String) -> Reading<Value> {
    #if DEBUG
      Logger(subsystem: "com.mrinoy.pith", category: "Aggregator")
        .error("accounting mismatch: \(inputs, privacy: .public)")
    #endif
    return .unavailable("accounting mismatch")
  }

  /// The growth of a cumulative counter of one `ProcessKey`. Keys include the start time, so a
  /// counter never goes backwards; if one does, it adds 0 in release builds.
  private static func delta(_ before: UInt64, _ after: UInt64) -> UInt64 {
    assert(after >= before, "counter went backwards: \(before) -> \(after)")
    return after >= before ? after - before : 0
  }

  private static func footprint(_ samples: [ProcessSample]) -> UInt64 {
    samples.reduce(0) { $0 + $1.footprint }
  }
}
