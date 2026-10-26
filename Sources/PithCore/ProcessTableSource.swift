// Portions adapted from Stats (https://github.com/exelban/stats), MIT License,
// Copyright (c) 2020 Serhiy Mytrovtsiy. Source: Modules/Disk/readers.swift L448-L457 at v3.0.22 (1282cd5).

import Darwin
import Foundation
import System
import os

public protocol ProcessTableReading: Sendable {
  func readTable() -> ProcessTable
}

/// Lists PIDs into a buffer of `count()` PIDs. The buffer doubles until `fill` returns fewer PIDs
/// than it holds, so a large table is never cut short.
public func listAllPIDs(
  count: () -> Int32, fill: (UnsafeMutablePointer<Int32>, Int32) -> Int32
) -> [Int32] {
  var capacity = count()
  precondition(capacity > 0, "PID buffer capacity \(capacity)")
  while true {
    let pids = [Int32](unsafeUninitializedCapacity: Int(capacity)) { buffer, filled in
      filled = Int(fill(buffer.baseAddress!, capacity))
      precondition(filled >= 0, "listing PIDs failed: errno \(errno)")
    }
    if pids.count < capacity { return pids }
    capacity *= 2
  }
}

/// xnu's `struct proc_uniqidentifierinfo` (bsd/sys/proc_info.h), private in the SDK, laid out as the
/// kernel copies it. Its own flavor checks no owner.
private struct UniqueIdentifierInfo {
  static let flavor: Int32 = 17  // PROC_PIDUNIQIDENTIFIERINFO
  var uuid: (UInt64, UInt64) = (0, 0)  // p_uuid, the Mach-O UUID that copies of a binary share
  var uniqueID: UInt64 = 0  // p_uniqueid: an exec keeps it, and a reused PID has a new one
  var parentUniqueID: UInt64 = 0  // p_puniqueid, the parent's p_uniqueid
  var idVersion: Int32 = 0  // p_idversion: new at every exec, even of the same binary (R140)
  var reserved: UInt32 = 0
  var reserved2: (UInt64, UInt64) = (0, 0)
}

/// xnu's `struct proc_bsdinfowithuniqid`: the BSD info, then the unique identifiers. Unlike the
/// short BSD info, the kernel refuses it (EPERM) for another user's process unless the caller is
/// root: the same check `proc_pid_rusage` makes.
private struct BSDInfoWithUniqueID {
  static let flavor: Int32 = 18  // PROC_PIDT_BSDINFOWITHUNIQID
  var bsd = proc_bsdinfo()
  var unique = UniqueIdentifierInfo()
}

/// The libproc calls behind one sweep.
public struct ProcessProbe: Sendable {
  public var listPIDs: @Sendable () -> [Int32]
  /// nil for a process that exited or is another user's. `idVersion` is `p_idversion`, and the
  /// unique IDs are `p_uniqueid` and `p_puniqueid`.
  public var bsdInfo:
    @Sendable (Int32) -> (
      uid: UInt32, parent: Int32, name: String, idVersion: Int32, uniqueID: UInt64,
      parentUniqueID: UInt64
    )?
  /// `p_idversion` alone, or nil for a process that exited (R150).
  public var idVersion: @Sendable (Int32) -> Int32?
  public var rusage: @Sendable (Int32) -> Result<rusage_info_v6, Errno>
  public var path: @Sendable (Int32) -> String?
  /// The process that sweeps, which every table holds (R158).
  public var ownPID: Int32

  public static let live: ProcessProbe = {
    // The buffer size that fit last time carries over, so a steady sweep lists once.
    let processCount = proc_listallpids(nil, 0)
    precondition(processCount > 0, "proc_listallpids(nil, 0) failed: errno \(errno)")
    let pidCapacity = OSAllocatedUnfairLock(initialState: processCount)
    return ProcessProbe(
      listPIDs: {
        pidCapacity.withLock { capacity in
          listAllPIDs(count: { capacity }) { buffer, size in
            capacity = size
            return proc_listallpids(buffer, size * Int32(MemoryLayout<Int32>.size))
          }
        }
      },
      bsdInfo: { pid in
        var info = BSDInfoWithUniqueID()
        let size = Int32(MemoryLayout<BSDInfoWithUniqueID>.size)
        let filled = proc_pidinfo(pid, BSDInfoWithUniqueID.flavor, 0, &info, size)
        guard filled == size else {
          // Any other result, such as a changed layout, would skip every process (R158).
          precondition(
            filled == 0 && (errno == ESRCH || errno == EPERM),
            "proc_pidinfo(\(pid)) gave \(filled): errno \(errno)")
          return nil
        }
        let name = withUnsafeBytes(of: info.bsd.pbi_comm) {
          String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (
          info.bsd.pbi_uid, Int32(info.bsd.pbi_ppid), name, info.unique.idVersion,
          info.unique.uniqueID, info.unique.parentUniqueID
        )
      },
      idVersion: { pid in
        var info = UniqueIdentifierInfo()
        let size = Int32(MemoryLayout<UniqueIdentifierInfo>.size)
        let filled = proc_pidinfo(pid, UniqueIdentifierInfo.flavor, 0, &info, size)
        guard filled == size else {
          precondition(
            filled == 0 && errno == ESRCH, "proc_pidinfo(\(pid)) gave \(filled): errno \(errno)")
          return nil
        }
        return info.idVersion
      },
      rusage: { pid in
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) {
          $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
          }
        }
        return result == 0 ? .success(usage) : .failure(Errno(rawValue: errno))
      },
      path: { pid in
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
      },
      ownPID: getpid())
  }()
}

