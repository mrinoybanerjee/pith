import os

/// Turns two process tables, their app groups and the system totals into one `Snapshot`
/// (spec 6.3, 6.4, 6.6). It is a pure function.
public enum Aggregator {
  /// The previous table's samples by executable, and the wall-clock time since it was taken.
  private typealias Baseline = (samples: [ExecutableKey: ProcessSample], wallNs: Double)

  /// Rows are keyed by app id. CPU and disk rates come only from processes in both tables with
  /// the same executable, so a new process, or one that ran `exec`, adds memory but no rate this
  /// tick. An app with no process in `previous` has no
  /// rates yet. An open snapshot is taken at `current.takenAtNs`, and `current` must exist. A
  /// closed one reads no table: it is taken at `nowNs` and has no apps and no residual.
  public static func snapshot(
    previous: ProcessTable?, current: ProcessTable?, groups: [ProcessKey: AppIdentity],
    totals: SystemTotals, cpuCount: Int, guide: Guide, grouping: GroupingQuality, mode: Mode,
    nowNs: UInt64
  ) -> Snapshot {
    guard mode == .open else {
      return Snapshot(
        takenAtNs: nowNs, mode: mode, totals: totals, apps: [], system: .unavailable("closed"),
        grouping: grouping)
    }
    guard let current else { preconditionFailure("an open snapshot needs a current table") }
    let baseline = previous.map { p -> Baseline in
      precondition(
        current.takenAtNs > p.takenAtNs, "takenAtNs \(p.takenAtNs) -> \(current.takenAtNs)")
      return (
        Dictionary(uniqueKeysWithValues: p.samples.map { ($0.executableKey, $0) }),
        Double(current.takenAtNs - p.takenAtNs)
      )
    }
    let apps = Dictionary(grouping: current.samples) { groups[$0.key]!.id }.values
      .map { usage($0, groups, baseline, cpuCount, guide) }
      .sorted { $0.memory != $1.memory ? $0.memory > $1.memory : $0.id < $1.id }
    // A process that is new this tick has no CPU reading yet, so its CPU stays in the residual.
    let appCPU: Reading<Double> =
      baseline == nil
      ? .firstSample : .value(apps.compactMap(\.cpu.value).reduce(0, +))
    return Snapshot(
      takenAtNs: current.takenAtNs, mode: mode, totals: totals, apps: apps,
      system: residual(totals, appMemory: apps.reduce(0) { $0 + $1.memory }, appCPU: appCPU),
      grouping: grouping)
  }

  /// One app's row. Inside, processes group by helper label; a bundled app's own executable (its
  /// `CFBundleExecutable`) is the "Main process"; any other process is listed by its file name.
  private static func usage(
    _ members: [ProcessSample], _ groups: [ProcessKey: AppIdentity], _ baseline: Baseline?,
    _ cpuCount: Int, _ guide: Guide
  ) -> AppUsage {
    let identity = groups[members[0].key]!
    var cpu = Reading<Double>.firstSample
    var disk = cpu
    let continuing = members.compactMap { s in
      baseline?.samples[s.executableKey].map { ($0, s) }
    }
    if let wallNs = baseline?.wallNs, !continuing.isEmpty {
      var cpuNs: UInt64 = 0
      var bytes: UInt64? = 0
      // An exec keeps the PID and start time and can lower the CPU time (seen on macOS 26.6.2), so
      // the baseline is per executable: an exec starts a new one (R132). Within one executable
      // only the CPU time and bytes read are monotonic, and a CPU time that goes backwards traps.
      // The disk total can step back when a process reads during the kernel's lock-free update of
      // it; then the app has no disk rate this tick (R155).
      for (p, s) in continuing {
        cpuNs += s.cpuTimeNs - p.cpuTimeNs
        bytes = bytes.flatMap {
          s.diskBytes >= p.diskBytes ? $0 + (s.diskBytes - p.diskBytes) : nil
        }
      }
      // Where a scan reads each process can push a saturated Mac a little past 100% (spec 6.3).
      let share = Double(cpuNs) / (wallNs * Double(cpuCount))
      assert(share <= 1.02, "\(identity.id) CPU share \(share)")
      cpu = .value(min(share, 1))
      disk =
        bytes.map { .value(Double($0) / (wallNs / 1e9)) } ?? .unavailable("disk total went down")
    }
    let inside = Dictionary(grouping: members) { (member: ProcessSample) -> String in
      let file = member.fileName
      return guide.helperLabel(processName: file)
        ?? (file == identity.executable ? "Main process" : file)
    }
    .map { label, group in HelperGroup(label: label, count: group.count, memory: footprint(group)) }
    .sorted { $0.memory != $1.memory ? $0.memory > $1.memory : $0.label < $1.label }
    return AppUsage(
      id: identity.id, name: identity.name,
      bundlePath: identity.bundlePath, bundleID: identity.bundleID,
      pids: members.map(\.key.pid), processCount: members.count, memory: footprint(members),
      cpu: cpu, diskBytesPerSecond: disk, inside: inside)
  }

  /// Spec 6.6: what the user's own processes leave unexplained. Memory comes from the footprint
  /// total, which counts a compressed page at its full size, as footprints do (R133). Without it
  /// the whole row is unavailable, and a negative memory residual makes it a mismatch. A CPU residual less than
  /// 0.01 below 0 is rounding, so it reads 0.
  private static func residual(
    _ totals: SystemTotals, appMemory: UInt64, appCPU: Reading<Double>
  ) -> Reading<SystemResidual> {
    guard let total = totals.footprintTotal.value else {
      return .unavailable("memory unavailable")
    }
    guard appMemory <= total else {
      return mismatch("footprint total \(total), apps \(appMemory)")
    }
    let cpu: Reading<Double> =
      switch (totals.cpuBusy, appCPU) {
      case (.value(let busy), .value(let apps)) where busy - apps > -0.01:
        .value(max(0, busy - apps))
      case (.value(let busy), .value(let apps)): mismatch("CPU busy \(busy), apps \(apps)")
      case (.unavailable(let reason), _), (_, .unavailable(let reason)): .unavailable(reason)
      }
    return .value(SystemResidual(memory: total - appMemory, cpu: cpu))
  }

  /// Shown as "—", never as 0. Debug builds log the inputs (spec 6.6).
  private static func mismatch<Value>(_ inputs: String) -> Reading<Value> {
    #if DEBUG
      Logger(subsystem: "com.mrinoy.pith", category: "Aggregator")
        .error("accounting mismatch: \(inputs, privacy: .public)")
    #endif
    return .unavailable("accounting mismatch")
  }

  private static func footprint(_ samples: [ProcessSample]) -> UInt64 {
    samples.reduce(0) { $0 + $1.footprint }
  }
}
