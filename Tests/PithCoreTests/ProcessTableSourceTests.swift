import Darwin
import Foundation
import Testing
import os

@testable import PithCore

@Test func ownProcessIsPresentAndOthersAreNot() throws {
  let t = LibprocProcessTable().readTable()
  let me = try #require(t.samples.first { $0.key.pid == getpid() })
  #expect(me.footprint > 0 && me.uid == getuid())
  #expect(t.samples.allSatisfy { $0.uid == getuid() })
  #expect(!t.samples.contains { $0.key.pid == 1 })
}

@Test func liveListingReachesLaunchd() {  // launchd is the oldest process
  #expect(ProcessProbe.live.listPIDs().contains(1))
}

@Test func cpuTimeAdvances() throws {
  let src = LibprocProcessTable()
  let a = try #require(src.readTable().samples.first { $0.key.pid == getpid() })
  var x = 0.0
  for i in 0..<3_000_000 { x += Double(i).squareRoot() }
  _ = x
  let b = try #require(src.readTable().samples.first { $0.key.pid == getpid() })
  #expect(b.cpuTimeNs > a.cpuTimeNs && a.key == b.key)
}

@Test func execOfTheSameBinaryGetsANewIDVersion() throws {  // R140, on the live kernel
  // zsh prints 1, then on our newline execs /bin/zsh, which prints 2: one process, one binary.
  let input = Pipe()
  let output = Pipe()
  let zsh = Process()
  zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
  zsh.arguments = ["-fc", "echo 1; read x; exec /bin/zsh -fc 'echo 2; read x'"]
  zsh.standardInput = input
  zsh.standardOutput = output
  try zsh.run()
  func sample(after line: String) throws -> (version: Int32, uuid: UUID, start: UInt64) {
    #expect(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self) == line)
    let usage = try ProcessProbe.live.rusage(zsh.processIdentifier).get()
    let info = try #require(ProcessProbe.live.bsdInfo(zsh.processIdentifier))
    // The private layouts (R150, R151): the identity read alone agrees, and zsh's parent is us.
    #expect(ProcessProbe.live.idVersion(zsh.processIdentifier) == info.idVersion)
    #expect(info.parentUniqueID == ProcessProbe.live.bsdInfo(getpid())?.uniqueID)
    input.fileHandleForWriting.write(Data("\n".utf8))
    return (info.idVersion, UUID(uuid: usage.ri_uuid), usage.ri_proc_start_abstime)
  }
  let before = try sample(after: "1\n")
  let after = try sample(after: "2\n")
  zsh.waitUntilExit()
  #expect(after.version != before.version)
  #expect(after.uuid == before.uuid && after.start == before.start)
}

@Test func anExecBetweenTheReadsIsReadAgain() {  // R150
  // The exec lands after the info read, so the counters are the new executable's and the identity
  // read after them differs. The second read pairs the new identity with them.
  let reads = OSAllocatedUnfairLock(initialState: 0)
  var probe = ProcessProbe.fake(pids: [10], uid: 501)
  probe.bsdInfo = { _ in
    (
      501, 1, "fake",
      reads.withLock {
        $0 += 1
        return $0
      } == 1 ? 1 : 2, 10, 1
    )
  }
  probe.idVersion = { _ in 2 }
  let t = LibprocProcessTable(probe: probe, uid: 501).readTable()
  #expect(t.samples.map(\.idVersion) == [2] && reads.withLock { $0 } == 2)
}

@Test func aProcessThatExecsAtEachReadIsLeftOutThisTick() {  // R150
  let version = OSAllocatedUnfairLock(initialState: Int32(0))
  let next: @Sendable (Int32) -> Int32 = {
    $0 == 10
      ? version.withLock {
        $0 += 1
        return $0
      } : 1
  }
  var probe = ProcessProbe.fake(pids: [10, 11], uid: 501)
  probe.bsdInfo = { pid in (501, 1, "fake", next(pid), UInt64(pid), 1) }
  probe.idVersion = next
  let t = LibprocProcessTable(probe: probe, uid: 501).readTable()
  #expect(t.samples.map(\.key.pid) == [11] && t.vanished == 0)
}

@Test func vanishedProcessIsCountedNotReported() {  // Review Focus 2
  var probe = ProcessProbe.fake(pids: [10, 11], uid: 501)
  probe.rusage = { $0 == 11 ? .failure(.noSuchProcess) : .success(.fake(footprint: 1)) }
  let t = LibprocProcessTable(probe: probe, uid: 501).readTable()
  #expect(t.samples.map(\.key.pid) == [10] && t.vanished == 1)
}

@Test func pidBufferGrows() {  // Review Focus 1
  var calls = 0
  let pids = listAllPIDs(
    count: { 2_000 },
    fill: { buf, cap in
      calls += 1
      let n = min(5_000, Int(cap))
      for i in 0..<n { buf[i] = Int32(i + 1) }
      return Int32(n) == cap ? cap : Int32(n)
    })
  #expect(pids.count == 5_000 && calls >= 2)
}

