import PithCore

/// What `--snapshot-json` prints: the second of two open readings, and each of its processes by
/// PID, from the Aggregator's own code, so each app's memory and CPU are the sums over its PIDs
/// (R143). `scripts/accuracy.sh` compares only the PIDs that `top` saw too (R138). Debug output.
struct LiveReading: Encodable {
  let snapshot: Snapshot
  let processes: [String: Aggregator.ProcessUsage]

  /// `snapshot` is the reading of `current`, taken after `previous`.
  init(snapshot: Snapshot, previous: ProcessTable, current: ProcessTable, cpuCount: Int) {
    precondition(snapshot.takenAtNs == current.takenAtNs, "the snapshot is not of this table")
    self.snapshot = snapshot
    processes = Dictionary(
      uniqueKeysWithValues: Aggregator.processes(
        previous: previous, current: current, cpuCount: cpuCount
      ).map { ("\($0.key)", $0.value) })
  }
}
