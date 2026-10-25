import Testing

@testable import PithCore

private let guide = Guide(entries: [
  helper("Helper (Renderer)", "Tabs and sites"), helper("Helper (GPU)", "Graphics"),
])

private func helper(_ pattern: String, _ title: String) -> GuideEntry {
  GuideEntry(
    match: .helperPattern(pattern), title: title, explanation: "e", kind: .helper,
    quittable: false, source: nil)
}

/// Aggregates `current` against `previous`, grouped by `AppGrouper` in `.limited` mode.
private func snap(
  previous: ProcessTable?, current: ProcessTable?, cores: Int = 10,
  memoryUsed: Reading<UInt64> = .value(16 << 30), cpuBusy: Reading<Double> = .value(0.5),
  mode: Mode = .open, nowNs: UInt64 = 9_000_000_000
) -> Snapshot {
  var grouper = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  return Aggregator.snapshot(
    previous: previous, current: current, groups: current.map { grouper.assign($0) } ?? [:],
    totals: SystemTotals(
      memoryUsed: memoryUsed, memoryTotal: 16 << 30, pressure: .value(.normal), swapUsed: .value(0),
      cpuBusy: cpuBusy, storageFree: .unavailable("unused"), storageTotal: .unavailable("unused")),
    cpuCount: cores, guide: guide, grouping: grouper.quality, mode: mode, nowNs: nowNs)
}

/// The first tick of a fixture table: memory only.
private func snap(fixture: String, memoryUsed: Reading<UInt64> = .value(16 << 30)) -> Snapshot {
  snap(previous: nil, current: Fixture.table(fixture), memoryUsed: memoryUsed)
}

/// A process of `/Applications/<app>.app` with 64 MB; its kernel name is `file` cut to 16 bytes.
private func process(
  _ pid: Int32, start: UInt64 = 1_000, app: String = "Notes", file: String? = nil,
  executable: UInt8 = 0, cpu: UInt64 = 0, read: UInt64 = 0, written: UInt64 = 0,
  memory: UInt64 = 64 << 20
) -> ProcessSample {
  let file = file ?? app
  return ProcessSample(
    key: ProcessKey(pid: pid, startTime: start), parent: 1, uid: 501, name: String(file.prefix(16)),
    path: "/Applications/\(app).app/Contents/MacOS/\(file)", executableID: .executable(executable),
    footprint: memory, cpuTimeNs: cpu, diskRead: read, diskWritten: written)
}

private func table(_ samples: [ProcessSample], at ns: UInt64) -> ProcessTable {
  ProcessTable(samples: samples, takenAtNs: ns, vanished: 0)
}

/// One Notes process, pid 300.
private func table(cpu: UInt64, at ns: UInt64, read: UInt64 = 0, written: UInt64 = 0)
  -> ProcessTable
{
  table([process(300, cpu: cpu, read: read, written: written)], at: ns)
}

private func snapWithDisk(read: UInt64, written: UInt64, overSeconds seconds: UInt64) -> Snapshot {
  snap(
    previous: table(cpu: 0, at: 0),
    current: table(cpu: 0, at: seconds * 1_000_000_000, read: read, written: written))
}

/// The CPU residual when the apps use 25% of the Mac (2.5 s over 1 s on 10 cores).
private func cpuResidual(busy: Reading<Double>) -> Reading<Double>? {
  snap(
    previous: table(cpu: 0, at: 0), current: table(cpu: 2_500_000_000, at: 1_000_000_000),
    cpuBusy: busy
  ).system.value?.cpu
}

@Test func cpuIsShareOfWholeMac() {  // 2 s of CPU over 1 s wall on 10 cores = 20%
  let s = snap(
    previous: table(cpu: 0, at: 0), current: table(cpu: 2_000_000_000, at: 1_000_000_000),
    cores: 10)
  #expect(s.apps[0].cpu == .value(0.2))
}