@Test func otherUsersAndDeniedProcessesAreLeftOut() {
  var probe = ProcessProbe.fake(pids: [10, 11, 12], uid: 501)
  probe.bsdInfo = { ($0 == 11 ? 0 : 501, 1, "fake", 1, UInt64($0), 1) }
  probe.rusage = { $0 == 12 ? .failure(.notPermitted) : .success(.fake(footprint: 1)) }
  let t = LibprocProcessTable(probe: probe, uid: 501).readTable()
  #expect(t.samples.map(\.key.pid) == [10] && t.vanished == 0)
}

@Test func sampleConvertsTicksWithTheTimebase() throws {
  var usage = rusage_info_v6.fake(footprint: 7)
  usage.ri_proc_start_abstime = 24_000_000  // 1 s at 125/3
  usage.ri_user_time = 1_800_000
  usage.ri_system_time = 600_000  // 0.1 s together
  usage.ri_diskio_bytesread = 3
  usage.ri_diskio_byteswritten = 4
  var probe = ProcessProbe.fake(pids: [10], uid: 501)
  probe.rusage = { [usage] _ in .success(usage) }
  let table = LibprocProcessTable(
    probe: probe, uid: 501, timebase: MachTimebase(numer: 125, denom: 3))
  #expect(
    table.readTable().samples == [
      ProcessSample(
        key: ProcessKey(pid: 10, startTime: 1_000_000), parent: 1, uniqueID: 10,
        parentUniqueID: 1, uid: 501, name: "fake",
        path: "/Applications/Fake.app/Contents/MacOS/Fake", idVersion: 1,
        footprint: 7, cpuTimeNs: 100_000_000, diskRead: 3, diskWritten: 4)
    ])
}

@Test func execReadsThePathAgain() {  // an exec keeps the PID and start time: a shell runs Python
  let image = OSAllocatedUnfairLock(initialState: Int32(1))
  var probe = ProcessProbe.fake(pids: [10], uid: 501)
  probe.bsdInfo = { _ in (501, 1, "fake", image.withLock { $0 }, 10, 1) }
  probe.idVersion = { _ in image.withLock { $0 } }
  probe.path = { _ in image.withLock { $0 } == 1 ? "/bin/zsh" : "/usr/bin/python3" }
  let table = LibprocProcessTable(probe: probe, uid: 501)
  let shell = table.readTable().samples[0]
  image.withLock { $0 = 2 }
  let python = table.readTable().samples[0]
  #expect(shell.key == python.key && shell.idVersion != python.idVersion)
  #expect([shell.path, python.path] == ["/bin/zsh", "/usr/bin/python3"])
}

@Test func pathIsReadOncePerKeyAndEvictedWhenGone() {
  let pids = OSAllocatedUnfairLock(initialState: [Int32]([10, 11]))
  let reads = OSAllocatedUnfairLock(initialState: [Int32]())
  var probe = ProcessProbe.fake(pids: [], uid: 501)
  probe.listPIDs = { pids.withLock { $0 } }
  probe.path = { pid in
    reads.withLock { $0.append(pid) }
    return "/Applications/Fake.app/Contents/MacOS/Fake"
  }
  let table = LibprocProcessTable(probe: probe, uid: 501)
  _ = table.readTable()
  _ = table.readTable()  // both paths come from the cache
  pids.withLock { $0 = [10] }
  _ = table.readTable()  // 11 is evicted
  pids.withLock { $0 = [10, 11] }
  _ = table.readTable()  // so its path is read again
  #expect(reads.withLock { $0 } == [10, 11, 11])
}

@Test func unreadablePathKeepsTheSampleWithAnEmptyPath() {
  let reads = OSAllocatedUnfairLock(initialState: 0)
  var probe = ProcessProbe.fake(pids: [10], uid: 501)
  probe.path = { _ in
    reads.withLock { $0 += 1 }
    return nil
  }
  let table = LibprocProcessTable(probe: probe, uid: 501)
  _ = table.readTable()
  let t = table.readTable()
  #expect(t.samples.map(\.path) == [""] && t.vanished == 0)
  #expect(reads.withLock { $0 } == 1)  // the empty path is cached too
}

@Test func missingBSDInfoIsSkippedNotCounted() {
  var probe = ProcessProbe.fake(pids: [10, 11], uid: 501)
  probe.bsdInfo = { $0 == 11 ? nil : (501, 1, "fake", 1, UInt64($0), 1) }
  let t = LibprocProcessTable(probe: probe, uid: 501).readTable()
  #expect(t.samples.map(\.key.pid) == [10] && t.vanished == 0)
}
