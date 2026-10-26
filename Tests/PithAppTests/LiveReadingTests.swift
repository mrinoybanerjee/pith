import Foundation
import PithCore
import Testing

@testable import Pith

/// R143: the JSON of `--snapshot-json` has the fields that `scripts/accuracy.sh` reads, with the
/// app rows' own values, and per-process values that sum to them.
@Test func theSnapshotJSONHasTheFieldsTheAccuracyGateReads() throws {
  func sample(_ pid: Int32, _ path: String, cpu: UInt64, memory: UInt64) -> ProcessSample {
    ProcessSample(
      key: ProcessKey(pid: pid, startTime: 1_000), parent: 1, uniqueID: UInt64(pid),
      parentUniqueID: 1, uid: 501, name: "Example", path: path, idVersion: 0, footprint: memory,
      cpuTimeNs: cpu, diskRead: 0, diskWritten: 0)
  }
  let editor = "/Applications/Example Editor.app/Contents/MacOS/Example Editor"
  let before = ProcessTable(
    samples: [sample(4101, editor, cpu: 0, memory: 1), sample(4102, editor, cpu: 0, memory: 1)],
    takenAtNs: 1_000_000_000, vanished: 0)
  let after = ProcessTable(
    samples: [
      sample(4101, editor, cpu: 400_000_000, memory: 200 << 20),
      sample(4102, editor, cpu: 100_000_000, memory: 100 << 20),
    ], takenAtNs: 2_000_000_000, vanished: 0)
  var grouper = AppGrouper(responsible: nil, bundleInfo: { _ in nil })
  let snapshot = Aggregator.snapshot(
    previous: before, current: after, groups: grouper.assign(after),
    totals: DemoSnapshots.calm.totals,
    cpuCount: 10, guide: .empty, grouping: .limited, mode: .open, nowNs: after.takenAtNs)
  let reading = LiveReading(snapshot: snapshot, previous: before, current: after, cpuCount: 10)
  let json = try #require(
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(reading)) as? [String: Any])
  let app = try #require(((json["snapshot"] as? [String: Any])?["apps"] as? [[String: Any]])?.first)
  #expect(app["name"] as? String == "Example Editor")
  #expect(app["memory"] as? UInt64 == 300 << 20 && app["pids"] as? [Int32] == [4101, 4102])
  #expect(
    ((app["cpu"] as? [String: Any])?["value"] as? Double).map { abs($0 - 0.05) < 1e-12 } == true)
  let system = try #require((json["snapshot"] as? [String: Any])?["system"] as? [String: Any])
  #expect((system["value"] as? [String: Any])?["cpu"] != nil)
  let processes = try #require(json["processes"] as? [String: [String: Any]])
  #expect(processes["4101"]?["footprint"] as? UInt64 == 200 << 20)
  #expect(((processes["4101"]?["cpu"] as? Double).map { abs($0 - 0.04) < 1e-12 }) == true)
}