@Test func firstTickHasNoCPUOrDisk() {
  let s = snap(previous: nil, current: table(cpu: 5, at: 0), cores: 10)
  #expect(s.apps[0].cpu == .unavailable("first sample") && s.apps[0].memory > 0)
  #expect(s.apps[0].diskBytesPerSecond == .unavailable("first sample"))
}

@Test func diskRateFromDeltas() {
  #expect(
    snapWithDisk(read: 4_000_000, written: 1_000_000, overSeconds: 2).apps[0].diskBytesPerSecond
      == .value(2_500_000))
}

@Test func helpersSumAndInsideGroups() {
  let s = snap(fixture: "chrome-usage")
  #expect(s.apps[0].processCount == 5 && s.apps[0].memory == 5 * 100 << 20)
  #expect(
    s.apps[0].inside.first == HelperGroup(label: "Tabs and sites", count: 3, memory: 300 << 20))
}

@Test func residualIsTotalMinusApps() {
  let s = snap(fixture: "chrome-usage", memoryUsed: .value(2 << 30))
  #expect(s.system.value?.memory == (2 << 30) - 5 * (100 << 20))
}

@Test func negativeResidualIsVisibleMismatch() {
  #expect(
    snap(fixture: "chrome-usage", memoryUsed: .value(1)).system
      == .unavailable("accounting mismatch"))
}

@Test func unavailableMemoryUsedHasNoResidual() {  // never a residual of 0 or a mismatch
  #expect(
    snap(fixture: "chrome-usage", memoryUsed: .unavailable("host_statistics64 failed: 5")).system
      == .unavailable("memory unavailable"))
}

@Test func closedModeHasNoApps() {
  #expect(snap(previous: nil, current: nil, mode: .closed).apps.isEmpty)
}

@Test func closedModeHasNoResidual() {
  #expect(snap(previous: nil, current: nil, mode: .closed).system == .unavailable("closed"))
}

@Test func ratesCountOnlyProcessesInBothTables() {  // 1 s + 1 s over 1 s on 10 cores; 302 is new
  let s = snap(
    previous: table([process(300), process(301)], at: 0),
    current: table(
      [
        process(300, cpu: 1_000_000_000), process(301, cpu: 1_000_000_000),
        process(302, cpu: 5_000_000_000, read: 1_000),
      ], at: 1_000_000_000))
  #expect(s.apps.map(\.cpu) == [.value(0.2)])
  #expect(s.apps[0].diskBytesPerSecond == .value(0))
  #expect(s.apps[0].processCount == 3 && s.apps[0].memory == 3 * 64 << 20)
}

@Test func rowCopiesItsIdentity() {  // the clone main process comes first
  let chrome = snap(fixture: "chrome-usage").apps[0]
  #expect(chrome.id == "/Applications/Google Chrome.app" && chrome.name == "Google Chrome")
  #expect(chrome.bundlePath == chrome.id && chrome.bundleID == "com.google.Chrome")
}

@Test func insideUsesFileNamesAndBreaksTiesByLabel() {  // not the 16-byte kernel names
  let s = snap(
    previous: nil,
    current: table(
      [
        process(300, file: "Notes Helper (Renderer)"),
        process(301, file: "Notes Background Worker"),
      ],
      at: 0))
  #expect(
    s.apps[0].inside == [
      HelperGroup(label: "Notes Background Worker", count: 1, memory: 64 << 20),
      HelperGroup(label: "Tabs and sites", count: 1, memory: 64 << 20),
    ])
}

@Test func appsSortByMemoryThenID() {
  let s = snap(
    previous: nil,
    current: table(
      [
        process(1, app: "Slack"), process(2, app: "Notes"),
        process(3, app: "Claude", memory: 1 << 30),
      ],
      at: 0))
  #expect(
    s.apps.map(\.id) == [
      "/Applications/Claude.app", "/Applications/Notes.app", "/Applications/Slack.app",
    ])
}

