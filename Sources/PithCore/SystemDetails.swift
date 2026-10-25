import Foundation
import os

public enum SystemDetailsError: Error {
  case failed(String)
}

public struct SystemProcess: Equatable, Sendable {
  public let pid: Int32
  public let name: String
  public let cpu: Double
  public let memory: UInt64  // bytes
  public let uid: UInt32
}

/// Reads the output of `top -l 2 ... -stats pid,command,cpu,mem,uid` (spec 6.7).
public enum TopParser {
  /// The rows of the second sample, in the order `top` printed them, without the rows owned by
  /// `excludingUID`. The first sample is cumulative, so it is dropped. Throws on a row it cannot
  /// read.
  static func parse(_ output: String, excludingUID: UInt32) throws -> [SystemProcess] {
    let lines = output.split(whereSeparator: \.isNewline)
    let samples = lines.indices.filter { lines[$0].hasPrefix("Processes:") }
    guard samples.count >= 2 else {
      throw SystemDetailsError.failed("top printed \(samples.count) samples, not 2")
    }
    let sample = lines[samples[1]...]
    guard let headerIndex = sample.firstIndex(where: { $0.hasPrefix("PID") }) else {
      throw SystemDetailsError.failed("top printed no column header in its second sample")
    }
    let header = sample[headerIndex].split(whereSeparator: \.isWhitespace)
    func column(_ name: Substring) throws -> Int {
      guard let index = header.firstIndex(of: name) else {
        throw SystemDetailsError.failed("top printed no \(name) column")
      }
      return index
    }
    let (pidAt, commandAt, cpuAt, memAt, uidAt) = (
      try column("PID"), try column("COMMAND"), try column("%CPU"), try column("MEM"),
      try column("UID")
    )

    return try sample[(headerIndex + 1)...].compactMap { line in
      let cells = line.split(whereSeparator: \.isWhitespace)
      // The command can hold spaces. Columns before it count from the left, columns after it
      // from the right.
      let fromRight = cells.count - header.count
      func cell(_ index: Int) -> Substring { cells[index < commandAt ? index : index + fromRight] }
      guard fromRight >= 0, let pid = Int32(cell(pidAt)), let cpu = Double(cell(cpuAt)),
        let memory = bytes(cell(memAt)), let signedUID = Int32(cell(uidAt))
      else { throw SystemDetailsError.failed("cannot read top row: \(line)") }
      // top prints the UID as a signed number: `nobody` (4294967294) is -2.
      let uid = UInt32(bitPattern: signedUID)
      guard uid != excludingUID else { return nil }
      let name = cells[commandAt...(commandAt + fromRight)].joined(separator: " ")
      return SystemProcess(pid: pid, name: name, cpu: cpu, memory: memory, uid: uid)
    }
  }

  /// "420M+" is 420 << 20. `K`, `M` and `G` are powers of 1024, a bare number is bytes, and one
  /// trailing `+` or `-` (the change since the first sample) is dropped.
  private static func bytes(_ text: Substring) -> UInt64? {
    var digits = text
    if let last = digits.last, last == "+" || last == "-" { digits.removeLast() }
    let shift: UInt64 =
      switch digits.last {
      case "K": 10
      case "M": 20
      case "G": 30
      default: 0
      }
    if shift > 0 { digits.removeLast() }
    guard let value = UInt64(digits), value <= UInt64.max >> shift else { return nil }
    return value << shift
  }
}

public struct SystemItem: Equatable, Sendable {
  public let title: String
  public let memory: UInt64
  public let explanation: String?

  public init(title: String, memory: UInt64, explanation: String?) {
    self.title = title
    self.memory = memory
    self.explanation = explanation
  }
}

public struct SystemBreakdown: Equatable, Sendable {
  /// The top 4 processes that are not the user's, by memory.
  public let items: [SystemItem]
  /// The memory of all the other processes that are not the user's.
  public let other: UInt64

  public init(items: [SystemItem], other: UInt64) {
    self.items = items
    self.other = other
  }
}

/// Measures the processes Pith cannot read itself (root and other users) with one run of
/// Apple's setuid `top`, at most once per 10 s (spec 4.4 and 6.7). This is the only child process
/// Pith starts.
public actor SystemDetails {
  /// No `-n`: top lists every process, so `other` is the true remainder.
  private static let topArguments = [
    "-l", "2", "-s", "1", "-o", "mem", "-stats", "pid,command,cpu,mem,uid",
  ]
  private static let cacheNs: UInt64 = 10_000_000_000

  private let guide: Guide
  private let run: @Sendable ([String]) async throws -> String
  private let ownUID: UInt32
  private let nowNs: @Sendable () -> UInt64
  private var cached: (atNs: UInt64, breakdown: SystemBreakdown)?
  /// The run that every `measure()` call during it waits for.
  private var inFlight: Task<SystemBreakdown, any Error>?

  public init(
    guide: Guide,
    run: @escaping @Sendable ([String]) async throws -> String = {
      try await SystemDetails.runTop($0)
    },
    ownUID: UInt32 = getuid(),
    nowNs: @escaping @Sendable () -> UInt64
  ) {
    self.guide = guide
    self.run = run
    self.ownUID = ownUID
    self.nowNs = nowNs
  }

  public func measure() async throws -> SystemBreakdown {
    if let cached, nowNs() - cached.atNs < Self.cacheNs { return cached.breakdown }
    let task = inFlight ?? Task { try await fetch() }
    inFlight = task
    return try await task.value
  }

  private func fetch() async throws -> SystemBreakdown {
    defer { inFlight = nil }
    let rows = try TopParser.parse(try await run(Self.topArguments), excludingUID: ownUID)
    let items = rows.prefix(4).map { row in
      let entry = guide.entry(name: row.name, bundleID: nil, path: nil)
      return SystemItem(
        title: entry?.title ?? row.name, memory: row.memory, explanation: entry?.explanation)
    }
    let other = rows.dropFirst(4).reduce(0) { $0 + $1.memory }
    let breakdown = SystemBreakdown(items: items, other: other)
    cached = (nowNs(), breakdown)
    return breakdown
  }

  /// Runs `/usr/bin/top` with `arguments` and returns what it printed. Throws `.failed` when top
  /// exits with a non-zero status, or when it is still running after `timeout` seconds and gets
  /// terminated.
  public static func runTop(_ arguments: [String], timeout: TimeInterval = 5) async throws
    -> String
  {
    try await withCheckedThrowingContinuation { continuation in
      // The read and the wait block, so they run on a Dispatch thread, not a Swift one.
      DispatchQueue.global().async {
        continuation.resume(with: Result { try runTopBlocking(arguments, timeout: timeout) })
      }
    }
  }

  private static func runTopBlocking(_ arguments: [String], timeout: TimeInterval) throws
    -> String
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    try pipe.fileHandleForWriting.close()  // else the read below never sees the end of the output

    let timedOut = OSAllocatedUnfairLock(initialState: false)
    let stop = DispatchWorkItem {
      timedOut.withLock { $0 = true }
      process.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
    // Reading while top runs keeps its output from filling the pipe and blocking it.
    let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    stop.cancel()

    guard process.terminationStatus == 0 else {
      throw SystemDetailsError.failed(
        timedOut.withLock { $0 }
          ? "top did not finish in \(timeout) s"
          : "top exited with status \(process.terminationStatus)")
    }
    return String(decoding: output, as: UTF8.self)
  }
}
