import Testing

@testable import PithCore

private func app(_ name: String, memory: UInt64, processes: Int, cpu: Reading<Double>) -> AppUsage {
  AppUsage(
    id: name, name: name, bundlePath: nil, pids: [], processCount: processes, memory: memory,
    cpu: cpu, diskBytesPerSecond: .unavailable("first sample"), inside: [])
}

private let chrome = app(
  "Google Chrome", memory: UInt64(6.4 * Double(1 << 30)), processes: 41, cpu: .value(0.05))
private let xcode = app("Xcode", memory: 3 << 30, processes: 6, cpu: .value(0.62))

/// A calm open-mode snapshot: Chrome has the most memory and Xcode the most CPU.
private func snapshot(
  _ pressure: Pressure = .normal, cpu: Reading<Double> = .value(0.2),
  free: Reading<UInt64> = .value(112_000_000_000),
  total: Reading<UInt64> = .value(228_000_000_000), apps: [AppUsage] = [chrome, xcode]
) -> Snapshot {
  Snapshot(
    takenAtNs: 0, mode: apps.isEmpty ? .closed : .open,
    totals: SystemTotals(
      memoryUsed: 6 << 30, memoryTotal: 16 << 30, pressure: pressure, swapUsed: 0, cpuBusy: cpu,
      storageFree: free, storageTotal: total),
    apps: apps, system: .unavailable("test"), grouping: .full)
}

private func eval(
  _ pressure: Pressure, free: UInt64 = 112_000_000_000, total: UInt64 = 228_000_000_000
) -> Status {
  var rules = StatusRules(amberOnCPU: true)
  return rules.evaluate(snapshot(pressure, free: .value(free), total: .value(total)), nowNs: 0)
}

private func cpu(_ busy: Double) -> Snapshot { snapshot(cpu: .value(busy)) }

/// Rules that have turned the CPU cause on, at 60 s.
private func busyRules() -> StatusRules {
  var r = StatusRules(amberOnCPU: true)
  _ = r.evaluate(cpu(0.85), nowNs: 0)
  _ = r.evaluate(cpu(0.85), nowNs: 60_000_000_000)
  return r
}

@Test func calm() {
  #expect(
    eval(.normal)
      == Status(dot: .calm, title: "All calm", sentence: "Plenty of memory and CPU to spare."))
}

@Test func memoryTight() {
  #expect(
    eval(.warning)
      == Status(
        dot: .tight, title: "Memory is tight",
        sentence: "Google Chrome uses the most: 6.4 GB across 41 processes."))
}

@Test func memoryCritical() {
  #expect(eval(.critical).dot == .critical && eval(.critical).title == "Memory is very tight")
}

@Test func oneProcessIsSingular() {
  var r = StatusRules(amberOnCPU: true)
  let notes = app("Notes", memory: 180 << 20, processes: 1, cpu: .value(0.01))
  #expect(
    r.evaluate(snapshot(.warning, apps: [notes]), nowNs: 0).sentence
      == "Notes uses the most: 180 MB across 1 process.")
}

@Test func storageCriticalBelowFivePercent() {
  #expect(eval(.normal, free: 4, total: 100).title == "Storage is almost full")
}

@Test func storageTightBelowTenPercent() {
  #expect(eval(.normal, free: 9, total: 100).dot == .tight)
}

@Test func storageSentence() {
  #expect(
    eval(.normal, free: 9_400_000_000, total: 228_300_000_000)
      == Status(
        dot: .critical, title: "Storage is almost full", sentence: "9.4 GB free of 228 GB."))
  #expect(
    eval(.normal, free: 20_000_000_000, total: 228_300_000_000)
      == Status(
        dot: .tight, title: "Storage is getting full", sentence: "20 GB free of 228 GB."))
}

@Test func storageBoundariesAreStrictlyBelow() {
  #expect(eval(.normal, free: 5, total: 100).title == "Storage is getting full")
  #expect(eval(.normal, free: 10, total: 100).dot == .calm)
}

@Test func unavailableStorageNeverCounts() {
  var r = StatusRules(amberOnCPU: true)
  #expect(r.evaluate(snapshot(free: .unavailable("no volume")), nowNs: 0).dot == .calm)
  #expect(
    r.evaluate(snapshot(free: .value(1), total: .unavailable("no volume")), nowNs: 0).dot == .calm)
}

@Test func cpuBusyNeedsSixtySeconds() {
  var r = StatusRules(amberOnCPU: true)
  #expect(r.evaluate(cpu(0.85), nowNs: 0).dot == .calm)
  #expect(r.evaluate(cpu(0.85), nowNs: 59_000_000_000).dot == .calm)
  #expect(
    r.evaluate(cpu(0.85), nowNs: 60_000_000_000)
      == Status(dot: .tight, title: "Your Mac is busy", sentence: "Xcode is using 62% of the CPU."))
}

@Test func cpuClearsOnlyAfterSixtySecondsBelowSeventy() {
  var r = busyRules()  // already tight from CPU
  #expect(r.evaluate(cpu(0.75), nowNs: 120_000_000_000).dot == .tight)  // 0.70–0.80 holds
  #expect(r.evaluate(cpu(0.5), nowNs: 130_000_000_000).dot == .tight)
  #expect(r.evaluate(cpu(0.5), nowNs: 190_000_000_000).dot == .calm)
}

