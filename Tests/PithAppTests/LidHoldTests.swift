import Foundation
import Testing

@testable import Pith

/// What a stand-in lid hold did: the flag clears that Pith made, and the `ended` calls.
@MainActor private final class Counts {
  var clears = 0
  var ends = 0
}

/// A lid hold whose copy is a shell that writes its PID to a new file, then reads its input to the
/// end, as `--hold-lid` does. It never sets the real flag.
@MainActor private func standIn(_ counts: Counts) -> (hold: LidHold, pidFile: URL) {
  let pidFile = FileManager.default.temporaryDirectory.appending(path: "pith.tests.\(UUID()).pid")
  let hold = LidHold.process(
    URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec cat > /dev/null"], hasLid: true,
    clear: { counts.clears += 1 })
  return (hold, pidFile)
}

/// The PID that the copy wrote, once it differs from `old`.
@MainActor private func copyPID(in pidFile: URL, not old: pid_t = 0) async throws -> pid_t {
  func read() -> pid_t? {
    (try? String(contentsOf: pidFile, encoding: .utf8))
      .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .flatMap { $0 == old ? nil : $0 }
  }
  for _ in 0..<200 where read() == nil { try await Task.sleep(for: .milliseconds(10)) }
  return try #require(read())
}

private func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// Waits up to 2 s for `condition`, letting the main actor run.
@MainActor private func within2s(_ condition: () -> Bool) async throws -> Bool {
  for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
  return condition()
}

/// Awake spec 4.2: `stop` clears the flag in Pith and ends the copy, which then never calls
/// `ended`. A child that Pith starts after the copy does not keep the copy's input open.
@MainActor @Test func stopClearsTheFlagAndEndsTheCopy() async throws {
  let counts = Counts()
  let (hold, pidFile) = standIn(counts)
  defer { try? FileManager.default.removeItem(at: pidFile) }
  hold.start { counts.ends += 1 }
  let pid = try await copyPID(in: pidFile)
  let later = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
  defer { later.terminate() }
  hold.stop()
  #expect(counts.clears == 1)
  #expect(try await within2s { !isRunning(pid) })
  try await Task.sleep(for: .milliseconds(100))
  #expect(counts.clears == 1 && counts.ends == 0)
}

/// Awake spec 4.2: a copy that dies makes Pith clear the flag and call `ended`, once. One that
/// dies just before `stop` costs nothing: no SIGPIPE, one clear, and no `ended`.
@MainActor @Test func aCopyThatDiesIsClearedOnce() async throws {
  let counts = Counts()
  let (hold, pidFile) = standIn(counts)
  defer { try? FileManager.default.removeItem(at: pidFile) }
  hold.start { counts.ends += 1 }
  let first = try await copyPID(in: pidFile)
  kill(first, SIGKILL)
  #expect(try await within2s { counts.ends == 1 })
  #expect(counts.clears == 1)

  hold.start { counts.ends += 1 }
  let second = try await copyPID(in: pidFile, not: first)
  kill(second, SIGKILL)
  // A busy wait holds the main actor, so Pith hears of the exit only after `stop`.
  for _ in 0..<2000 where isRunning(second) { usleep(1000) }
  #expect(!isRunning(second))
  hold.stop()
  try await Task.sleep(for: .milliseconds(200))
  #expect(counts.clears == 2 && counts.ends == 1)
}
