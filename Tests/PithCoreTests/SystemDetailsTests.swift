import Foundation
import Testing
import os

@testable import PithCore

private let twoSamples = Fixture.text("top/two-samples")

/// A second sample with `rows` under a header that lists `columns`.
private func secondSample(columns: String = "PID COMMAND %CPU MEM UID", rows: [String]) -> String {
  (["Processes: 1 total", "Processes: 1 total", "", columns] + rows).joined(separator: "\n")
}

@Test func parsesSecondSampleOnly() throws {
  let rows = try TopParser.parse(twoSamples, excludingUID: 501)
  #expect(
    rows.map(\.name) == [
      "mds_stores", "WindowServer", "photoanalysisd", "launchd", "cloudd", "x86helperd",
    ])
  #expect(rows[0].memory == 420 << 20)  // "420M+"
  #expect(rows.first { $0.name == "launchd" }?.memory == 12_288 << 10)  // "12288K"
  #expect(rows.allSatisfy { $0.uid != 501 })
}

@Test func readsEveryColumn() throws {
  let rows = try TopParser.parse(twoSamples, excludingUID: 501)
  #expect(
    rows[1] == SystemProcess(pid: 174, name: "WindowServer", cpu: 1.3, memory: 345 << 20, uid: 88))
}

@Test func rosettaPIDKeepsOnlyTheNumber() throws {  // R57: Apple Silicon top prints `123*`
  let rows = try TopParser.parse(twoSamples, excludingUID: 501)
  #expect(
    rows.last
      == SystemProcess(pid: 3105, name: "x86helperd", cpu: 0.1, memory: 4096 << 10, uid: 0))
}

@Test func rosettaRowOfTheExcludedUserStillParses() throws {  // R57
  // Before it is filtered out, the row must parse: an unreadable row fails the whole measurement.
  let rows = try TopParser.parse(
    secondSample(rows: ["9* a 0.0 2M 501", "8 b 0.0 1M 0"]), excludingUID: 501)
  #expect(rows.map(\.pid) == [8])
}

@Test func malformedOutputThrows() {
  #expect(throws: SystemDetailsError.self) { try TopParser.parse("garbage", excludingUID: 501) }
}

@Test func emptySecondSampleThrows() {
  #expect(throws: SystemDetailsError.self) {
    try TopParser.parse(secondSample(rows: []), excludingUID: 501)
  }
}

@Test func oneSampleThrows() {
  let first = twoSamples.components(separatedBy: "\nProcesses:")[0]
  #expect(throws: SystemDetailsError.self) { try TopParser.parse(first, excludingUID: 501) }
}

@Test func missingHeaderOrColumnThrows() {
  #expect(throws: SystemDetailsError.self) {
    try TopParser.parse("Processes: 1\nProcesses: 1\n1 a 0.0 1M 0", excludingUID: 501)
  }
  #expect(throws: SystemDetailsError.self) {
    try TopParser.parse(
      secondSample(columns: "PID COMMAND %CPU UID", rows: ["1 a 0.0 0"]), excludingUID: 501)
  }
}

@Test(arguments: [
  "1 a 0.0 12X 0",  // unknown unit
  "1 a 0.0 M 0",  // no digits
  "1 a 0.0 17179869184G 0",  // 2^64 bytes
  "x a 0.0 1M 0",  // bad PID
  "1** a 0.0 1M 0",  // one `*` is dropped, not two
  "* a 0.0 1M 0",  // no digits
  "1 a x 1M 0",  // bad CPU
  "1 a 0.0 1M x",  // bad UID
  "1 0.0 1M 0",  // no COMMAND
])
func unparseableRowThrows(row: String) {
  #expect(throws: SystemDetailsError.self) {
    try TopParser.parse(secondSample(rows: ["2 b 0.0 1M 0", row]), excludingUID: 501)
  }
}

