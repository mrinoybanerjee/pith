import PithCore

/// Synthetic snapshots with the apps and numbers of the approved mockup (design section 1), for
/// tests and screenshots. Nothing here comes from a real Mac.
enum DemoSnapshots {
  /// "All calm": 9.8 of 16 GB, CPU 14%, Google Chrome first with 3.2 GB.
  static let calm = snapshot(
    used: gb(9.8), pressure: .normal, swap: gb(0.3), cpu: 0.14, system: gb(1.0),
    apps: [
      app(
        "Google Chrome", "com.google.Chrome", pid: 410, cpu: 0.032,
        inside: [
          ("Tabs and sites", 17, gb(2.4)), ("Graphics", 1, mb(380)), ("Extensions", 3, mb(240)),
          ("Main process", 1, mb(150)),
        ]),
      app("Claude", "com.anthropic.claudefordesktop", pid: 520, cpu: 0.013, (9, gb(1.5))),
      app("Codex", "com.openai.codex", pid: 610, cpu: 0.008, (6, gb(1.1))),
      app("Slack", "com.tinyspeck.slackmacgap", pid: 730, cpu: 0.005, (7, mb(710))),
      app("Finder", "com.apple.finder", pid: 340, cpu: 0.001, (1, mb(180))),
    ])

  /// "Memory is tight": 15.1 of 16 GB with 2.1 GB of swap, Google Chrome first with 6.4 GB across
  /// 41 processes.
  static let tight = snapshot(
    used: gb(15.1), pressure: .warning, swap: gb(2.1), cpu: 0.38, system: mb(1200),
    apps: [
      app(
        "Google Chrome", "com.google.Chrome", pid: 410, cpu: 0.082,
        inside: [
          ("Tabs and sites", 34, gb(5.1)), ("Graphics", 1, mb(620)), ("Extensions", 5, mb(480)),
          ("Main process", 1, mb(210)),
        ]),
      app("Xcode", "com.apple.dt.Xcode", pid: 880, cpu: 0.062, (14, gb(2.8))),
      app("Claude", "com.anthropic.claudefordesktop", pid: 520, cpu: 0.013, (9, gb(1.6))),
      app("Codex", "com.openai.codex", pid: 610, cpu: 0.011, (6, gb(1.1))),
      app("Slack", "com.tinyspeck.slackmacgap", pid: 730, cpu: 0.006, (7, mb(790))),
    ])

  /// `calm` with its first app renamed.
  static func withAppName(_ name: String) -> Snapshot {
    let first = calm.apps[0]
    let renamed = AppUsage(
      id: first.id, name: name, bundlePath: first.bundlePath, bundleID: first.bundleID,
      pids: first.pids, processCount: first.processCount, memory: first.memory, cpu: first.cpu,
      diskBytesPerSecond: first.diskBytesPerSecond, inside: first.inside)
    return Snapshot(
      takenAtNs: calm.takenAtNs, mode: .open, totals: calm.totals,
      apps: [renamed] + calm.apps.dropFirst(), system: calm.system, grouping: .full)
  }

  private static func gb(_ value: Double) -> UInt64 { UInt64(value * 1_073_741_824) }
  private static func mb(_ value: Double) -> UInt64 { UInt64(value * 1_048_576) }

  private static func snapshot(
    used: UInt64, pressure: Pressure, swap: UInt64, cpu: Double, system: UInt64,
    apps: [AppUsage]
  ) -> Snapshot {
    Snapshot(
      takenAtNs: 1_000_000_000, mode: .open,
      totals: SystemTotals(
        memoryUsed: .value(used), footprintTotal: .value(apps.reduce(system) { $0 + $1.memory }),
        memoryTotal: 16 << 30, pressure: .value(pressure),
        swapUsed: .value(swap), cpuBusy: .value(cpu), storageFree: .value(112_000_000_000),
        storageTotal: .value(228_000_000_000)),
      apps: apps, system: .value(SystemResidual(memory: system, cpu: .value(0.04))),
      grouping: .full)
  }

  /// An app in `/Applications` with `count` processes and `memory` in all: its main process with
  /// a fifth of it, and helpers with the rest.
  private static func app(
    _ name: String, _ bundleID: String, pid: Int32, cpu: Double,
    _ total: (count: Int, memory: UInt64)
  ) -> AppUsage {
    let main = total.count == 1 ? total.memory : total.memory / 5
    let helpers = total.count == 1 ? [] : [("Helpers", total.count - 1, total.memory - main)]
    return app(name, bundleID, pid: pid, cpu: cpu, inside: helpers + [("Main process", 1, main)])
  }

  /// An app in `/Applications` with the processes `inside` it, largest first, and made-up PIDs from
  /// `pid` on.
  private static func app(
    _ name: String, _ bundleID: String, pid: Int32, cpu: Double,
    inside: [(label: String, count: Int, memory: UInt64)]
  ) -> AppUsage {
    let path = "/Applications/\(name).app"
    let count = inside.reduce(0) { $0 + $1.count }
    return AppUsage(
      id: path, name: name, bundlePath: path, bundleID: bundleID,
      pids: (0..<Int32(count)).map { pid + $0 }, processCount: count,
      memory: inside.reduce(0) { $0 + $1.memory }, cpu: .value(cpu),
      diskBytesPerSecond: .value(cpu * 40_000_000),
      inside: inside.map { HelperGroup(label: $0.label, count: $0.count, memory: $0.memory) })
  }
}
