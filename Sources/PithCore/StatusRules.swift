public enum DotState: Sendable, Equatable { case calm, tight, critical }

/// The dot, the title and the sentence at the top of the panel.
public struct Status: Equatable, Sendable {
  public let dot: DotState
  public let title: String
  public let sentence: String
}

/// Turns each snapshot into a `Status` (spec 4.1 and 7.3). It remembers the CPU run and the last
/// apps it saw, so the app's store owns one value and calls `evaluate` on every tick.
public struct StatusRules: Sendable {
  private static let sustainNs: UInt64 = 60_000_000_000
  private static let calmSentence = "Plenty of memory and CPU to spare."

  private let amberOnCPU: Bool
  private var cpuBusy = false
  /// When the readings that would flip `cpuBusy` began, or nil when the run is broken.
  private var flipRunStartNs: UInt64?
  /// The apps of the last snapshot that had any. A closed snapshot has none.
  private var lastApps: [AppUsage] = []

  public init(amberOnCPU: Bool) { self.amberOnCPU = amberOnCPU }

  public mutating func evaluate(_ snapshot: Snapshot, nowNs: UInt64) -> Status {
    let totals = snapshot.totals
    if !snapshot.apps.isEmpty { lastApps = snapshot.apps }
    if amberOnCPU, let cpu = totals.cpuBusy.value { trackCPU(cpu, nowNs: nowNs) }
    if totals.pressure == .critical {
      return Status(dot: .critical, title: "Memory is very tight", sentence: memorySentence)
    }
    if let sentence = lowStorageSentence(totals, below: 20) {
      return Status(dot: .critical, title: "Storage is almost full", sentence: sentence)
    }
    if totals.pressure == .warning {
      return Status(dot: .tight, title: "Memory is tight", sentence: memorySentence)
    }
    if cpuBusy { return Status(dot: .tight, title: "Your Mac is busy", sentence: cpuSentence) }
    if let sentence = lowStorageSentence(totals, below: 10) {
      return Status(dot: .tight, title: "Storage is getting full", sentence: sentence)
    }
    return Status(dot: .calm, title: "All calm", sentence: Self.calmSentence)
  }

  /// `cpuBusy` turns on after 60 s at 0.80 or more and off after 60 s under 0.70. A reading
  /// that is not on the far side of the current state's threshold breaks the run.
  private mutating func trackCPU(_ cpu: Double, nowNs: UInt64) {
    guard cpuBusy ? cpu < 0.70 : cpu >= 0.80 else {
      flipRunStartNs = nil
      return
    }
    let start = flipRunStartNs ?? nowNs
    flipRunStartNs = start
    if nowNs - start >= Self.sustainNs {
      cpuBusy.toggle()
      flipRunStartNs = nil
    }
  }

  /// "{free} free of {total}." when free space is under 1/`divisor` of the disk. An unavailable
  /// reading is never low.
  private func lowStorageSentence(_ totals: SystemTotals, below divisor: UInt64) -> String? {
    guard let free = totals.storageFree.value, let total = totals.storageTotal.value,
      free * divisor < total
    else { return nil }
    return "\(ByteFormat.storage(free)) free of \(ByteFormat.storage(total))."
  }

  private var memorySentence: String {
    guard let top = lastApps.first else { return Self.calmSentence }
    let processes = top.processCount == 1 ? "1 process" : "\(top.processCount) processes"
    return "\(top.name) uses the most: \(ByteFormat.memory(top.memory)) across \(processes)."
  }

  /// Names the app with the largest available CPU share.
  private var cpuSentence: String {
    guard let top = lastApps.max(by: { ($0.cpu.value ?? -1) < ($1.cpu.value ?? -1) }),
      let cpu = top.cpu.value
    else { return "Your Mac is working hard." }
    return "\(top.name) is using \(PercentFormat.app(cpu)) of the CPU."
  }
}