@Test func memoryUnits() throws {
  let rows = try TopParser.parse(
    secondSample(rows: [
      "1 a 0.0 2G 0", "2 b 0.0 3M+ 0", "3 c 0.0 4K- 0", "4 d 0.0 512 0", "5 e 0.0 0 0",
      "6 f 0.0 8192B 0", "7 g 0.0 0B 0", "8 h 0.0 64B- 0",
    ]),
    excludingUID: 501)
  #expect(rows.map(\.memory) == [2 << 30, 3 << 20, 4 << 10, 512, 0, 8192, 0, 64])
}

@Test func commandCanHaveSpacesAndRowsCanEndInSpaces() throws {
  let rows = try TopParser.parse(
    secondSample(rows: ["7 Example Web Content ( 0.5 9M 88 ", "8 x 0.0 1M 0"]), excludingUID: 501)
  #expect(rows.map(\.name) == ["Example Web Content (", "x"])
  #expect(rows.map(\.uid) == [88, 0])
}

@Test func signedUIDIsReadAsUnsigned() throws {
  // top prints the UID as a signed number: `nobody` is 4294967294, shown as -2.
  let rows = try TopParser.parse(secondSample(rows: ["1 a 0.0 1M -2"]), excludingUID: 501)
  #expect(rows.map(\.uid) == [4_294_967_294])
}

@Test func columnsAreFoundByHeader() throws {
  let rows = try TopParser.parse(
    secondSample(columns: "PID UID COMMAND MEM %CPU", rows: ["7 88 Some Name 3M 0.5"]),
    excludingUID: 501)
  #expect(
    rows == [SystemProcess(pid: 7, name: "Some Name", cpu: 0.5, memory: 3 << 20, uid: 88)])
}

@Test func breakdownTopFourPlusOther() async throws {
  let guide = try Guide.bundled()
  let d = SystemDetails(guide: guide, run: { _ in twoSamples }, ownUID: 501, nowNs: { 0 })
  let b = try await d.measure()
  #expect(
    b.items.map(\.title) == ["Spotlight indexing", "Window server", "Photos analysis", "launchd"])
  #expect(b.items.map(\.memory) == [420 << 20, 345 << 20, 180 << 20, 12_288 << 10])
  #expect(
    b.items[0].explanation
      == guide.entry(name: "mds_stores", bundleID: nil, path: nil)?.explanation)
  #expect(b.items[3].explanation == nil)  // launchd has no guide entry
  #expect(b.other == (5120 + 4096) << 10)  // cloudd and x86helperd fall into "Other system work"
}

@Test func cachedForTenSeconds() async throws {
  let counter = Counter()
  let now = OSAllocatedUnfairLock(initialState: UInt64(0))
  let d = SystemDetails(
    guide: try .bundled(),
    run: { _ in
      await counter.bump()
      return twoSamples
    }, ownUID: 501,
    nowNs: { now.withLock { $0 } })
  _ = try await d.measure()
  now.withLock { $0 = 9_000_000_000 }
  _ = try await d.measure()
  #expect(await counter.value == 1)
  now.withLock { $0 = 10_500_000_000 }
  _ = try await d.measure()
  #expect(await counter.value == 2)
}

@Test func failuresAreNotCached() async throws {
  let counter = Counter()
  let d = SystemDetails(
    guide: try .bundled(),
    run: { _ in
      await counter.bump()
      guard await counter.value > 1 else { throw SystemDetailsError.failed("first run fails") }
      return twoSamples
    }, ownUID: 501, nowNs: { 0 })
  await #expect(throws: SystemDetailsError.self) { try await d.measure() }
  _ = try await d.measure()  // the same instant: the failure left nothing in the cache
  #expect(await counter.value == 2)
}

