// Portions adapted from Stats (https://github.com/exelban/stats), MIT License,
// Copyright (c) 2020 Serhiy Mytrovtsiy. Source: Modules/Disk/readers.swift L448-L457 at v3.0.22 (1282cd5).

import Darwin
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

/// The libproc calls behind one sweep.
public struct ProcessProbe: Sendable {
  public var listPIDs: @Sendable () -> [Int32]
  public var bsdInfo: @Sendable (Int32) -> (uid: UInt32, parent: Int32, name: String)?
  public var rusage: @Sendable (Int32) -> Result<rusage_info_v6, Errno>
  public var path: @Sendable (Int32) -> String?

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
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let filled = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        guard filled == size else {
          assert(
            filled == 0 && errno == ESRCH, "proc_pidinfo(\(pid)) gave \(filled): errno \(errno)")
          return nil
        }
        let name = withUnsafeBytes(of: info.pbsi_comm) {
          String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (info.pbsi_uid, Int32(info.pbsi_ppid), name)
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
      })
  }()
}

/// Reads the user's own processes in-process: one PID listing, then the short BSD info of each
/// PID and `proc_pid_rusage` for those owned by `uid`. Paths are read once per `ProcessKey`.
public final class LibprocProcessTable: ProcessTableReading {
  private let probe: ProcessProbe
  private let uid: UInt32
  private let timebase: MachTimebase
  private let pathCache = OSAllocatedUnfairLock(initialState: [ProcessKey: String]())

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
      var seen = [ProcessKey: String](minimumCapacity: cache.count)
      var vanished = 0
      for pid in probe.listPIDs() {
        // A PID that exited before its info read has no known owner, so it is not `vanished`.
        guard let info = probe.bsdInfo(pid), info.uid == uid else { continue }
        let usage: rusage_info_v6
        switch probe.rusage(pid) {
        case .success(let value): usage = value
        case .failure(.noSuchProcess):  // exited after the listing
          vanished += 1
          continue
        case .failure(.notPermitted): continue  // changed user after the UID check
        case .failure(let code):
          assertionFailure("proc_pid_rusage(\(pid)) failed: errno \(code.rawValue)")
          continue
        }
        let start = timebase.nanoseconds(fromTicks: usage.ri_proc_start_abstime) / 1_000
        let key = ProcessKey(pid: pid, startTime: start)
        // "" when the path can't be read (a deleted executable). Cached, so it is read once.
        let path = cache[key] ?? probe.path(pid) ?? ""
        seen[key] = path
        samples.append(
          ProcessSample(
            key: key, parent: info.parent, uid: uid, name: info.name, path: path,
            footprint: usage.ri_phys_footprint,
            cpuTimeNs: timebase.nanoseconds(fromTicks: usage.ri_user_time + usage.ri_system_time),
            diskRead: usage.ri_diskio_bytesread, diskWritten: usage.ri_diskio_byteswritten))
      }
      cache = seen
      return ProcessTable(samples: samples, takenAtNs: takenAtNs, vanished: vanished)
    }
  }
}
