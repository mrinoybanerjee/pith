import System

public struct ProcessKey: Hashable, Sendable, Codable {
  public let pid: Int32
  public let startTime: UInt64  // µs

  public init(pid: Int32, startTime: UInt64) {
    self.pid = pid
    self.startTime = startTime
  }
}

/// A process and the executable it runs, so an `exec` makes a new key for the same `ProcessKey`.
struct ExecutableKey: Hashable, Sendable {
  let process: ProcessKey
  let idVersion: Int32
}

public struct ProcessSample: Sendable, Equatable, Codable {
  public let key: ProcessKey
  public let parent: Int32
  /// p_uniqueid and p_puniqueid: a parent edge holds only while they match, as a reused PID has a
  /// new unique ID (R151).
  public let uniqueID: UInt64
  public let parentUniqueID: UInt64
  public let uid: UInt32
  public let name: String
  public let path: String
  /// p_idversion. Each `exec` changes it, even of the same binary from another path, and keeps
  /// the `ProcessKey` (R140).
  public let idVersion: Int32
  public let footprint: UInt64  // ri_phys_footprint, bytes
  public let cpuTimeNs: UInt64  // ri_user_time + ri_system_time, converted from Mach ticks
  /// Bytes read plus bytes written, the kernel's total I/O. Written alone can step back or wrap: the
  /// kernel computes it as the total less bytes read, from counters it updates without a lock
  /// (R155). The wrapping sum is the total again.
  public let diskBytes: UInt64

  public init(
    key: ProcessKey, parent: Int32, uniqueID: UInt64, parentUniqueID: UInt64, uid: UInt32,
    name: String, path: String, idVersion: Int32, footprint: UInt64, cpuTimeNs: UInt64,
    diskRead: UInt64, diskWritten: UInt64
  ) {
    self.key = key
    self.parent = parent
    self.uniqueID = uniqueID
    self.parentUniqueID = parentUniqueID
    self.uid = uid
    self.name = name
    self.path = path
    self.idVersion = idVersion
    self.footprint = footprint
    self.cpuTimeNs = cpuTimeNs
    diskBytes = diskRead &+ diskWritten
  }

  /// The executable's file name, or the 16-byte kernel name when `path` is "".
  var fileName: String { FilePath(path).lastComponent?.string ?? name }

  var executableKey: ExecutableKey { ExecutableKey(process: key, idVersion: idVersion) }
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
  public let memoryUsed: Reading<UInt64>
  /// Memory used with each compressed page at its full size, as footprints count it (R133).
  public let footprintTotal: Reading<UInt64>
  public let memoryTotal: UInt64  // ProcessInfo.physicalMemory, which cannot fail
  public let pressure: Reading<Pressure>
  public let swapUsed: Reading<UInt64>
  public let cpuBusy: Reading<Double>  // 0...1, whole machine
  public let storageFree: Reading<UInt64>
  public let storageTotal: Reading<UInt64>

  public init(
    memoryUsed: Reading<UInt64>, footprintTotal: Reading<UInt64>, memoryTotal: UInt64,
    pressure: Reading<Pressure>,
    swapUsed: Reading<UInt64>, cpuBusy: Reading<Double>, storageFree: Reading<UInt64>,
    storageTotal: Reading<UInt64>
  ) {
    self.memoryUsed = memoryUsed
    self.footprintTotal = footprintTotal
    self.memoryTotal = memoryTotal
    self.pressure = pressure
    self.swapUsed = swapUsed
    self.cpuBusy = cpuBusy
    self.storageFree = storageFree
    self.storageTotal = storageTotal
  }
}

public struct AppIdentity: Sendable, Equatable {
  /// A bundled app's `.app` path, so separate installations of one app stay apart. A Chromium
  /// clone takes the id of the one installation with its bundle ID that holds its own child
  /// processes (R156), else it is "clone:" and the path of its `.app.bundle`. Any other process is
  /// "proc:" and its executable's file name (the kernel name only when `path` is "").
  public let id: String
  public let name: String
  public let bundlePath: String?
  public let bundleID: String?  // nil when there is no bundle or it cannot be read

  public init(id: String, name: String, bundlePath: String?, bundleID: String?) {
    self.id = id
    self.name = name
    self.bundlePath = bundlePath
    self.bundleID = bundleID
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
  /// A bundled app's `.app` path, so separate installations of one app stay apart. A Chromium
  /// clone takes the id of the one installation with its bundle ID that holds its own child
  /// processes (R156), else it is "clone:" and the path of its `.app.bundle`. Any other process is
  /// "proc:" and its executable's file name (the kernel name only when `path` is "").
  public let id: String
  public let name: String
  public let bundlePath: String?
  public let bundleID: String?
  public let pids: [Int32]
  public let processCount: Int
  public let memory: UInt64
  public let cpu: Reading<Double>  // share of the whole Mac, 0...1
  public let diskBytesPerSecond: Reading<Double>
  public let inside: [HelperGroup]

  public init(
    id: String, name: String, bundlePath: String?, bundleID: String?, pids: [Int32],
    processCount: Int, memory: UInt64, cpu: Reading<Double>, diskBytesPerSecond: Reading<Double>,
    inside: [HelperGroup]
  ) {
    self.id = id
    self.name = name
    self.bundlePath = bundlePath
    self.bundleID = bundleID
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