@Test func parseFailureIsNotCached() async throws {
  let counter = Counter()
  let d = SystemDetails(
    guide: try .bundled(),
    run: { _ in
      await counter.bump()
      return await counter.value > 1 ? twoSamples : "garbage"
    }, ownUID: 501, nowNs: { 0 })
  await #expect(throws: SystemDetailsError.self) { try await d.measure() }
  _ = try await d.measure()  // the same instant: the failure left nothing in the cache
  #expect(await counter.value == 2)
}

@Test func concurrentMeasuresRunTopOnce() async throws {
  let counter = Counter()
  let d = SystemDetails(
    guide: try .bundled(),
    run: { _ in
      await counter.bump()
      try await Task.sleep(for: .milliseconds(200))
      return twoSamples
    }, ownUID: 501, nowNs: { 0 })
  async let first = d.measure()
  async let second = d.measure()
  let (a, b) = try await (first, second)
  #expect(a == b)
  #expect(await counter.value == 1)
}

@Test func liveTopRuns() async throws {
  let b = try await SystemDetails(
    guide: try .bundled(), nowNs: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
  ).measure()
  // Every process is listed, so a Mac always has more than 4 that are not the user's.
  #expect(b.items.count == 4 && b.other > 0)
}

@Test func runTopFailsOnNonZeroExit() async {
  await #expect(throws: SystemDetailsError.self) { try await SystemDetails.runTop(["-bogus"]) }
}

@Test func runTopReadsMoreThanAPipeHolds() async throws {
  // Eight samples are far more than the 64 KB a pipe holds. Without a concurrent read, top blocks.
  let output = try await SystemDetails.runTop(["-l", "8", "-s", "0"])
  #expect(output.utf8.count > 65_536)
}

@Test func runTopStopsTopAfterTheTimeout() async {
  let start = ContinuousClock.now
  await #expect(throws: SystemDetailsError.self) {
    try await SystemDetails.runTop(["-l", "100", "-s", "1"], timeout: 0.5)  // would run for 100 s
  }
  #expect(ContinuousClock.now - start >= .seconds(0.5))
  #expect(ContinuousClock.now - start < .seconds(10))
}

@Test func launchFailureIsFailed() async {
  await #expect(throws: SystemDetailsError.self) {
    try await SystemDetails.runProcess("/nonexistent/top", [], timeout: 1)
  }
}

@Test func processThatIgnoresTermIsKilled() async throws {
  let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: pidFile) }
  let start = ContinuousClock.now
  await #expect(throws: SystemDetailsError.self) {
    // `exec` keeps one process, which ignores SIGTERM and holds the output pipe open.
    try await SystemDetails.runProcess(
      "/bin/sh", ["-c", "echo $$ > '\(pidFile.path)'; trap '' TERM; exec sleep 30"], timeout: 0.5)
  }
  let elapsed = ContinuousClock.now - start
  #expect(elapsed >= .seconds(1.4))  // SIGTERM at 0.5 s had no effect; SIGKILL came 1 s later
  #expect(elapsed < .seconds(3))
  let pid = try #require(
    Int32(
      String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
  #expect(kill(pid, 0) == -1 && errno == ESRCH)  // gone and reaped
}

@Test func aChildThatExitedBeforeTheTimeoutIsNotATimeout() async throws {  // R168
  // The shell exits 0 at once, but its background sleep holds the output pipe open past 0.3 s.
  let output = try await SystemDetails.runProcess(
    "/bin/sh", ["-c", "echo done; sleep 1 & exit 0"], timeout: 0.3)
  #expect(output == "done\n")
}

@Test func timeoutIsFailedEvenWhenTheChildExitsZero() async {
  await #expect {
    // The trap runs when TERM arrives during `wait`, stops the sleep, and exits 0.
    try await SystemDetails.runProcess(
      "/bin/sh", ["-c", "sleep 30 >/dev/null & trap 'kill $!; exit 0' TERM; wait"], timeout: 0.5)
  } throws: { error in
    guard case SystemDetailsError.failed(let message) = error else { return false }
    return message.contains("did not finish")
  }
}
