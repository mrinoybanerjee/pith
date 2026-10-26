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
  memoryUsed: Reading<UInt64> = .value(16 << 30),
  footprintTotal: Reading<UInt64> = .value(16 << 30),
  cpuBusy: Reading<Double> = .value(0.5),
  mode: Mode = .open, nowNs: UInt64 = 9_000_000_000
) -> Snapshot {
  var grouper = AppGrouper(responsible: nil, bundleInfo: Fixture.bundleInfo)
  return Aggregator.snapshot(
    previous: previous, current: current, groups: current.map { grouper.assign($0) } ?? [:],
    totals: SystemTotals(
      memoryUsed: memoryUsed, footprintTotal: footprintTotal, memoryTotal: 16 << 30,
      pressure: .value(.normal), swapUsed: .value(0),
      cpuBusy: cpuBusy, storageFree: .unavailable("unused"), storageTotal: .unavailable("unused")),
    cpuCount: cores, guide: guide, grouping: grouper.quality, mode: mode, nowNs: nowNs)
}

/// The first tick of a fixture table: memory only.
private func snap(
  fixture: String, memoryUsed: Reading<UInt64> = .value(16 << 30),
  footprintTotal: Reading<UInt64> = .value(16 << 30)
) -> Snapshot {
  snap(
    previous: nil, current: Fixture.table(fixture), memoryUsed: memoryUsed,
    footprintTotal: footprintTotal)
}

/// A process of `/Applications/<app>.app` with 64 MB; its kernel name is `file` cut to 16 bytes.
private func process(
  _ pid: Int32, start: UInt64 = 1_000, app: String = "Notes", file: String? = nil,
  idVersion: Int32 = 0, cpu: UInt64 = 0, read: UInt64 = 0, written: UInt64 = 0,
  memory: UInt64 = 64 << 20
) -> ProcessSample {
  let file = file ?? app
  return ProcessSample(
    key: ProcessKey(pid: pid, startTime: start), parent: 1, uniqueID: UInt64(pid),
    parentUniqueID: 1,
    uid: 501, name: String(file.prefix(16)),
    path: "/Applications/\(app).app/Contents/MacOS/\(file)", idVersion: idVersion,
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

@Test func helpersSumAndInsideGroups() {  // the main process runs from a code-sign clone
  let s = snap(fixture: "chrome-usage")
  #expect(s.apps[0].processCount == 5 && s.apps[0].memory == 5 * 100 << 20)
  #expect(
    s.apps[0].inside == [
      HelperGroup(label: "Tabs and sites", count: 3, memory: 300 << 20),
      HelperGroup(label: "Graphics", count: 1, memory: 100 << 20),
      HelperGroup(label: "Main process", count: 1, memory: 100 << 20),
    ])
}

@Test func theBundlesExecutableIsTheMainProcess() {  // R86: Firefox runs "firefox"
  let s = snap(
    previous: nil,
    current: table(
      [
        process(300, app: "Firefox", file: "firefox"),
        process(301, app: "Firefox", file: "Firefox"),
      ],
      at: 0))
  #expect(
    s.apps[0].inside == [
      HelperGroup(label: "Firefox", count: 1, memory: 64 << 20),
      HelperGroup(label: "Main process", count: 1, memory: 64 << 20),
    ])
}

@Test func aProcessOutsideAnyAppKeepsItsFileName() {  // R86: no bundle, so no "Main process"
  let node = (0..<5).map { i in
    ProcessSample(
      key: ProcessKey(pid: 900 + Int32(i), startTime: 1_000), parent: 1,
      uniqueID: 1_900 + UInt64(i), parentUniqueID: 1, uid: 501, name: "node",
      path: "/usr/local/bin/node", idVersion: 0, footprint: 64 << 20,
      cpuTimeNs: 0, diskRead: 0, diskWritten: 0)
  }
  let s = snap(previous: nil, current: table(node, at: 0))
  #expect(s.apps.map(\.id) == ["proc:node"])
  #expect(s.apps[0].inside == [HelperGroup(label: "node", count: 5, memory: 5 * 64 << 20)])
}

@Test func residualIsFootprintTotalMinusApps() {
  let s = snap(fixture: "chrome-usage", footprintTotal: .value(2 << 30))
  #expect(s.system.value?.memory == (2 << 30) - 5 * (100 << 20))
}

@Test func compressedMemoryLeavesAPositiveResidual() {  // R133
  // The apps' 500 MB pass the 300 MB used, as their footprints count each compressed page at its
  // full size. The footprint total counts the compressor's pages that way too: 600 MB.
  let s = snap(
    fixture: "chrome-usage", memoryUsed: .value(300 << 20), footprintTotal: .value(600 << 20))
  #expect(s.system.value?.memory == 100 << 20)
}

