import os

/// Turns two process tables, their app groups and the system totals into one `Snapshot`
/// (spec 6.3, 6.4, 6.6). It is a pure function.
public enum Aggregator {
  /// The previous table's samples by executable, and the wall-clock time since it was taken.
  private typealias Baseline = (samples: [ExecutableKey: ProcessSample], wallNs: Double)

  /// One process as its app's row counts it: its footprint, and its CPU share of the whole Mac
  /// since the previous table, when it ran the same executable in both.
  public struct ProcessUsage: Sendable, Equatable, Codable {
    public let footprint: UInt64
    public let cpu: Double?
  }

  /// Each process of `current` by PID, from the same code as the rows, so each row's memory and
  /// CPU are the sums over its PIDs (R143). For `--snapshot-json`, whose per-process values the
  /// accuracy gate compares with `top`.
  public static func processes(
    previous: ProcessTable, current: ProcessTable, cpuCount: Int
  ) -> [Int32: ProcessUsage] {
    let baseline = Self.baseline(previous, current)
    return Dictionary(
      uniqueKeysWithValues: current.samples.map { s in
        let cpu = delta(s, baseline).map { share($0.cpuNs, baseline.wallNs, cpuCount) }
        return (s.key.pid, ProcessUsage(footprint: s.footprint, cpu: cpu))
      })
  }

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
    let baseline = previous.map { Self.baseline($0, current) }
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
    let deltas = baseline.map { b in members.compactMap { delta($0, b) } } ?? []
    if let wallNs = baseline?.wallNs, !deltas.isEmpty {
      let cpuNs = deltas.reduce(0) { $0 + $1.cpuNs }
      // A disk total that went down leaves the app with no disk rate this tick (R155).
      let bytes = deltas.reduce(UInt64?(0)) { sum, d in sum.flatMap { t in d.bytes.map { t + $0 } }
      }
      // Where a scan reads each process can push a saturated Mac a little past 100% (spec 6.3).
      let share = Self.share(cpuNs, wallNs, cpuCount)
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

  private static func baseline(_ previous: ProcessTable, _ current: ProcessTable) -> Baseline {
    precondition(
      current.takenAtNs > previous.takenAtNs,
      "takenAtNs \(previous.takenAtNs) -> \(current.takenAtNs)")
    return (
      Dictionary(uniqueKeysWithValues: previous.samples.map { ($0.executableKey, $0) }),
      Double(current.takenAtNs - previous.takenAtNs)
    )
  }

  /// A process's CPU time and disk bytes since its baseline sample, when it ran the same
  /// executable then. An exec keeps the PID and start time and can lower the CPU time (seen on
  /// macOS 26.6.2), so the baseline is per executable: an exec starts a new one (R132). Within one
  /// executable only the CPU time and bytes read are monotonic, and a CPU time that goes backwards
  /// traps. The disk total can step back when a process reads during the kernel's lock-free update
  /// of it, also across zero; then `bytes` is nil (R155). So the difference wraps and is signed: a
  /// negative one is a step back, never a gain of nearly 2^64 (R166).
  private static func delta(
    _ s: ProcessSample, _ baseline: Baseline
  ) -> (cpuNs: UInt64, bytes: UInt64?)? {
    baseline.samples[s.executableKey].map { p in
      let bytes = s.diskBytes &- p.diskBytes
      return (s.cpuTimeNs - p.cpuTimeNs, Int64(bitPattern: bytes) < 0 ? nil : bytes)
    }
  }

  /// CPU time as a share of the whole Mac over `wallNs` (spec 6.3).
  private static func share(_ cpuNs: UInt64, _ wallNs: Double, _ cpuCount: Int) -> Double {
    Double(cpuNs) / (wallNs * Double(cpuCount))
  }

  private static func footprint(_ samples: [ProcessSample]) -> UInt64 {
    samples.reduce(0) { $0 + $1.footprint }
  }
}
