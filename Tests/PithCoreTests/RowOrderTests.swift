import Testing

@testable import PithCore

private func usage(
  _ id: String, mem: UInt64 = 0, cpu: Reading<Double> = .unavailable("first sample"),
  disk: Reading<Double> = .unavailable("first sample")
) -> AppUsage {
  AppUsage(
    id: id, name: id, bundlePath: nil, pids: [], processCount: 1, memory: mem, cpu: cpu,
    diskBytesPerSecond: disk, inside: [])
}

@Test func rowsKeepOrderWithinTwoPercent() {
  let prev = ["a", "b"]
  let apps = [usage("a", mem: 1000), usage("b", mem: 1015)]
  #expect(RowOrder.stable(previous: prev, apps: apps, metric: .memory).map(\.id) == ["a", "b"])
  #expect(
    RowOrder.stable(
      previous: prev, apps: [usage("a", mem: 1000), usage("b", mem: 1030)], metric: .memory
    ).map(\.id) == ["b", "a"])
}

@Test func topEightOnly() {
  #expect(
    RowOrder.stable(
      previous: [], apps: (0..<12).map { usage("\($0)", mem: UInt64($0)) }, metric: .memory
    ).count == 8)
}

@Test func newRowsFollowInMetricOrder() {  // c and b are within 2%, so only their rank orders them
  let apps = [usage("a", mem: 1000), usage("b", mem: 1010), usage("c", mem: 1015)]
  #expect(
    RowOrder.stable(previous: ["a"], apps: apps, metric: .memory).map(\.id) == ["a", "c", "b"])
}

@Test func swapsRepeatUntilStable() {  // c climbs two rows
  let apps = [usage("a", mem: 10), usage("b", mem: 10), usage("c", mem: 1000)]
  #expect(
    RowOrder.stable(previous: ["a", "b", "c"], apps: apps, metric: .memory).map(\.id) == [
      "c", "a", "b",
    ])
}

@Test func goneRowsDrop() {
  #expect(
    RowOrder.stable(previous: ["gone", "a"], apps: [usage("a")], metric: .memory).map(\.id) == [
      "a"
    ])
}

@Test func unavailableRatesRankAsZero() {
  let apps = [usage("a"), usage("b", cpu: .value(0.1), disk: .value(10))]
  #expect(RowOrder.stable(previous: ["a", "b"], apps: apps, metric: .cpu).map(\.id) == ["b", "a"])
  #expect(
    RowOrder.stable(previous: ["a", "b"], apps: apps, metric: .disk).map(\.id) == ["b", "a"])
}