@Test func cpuThresholdsAreEightyAndSeventy() {
  var r = StatusRules(amberOnCPU: true)
  _ = r.evaluate(cpu(0.79), nowNs: 0)
  #expect(r.evaluate(cpu(0.79), nowNs: 60_000_000_000).dot == .calm)
  _ = r.evaluate(cpu(0.80), nowNs: 61_000_000_000)
  #expect(r.evaluate(cpu(0.80), nowNs: 121_000_000_000).dot == .tight)
  _ = r.evaluate(cpu(0.70), nowNs: 122_000_000_000)
  #expect(r.evaluate(cpu(0.70), nowNs: 200_000_000_000).dot == .tight)  // 0.70 is not below 0.70
  _ = r.evaluate(cpu(0.69), nowNs: 201_000_000_000)
  #expect(r.evaluate(cpu(0.69), nowNs: 261_000_000_000).dot == .calm)
}

@Test func cpuReadingBetweenTheThresholdsRestartsTheRun() {
  var r = StatusRules(amberOnCPU: true)
  _ = r.evaluate(cpu(0.85), nowNs: 0)
  _ = r.evaluate(cpu(0.75), nowNs: 30_000_000_000)
  #expect(r.evaluate(cpu(0.85), nowNs: 60_000_000_000).dot == .calm)  // the run restarted at 60 s
  #expect(r.evaluate(cpu(0.85), nowNs: 120_000_000_000).dot == .tight)

  _ = r.evaluate(cpu(0.5), nowNs: 130_000_000_000)
  _ = r.evaluate(cpu(0.75), nowNs: 160_000_000_000)
  #expect(r.evaluate(cpu(0.5), nowNs: 190_000_000_000).dot == .tight)  // the run restarted at 190 s
  #expect(r.evaluate(cpu(0.5), nowNs: 250_000_000_000).dot == .calm)
}

@Test func unavailableCPUHoldsTheStateAndTheTimers() {
  var r = StatusRules(amberOnCPU: true)
  let gap = snapshot(cpu: .unavailable("first tick"))
  _ = r.evaluate(cpu(0.85), nowNs: 0)
  #expect(r.evaluate(gap, nowNs: 30_000_000_000).dot == .calm)
  #expect(r.evaluate(cpu(0.85), nowNs: 60_000_000_000).dot == .tight)  // the gap kept the run
  _ = r.evaluate(cpu(0.5), nowNs: 70_000_000_000)
  #expect(r.evaluate(gap, nowNs: 100_000_000_000).dot == .tight)
  #expect(r.evaluate(cpu(0.5), nowNs: 130_000_000_000).dot == .calm)
}

@Test func cpuTimerRunsBehindHigherPriorityStates() {
  var r = StatusRules(amberOnCPU: true)
  #expect(r.evaluate(snapshot(.warning, cpu: .value(0.85)), nowNs: 0).title == "Memory is tight")
  #expect(r.evaluate(cpu(0.85), nowNs: 60_000_000_000).title == "Your Mac is busy")
}

@Test func cpuIgnoredWhenSettingOff() {
  var r = StatusRules(amberOnCPU: false)
  #expect(r.evaluate(cpu(0.99), nowNs: 999_000_000_000).dot == .calm)
}

@Test func cpuSentenceNamesTheTopAppByCPUWithARate() {
  var r = StatusRules(amberOnCPU: true)
  let notes = app("Notes", memory: 180 << 20, processes: 1, cpu: .value(0.045))
  let unrated = app("Mail", memory: 900 << 20, processes: 3, cpu: .unavailable("first sample"))
  let apps = [unrated, notes]
  _ = r.evaluate(snapshot(cpu: .value(0.85), apps: apps), nowNs: 0)
  #expect(
    r.evaluate(snapshot(cpu: .value(0.85), apps: apps), nowNs: 60_000_000_000).sentence
      == "Notes is using 4.5% of the CPU.")
}

@Test func priorityOrder() {
  #expect(eval(.warning, free: 4, total: 100).title == "Storage is almost full")
}

@Test func priorityOrderRest() {
  #expect(eval(.critical, free: 4, total: 100).title == "Memory is very tight")
  var r = busyRules()
  #expect(
    r.evaluate(snapshot(.warning, cpu: .value(0.85)), nowNs: 61_000_000_000).title
      == "Memory is tight")
  #expect(
    r.evaluate(
      snapshot(cpu: .value(0.85), free: .value(9), total: .value(100)), nowNs: 62_000_000_000
    )
    .title == "Your Mac is busy")
}

@Test func closedModeKeepsTheLastTopApp() {
  var r = StatusRules(amberOnCPU: true)
  _ = r.evaluate(snapshot(.warning), nowNs: 0)
  #expect(
    r.evaluate(snapshot(.warning, apps: []), nowNs: 5_000_000_000).sentence
      == "Google Chrome uses the most: 6.4 GB across 41 processes.")
}

@Test func withoutAnyAppTheSentencesAreGeneric() {
  var r = StatusRules(amberOnCPU: true)
  #expect(
    r.evaluate(snapshot(.warning, apps: []), nowNs: 0)
      == Status(
        dot: .tight, title: "Memory is tight", sentence: "Plenty of memory and CPU to spare."))
  var busy = StatusRules(amberOnCPU: true)
  _ = busy.evaluate(snapshot(cpu: .value(0.85), apps: []), nowNs: 0)
  #expect(
    busy.evaluate(snapshot(cpu: .value(0.85), apps: []), nowNs: 60_000_000_000)
      == Status(dot: .tight, title: "Your Mac is busy", sentence: "Your Mac is working hard."))
}