/// Reads the user's own processes in-process: one PID listing, then the BSD info of each PID, and
/// `proc_pid_rusage` and the identity again for those owned by `uid`. Paths are read once per
/// `ExecutableKey`, so again after an `exec`.
public final class LibprocProcessTable: ProcessTableReading {
  private let probe: ProcessProbe
  private let uid: UInt32
  private let timebase: MachTimebase
  private let pathCache = OSAllocatedUnfairLock(initialState: [ExecutableKey: String]())

  public init(
    probe: ProcessProbe = .live, uid: UInt32 = getuid(), timebase: MachTimebase = .current
  ) {
    self.probe = probe
    self.uid = uid
    self.timebase = timebase
  }

  public func readTable() -> ProcessTable {
    pathCache.withLock { cache in
      let takenAtNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      var samples: [ProcessSample] = []
      samples.reserveCapacity(cache.count)
      var seen = [ExecutableKey: String](minimumCapacity: cache.count)
      var vanished = 0
      for pid in probe.listPIDs() {
        // An exec between the reads would pair one executable's identity with another's counters,
        // so a process whose identity changed is read once more, and one that changes again is
        // left out of this tick (R150).
        var result = read(pid, cache)
        if case .execed = result { result = read(pid, cache) }
        switch result {
        case .sample(let s):
          seen[s.executableKey] = s.path
          samples.append(s)
        case .vanished: vanished += 1
        case .skipped, .execed: continue
        }
      }
      // Pith's own process is always its user's. A table without it means that the listing failed
      // (proc_listallpids returns 0 then) or that every read did (R158).
      precondition(
        samples.contains { $0.key.pid == probe.ownPID },
        "the sweep found no own process (PID \(probe.ownPID)) in \(samples.count) samples")
      cache = seen
      return ProcessTable(samples: samples, takenAtNs: takenAtNs, vanished: vanished)
    }
  }

  private enum Read {
    case sample(ProcessSample)
    /// Another user's PID, one that exited before its info read (no known owner, so not
    /// `vanished`), or a denied read.
    case skipped
    /// It exited after the listing.
    case vanished
    /// Its identity changed during the reads (R150).
    case execed
  }

  /// One process's info, counters and path, in that order, then its identity again (R150).
  private func read(_ pid: Int32, _ cache: [ExecutableKey: String]) -> Read {
    guard let info = probe.bsdInfo(pid), info.uid == uid else { return .skipped }
    let usage: rusage_info_v6
    switch probe.rusage(pid) {
    case .success(let value): usage = value
    case .failure(.noSuchProcess): return .vanished
    case .failure(.notPermitted): return .skipped  // changed user after the UID check
    case .failure(let code):
      preconditionFailure("proc_pid_rusage(\(pid)) failed: errno \(code.rawValue)")
    }
    let start = timebase.nanoseconds(fromTicks: usage.ri_proc_start_abstime) / 1_000
    let key = ProcessKey(pid: pid, startTime: start)
    // "" when the path can't be read (a deleted executable). Read once per executable.
    let path =
      cache[ExecutableKey(process: key, idVersion: info.idVersion)] ?? probe.path(pid) ?? ""
    guard probe.idVersion(pid) == info.idVersion else { return .execed }
    return .sample(
      ProcessSample(
        key: key, parent: info.parent, uniqueID: info.uniqueID,
        parentUniqueID: info.parentUniqueID, uid: uid, name: info.name, path: path,
        idVersion: info.idVersion, footprint: usage.ri_phys_footprint,
        cpuTimeNs: timebase.nanoseconds(fromTicks: usage.ri_user_time + usage.ri_system_time),
        diskRead: usage.ri_diskio_bytesread, diskWritten: usage.ri_diskio_byteswritten))
  }
}