@Test func appsOverTheFootprintTotalAreAVisibleMismatch() {  // R133
  #expect(
    snap(fixture: "chrome-usage", memoryUsed: .value(300 << 20), footprintTotal: .value(400 << 20))
      .system == .unavailable("accounting mismatch"))
}

@Test func unavailableMemoryHasNoResidual() {  // never a residual of 0 or a mismatch
  #expect(
    snap(
      fixture: "chrome-usage", memoryUsed: .unavailable("host_statistics64 failed: 5"),
      footprintTotal: .unavailable("host_statistics64 failed: 5")
    ).system == .unavailable("memory unavailable"))
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
    footprintTotal: .value(1 << 30))
  #expect(s.system == .value(SystemResidual(memory: (1 << 30) - (192 << 20), cpu: .value(0.125))))
}

/// R155: the kernel computes bytes written as total I/O less bytes read, from counters it updates
/// without a lock, so written alone can step back or wrap. Read and written together are the
/// kernel's total, which only a race moves back: then the app has no disk rate this tick.
@Test(arguments: [
  (UInt64(0), UInt64.max - 4_095, Reading<Double>.unavailable("disk total went down")),
  (UInt64.max - 4_095, 0, .value(4_096)),
  (100_000, 95_904, .unavailable("disk total went down")),
])
func aWriteCountThatStepsBackGivesNoTrap(written: (UInt64, UInt64, Reading<Double>)) {
  let s = snap(
    previous: table([process(300, read: 1_000_000, written: written.0)], at: 1_000_000_000),
    current: table([process(300, read: 1_000_000, written: written.1)], at: 2_000_000_000))
  #expect(s.apps[0].diskBytesPerSecond == written.2)
  #expect(s.apps[0].cpu == .value(0))  // the CPU rate stands
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

@Test func eachProcessSumsToItsRow() {  // R143: the values the accuracy gate checks
  let before = table(
    [
      process(300, cpu: 0), process(301, file: "Notes Helper", cpu: 0),
      process(302, file: "Notes Worker", idVersion: 1, cpu: 0), process(400, app: "Maps", cpu: 0),
    ], at: 1_000_000_000)
  let after = table(
    [
      process(300, cpu: 300_000_000, memory: 64 << 20),
      process(301, file: "Notes Helper", cpu: 120_000_000, memory: 32 << 20),
      process(302, file: "Notes Worker", idVersion: 2, cpu: 5_000_000, memory: 8 << 20),  // exec
      process(400, app: "Maps", cpu: 70_000_000, memory: 16 << 20),
    ], at: 2_000_000_000)
  let s = snap(previous: before, current: after)
  let processes = Aggregator.processes(previous: before, current: after, cpuCount: 10)
  #expect(Set(processes.keys) == [300, 301, 302, 400])
  #expect(processes[302]?.cpu == nil && processes[302]?.footprint == 8 << 20)
  for app in s.apps {
    #expect(app.pids.reduce(0) { $0 + processes[$1]!.footprint } == app.memory, "\(app.name)")
    let cpu = app.pids.compactMap { processes[$0]!.cpu }.reduce(0, +)
    #expect(abs(cpu - app.cpu.value!) < 1e-9, "\(app.name): \(cpu) vs \(app.cpu)")
  }
}

@Test func anExecThatLowersTheCPUTimeStartsAFreshBaseline() {  // R132
  // Seen on macOS 26.6.2 (MTLAssetUpgraderD): an exec keeps the PID and start time, and the new
  // executable's CPU time was lower. It counts as a new process: no rate this tick, and no trap.
  let before = table(
    [process(300, idVersion: 1, cpu: 2_000_000), process(301, app: "Maps")], at: 1_000_000_000)
  let after = table(
    [process(300, idVersion: 2, cpu: 1_000_000), process(301, app: "Maps", cpu: 100_000_000)],
    at: 2_000_000_000)
  let s = snap(previous: before, current: after)
  #expect(s.apps.first { $0.name == "Notes" }?.cpu == .unavailable("first sample"))
  #expect(s.apps.first { $0.name == "Maps" }?.cpu == .value(0.01))  // 0.1 s of 1 s on 10 cores
}

@Test func zeroMemoryResidualIsAValue() {
  #expect(
    snap(fixture: "chrome-usage", footprintTotal: .value(5 * 100 << 20)).system
      == .value(SystemResidual(memory: 0, cpu: .unavailable("first sample"))))
}
