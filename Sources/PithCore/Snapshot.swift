public struct ProcessKey: Hashable, Sendable, Codable {
  public let pid: Int32
  public let startTime: UInt64  // µs

  public init(pid: Int32, startTime: UInt64) {
    self.pid = pid
    self.startTime = startTime
  }
}

public struct ProcessSample: Sendable, Equatable, Codable {
  public let key: ProcessKey
  public let parent: Int32
  public let uid: UInt32
  public let name: String
  public let path: String
  public let footprint: UInt64  // ri_phys_footprint, bytes
  public let cpuTimeNs: UInt64  // ri_user_time + ri_system_time, converted from Mach ticks
  public let diskRead: UInt64
  public let diskWritten: UInt64

  public init(
    key: ProcessKey, parent: Int32, uid: UInt32, name: String, path: String, footprint: UInt64,
    cpuTimeNs: UInt64, diskRead: UInt64, diskWritten: UInt64
  ) {
    self.key = key
    self.parent = parent
    self.uid = uid
    self.name = name
    self.path = path
    self.footprint = footprint
    self.cpuTimeNs = cpuTimeNs
    self.diskRead = diskRead
    self.diskWritten = diskWritten
  }
}

public struct ProcessTable: Sendable, Equatable, Codable {
  public let samples: [ProcessSample]
  public let takenAtNs: UInt64
  public let vanished: Int

  public init(samples: [ProcessSample], takenAtNs: UInt64, vanished: Int) {
    self.samples = samples
    self.takenAtNs = takenAtNs
    self.vanished = vanished
  }
}

public enum Pressure: String, Sendable, Equatable, Codable { case normal, warning, critical }

public struct SystemTotals: Sendable, Equatable, Codable {
  public let memoryUsed: UInt64
  public let memoryTotal: UInt64
  public let pressure: Pressure
  public let swapUsed: UInt64
  public let cpuBusy: Reading<Double>  // 0...1, whole machine
  public let storageFree: Reading<UInt64>
  public let storageTotal: Reading<UInt64>

  public init(
    memoryUsed: UInt64, memoryTotal: UInt64, pressure: Pressure, swapUsed: UInt64,
    cpuBusy: Reading<Double>, storageFree: Reading<UInt64>, storageTotal: Reading<UInt64>
  ) {
    self.memoryUsed = memoryUsed
    self.memoryTotal = memoryTotal
    self.pressure = pressure
    self.swapUsed = swapUsed
    self.cpuBusy = cpuBusy
    self.storageFree = storageFree
    self.storageTotal = storageTotal
  }
}

public struct AppIdentity: Sendable, Equatable {
  public let id: String  // bundle ID, else the .app path, else "proc:<name>"
  public let name: String
  public let bundlePath: String?

  public init(id: String, name: String, bundlePath: String?) {
    self.id = id
    self.name = name
    self.bundlePath = bundlePath
  }
}

public struct HelperGroup: Sendable, Equatable, Codable {
  public let label: String
  public let count: Int
  public let memory: UInt64

  public init(label: String, count: Int, memory: UInt64) {
    self.label = label
    self.count = count
    self.memory = memory
  }
}

public struct AppUsage: Sendable, Equatable, Codable, Identifiable {
  public let id: String  // bundle ID, else the .app path, else "proc:<name>"
  public let name: String
  public let bundlePath: String?
  public let pids: [Int32]
  public let processCount: Int
  public let memory: UInt64
  public let cpu: Reading<Double>  // share of the whole Mac, 0...1
  public let diskBytesPerSecond: Reading<Double>
  public let inside: [HelperGroup]

  public init(
    id: String, name: String, bundlePath: String?, pids: [Int32], processCount: Int,
    memory: UInt64, cpu: Reading<Double>, diskBytesPerSecond: Reading<Double>,
    inside: [HelperGroup]
  ) {
    self.id = id
    self.name = name
    self.bundlePath = bundlePath
    self.pids = pids
    self.processCount = processCount
    self.memory = memory
    self.cpu = cpu
    self.diskBytesPerSecond = diskBytesPerSecond
    self.inside = inside
  }
}

public struct SystemResidual: Sendable, Equatable, Codable {
  public let memory: UInt64
  public let cpu: Reading<Double>

  public init(memory: UInt64, cpu: Reading<Double>) {
    self.memory = memory
    self.cpu = cpu
  }
}

public enum GroupingQuality: String, Sendable, Equatable, Codable { case full, limited }

public enum Mode: String, Sendable, Equatable, Codable { case closed, open }

public enum Metric: Sendable, Equatable { case memory, cpu, disk }

public struct Snapshot: Sendable, Equatable, Codable {
  public let takenAtNs: UInt64
  public let mode: Mode
  public let totals: SystemTotals
  public let apps: [AppUsage]  // empty when mode == .closed
  public let system: Reading<SystemResidual>
  public let grouping: GroupingQuality

  public init(
    takenAtNs: UInt64, mode: Mode, totals: SystemTotals, apps: [AppUsage],
    system: Reading<SystemResidual>, grouping: GroupingQuality
  ) {
    self.takenAtNs = takenAtNs
    self.mode = mode
    self.totals = totals
    self.apps = apps
    self.system = system
    self.grouping = grouping
  }
}