@Test func cpuResidualIsBusyMinusApps() { #expect(cpuResidual(busy: .value(0.5)) == .value(0.25)) }

@Test func smallNegativeCPUResidualIsRounding() {
  #expect(cpuResidual(busy: .value(0.245)) == .value(0))
}

@Test func largeNegativeCPUResidualIsVisibleMismatch() {
  #expect(cpuResidual(busy: .value(0.2)) == .unavailable("accounting mismatch"))
}

@Test func cpuResidualNeedsBothInputs() {
  #expect(cpuResidual(busy: .unavailable("no ticks elapsed")) == .unavailable("no ticks elapsed"))
  #expect(snap(fixture: "chrome-usage").system.value?.cpu == .unavailable("first sample"))
}

@Test func closedSnapshotIsTakenNow() {
  #expect(snap(previous: nil, current: nil, mode: .closed, nowNs: 42).takenAtNs == 42)
}

@Test func appWithOnlyNewProcessesHasNoRatesYet() {  // Slack started this tick; Notes uses 25%
  let s = snap(
    previous: table([process(300)], at: 0),
    current: table(
      [
        process(300, cpu: 2_500_000_000),
        process(400, app: "Slack", cpu: 1_000_000_000, read: 1_000),
      ], at: 1_000_000_000))
  #expect(s.apps.map(\.id) == ["/Applications/Notes.app", "/Applications/Slack.app"])
  #expect(s.apps.map(\.cpu) == [.value(0.25), .unavailable("first sample")])
  #expect(s.apps.map(\.diskBytesPerSecond) == [.value(0), .unavailable("first sample")])
  #expect(s.system.value?.cpu == .value(0.25))  // Slack's first second stays in the residual
}

@Test func cpuNeverExceedsTheWholeMac() {  // 0.5% over: where the scan read each process
  let s = snap(
    previous: table(cpu: 0, at: 0), current: table(cpu: 10_050_000_000, at: 1_000_000_000))
  #expect(s.apps[0].cpu == .value(1))
}

@Test func residualSubtractsEveryApp() {  // Notes: 25% and 64 MB; Slack: 12.5% and 128 MB
  let s = snap(
    previous: table([process(300), process(400, app: "Slack")], at: 0),
    current: table(
      [
        process(300, cpu: 2_500_000_000),
        process(400, app: "Slack", cpu: 1_250_000_000, memory: 128 << 20),
      ], at: 1_000_000_000),
    memoryUsed: .value(1 << 30))
  #expect(s.system == .value(SystemResidual(memory: (1 << 30) - (192 << 20), cpu: .value(0.125))))
}

@Test func diskRateSumsTheAppsProcesses() {  // 3 MB read by one, 1 MB written by another, in 2 s
  let s = snap(
    previous: table([process(300), process(301)], at: 0),
    current: table(
      [process(300, read: 3_000_000), process(301, written: 1_000_000)], at: 2_000_000_000))
  #expect(s.apps[0].diskBytesPerSecond == .value(2_000_000))
}

@Test func reusedPIDIsANewProcess() {  // pid 300 exited, and a new process got its PID
  let s = snap(
    previous: table([process(300)], at: 0),
    current: table([process(300, start: 2_000, cpu: 1_000_000_000, read: 1_000)], at: 1_000_000_000)
  )
  #expect(s.apps[0].cpu == .unavailable("first sample"))
  #expect(s.apps[0].diskBytesPerSecond == .unavailable("first sample"))
}

@Test func cpuDiffsAcrossAnExec() {  // the same task runs a new executable, and its counters go on
  let s = snap(
    previous: table([process(300)], at: 0),
    current: table([process(300, executable: 1, cpu: 2_000_000_000)], at: 1_000_000_000))
  #expect(s.apps[0].cpu == .value(0.2))
}

@Test func zeroMemoryResidualIsAValue() {
  #expect(
    snap(fixture: "chrome-usage", memoryUsed: .value(5 * 100 << 20)).system
      == .value(SystemResidual(memory: 0, cpu: .unavailable("first sample"))))
}
